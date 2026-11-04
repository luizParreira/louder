# Changelog

All notable changes to Louder are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-04

Initial release.

### Added

- Menu bar app that boosts system audio past 100%, using Core Audio process taps. Requires macOS 15.
- Per-device boost caps: +6 dB for headphones and unrecognized devices, +12 dB for built-in, HDMI, DisplayPort and AirPlay speakers and other devices named as speakers, displays or TVs.
- Loudness guard, peak limiter (-1 dBFS ceiling), boost ramping (up at most 3 dB/s, always from 0 dB), and a feedback detector that turns Louder off.
- Fail-open teardown and automatic restart when the output device disconnects or changes, its sample rate, source or channel layout changes, or audio stops flowing; Louder stays off after more than 5 restarts in 30 seconds.
- Output picker (follow the system output or pin a device) and launch at login.
- Turns off before sleep and back on after wake, and remembers boost, output and on/off state.
- One-line installer and uninstaller scripts; ad-hoc signed universal builds as DMG and zip.

[1.0.0]: https://github.com/luizParreira/louder/releases/tag/v1.0.0
