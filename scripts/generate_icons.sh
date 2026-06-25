#!/usr/bin/env bash
#
# generate_icons.sh — generate all required app icon sizes from a source 1024.png
# Usage: ./scripts/generate_icons.sh path/to/1024.png [output_dir]
#

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
SOURCE_ICON="${1:-icons/1024.png}"
OUTPUT_DIR="${2:-PrismaX/Resources/Assets.xcassets/AppIcon.appiconset}"

# ── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf "\033[1;34m▸ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: '$1'. $2"; }

# ── Preflight ───────────────────────────────────────────────────────────────
need sips "macOS built-in image processor"

[[ -f "$SOURCE_ICON" ]] || die "Source icon not found: $SOURCE_ICON"
mkdir -p "$OUTPUT_DIR"

log "Generating app icons from: $SOURCE_ICON"
log "Output directory: $OUTPUT_DIR"

# ── Generate sizes ──────────────────────────────────────────────────────────
# mac app icon sizes (points): 16,32,64,128,256,512,1024 (×2 scales).
SIZES=(
  "16:icon_16.png"
  "32:icon_16@2x.png"
  "32:icon_32.png"
  "64:icon_32@2x.png"
  "128:icon_128.png"
  "256:icon_128@2x.png"
  "256:icon_256.png"
  "512:icon_256@2x.png"
  "512:icon_512.png"
  "1024:icon_512@2x.png"
)

count=0
for entry in "${SIZES[@]}"; do
  size="${entry%%:*}"
  filename="${entry##*:}"
  output_path="$OUTPUT_DIR/$filename"

  log "  Generating $filename (${size}×${size})"

  # Use sips to resize the icon
  if sips -z "$size" "$size" "$SOURCE_ICON" --out "$output_path" >/dev/null 2>&1; then
    ok "$filename"
    ((count++))
  else
    echo "Warning: Failed to generate $filename"
  fi
done

log "Icon generation complete!"
ok "Generated $count icon sizes in $OUTPUT_DIR"