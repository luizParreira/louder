# How Louder works

macOS has no built-in way to go past 100% system volume. Louder gets there without a driver.

## Signal path

1. Louder creates a Core Audio **process tap** (an API available since macOS 14.2; Louder requires macOS 15) that captures the audio every other app sends to the output device you chose.
2. The tap mutes that original audio, but only while the tap exists.
3. Louder applies the boost and plays the result to the same device through a private aggregate device.

There is no kernel extension and no virtual audio driver. Nothing leaves your Mac.

## Headphones or speakers

Each output device gets a safety profile. Louder decides which one from the device name and its connection type, in this order:

1. Every Bluetooth device is **Headphones**, whatever its name.
2. A name containing headphone, AirPods, buds, headset or earphone means **Headphones**.
3. The built-in output is **Speakers** only when its current source is the internal speakers, and **Headphones** otherwise.
4. HDMI, DisplayPort and AirPlay outputs are **Speakers**.
5. Anything else (USB and other wired devices) is **Speakers** if its name contains speaker or display, and **Headphones** otherwise.

When in doubt Louder picks Headphones, the more conservative profile. The panel shows which profile is in use. If you pinned a device in the Output picker and it is not connected, Louder does not start and says so; it never boosts a different device than the one you picked.

| Profile | Maximum boost | Loudness ceiling | Peak ceiling |
| --- | --- | --- | --- |
| Headphones | +6 dB | -14 dBFS RMS | -1 dBFS |
| Speakers | +12 dB | -10 dBFS RMS | -1 dBFS |

## Safety

| Protection | Behavior |
| --- | --- |
| Cap | The boost never goes past the profile's maximum, whatever the slider asks for. |
| Loudness guard | Louder measures the short-term RMS level of the incoming audio and lowers the boost so that level plus the boost stays under the profile's loudness ceiling. Quiet content gets the full boost; already-loud content gets little or none. |
| Peak limiter | A stereo-linked limiter, followed by a hard clamp, keeps every output sample at or below -1 dBFS. |
| Ramping | Boost rises at most 3 dB/s, drops instantly when audio gets louder (a 5 ms level detector), holds during silence, and starts from 0 dB every time Louder starts or restarts. |
| Feedback detector | If the measured input level stays above -4 dBFS for 0.3 s, Louder silences its output and turns itself off. |
| Self-exclusion | Louder excludes its own process from the tap, so it never captures its own output. If it cannot identify its own process, it refuses to start. |
| Fail open | Louder tears everything down, so normal audio returns immediately, and then starts again after a short pause when the boosted device disconnects or disappears, the default output changes (when following the system output), the device's sample rate, output source or channel layout changes, or audio stops flowing for about 1.5 s (5 s while a session is first starting up). After more than 5 restarts in 30 seconds it stays off. |
| Crash safety | The tap uses Core Audio's *muted when tapped* mode: the original audio is muted only while a client is actively reading the tap. If Louder's process dies or is force-quit, nothing reads the tap and normal audio returns. The tap and aggregate device are private to the process. |
| One session | A per-user lock file means only one Louder (app or `louder-cli`) can boost at a time, so two copies can never tap and boost each other. |
| Real-time safety | The audio callback never allocates or locks; it is run once before audio starts so Swift's lazy runtime lookups don't happen on the real-time thread. Louder only uses the tap's own channels and writes silence to any other output channels. |

## Permission

Process taps need the System Audio Recording permission. Louder checks it before creating the tap: if it was denied, Louder stays off and shows **Needs permission**; if macOS has not asked yet, it asks. While running it checks again every couple of seconds and turns off if the permission is removed. A tap without the permission receives only silence.

## Signing

Builds are ad-hoc signed (no Developer ID), so macOS may ask for the permission again after an update.
