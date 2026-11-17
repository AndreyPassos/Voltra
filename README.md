# Voltra

**Your Mac. Your Sound.**

Voltra is a native macOS menu bar app for managing system audio, per-app volume, and audio devices. It is built with SwiftUI and Core Audio and has no external dependencies.

> Voltra is an early release. The current development installer is for Apple Silicon and is not notarized. Review the device and audio limitations below before using it as your primary audio manager.

## Features

- **System audio** — adjust and mute the default output when the device exposes writable controls.
- **Per-app mixer** — adjust volume and mute active applications, choose an output, and remember settings between sessions. Automatic control is enabled by default and can be disabled in Settings.
- **Audio devices** — select default input and output devices, set preferred devices, and automatically switch on connection or disconnection.
- **Profiles** — save devices, system volume, mute, and app settings. Changes are saved to the active profile. At least one profile is always retained.
- **Automations** — apply settings when a device connects, an app opens, or a daily schedule is reached.
- **Menu bar access** — control audio and switch profiles without keeping the main window open.
- **English and Portuguese** — choose a language in Settings or follow the system language. Other system languages fall back to English.

## Requirements

- macOS 14.2 or later.
- System audio recording permission for per-app control. macOS may request this permission when a Process Tap starts.
- The provided development installer contains an **arm64** executable. An Intel release has not been tested.

## Build and run

From the project directory:

```sh
./build-app.sh
open build/Voltra.app
```

The script signs the app ad hoc by default. To use a development identity already in your keychain:

```sh
VOLTRA_SIGN_IDENTITY="Apple Development: Name (TEAMID)" ./build-app.sh
```

A stable signing identity can reduce permission prompts caused by signature changes, but does not guarantee that macOS will retain a grant. To build a separate app bundle without replacing the current one:

```sh
VOLTRA_BUILD_OUTPUT=build/candidate/Voltra.app ./build-app.sh
```

Closing the main window leaves Voltra running in the menu bar. Choose **Quit Voltra** from the menu to exit.

## Development installer

```sh
VOLTRA_SIGN_IDENTITY="Apple Development: Name (TEAMID)" ./build-installer.sh
```

This creates `build/Voltra-0.1.0-macOS.dmg`. Open the image and drag Voltra to Applications. Without a signing identity, the build uses an ad hoc signature.

The DMG is a development build and has not been notarized. Gatekeeper may prevent it from opening on other Macs. Public distribution requires a Developer ID Application signature, Hardened Runtime, and Apple notarization.

## Calls and audio behavior

When Core Audio reports that an app with active output is also using audio input, Voltra keeps that app on its native audio path and hides its individual volume, mute, and output controls. Use the system volume during this period. Saved app settings are retained and can resume when input activity stops.

This behavior was checked during a WhatsApp test call. Detection uses system process metadata, so it can also apply to apps using input outside a call. A transition can take until the next refresh.

