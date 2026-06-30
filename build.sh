#!/usr/bin/env bash
#
# build.sh — build PrismaX into distributable macOS .apps (+ optional .dmgs),
# one per architecture.
#
# This is for community/open-source distribution WITHOUT an Apple Developer
# account: the app is ad-hoc signed (CODE_SIGN_IDENTITY="-") and NOT
# notarized. Recipients will see a Gatekeeper warning on first launch and
# must right-click → Open (or System Settings → Privacy & Security → Open
# Anyway) the first time. That's expected for unsigned apps.
#
# Two builds are produced — one for Apple Silicon (arm64) and one for Intel
# (x64) — each packaged into its own arch-specific DMG. Single-arch builds
# are roughly half the size of a universal build, so downloads are leaner and
# the right one is unambiguous.
#
# Requirements:
#   - Xcode 16+ (or Command Line Tools)  → xcodebuild
#   - XcodeGen                           → brew install xcodegen
#   - A working `swift` (bundled with Xcode) for icon rendering
#
# Usage:
#   ./build.sh              # build arm64 + x64 .apps + DMGs into ./dist
#   ./build.sh --app        # build only the per-arch .apps (no DMGs)
#   ./build.sh --dmg        # build only the per-arch DMGs (no .apps)
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
# By default both artifacts are produced. Use the opt-in flags to build only
# one kind: --app (just .apps), --dmg (just .dmg). Both together = same as
# default. If neither is passed, both are built (sensible default).
MAKE_APP=0
MAKE_DMG=0
EXPLICIT=0
RENDER_ICON=1
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --app)     MAKE_APP=1; EXPLICIT=1 ;;
    --dmg)     MAKE_DMG=1; EXPLICIT=1 ;;
    --no-icon) RENDER_ICON=0 ;;
    --clean)   CLEAN=1 ;;
    -h|--help)
      sed -n '3,26p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
# If neither --app nor --dmg was given, build both (the default).
if [[ "$EXPLICIT" == 0 ]]; then
  MAKE_APP=1
  MAKE_DMG=1
fi

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

