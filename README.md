# Homebrew Sender

A small iOS and Android app (Wii, Wii U, 3DS and Switch) for sending `.dol` / `.elf` homebrew builds to a Wii or Wii U
running the Homebrew Channel (or any other [wiiload](https://github.com/devkitPro/wiiload)
listener) over your local network — no need for a laptop in the room.

## Features

- Choose your console: Wii / Wii U (wiiload, port 4299), 3DS (3dslink, port 17491) or Switch (nxlink, port 28280)
- "Scan" finds the console on your Wi-Fi subnet automatically
- Share the loaded file from inside the app

- Enter the console's IP address (remembered between launches)
- Pick a `.dol`/`.elf` from Files, or send one straight from Safari/AirDrop/etc. via "Open In"
- Implements the real wiiload TCP protocol (port 4299): `HAXX` header + zlib-compressed
  payload, using the system's real zlib (`compress2`) linked via a bridging header —
  not a reimplementation
- Light/Dark/System appearance toggle

## Requirements

- iOS: Xcode 15+, iOS 16+
- Android: JDK 17, Android SDK 35, Android 7.0+ (API 24) device

## Building

**iOS:** open `HomebrewSender.xcodeproj` in Xcode, select your signing team, and run.

**Android:** the app lives in `android/` (Kotlin + Jetpack Compose).

```sh
cd android
./gradlew assembleRelease   # app/build/outputs/apk/release/app-release.apk
./gradlew testDebugUnitTest # protocol tests against mock wiiload/3dslink/nxlink listeners
```

On Android, files can be picked from the system file picker, opened from another app
("Open with"), or shared to Homebrew Sender from the share sheet (files or links).
Compression uses `java.util.zip.Deflater`, which is backed by the platform's zlib.

## Protocol notes

The header layout and compression scheme were verified against devkitPro's
reference [`wiiload` source](https://github.com/devkitPro/wiiload/blob/master/source/main.c)
rather than reimplemented from memory.
