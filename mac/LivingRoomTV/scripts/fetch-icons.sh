#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

ICONS_DIR="Sources/LivingRoomTV/Resources/Icons"
mkdir -p "$ICONS_DIR"

BASE_URL="https://raw.githubusercontent.com/lucide-icons/lucide/main/icons"

# Lucide icon slugs we use in the popup. Menu-bar label keeps SF Symbols to
# blend with the native macOS chrome.
ICONS=(
  settings
  sparkles
  arrow-up
  arrow-down
  chevron-left
  chevron-right
  chevron-up
  chevron-down
  chevrons-left
  chevrons-right
  play
  pause
  skip-back
  skip-forward
  volume-2
  volume-x
  tv
  tv-minimal
  signal
  sunrise
  film
  utensils
  moon
  power
  baby
  music
  search
  check
  circle-alert
  circle
  dot
  wifi
  edit-3
  plus
  minus
  house
)

echo "Fetching ${#ICONS[@]} Lucide icons into ${ICONS_DIR}/"
find "$ICONS_DIR" -type f -name "*.png" -delete 2>/dev/null || true

for icon in "${ICONS[@]}"; do
  url="$BASE_URL/$icon.svg"
  tmp=$(mktemp -t "lucide.XXXXXX").svg
  if ! curl -sfSL "$url" -o "$tmp"; then
    echo "  ✗ $icon (fetch failed)"
    rm -f "$tmp"
    continue
  fi
  # Rasterize at 20pt @1x and @2x. Lucide SVGs use currentColor stroke;
  # rsvg-convert renders that as black-on-transparent, which SwiftUI treats
  # as alpha in template mode and tints to the current foreground style.
  rsvg-convert -w 20  -h 20  "$tmp" -o "$ICONS_DIR/$icon.png"
  rsvg-convert -w 40  -h 40  "$tmp" -o "$ICONS_DIR/$icon@2x.png"
  rm -f "$tmp"
  echo "  ✓ $icon"
done

echo "Done."
