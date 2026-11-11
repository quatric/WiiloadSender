package com.quatricsoftware.homebrewsender

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.Deflater
import kotlin.coroutines.coroutineContext

sealed interface SendProgress {
    data object Connecting : SendProgress
    data class Sending(val fraction: Double) : SendProgress
    data object Finished : SendProgress
}

class SendException(message: String) : IOException(message)

/**
 * Implements the wiiload protocol (Wii / Wii U, port 4299) and the netloader
 * protocol shared by 3dslink (3DS, port 17491) and nxlink (Switch, port 28280).
 */
object HomebrewClient {
    private const val VERSION_MAJOR = 0
    private const val VERSION_MINOR = 5
    private const val WIILOAD_CHUNK = 128 * 1024
    private const val LINK_CHUNK = 16 * 1024
    private const val CONNECT_TIMEOUT_MS = 10_000
    private const val READ_TIMEOUT_MS = 30_000

    /** zlib (RFC 1950) stream at level 6, matching `compress2` in devkitPro's wiiload. */
    fun deflate(source: ByteArray, level: Int = 6): ByteArray {
        if (source.isEmpty()) return ByteArray(0)
        val deflater = Deflater(level)
        try {
            deflater.setInput(source)
            deflater.finish()
            val out = ByteArrayOutputStream(source.size / 2 + 64)
            val buf = ByteArray(64 * 1024)
            while (!deflater.finished()) {
                val n = deflater.deflate(buf)
                out.write(buf, 0, n)
            }
            return out.toByteArray()
        } finally {
            deflater.end()
        }
    }