# ── 3. Build + package per architecture ──────────────────────────────────────
# We build once per arch (arm64 = Apple Silicon, x86_64 = Intel) and package
# each into its own arch-specific DMG. Single-arch builds are ~half the size of
# a universal build, so downloads are leaner and the right one is unambiguous.
# Ad-hoc sign (no Developer account needed). Hardened runtime stays off so the
# embedded PTY/forkpty and arbitrary child-process execution work unimpeded.
#
# build_arch <arch> <slug>  — builds, stages, and (unless --no-dmg) DMGs.
#   <arch>  : the value passed to xcodebuild -arch (arm64 / x86_64)
#   <slug>  : the suffix used in the DMG name (arm64 / x64)
build_arch() {
  local arch="$1" slug="$2"

  log "Building $PROJECT_NAME ($arch / $slug, $CONFIGURATION, ad-hoc signed)"
  local arch_build_dir="$BUILD_DIR/DerivedData-$slug"
  xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -arch "$arch" \
    -derivedDataPath "$arch_build_dir" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build >/dev/null
  ok "Build succeeded ($arch)"

  local built_app="$arch_build_dir/Build/Products/$CONFIGURATION/$PROJECT_NAME.app"
  [[ -d "$built_app" ]] || die "Built .app not found at expected path: $built_app"

  # Stage into ./dist as <name>-<slug>.app. Always staged (the DMG step copies
  # from it too); if --dmg-only was requested, it's removed again after the DMG
  # is made so ./dist ends up containing only what was asked for.
  log "Staging into ./dist ($slug)"
  local staged_app="$DIST_DIR/$PROJECT_NAME-$slug.app"
  rm -rf "$staged_app"
  cp -R "$built_app" "$staged_app"
  # Re-stamp the ad-hoc signature on the staged copy.
  codesign --force --deep --sign - "$staged_app" >/dev/null 2>&1 || true
  if [[ "$MAKE_APP" == 1 ]]; then
    ok "$staged_app"
  fi

  if [[ "$MAKE_DMG" == 1 ]]; then
    # Version is read once outside (before any arch builds); reuse it here.
    local dmg_name="$PROJECT_NAME-$APP_VERSION-$slug.dmg"
    local dmg_path="$DIST_DIR/$dmg_name"
    local volname="$PROJECT_NAME $APP_VERSION ($slug)"
    log "Creating disk image: $dmg_name"

    # The app icon to use as the DMG's volume icon. The build already embeds
    # AppIcon.icns in the bundle, so reuse it instead of re-rendering.
    local app_icns="$staged_app/Contents/Resources/AppIcon.icns"

    # hdiutil -srcfolder can't set a volume icon directly. The standard recipe:
    # build a read/write image with a .VolumeIcon.icns at its root, set the
    # volume's custom-icon flag with SetFile, then convert to compressed
    # read-only. This gives the DMG the app's icon in Finder/Downloads without a
    # "drag to Applications" background layout.
    local stage; stage=$(mktemp -d -t prismax_dmg)
    cp -R "$staged_app" "$stage/"
    [[ -f "$app_icns" ]] && cp "$app_icns" "$stage/.VolumeIcon.icns"

    local rw_dmg="$DIST_DIR/.${PROJECT_NAME}-${slug}-rw.$$.dmg"
    rm -f "$dmg_path" "$rw_dmg"
    hdiutil create \
      -ov \
      -volname "$volname" \
      -srcfolder "$stage" \
      -fs HFS+ \
      -format UDRW \
      "$rw_dmg" >/dev/null
    rm -rf "$stage"

    # Attach read/write at a known mount point (avoids parsing hdiutil output),
    # set the custom-icon flag, then detach.
    local mountpt="$DIST_DIR/.mnt_${slug}_$$"
    mkdir -p "$mountpt"
    if hdiutil attach -nobrowse -noverify -mountpoint "$mountpt" "$rw_dmg" >/dev/null 2>&1; then
      if [[ -f "$app_icns" ]]; then
        # SetFile ships with Xcode (which this script already requires). Guard
        # anyway so a missing tool can't fail the whole build.
        xcrun SetFile -a C "$mountpt" 2>/dev/null || true
      fi
      hdiutil detach "$mountpt" >/dev/null 2>&1 || true
    fi
    rmdir "$mountpt" 2>/dev/null || true

    # Convert to compressed, read-only distribution image.
    hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null
    rm -f "$rw_dmg"
    ok "$dmg_path"

    # If only DMGs were requested, drop the staged .app so ./dist holds only
    # what was asked for. (When --app is also set, keep it.)
    if [[ "$MAKE_APP" == 0 ]]; then
      rm -rf "$staged_app"
    fi
  fi
}

# Version is the same for both arch builds; read it once up front from the
# XcodeGen source (project.yml) rather than from a built .app, so the log
# ordering stays sensible before any arch build runs.
APP_VERSION="$(grep -E 'MARKETING_VERSION:' "$ROOT_DIR/project.yml" | head -1 | sed -E 's/^[^"]*"([^"]+)".*$/\1/' )"
[[ -n "$APP_VERSION" ]] || APP_VERSION="0.0.0"
ok "Version: $APP_VERSION"

build_arch "arm64"  "arm64"   # Apple Silicon
build_arch "x86_64" "x64"     # Intel

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
ok "Done. Distribution artifacts in ./dist:"
ls -1 "$DIST_DIR" | sed 's/^/    /'
echo ""
printf "\033[33mNote:\033[0m This app is unsigned. On first launch, Gatekeeper will warn\n"
printf "recipients. To open: right-click the app → \033[1mOpen\033[0m → \033[1mOpen\033[0m.\n"
