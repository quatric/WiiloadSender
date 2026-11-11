package com.quatricsoftware.homebrewsender

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.DataInputStream
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.Inflater
import kotlin.concurrent.thread
import kotlin.random.Random

/** Exercises both protocols against in-process listeners that parse them like the consoles do. */
class HomebrewClientTest {
    private val payload = Random(42).nextBytes(300_000) + ByteArray(200_000) // mix of random and compressible

    private fun inflate(data: ByteArray, size: Int): ByteArray {
        val inf = Inflater()
        inf.setInput(data)
        val out = ByteArray(size)
        var n = 0
        while (!inf.finished()) n += inf.inflate(out, n, size - n)
        inf.end()
        assertEquals(size, n)
        return out
    }

    @Test
    fun wiiload() {
        ServerSocket(0).use { server ->
            var header = ByteArray(0); var body = ByteArray(0); var args = ByteArray(0)
            val t = thread {
                server.accept().use { s ->
                    val input = DataInputStream(s.getInputStream())
                    header = ByteArray(16).also { input.readFully(it) }
                    val bb = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN)
                    val argLen = bb.getShort(6).toInt() and 0xffff
                    val cLen = bb.getInt(8)
                    body = ByteArray(cLen).also { input.readFully(it) }
                    args = ByteArray(argLen).also { input.readFully(it) }
                    assertEquals(-1, input.read())
                }
            }
            var last: SendProgress? = null
            runBlocking {
                HomebrewClient.sendWiiload(payload, "boot.dol", "-a  b", "127.0.0.1", server.localPort) { last = it }
            }
            t.join()
            assertEquals("HAXX", String(header, 0, 4))
            assertEquals(0, header[4].toInt()); assertEquals(5, header[5].toInt())
            assertEquals(payload.size, ByteBuffer.wrap(header).getInt(12))
            assertArrayEquals(payload, inflate(body, payload.size))
            assertEquals("boot.dol\u0000-a\u0000b\u0000", String(args))
            assertEquals(SendProgress.Finished, last)
        }
    }

    private fun linkServer(platform: Platform, status: Int = 0): Triple<String, ByteArray, String> {
        ServerSocket(0).use { server ->
            var name = ""; var data = ByteArray(0); var args = ""
            val t = thread {
                server.accept().use { s ->
                    val input = DataInputStream(s.getInputStream())
                    val out = s.getOutputStream()
                    fun le32(): Int { val b = ByteArray(4); input.readFully(b); return ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).int }
                    fun send32(v: Int) = out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array())
                    val nameLen = le32()
                    name = String(ByteArray(nameLen).also { input.readFully(it) })
                    val size = le32()
                    send32(status)
                    if (status != 0) return@thread
                    val inf = Inflater(); val result = ByteArray(size); var got = 0
                    while (got < size) {
                        val chunk = ByteArray(le32()).also { input.readFully(it) }
                        inf.setInput(chunk)
                        while (!inf.needsInput() && got < size) got += inf.inflate(result, got, size - got)
                    }
                    data = result
                    send32(0)
                    args = String(ByteArray(le32()).also { input.readFully(it) })
                }
            }
            try {
                runBlocking {
                    HomebrewClient.sendLink(payload, "app.3dsx", platform, "x y", "127.0.0.1", server.localPort) {}
                }
            } finally {
                t.join()
            }
            return Triple(name, data, args)
        }
    }

    @Test
    fun link3ds() {
        val (name, data, args) = linkServer(Platform.DS3)
        assertEquals("app.3dsx", name)
        assertArrayEquals(payload, data)
        assertEquals("sdmc:/3ds/app.3dsx\u0000x\u0000y\u0000", args)
    }

    @Test
    fun linkSwitch() {
        val (_, data, args) = linkServer(Platform.NX)
        assertArrayEquals(payload, data)
        assertEquals("x\u0000y\u0000", args)
    }

    @Test(expected = SendException::class)
    fun linkRejected() {
        linkServer(Platform.NX, status = -2)
    }

    @Test
    fun subnetHostsAreBounded() {
        val hosts = HomebrewClient.localSubnetHosts()
        assert(hosts.size <= 1022)
    }
}
