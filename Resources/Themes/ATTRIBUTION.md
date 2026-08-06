# Banner artwork attribution

The PNGs in this folder are single frames taken from the BUSY Bar firmware's
theme animations.

- **Source:** [busy-app/busybar-firmware](https://github.com/busy-app/busybar-firmware),
  `assets/shared/animations/*_72x16.zip`
- **Copyright:** © 2024–2026 Flipper FZCO
- **License:** [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/)
- **Changes:** one representative frame extracted per animation and renamed to
  the theme id; the images themselves are unmodified.

These files stay under CC-BY-SA-4.0 — the MIT license covering the rest of this
repository does not apply to them.

Refresh them with `./Scripts/fetch-themes.sh`. Each file is named after the
theme id the device expects; `Banner.all` in `Sources/Banners.swift` is the
authoritative list. The default `busy` theme has no published animation, so its
entry falls back to a text label.
