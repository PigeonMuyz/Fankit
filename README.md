# Fankit

A native Swift and SwiftUI fan monitor for Apple silicon Macs. The project is
being built as an open-source replacement for Intel-only fan utilities before
general-purpose Rosetta support ends after macOS 27.

## Current status

- Universal `arm64` + `x86_64` macOS app
- Live AppleSMC fan RPM, fan limits, and temperature readings
- Main window plus a compact menu bar panel for essential readings and control
- Customizable menu bar content and SF Symbol icon
- English, Japanese, Cantonese, and Mandarin localizations
- Signed native root helper embedded with the app
- Working System and Max control paths after one-time macOS approval
- Auto Boost temperature curves with live interpolation and per-fan targets
- Quiet, Balanced, Cool, and Sustained Work presets
- A dedicated Curve Editor with click-to-adjust chart controls
- Multiple named custom presets with 2–8 points, persisted locally
- AI Scheduling with up to 24 hours of local System observation, prompt export,
  strict JSON import, preview, and safe curve activation

## Build and run

Open `Fankit.xcodeproj` in Xcode, or run:

```sh
./script/build_and_run.sh
```

Run the localization completeness audit with:

```sh
./script/i18n_verify.py
```

The project targets macOS 14 (Sonoma) and newer on Apple silicon. On first use, click
**Enable Control** and approve Fankit under **System Settings → General →
Login Items & Extensions** if macOS asks. Monitoring remains available without
the helper. After an app update, Fankit asks the authenticated old helper to
restore System mode and exit, then lets launchd start the updated helper without
changing the existing approval switch.

## Release build

Create a local Release app and a drag-to-install DMG with:

```sh
./script/build_release_dmg.sh 1.0.7
```

The output is written to `dist/Fankit-1.0.7.dmg` together with its SHA-256
checksum. The script automatically selects the local code-signing identity that
matches the currently registered Fankit helper, or you can choose
one explicitly with `SIGNING_IDENTITY=<identity>`. If several identities exist
and no prior Fankit registration identifies the correct team, the script stops
instead of silently changing developer teams and invalidating the user's prior
approval.
The version argument is written to both `CFBundleShortVersionString` and the
monotonically increasing `CFBundleVersion`, so Service Management can recognize
the new helper registration as an app update.
The app still needs one-time approval under **System Settings → General →
Login Items & Extensions**. A notarized distribution still requires a
Developer ID signature and the owner's Apple Developer credentials.

Fankit's Updates settings checks the repository's latest non-prerelease GitHub
Release. Release DMGs should keep the `Fankit-<version>.dmg` name and include
either GitHub's asset `sha256:` digest or a matching `.dmg.sha256` asset. Fankit
verifies that digest before opening the downloaded installer.

## Signing for open-source builds

A paid Apple Developer Program membership is not required to build and test the
project from source. Select your free Personal Team under Signing & Capabilities
for both the `Fankit` and `FankitHelper` targets. Xcode creates an Apple
Development certificate for that team. The helper reads its own Team ID at
runtime and accepts only the main app with the same Team ID and expected bundle
identifier, so contributors do not need to hard-code their certificate name.

An Apple Development signature is intended for local development. Distributing
a prebuilt app that other people can launch without rebuilding still requires a
Developer ID signature and notarization. Contributors without a paid membership
can build with their own Personal Team.

## Safety

AppleSMC fan writes are undocumented and hardware-sensitive. The app never
writes fan keys from the regular UI process. The helper exposes only System,
Max, and bounded fixed-RPM operations—never arbitrary SMC keys. Requested RPMs
are clamped to the fan's reported hardware range.

Auto Boost uses the hottest valid processor, graphics, or memory sensor. Below
the first point of the selected curve, it leaves the fans in System mode. Above
that threshold it applies linear interpolation, ramps up faster than it ramps
down, and uses a 2°C return hysteresis. At 100°C it requests maximum cooling.
Missing sensor data or any helper failure stops Auto Boost and restores System
mode.

Before taking manual ownership, the helper writes a recovery marker. It restores
System mode and clears that marker when the app disconnects, its 15-second lease
expires, it receives a termination signal, or it restarts after an interrupted
override. Sleep resets Apple Silicon's SMC control state in firmware; reconnecting
after wake starts from System mode.

## License

Fankit is released under the [MIT License](LICENSE).
