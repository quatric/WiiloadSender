package com.quatricsoftware.homebrewsender

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder

sealed interface SendStatus {
    data object Idle : SendStatus
    data object Connecting : SendStatus
    data class Sending(val fraction: Double) : SendStatus
    data object Success : SendStatus
    data object Failure : SendStatus

    val isBusy: Boolean get() = this is Connecting || this is Sending
}

class MainViewModel(app: Application) : AndroidViewModel(app) {
    val settings = AppSettings(app)

    var fileData by mutableStateOf<ByteArray?>(null)
        private set
    var fileName by mutableStateOf("")
        private set
    var fileSize by mutableStateOf(0)
        private set
    var sharedFileUri by mutableStateOf<Uri?>(null)
        private set

    var isScanning by mutableStateOf(false)
        private set
    var isDownloading by mutableStateOf(false)
        private set
    var status by mutableStateOf<SendStatus>(SendStatus.Idle)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    val canSend: Boolean
        get() = fileData != null &&
            settings.lastIPAddress.isNotBlank() &&
            !status.isBusy && !isScanning && !isDownloading &&
            settings.port in 1..65535

    private fun fail(message: String) {
        errorMessage = message
        status = SendStatus.Failure
    }

    private fun resetStatus() {
        errorMessage = null
        status = SendStatus.Idle
    }

    /** Handles VIEW / SEND intents from other apps (files, or links to download). */
    fun handleIntent(intent: Intent?) {
        intent ?: return
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { openUri(it) }
            Intent.ACTION_SEND -> {
                val stream: Uri? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (stream != null) {
                    openUri(stream)
                } else {
                    intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()?.let { text ->
                        val link = Regex("""https?://\S+""").find(text)?.value
                        if (link != null) download(link) else fail("That doesn't look like a file or a link.")
                    }
                }
            }
        }
    }

    private fun openUri(uri: Uri) {
        when (uri.scheme?.lowercase()) {
            "http", "https" -> download(uri.toString())
            else -> loadFile(uri)
        }
    }

    fun loadFile(uri: Uri) {
        resetStatus()
        viewModelScope.launch {
            try {
                val (data, name) = withContext(Dispatchers.IO) {
                    val resolver = getApplication<Application>().contentResolver
                    val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
                        ?: throw IOException("The file couldn't be opened.")
                    bytes to displayName(uri)
                }
                setSelection(data, name)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                fail("Couldn't read that file: ${e.localizedMessage ?: e.javaClass.simpleName}")
            }
        }
    }

    private fun displayName(uri: Uri): String {
        if (uri.scheme == "content") {
            try {
                getApplication<Application>().contentResolver
                    .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { c -> if (c.moveToFirst()) c.getString(0)?.let { if (it.isNotBlank()) return it } }
            } catch (_: Exception) {
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "file"
    }

    fun download(urlText: String) {
        val trimmed = urlText.trim()
        val url = try {
            URL(trimmed).takeIf { it.protocol.equals("http", true) || it.protocol.equals("https", true) }
        } catch (_: Exception) {
            null
        }
        if (url == null) {
            fail("Enter a valid http(s) URL.")
            return
        }
        isDownloading = true
        resetStatus()
        viewModelScope.launch {
            try {
                val (data, name) = withContext(Dispatchers.IO) { fetch(url) }
                setSelection(data, name)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                fail("Download failed: ${e.localizedMessage ?: e.javaClass.simpleName}")
            } finally {
                isDownloading = false
            }
        }
    }

    private fun fetch(url: URL): Pair<ByteArray, String> {
        val conn = url.openConnection() as HttpURLConnection
        try {
            conn.instanceFollowRedirects = true
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            val code = conn.responseCode
            if (code !in 200..299) throw IOException("The server responded with HTTP $code.")
            val data = conn.inputStream.use { it.readBytes() }
            var name = conn.getHeaderField("Content-Disposition")?.let(::filenameFromDisposition)
                ?: conn.url.path.substringAfterLast('/').let {
                    try { URLDecoder.decode(it, "UTF-8") } catch (_: Exception) { it }
                }
            if (name.isBlank() || name == "/") name = "download"
            return data to name
        } finally {
            conn.disconnect()
        }
    }

    private fun filenameFromDisposition(header: String): String? {
        Regex("""filename\*\s*=\s*(?:UTF-8'')?([^;]+)""", RegexOption.IGNORE_CASE).find(header)?.let {
            return try { URLDecoder.decode(it.groupValues[1].trim('"', ' '), "UTF-8") } catch (_: Exception) { null }
        }
        return Regex("""filename\s*=\s*"?([^";]+)"?""", RegexOption.IGNORE_CASE).find(header)
            ?.groupValues?.get(1)?.trim()?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
    }

    private suspend fun setSelection(data: ByteArray, name: String) {
        val safeName = name.replace('/', '_').ifBlank { "file" }
        fileData = data
        fileName = safeName
        fileSize = data.size
        // Keep a cache copy so the loaded file can be shared from inside the app.
        sharedFileUri = withContext(Dispatchers.IO) {
            try {
                val app = getApplication<Application>()
                val dir = File(app.cacheDir, "shared")
                dir.deleteRecursively()
                dir.mkdirs()
                val copy = File(dir, safeName)
                copy.writeBytes(data)
                FileProvider.getUriForFile(app, "${app.packageName}.files", copy)
            } catch (_: Exception) {
                null
            }
        }
    }

    fun clearSelection() {
        fileData = null
        fileName = ""
        fileSize = 0
        sharedFileUri = null
    }

    fun removeSelection() {
        clearSelection()
        resetStatus()
    }

    fun send() {
        val data = fileData ?: return
        val platform = settings.platform
        val name = fileName
        val args = settings.arguments
        val host = settings.lastIPAddress
        val port = settings.port
        errorMessage = null
        status = SendStatus.Connecting
        viewModelScope.launch {
            val onProgress: (SendProgress) -> Unit = { p ->
                viewModelScope.launch(Dispatchers.Main.immediate) {
                    when (p) {
                        SendProgress.Connecting -> status = SendStatus.Connecting
                        is SendProgress.Sending -> if (status.isBusy) status = SendStatus.Sending(p.fraction)
                        SendProgress.Finished -> Unit
                    }
                }
            }
            try {
                if (platform.usesLinkProtocol) {
                    HomebrewClient.sendLink(data, name, platform, args, host, port, onProgress)
                } else {
                    HomebrewClient.sendWiiload(data, name, args, host, port, onProgress)
                }
                status = SendStatus.Success
                clearSelection()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                fail(e.localizedMessage ?: "Something went wrong.")
            }
        }
    }

    fun scan() {
        isScanning = true
        resetStatus()
        val platform = settings.platform
        viewModelScope.launch {
            val found = HomebrewClient.scan(settings.port)
            isScanning = false
            if (found != null) {
                settings.updateIPAddress(found)
            } else {
                fail("No ${platform.label} found on this network. ${platform.hint} Also make sure this device is connected to Wi-Fi.")
            }
        }
    }
}