    /** `filename\0` followed by each space-separated argument and a `\0`. */
    fun wiiloadArgumentBuffer(fileName: String, arguments: String): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(fileName.toByteArray(Charsets.UTF_8)); out.write(0)
        splitArgs(arguments).forEach { out.write(it.toByteArray(Charsets.UTF_8)); out.write(0) }
        return out.toByteArray()
    }

    private fun splitArgs(arguments: String) = arguments.split(' ').filter { it.isNotEmpty() }

    private fun openSocket(host: String, port: Int): Socket {
        val trimmed = host.trim()
        if (trimmed.isEmpty() || port !in 1..65535) throw SendException("Enter a valid IP address.")
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = READ_TIMEOUT_MS
            socket.connect(InetSocketAddress(trimmed, port), CONNECT_TIMEOUT_MS)
        } catch (e: IOException) {
            socket.close()
            throw SendException("Connection failed: ${e.localizedMessage ?: e.javaClass.simpleName}")
        }
        return socket
    }

    suspend fun sendWiiload(
        fileData: ByteArray, fileName: String, arguments: String,
        host: String, port: Int, progress: (SendProgress) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val argBuffer = wiiloadArgumentBuffer(fileName, arguments)
        val compressed = deflate(fileData)

        val header = ByteArrayOutputStream(16).apply {
            write("HAXX".toByteArray(Charsets.US_ASCII))
            write(VERSION_MAJOR)
            write(VERSION_MINOR)
            writeBE16(minOf(argBuffer.size, 0xFFFF))
            writeBE32(compressed.size)
            writeBE32(fileData.size)
        }.toByteArray()

        openSocket(host, port).use { socket ->
            progress(SendProgress.Connecting)
            val out = socket.getOutputStream()
            wrapIO {
                out.write(header)
                writeChunked(out, compressed, WIILOAD_CHUNK, prefixLength = false, progress)
                out.write(argBuffer)
                out.flush()
                socket.shutdownOutput()
            }
        }
        progress(SendProgress.Finished)
    }

    suspend fun sendLink(
        fileData: ByteArray, fileName: String, platform: Platform, arguments: String,
        host: String, port: Int, progress: (SendProgress) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val compressed = deflate(fileData)

        openSocket(host, port).use { socket ->
            progress(SendProgress.Connecting)
            val out = socket.getOutputStream()
            val input = DataInputStream(socket.getInputStream())
            wrapIO {
                val nameBytes = fileName.toByteArray(Charsets.UTF_8)
                val head = ByteArrayOutputStream().apply {
                    writeLE32(nameBytes.size); write(nameBytes); writeLE32(fileData.size)
                }.toByteArray()
                out.write(head); out.flush()

                val status = readLE32(input)
                if (status != 0) {
                    val reason = when (status) {
                        -1 -> "the console couldn't create the file"
                        -2 -> "the console has insufficient space"
                        -3 -> "the console has insufficient memory"
                        else -> "error code $status"
                    }
                    throw SendException("Rejected: $reason.")
                }

                writeChunked(out, compressed, LINK_CHUNK, prefixLength = true, progress)
                out.flush()
                readLE32(input)

                // 3dslink prepends argv[0]; nxlink sends only the user's arguments.
                val args = ByteArrayOutputStream()
                if (platform == Platform.DS3) {
                    args.write("sdmc:/3ds/$fileName".toByteArray(Charsets.UTF_8)); args.write(0)
                }
                splitArgs(arguments).forEach { args.write(it.toByteArray(Charsets.UTF_8)); args.write(0) }
                val tail = ByteArrayOutputStream().apply {
                    writeLE32(args.size()); write(args.toByteArray())
                }.toByteArray()
                out.write(tail); out.flush()
            }
        }
        progress(SendProgress.Finished)
    }

    private suspend fun writeChunked(
        out: OutputStream, data: ByteArray, chunk: Int, prefixLength: Boolean,
        progress: (SendProgress) -> Unit,
    ) {
        var offset = 0
        while (offset < data.size) {
            coroutineContext.ensureActive()
            val len = minOf(chunk, data.size - offset)
            if (prefixLength) out.write(le32(len))
            out.write(data, offset, len)
            offset += len
            progress(SendProgress.Sending(offset.toDouble() / data.size))
        }
    }

    private inline fun <T> wrapIO(block: () -> T): T = try {
        block()
    } catch (e: SendException) {
        throw e
    } catch (e: IOException) {
        throw SendException("Connection failed: ${e.localizedMessage ?: e.javaClass.simpleName}")
    }

    private fun readLE32(input: DataInputStream): Int {
        val b = ByteArray(4)
        try {
            input.readFully(b)
        } catch (e: IOException) {
            throw SendException("No response from the console.")
        }
        return (b[0].toInt() and 0xff) or ((b[1].toInt() and 0xff) shl 8) or
            ((b[2].toInt() and 0xff) shl 16) or ((b[3].toInt() and 0xff) shl 24)
    }

    private fun le32(v: Int) = byteArrayOf(v.toByte(), (v ushr 8).toByte(), (v ushr 16).toByte(), (v ushr 24).toByte())
    private fun ByteArrayOutputStream.writeLE32(v: Int) = write(le32(v))
    private fun ByteArrayOutputStream.writeBE16(v: Int) { write(v ushr 8 and 0xff); write(v and 0xff) }
    private fun ByteArrayOutputStream.writeBE32(v: Int) {
        write(v ushr 24 and 0xff); write(v ushr 16 and 0xff); write(v ushr 8 and 0xff); write(v and 0xff)
    }

    // ---- LAN discovery ----

    /** All usable host addresses on the Wi-Fi/Ethernet subnet (capped to a /22), excluding our own. */
    fun localSubnetHosts(): List<String> {
        data class Candidate(val name: String, val ip: Long, val prefix: Int)

        val candidates = mutableListOf<Candidate>()
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        } catch (e: Exception) {
            emptyList()
        }
        for (nif in interfaces) {
            val up = try { nif.isUp && !nif.isLoopback && !nif.isVirtual } catch (e: Exception) { false }
            if (!up) continue
            val name = nif.name ?: continue
            if (!(name.startsWith("wlan") || name.startsWith("eth") || name.startsWith("ap") ||
                    name.startsWith("swlan") || name.startsWith("en"))) continue
            for (ia in nif.interfaceAddresses) {
                val addr = ia.address as? Inet4Address ?: continue
                val b = addr.address
                val ip = ((b[0].toLong() and 0xff) shl 24) or ((b[1].toLong() and 0xff) shl 16) or
                    ((b[2].toLong() and 0xff) shl 8) or (b[3].toLong() and 0xff)
                if (ip ushr 16 == 0xA9FEL) continue // link-local
                candidates += Candidate(name, ip, ia.networkPrefixLength.toInt())
            }
        }
        val best = candidates.firstOrNull { it.name.startsWith("wlan") }
            ?: candidates.firstOrNull { it.name.startsWith("eth") }
            ?: candidates.firstOrNull() ?: return emptyList()

        val prefix = maxOf(best.prefix, 22)
        if (prefix > 30) return emptyList()
        val mask = (0xFFFFFFFFL shl (32 - prefix)) and 0xFFFFFFFFL
        val network = best.ip and mask
        val broadcast = network or (mask.inv() and 0xFFFFFFFFL)
        if (broadcast <= network + 1) return emptyList()

        // Probe neighbours of our own address first: consoles often get nearby DHCP leases.
        return ((network + 1) until broadcast)
            .filter { it != best.ip }
            .sortedBy { kotlin.math.abs(it - best.ip) }
            .map { h -> "${h ushr 24}.${(h ushr 16) and 255}.${(h ushr 8) and 255}.${h and 255}" }
    }

    /** Scans the local subnet for a listener on [port]. Returns the first match. */
    suspend fun scan(port: Int, timeoutMs: Int = 1500): String? = withContext(Dispatchers.IO) {
        val hosts = localSubnetHosts()
        if (hosts.isEmpty()) return@withContext null
        val found = AtomicReference<String?>(null)
        val gate = Semaphore(96)
        coroutineScope {
            hosts.map { ip ->
                async {
                    gate.withPermit {
                        if (found.get() == null && probe(ip, port, timeoutMs)) found.compareAndSet(null, ip)
                    }
                }
            }.forEach { it.await() }
        }
        found.get()
    }

    private fun probe(host: String, port: Int, timeoutMs: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs); true }
    } catch (e: Exception) {
        false
    }
}
