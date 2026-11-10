# Homebrew Sender

A small iOS app (Wii, Wii U, 3DS and Switch) for sending `.dol` / `.elf` homebrew builds to a Wii or Wii U
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

- Xcode 15+
- iOS 16+

## Building

Open `HomebrewSender.xcodeproj` in Xcode, select your signing team, and run.

## Protocol notes

The header layout and compression scheme were verified against devkitPro's
reference [`wiiload` source](https://github.com/devkitPro/wiiload/blob/master/source/main.c)
rather than reimplemented from memory.
