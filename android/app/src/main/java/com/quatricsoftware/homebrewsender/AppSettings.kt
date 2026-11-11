package com.quatricsoftware.homebrewsender

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

enum class AppearanceMode(val label: String) {
    SYSTEM("System"), LIGHT("Light"), DARK("Dark")
}

enum class Platform(
    val label: String,
    val defaultPort: Int,
    val protocolName: String,
    val hint: String,
) {
    WII(
        "Wii", 4299, "wiiload",
        "Start the Homebrew Channel on your Wii (it waits for a connection) and join the same Wi-Fi network.",
    ),
    WII_U(
        "Wii U", 4299, "wiiload",
        "Start the Homebrew Launcher on your Wii U (with the wiiload/network loader enabled) on the same Wi-Fi network.",
    ),
    DS3(
        "3DS", 17491, "3dslink",
        "Open the Homebrew Launcher on your 3DS and press Y to start the NetLoader.",
    ),
    NX(
        "Switch", 28280, "nxlink",
        "Open the Homebrew Menu on your Switch and press Y to start NetLoader.",
    );

    val usesLinkProtocol: Boolean get() = this == DS3 || this == NX
}

/** Persistent settings backed by SharedPreferences, exposed as Compose state. */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var lastIPAddress by mutableStateOf(prefs.getString(KEY_IP, "") ?: "")
        private set
    var platform by mutableStateOf(
        Platform.entries.getOrElse(prefs.getInt(KEY_PLATFORM, 0)) { Platform.WII }
    )
        private set
    var port by mutableStateOf(
        prefs.getInt(KEY_PORT, 0).takeIf { it in 1..65535 } ?: platform.defaultPort
    )
        private set
    var arguments by mutableStateOf(prefs.getString(KEY_ARGS, "") ?: "")
        private set
    var appearance by mutableStateOf(
        AppearanceMode.entries.getOrElse(prefs.getInt(KEY_APPEARANCE, 0)) { AppearanceMode.SYSTEM }
    )
        private set

    fun updateIPAddress(value: String) {
        lastIPAddress = value
        prefs.edit().putString(KEY_IP, value).apply()
    }

    fun updatePlatform(value: Platform) {
        if (value == platform) return
        platform = value
        prefs.edit().putInt(KEY_PLATFORM, value.ordinal).apply()
        updatePort(value.defaultPort)
    }

    fun updatePort(value: Int) {
        port = value
        prefs.edit().putInt(KEY_PORT, value).apply()
    }

    fun updateArguments(value: String) {
        arguments = value
        prefs.edit().putString(KEY_ARGS, value).apply()
    }

    fun updateAppearance(value: AppearanceMode) {
        appearance = value
        prefs.edit().putInt(KEY_APPEARANCE, value.ordinal).apply()
    }

    private companion object {
        const val KEY_IP = "lastIPAddress"
        const val KEY_PLATFORM = "platform"
        const val KEY_PORT = "port"
        const val KEY_ARGS = "arguments"
        const val KEY_APPEARANCE = "appearanceMode"
    }
}
