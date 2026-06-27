#!/usr/bin/env bash
#
# build.sh — build PrismaX into a distributable macOS .app (+ optional .dmg).
#
# This is for community/open-source distribution WITHOUT an Apple Developer
# account: the app is ad-hoc signed (CODE_SIGN_IDENTITY="-") and NOT
# notarized. Recipients will see a Gatekeeper warning on first launch and
# must right-click → Open (or System Settings → Privacy & Security → Open
# Anyway) the first time. That's expected for unsigned apps.
#
# Requirements:
#   - Xcode 16+ (or Command Line Tools)  → xcodebuild
#   - XcodeGen                           → brew install xcodegen
#   - A working `swift` (bundled with Xcode) for icon rendering
#
# Usage:
#   ./build.sh              # build Release .app + DMG into ./dist
#   ./build.sh --no-dmg     # skip DMG, just the .app
#   ./build.sh --no-icon    # skip re-rendering the icon (use existing PNGs)
#   ./build.sh --clean      # remove ./build and ./dist before building
#
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_NAME="PrismaX"
SCHEME="PrismaX"
CONFIGURATION="Release"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
ICONSET_DIR="$ROOT_DIR/PrismaX/Resources/Assets.xcassets/AppIcon.appiconset"

# ── Flags ───────────────────────────────────────────────────────────────────
MAKE_DMG=1
RENDER_ICON=1
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --no-dmg)  MAKE_DMG=0 ;;
    --no-icon) RENDER_ICON=0 ;;
    --clean)   CLEAN=1 ;;
    -h|--help)
      sed -n '3,28p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf "\033[1;34m▸ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: '$1'. $2"; }

# ── Preflight ───────────────────────────────────────────────────────────────
need xcodebuild "Install Xcode 16+ or the Command Line Tools."
need xcodegen   "Install with:  brew install xcodegen"
need swift      "Comes with Xcode."
[[ -f "$ROOT_DIR/project.yml" ]] || die "project.yml not found — run from the repo root."

if [[ "$CLEAN" == 1 ]]; then
  log "Cleaning previous build output"
  rm -rf "$BUILD_DIR" "$DIST_DIR"
fi

mkdir -p "$DIST_DIR"

# ── 1. Icon ─────────────────────────────────────────────────────────────────
if [[ "$RENDER_ICON" == 1 ]]; then
  log "Generating app icons from source 1024.png"
  if [[ -f "$ROOT_DIR/icons/1024.png" ]]; then
    if bash "$ROOT_DIR/scripts/generate_icons.sh" "$ROOT_DIR/icons/1024.png" "$ICONSET_DIR" >/dev/null; then
      ok "Icons generated → AppIcon.appiconset"
    else
      die "Icon generation failed."
    fi
  else
    die "Source icon not found: icons/1024.png"
  fi
fi

# ── 2. Generate Xcode project ───────────────────────────────────────────────
log "Generating Xcode project (XcodeGen)"
( cd "$ROOT_DIR" && xcodegen generate >/dev/null )
ok "PrismaX.xcodeproj generated"

# ── 3. Build Release ────────────────────────────────────────────────────────
# Ad-hoc sign (no Developer account needed). Hardened runtime stays off so the
# embedded PTY/forkpty and arbitrary child-process execution work unimpeded.
log "Building $PROJECT_NAME ($CONFIGURATION, ad-hoc signed)"
xcodebuild \
  -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build >/dev/null
ok "Build succeeded"

BUILT_APP="$BUILD_DIR/DerivedData/Build/Products/$CONFIGURATION/$PROJECT_NAME.app"
[[ -d "$BUILT_APP" ]] || die "Built .app not found at expected path: $BUILT_APP"

# ── 4. Stage into ./dist ────────────────────────────────────────────────────
log "Staging into ./dist"
STAGED_APP="$DIST_DIR/$PROJECT_NAME.app"
rm -rf "$STAGED_APP"
cp -R "$BUILT_APP" "$STAGED_APP"
# Re-stamp the ad-hoc signature on the staged copy.
codesign --force --deep --sign - "$STAGED_APP" >/dev/null 2>&1 || true
ok "$STAGED_APP"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
ok "Version: $APP_VERSION"

# ── 5. DMG (optional) ───────────────────────────────────────────────────────
if [[ "$MAKE_DMG" == 1 ]]; then
  DMG_NAME="$PROJECT_NAME-$APP_VERSION.dmg"
  DMG_PATH="$DIST_DIR/$DMG_NAME"
  VOLNAME="$PROJECT_NAME $APP_VERSION"
  log "Creating disk image: $DMG_NAME"

  # The app icon to use as the DMG's volume icon. The build already embeds
  # AppIcon.icns in the bundle, so reuse it instead of re-rendering.
  APP_ICNS="$STAGED_APP/Contents/Resources/AppIcon.icns"

  # hdiutil -srcfolder can't set a volume icon directly. The standard recipe:
  # build a read/write image with a .VolumeIcon.icns at its root, set the
  # volume's custom-icon flag with SetFile, then convert to compressed
  # read-only. This gives the DMG the app's icon in Finder/Downloads without a
  # "drag to Applications" background layout.
  STAGE=$(mktemp -d -t prismax_dmg)
  cp -R "$STAGED_APP" "$STAGE/"
  [[ -f "$APP_ICNS" ]] && cp "$APP_ICNS" "$STAGE/.VolumeIcon.icns"

  RW_DMG="$DIST_DIR/.${PROJECT_NAME}-rw.$$.dmg"
  rm -f "$DMG_PATH" "$RW_DMG"
  hdiutil create \
    -ov \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDRW \
    "$RW_DMG" >/dev/null
  rm -rf "$STAGE"

  # Attach read/write at a known mount point (avoids parsing hdiutil output),
  # set the custom-icon flag, then detach.
  MOUNTPT="$DIST_DIR/.mnt_$$"
  mkdir -p "$MOUNTPT"
  if hdiutil attach -nobrowse -noverify -mountpoint "$MOUNTPT" "$RW_DMG" >/dev/null 2>&1; then
    if [[ -f "$APP_ICNS" ]]; then
      # SetFile ships with Xcode (which this script already requires). Guard
      # anyway so a missing tool can't fail the whole build.
      xcrun SetFile -a C "$MOUNTPT" 2>/dev/null || true
    fi
    hdiutil detach "$MOUNTPT" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNTPT" 2>/dev/null || true

  # Convert to compressed, read-only distribution image.
  hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
  rm -f "$RW_DMG"
  ok "$DMG_PATH"
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
ok "Done. Distribution artifacts in ./dist:"
ls -1 "$DIST_DIR" | sed 's/^/    /'
echo ""
printf "\033[33mNote:\033[0m This app is unsigned. On first launch, Gatekeeper will warn\n"
printf "recipients. To open: right-click the app → \033[1mOpen\033[0m → \033[1mOpen\033[0m.\n"
