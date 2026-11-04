# Louder brand

**Name:** Louder. Open source (MIT), macOS menu bar app. Boosts system volume past 100% with a peak limiter and loudness guard, so quiet podcasts get the full boost and already-loud music barely moves.

## Tagline options

1. Safely louder.
2. Louder, without the ouch.
3. More volume. Same ears.

**Chosen: "Safely louder."** It is short, says both the benefit and the guardrail, and fits under the wordmark. Longer line for the README: "Louder boosts your Mac's volume past 100% and protects your ears while it does."

## Palette

Brand kit slug in Forge: `louder` (the account default kit is not used).

| Role | Name | Light mode | Dark mode |
| --- | --- | --- | --- |
| Primary | Calm Blue | `#2F6BFF` | `#5B8CFF` |
| Primary (deep, icon gradient end) | Deep Blue | `#2354E0` | `#2354E0` |
| Accent | Warm Coral | `#FF7A59` | `#FFA58A` |
| Ink (text, dark surfaces) | Night Navy | `#14213D` | `#14213D` |
| Surface | Cloud | `#F5F6FA` | `#1B1D26` |
| Secondary text | Slate | `#5B6275` | `#A4AABB` |
| Hairline | Mist | `#DDE0EA` | `#2E3140` |

Rules: Calm Blue on Cloud is about 4.2:1 (fine for large text and UI, not body text); use Night Navy for body text. Coral is an accent only (the outer wave, a single highlight), never a full background. In the app UI use system colors (`.accentColor`, `.primary`, `.secondary`) so Light, Dark and increased-contrast just work; the palette above is for icon, web and README art.

## Typography

- App: Apple system font, SF Pro (`.system`), with SF Pro Rounded for the big percentage readout if you want the playful touch. Respect Dynamic Type sizes in menus and popovers.
- Web / README: Nunito (SIL Open Font License, Google Fonts). Rounded terminals match the mark. Use 800 for the wordmark and 400/600 for text. Fall back to `-apple-system, "SF Pro Text", system-ui, sans-serif`.

## Voice

Friendly, calm, plainspoken. A little playful, never hype. Talk like a careful friend with a volume knob.

- Do: "Boosted to 140%. Limiter is catching peaks." "This one is already loud, so Louder stays out of the way."
- Do not: shouting, all caps, "MAX POWER", flames, "crank it", anything that sounds like a dare.
- Always frame the limiter as the feature, not a caveat. Mention hearing safety in plain words, not legal ones.

## Logo and icon usage

- Mark: a rounded speaker with three sound waves (`logo.svg`, Calm Blue, transparent background). The app icon shows the same mark in white on a blue squircle, with the outer wave in coral to read as "the extra headroom".
- Menu bar: `MenuBarIcon.png` and `@2x` are black-on-transparent template images. In AppKit set `image.isTemplate = true`; the system tints them for light, dark and highlighted states. Do not color them.
- Clear space: at least the height of the speaker body around the mark. Minimum size: 16 px for the mark, 24 px for the mark next to the wordmark.
- Backgrounds: Calm Blue mark on Cloud or white; white mark on Calm Blue or Night Navy. Do not place the blue mark on busy photos or on coral.
- Do not rotate, outline, add shadows to the flat mark, recolor the waves in rainbow colors, or add flames or lightning.
- App icon: ship `AppIcon.icns` (or the 1024 PNG into an asset catalog). The macOS squircle body is 824 px inside the 1024 canvas, with a soft drop shadow in the margin.