Calling apps can also ask macOS to attenuate other audio. This may occur without changing the values shown in Voltra. Voltra does not currently override another app's ducking policy. See Apple's [voice processing session](https://developer.apple.com/videos/play/wwdc2023/10235/).

## Audio and device limitations

Per-app mixing uses private Core Audio Process Taps and aggregate devices. The standard path accepts interleaved stereo Float32 input and mono or stereo Float32 output with one output stream. If rates differ on a Bluetooth output-only device, a separate output-only AUHAL bridge can convert compatible stereo audio; unsupported formats are rejected. This fallback was tested with QCY MeloBuds Pro at a 48 kHz capture rate and 44.1 kHz output, and does not enable the audio unit input. It has not been validated with every Bluetooth device or over long sessions.

Physical output devices that expose input in the same Core Audio device are rejected for per-app capture to avoid inadvertently opening a microphone. Virtual duplex outputs use AUHAL with input disabled. The virtual bridge negotiates the capture rate with the output unit and preloads 2,048 frames, adding approximately 43 ms at 48 kHz. A 44.1 to 48 kHz conversion was tested with Microsoft Teams Audio. Other virtual drivers, perceived latency, and long-duration stability require further validation.

Only applications with active audio processes appear in the mixer. Some helper processes may not be attributed to their parent app. If a selected app output disconnects, Voltra waits for it instead of silently choosing another output.

A session is rebuilt after supported process or device changes. Failed starts receive up to two automatic retries, followed by a manual retry. A Core Audio call can block during initialization, including in a test on this Mac. The UI reports a prolonged wait but cannot cancel that system call. Individual control has not yet been validated as reliable in every configuration.

System volume and mute require writable controls on the output device. Some devices, including HDMI outputs, do not expose them. See Apple's [Process Tap documentation](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

## Devices, profiles, and automations

Preferred input and output devices are stored separately by UID. After startup or a device-list change, automatic switching waits 1.5 seconds before selecting each available preferred device. If one is unavailable, Voltra chooses a compatible internal device when possible and restores the preference after reconnection. Manual default-device changes remain in place until the next applicable device event, startup, or re-enabling automatic switching.

Some Bluetooth headsets expose different input and output UIDs. Voltra associates them only when the identifiers match an unambiguous pattern. Otherwise, select the input manually. Bluetooth headsets can change profile and audio quality while their microphone is in use. Input and output changes are separate operations and can fail independently.

The active profile is restored when its devices are available. Changes to devices, system volume, mute, and app settings update that profile without changing other profiles. Automations support device connection, app launch, and a daily time, in that priority order when events coincide. The app must be running. Daily schedules recover the most recent occurrence after sleep, but do not recover events missed while Voltra was closed.

Device notifications are optional. The local mute shortcut is ⇧⌘M. Settings also offers a global mute shortcut using ⌃⌥⌘M, ⌃⌥⌘V, or ⌃⌥⌘S, and reports registration conflicts. Automation history keeps the latest 50 executions.

## Testing

Run the standard suite:

```sh
swift test
```

Optional integration tests can temporarily change Mac audio settings or play a generated tone. Test preferences use isolated domains.

```sh
# Device selection and restoration
VOLTRA_HARDWARE_TEST=1 swift test --filter HardwareIntegrationTests

# Current output volume and mute, restored afterward
VOLTRA_HARDWARE_VOLUME_TEST=1 swift test --filter HardwareIntegrationTests

# Process Tap gain, mute, and signal checks
VOLTRA_TAP_TEST=1 swift test --filter ProcessTapIntegrationTests

# App-launch automation
VOLTRA_AUTOMATION_TEST=1 VOLTRA_TAP_TEST=1 swift test --filter ProcessTapIntegrationTests

# Temporary login item and global shortcut
VOLTRA_LOGIN_TEST=1 swift test --filter LoginItemIntegrationTests
VOLTRA_HOTKEY_TEST=1 swift test --filter GlobalShortcutTests

# Refusal of a physical output with integrated input
VOLTRA_TAP_DUPLEX=1 VOLTRA_TAP_TEST=1 swift test --filter ProcessTapIntegrationTests

# Independent gain and mute for two audio processes
./scripts/test-concurrent.sh
```

For the Process Tap test, `VOLTRA_TAP_OUTPUT=default` selects the default output; otherwise it uses internal speakers. `VOLTRA_TAP_HFP=1` tests a headset with its microphone as the default input and restores the previous input afterward. The test process and Voltra may need separate audio permissions.

QCY headset disconnection and reconnection were observed with Voltra running, including preferred input and output fallback. Tests of buffers and generated signals do not replace listening tests, long-duration testing, or validation across all devices. Launch at login still requires a real login test with the installed app.

See [validation details](docs/VALIDACAO.md) and [development progress](docs/PROGRESSO.md) for test evidence and remaining work.

## Project

Built with SwiftUI, Core Audio, and native macOS frameworks.

**Voltra** by CaffeeeLabs.
