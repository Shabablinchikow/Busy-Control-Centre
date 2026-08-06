#!/usr/bin/env bash
# Fetch banner artwork for the theme picker.
#
# Source: BUSY Bar firmware, assets/shared/animations — the very animations the
# bar plays. Graphical assets there are CC-BY-SA-4.0, © 2024-2026 Flipper FZCO.
# One representative frame per theme is kept as a still preview.
#
#   ./Scripts/fetch-themes.sh
set -euo pipefail

BASE="https://raw.githubusercontent.com/busy-app/busybar-firmware/dev/assets/shared/animations"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Resources/Themes"
THEMES=(back_soon booked chill_time coding dnd flow keep_out low_social_battery
        lunch meeting on_air on_call)

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for t in "${THEMES[@]}"; do
    if ! curl -fsSL "$BASE/${t}_72x16.zip" -o "$tmp/$t.zip"; then
        echo "skip $t (not published)" >&2
        continue
    fi
    unzip -qo "$tmp/$t.zip" -x "__MACOSX/*" -d "$tmp/$t"
    # ponytail: largest frame ≈ the fullest one, since these animations build up
    # to the complete banner. Pick a frame by name if one ever looks wrong.
    # No `| head -1`: SIGPIPE trips `set -o pipefail`.
    all="$(ls -S "$tmp/$t/${t}_72x16"/*.png 2>/dev/null || true)"
    frame="${all%%$'\n'*}"
    [ -n "$frame" ] || { echo "skip $t (no frames)" >&2; continue; }
    cp "$frame" "$DEST/$t.png"
    echo "$t <- $(basename "$frame")"
done
