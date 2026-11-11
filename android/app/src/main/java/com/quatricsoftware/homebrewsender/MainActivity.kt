package com.quatricsoftware.homebrewsender

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) viewModel.handleIntent(intent)
        setContent {
            val dark = when (viewModel.settings.appearance) {
                AppearanceMode.SYSTEM -> isSystemInDarkTheme()
                AppearanceMode.LIGHT -> false
                AppearanceMode.DARK -> true
            }
            LaunchedEffect(dark) {
                val style = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT)
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            }
            HomebrewSenderTheme(dark) { MainScreen(viewModel) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        viewModel.handleIntent(intent)
    }
}

@Composable
fun HomebrewSenderTheme(dark: Boolean, content: @Composable () -> Unit) {
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(vm: MainViewModel) {
    val settings = vm.settings
    val context = LocalContext.current
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var showUrlPrompt by rememberSaveable { mutableStateOf(false) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) vm.loadFile(uri)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Homebrew Sender") },
                actions = {
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Section("Console") {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    Platform.entries.forEachIndexed { i, p ->
                        SegmentedButton(
                            selected = settings.platform == p,
                            onClick = { settings.updatePlatform(p) },
                            shape = SegmentedButtonDefaults.itemShape(i, Platform.entries.size),
                            enabled = !vm.status.isBusy,
                        ) { Text(p.label, maxLines = 1) }
                    }
                }
            }

            Section("${settings.platform.label} Address") {
                OutlinedTextField(
                    value = settings.lastIPAddress,
                    onValueChange = { settings.updateIPAddress(it.trim()) },
                    placeholder = { Text("e.g. 192.168.1.42") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedButton(
                    onClick = { vm.scan() },
                    enabled = !vm.isScanning && !vm.status.isBusy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (vm.isScanning) SmallSpinner() else Icon(Icons.Default.Search, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (vm.isScanning) "Scanning…" else "Scan for ${settings.platform.label}")
                }
            }

            Section("File") {
                OutlinedButton(
                    onClick = { picker.launch(arrayOf("*/*")) },
                    enabled = !vm.status.isBusy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Default.Add, null)
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            vm.fileName.ifEmpty { "Choose a file to send" },
                            maxLines = 1,
                        )
                        if (vm.fileSize > 0) {
                            Text(
                                Formatter.formatShortFileSize(context, vm.fileSize.toLong()) +
                                    if (settings.arguments.isEmpty()) "" else " · ${settings.arguments}",
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 1,
                            )
                        }
                    }
                }

                if (vm.fileName.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            onClick = { vm.removeSelection() },
                            enabled = !vm.status.isBusy,
                            modifier = Modifier.weight(1f),
                        ) {
                            Icon(Icons.Default.Close, null)
                            Spacer(Modifier.width(6.dp))
                            Text("Remove")
                        }
                        vm.sharedFileUri?.let { uri ->
                            OutlinedButton(
                                onClick = {
                                    val send = Intent(Intent.ACTION_SEND).apply {
                                        type = "application/octet-stream"
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    context.startActivity(Intent.createChooser(send, "Share ${vm.fileName}"))
                                },
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(Icons.Default.Share, null)
                                Spacer(Modifier.width(6.dp))
                                Text("Share")
                            }
                        }
                    }
                }

                OutlinedButton(
                    onClick = { showUrlPrompt = true },
                    enabled = !vm.isDownloading && !vm.status.isBusy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (vm.isDownloading) {
                        SmallSpinner()
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(if (vm.isDownloading) "Downloading…" else "Load from URL")
                }
            }

            Button(
                onClick = { vm.send() },
                enabled = vm.canSend,
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                if (vm.status.isBusy) {
                    SmallSpinner(MaterialTheme.colorScheme.onPrimary)
                    Spacer(Modifier.width(8.dp))
                }
                Text(sendButtonTitle(vm.status, settings.platform), fontWeight = FontWeight.SemiBold)
            }
            (vm.status as? SendStatus.Sending)?.let {
                LinearProgressIndicator(progress = { it.fraction.toFloat() }, modifier = Modifier.fillMaxWidth())
            }
            StatusFooter(vm.status, vm.errorMessage, settings.platform)
        }
    }

    if (showSettings) SettingsDialog(settings) { showSettings = false }
    if (showUrlPrompt) UrlDialog(
        onDismiss = { showUrlPrompt = false },
        onDownload = { showUrlPrompt = false; vm.download(it) },
    )
}

private fun sendButtonTitle(status: SendStatus, platform: Platform) = when (status) {
    SendStatus.Idle, SendStatus.Failure -> "Send to ${platform.label}"
    SendStatus.Connecting -> "Connecting…"
    is SendStatus.Sending -> "Sending… ${(status.fraction * 100).toInt()}%"
    SendStatus.Success -> "Sent!"
}

@Composable
private fun StatusFooter(status: SendStatus, error: String?, platform: Platform) {
    when (status) {
        SendStatus.Success -> Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.CheckCircle, null, tint = Color(0xFF2E9E4F))
            Spacer(Modifier.width(6.dp))
            Text("File sent successfully.", color = Color(0xFF2E9E4F))
        }
        SendStatus.Failure -> Row(verticalAlignment = Alignment.Top) {
            Icon(Icons.Default.Warning, null, tint = MaterialTheme.colorScheme.error)
            Spacer(Modifier.width(6.dp))
            Text(error ?: "Something went wrong.", color = MaterialTheme.colorScheme.error)
        }
        else -> Text(
            platform.hint,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { content() }
        }
    }
}

@Composable
private fun SmallSpinner(color: Color = MaterialTheme.colorScheme.primary) {
    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = color)
}

@Composable
private fun UrlDialog(onDismiss: () -> Unit, onDownload: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Load from URL") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Enter a link to the file you want to send.")
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    placeholder = { Text("https://example.com/file") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                )
            }
        },
        confirmButton = { TextButton(onClick = { onDownload(text) }) { Text("Download") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun SettingsDialog(settings: AppSettings, onDismiss: () -> Unit) {
    var portText by remember { mutableStateOf(settings.port.toString()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Settings") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(settings.platform.protocolName, style = MaterialTheme.typography.labelLarge)
                OutlinedTextField(
                    value = settings.arguments,
                    onValueChange = { settings.updateArguments(it) },
                    label = { Text("Arguments") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                )
                OutlinedTextField(
                    value = portText,
                    onValueChange = { v ->
                        val digits = v.filter(Char::isDigit).take(5)
                        portText = digits
                        digits.toIntOrNull()?.let { settings.updatePort(it) }
                    },
                    label = { Text("Port") },
                    isError = portText.toIntOrNull()?.let { it !in 1..65535 } ?: true,
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                Text(
                    "Arguments are passed to the program (space-separated). Default port is ${settings.platform.defaultPort}.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text("Appearance", style = MaterialTheme.typography.labelLarge)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    AppearanceMode.entries.forEachIndexed { i, mode ->
                        SegmentedButton(
                            selected = settings.appearance == mode,
                            onClick = { settings.updateAppearance(mode) },
                            shape = SegmentedButtonDefaults.itemShape(i, AppearanceMode.entries.size),
                        ) { Text(mode.label, maxLines = 1) }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}
