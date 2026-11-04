# Contributing to Louder

Thanks for helping. Louder is a small project with one hard rule: it must never make it easier to hurt someone's ears.

## Build and test

Requirements: macOS 15+, the Xcode toolchain (Swift 6). There is no Xcode project; everything goes through SwiftPM and the Makefile.

```sh
make test      # run the unit tests (swift test)
make app       # build build/Louder.app (universal, ad-hoc signed)
make run       # build and open build/Louder.app
make install   # build and copy Louder.app to /Applications
make dmg       # build the DMG, zip and SHA-256 checksums in build/
```

Run `make` on its own to list every target. Plain SwiftPM works too: `swift build` and `swift test`.

`louder-cli` exercises the engine without the app:

```sh
swift run louder-cli --list       # output devices and the safety profile each one gets
swift run louder-cli --selftest   # starts and stops the engine with its output silent; you hear no change
swift run louder-cli --boost 3    # boosts for real until you type q and press Return
```

The CLI needs the System Audio Recording permission for your terminal app, not for Louder. `--selftest` never asks for it and only checks that audio callbacks run, so it reports PASSED even when the terminal lacks the permission and the tap hears only silence.

Do not enable boosting while you are wearing headphones that are turned up. Start with a low system volume when trying changes by hand.

## Project layout

| Path | What lives there |
| --- | --- |
| `Sources/LouderEngine` | The audio engine library: `BoostEngine` (state and lifecycle), `BoostProcessor` (DSP and safety profiles), `HAL` (output devices), `AudioCapturePermission` |
| `Sources/Louder` | The menu bar app |
| `Sources/louder-cli` | Command line tool for exercising the engine |
| `Tests/LouderEngineTests` | Unit tests for the engine |
| `Resources/` | `Info.plist` for the app bundle |
| `Brand/` | Icons, logo, hero image, brand notes |
| `scripts/` | App bundling, DMG, install and uninstall scripts |
| `.github/workflows/` | CI and release builds |
| `docs/` | Extra documentation |

## Safety-critical code

This code protects people's hearing:

- `SafetyProfile` and `BoostProcessor` in `BoostProcessor.swift`: caps, loudness ceilings, the -1 dBFS peak ceiling, ramp rates, the limiter and the feedback detector.
- `OutputDevice.classify` in `HAL.swift`: it decides whether a device gets the headphone or the speaker profile.
- `BoostEngine.swift`: self-exclusion from the tap, teardown order, the stall watchdog, the restart limit and the feedback safety stop.

Rules for changing it:

- Every change needs tests that show the safety property still holds.
- Never raise a cap (+6 dB headphones, +12 dB speakers), a loudness ceiling (-14 / -10 dBFS RMS) or the -1 dBFS peak ceiling, never speed up the 3 dB/s ramp-up, and never move a kind of device from the headphone profile to the speaker profile, without opening an issue and discussing it first. Pull requests that do this won't be merged without that discussion.
- Failing open matters: when anything goes wrong, normal audio must come back. Do not add paths that leave the original audio muted.
- Louder must keep excluding its own process from the tap and refuse to start if it cannot.

## Pull requests

- Keep each PR focused on one change.
- Run `make test` before opening it, and say how you tried the change by hand if it touches audio.
- Add tests for new behavior and state transitions.
- Follow the existing style. Prefer self-explanatory code; comment only non-obvious constraints.
- Update `CHANGELOG.md` for user-visible changes.
- Do not add a kernel extension, a virtual audio driver, or any network access. Louder runs entirely on your Mac.

## Reporting problems

Open an issue at https://github.com/luizParreira/louder/issues with your macOS version, the output device (and whether it is Bluetooth), whether the panel showed it as Headphones or Speakers, and what you heard. For anything that sounds like a safety bug (too loud, boost not backing off, headphones shown as Speakers), say so in the title.
