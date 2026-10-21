# WaveBird

A macOS app that connects Nintendo Switch 2 controllers over Bluetooth LE and
exposes them through a cemuhook/DSU server. DSU clients such as Dolphin and Cemu
can read up to four logical pads; Ryujinx can consume their motion data.

Switch 2 controllers don't pair via the standard Bluetooth Security Manager
Protocol and don't expose HID over GATT — they speak Nintendo's proprietary
profile over a vendor BLE service. macOS therefore can't pair or use them
natively. WaveBird connects via CoreBluetooth, parses the proprietary report
format into a canonical state, and serves it at `127.0.0.1:26760` over UDP.
DSU is the default output and does not require Accessibility permission or the
restricted virtual-HID entitlement.

## Status

Early. Currently supports:

- **Nintendo Switch 2 GameCube Controller (NSO)** over Bluetooth LE —
  analog sticks, all face/shoulder buttons, D-pad, Rumble and Motion
- **Nintendo Switch 2 Pro Controller** over Bluetooth LE — analog sticks,
  all buttons including Home and Capture, Rumble and Motion
- **Nintendo Switch 2 Joy-Con (L / R)** over Bluetooth LE — used as a merged
  L + R DSU pad, or each side on its own DSU slot.
  Sticks, all buttons, Rumble and Motion. Attach the second side and WaveBird
  forms the pair automatically; split them back into solo controllers anytime.
- **Bluetooth pairing** — WaveBird remembers controllers across launches, so
  after the first pair you reconnect by pressing any button instead of holding
  SYNC. Remembered controllers stay visible (offline) in the list.

Not yet supported: Charging Grip and USB connections.

## Install

1. Download the latest `WaveBird-<version>.dmg` from the
   [Releases page](https://github.com/murphyjt/wavebird/releases/latest).
2. Open the DMG and drag **WaveBird.app** to **Applications**.

The app is signed and notarized by Apple, so it launches without a Gatekeeper
warning. You can also check for updates from within the app
(*WaveBird → Check for Updates…*).

### Verifying the download

Each release DMG carries a SLSA build-provenance attestation. To verify it was
built by this repo's release workflow before installing:

```sh
gh attestation verify --repo murphyjt/wavebird WaveBird-<version>.dmg
```

## Controller mappings and legacy HID profiles

Open a controller card and use the "Use profile" picker on the General tab to
choose its button-mapping profile. Built-in profiles retain the existing HID
presentation names because they also define the available mapping controls:

| Profile | Rumble | Motion | Notes |
|---|---|---|---|
| **Switch Pro Controller** | ✅ | ✅ | Recommended |
| **DualShock 4** | ✅ | ❌ | |
| **DualSense** | ✅ | ❌ | |
| **Xbox Wireless Controller** | ✅ | — | Recommended |

The selection persists per-controller (by serial) across reconnects, and can
be changed while the controller is offline. Custom button mappings feed DSU
output. The listed HID presentations remain compiled for compatibility, but
this build omits the restricted virtual-HID entitlement; DSU remains the
default and silent fallback.

The General tab also has a Sticks section for inverting the left and/or right
stick Y-axis. Per-controller rumble tuning (intensity, preset, per-band
frequency and amplitude) lives on the Haptics tab. All controller settings
persist per controller (by serial), so each physical controller carries its
own configuration across re-pairings.

DSU pads do not appear as macOS game controllers. Configure your emulator to use
the DSU server at `127.0.0.1:26760`. A merged Joy-Con pair uses one slot; split
Joy-Cons use two slots with distinct identities. The server supports four
logical pads total.

## Requirements

- macOS 26.0 or newer
- Xcode 26 or newer (Swift 6.2)

## Build

```sh
xcodebuild -project WaveBird.xcodeproj -scheme WaveBird -configuration Debug build
```

Or open `WaveBird.xcodeproj` in Xcode and run.

## Permissions

WaveBird needs Bluetooth access to scan for and connect to controllers. macOS
may prompt automatically, or you can grant it manually:

**System Settings → Privacy & Security → Bluetooth** — required to scan for and
connect to controllers.

If a permission prompt appears, click **Allow**. If WaveBird is listed but
unchecked, check it and relaunch.

The default DSU backend does not request Accessibility access. DSU uses the
loopback network listener on `127.0.0.1:26760`; if another process owns that
port, WaveBird will still connect and pair controllers, but DSU output is
unavailable until the port is free.

## Use

1. Launch the app — it begins scanning automatically.
2. Hold the SYNC button on your controller until the LEDs flash. (If you've
   paired it before, just press any button.)
3. WaveBird discovers and connects; the controller appears in the device list
   once it's ready.
4. On the first connect of a new controller, WaveBird asks whether to pair it.
   Accepting writes a long-term key to both sides so future reconnects don't
   need SYNC. **Pairing overwrites the controller's Nintendo Switch 2 console
   pairing** — to use it on the console again you'll need to hold SYNC there.
5. Click the controller card to open its settings — pick a virtual gamepad
  mapping profile, invert stick axes (General), or tune rumble (Haptics). Use the
   "Forget This Device…" button to drop WaveBird's record of a pairing; the
   controller keeps its stored key until you pair it with something else.

DSU input is consumed by compatible emulators and tools; it is not presented to
macOS Game Controller or browser Gamepad APIs by default.

## Credits

- [BlueRetro](https://github.com/darthcloud/BlueRetro) by darthcloud — protocol
  reference for Switch 2 controllers (Apache 2.0).
- [switch2_controller_research](https://github.com/ndeadly/switch2_controller_research)
  by ndeadly — detailed write-ups of the Switch 2 BLE / HID protocol.
- [SDL](https://github.com/libsdl-org/SDL) — `SDL_hidapi_switch2.c` for the
  factory trigger-calibration flash layout and the NS2 LRA `EncodeHDRumble`
  bit packing; `SDL_hidapi_switch.c` for the Switch 1 Pro Controller
  subcommand handshake the Switch Pro presentation emulates, and the NS1 HD
  Rumble amplitude table we invert to decode the presentation's incoming
  rumble (zlib).
- [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering)
  — write-up of the Switch 1 Bluetooth HID protocol (subcommand IDs, report
  0x30 button/stick layout) used by the Switch Pro presentation, and the
  `rumble_data_table.md` amplitude curve we use to decode NS1 HD Rumble
  bytes back into 16-bit amplitudes before re-encoding for NS2 LRA.

## License

MIT — see [LICENSE](LICENSE).
