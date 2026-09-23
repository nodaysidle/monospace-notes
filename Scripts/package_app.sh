#!/bin/bash
#
# Scripts/package_app.sh — the SOLE packaging authority for Monospace Notes.
#
# Owner: OWN-PACKAGING (TASK-15-PACKAGING, CON-PACKAGING-RELEASE).
#
# Every release step lives here and nowhere else. Any failure exits non-zero
# immediately (`set -euo pipefail` plus explicit checks); a later gate is never
# reached once an earlier one has failed.
#
#   1. release build ............ swift build -c release --arch arm64
#   2. resolve the release binary (Swift 6.4: .build/out/Products/Release)
#   3. reject a non-arm64 Mach-O
#   4. verify Resources/Info.plist against the locked identity
#   5. assemble dist/Monospace Notes.app
#   6. copy the executable, Info.plist and AppIcon.icns into the bundle
#   7. sign once with Resources/App.entitlements
#      (Developer ID Application when present, otherwise ad-hoc '-')
#   8. codesign --verify --deep --strict — reject failure BEFORE the DMG
#   9. create dist/Monospace Notes.dmg and verify it with hdiutil
#
# Bundle structure produced (and re-verified) by this script:
#   dist/Monospace Notes.app/Contents/Info.plist
#   dist/Monospace Notes.app/Contents/MacOS/MonospaceNotes
#   dist/Monospace Notes.app/Contents/Resources/AppIcon.icns
#
# This script never installs and never launches: nothing is copied into the
# system applications folder and the bundle is not opened. Installation and
# LaunchServices registration are a separate step gated on explicit approval.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Locked identity (must match Sources/MonospaceNotes/AppState.swift LockedIdentity)
# ---------------------------------------------------------------------------
BUNDLE_ID="com.monospace.notes"
BUNDLE_NAME="Monospace Notes"
EXECUTABLE_NAME="MonospaceNotes"
ICON_NAME="AppIcon"
SHORT_VERSION="1.0.0"
BUILD_VERSION="1"
MIN_SYSTEM_VERSION="14.0"

DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/$BUNDLE_NAME.app"
DMG_PATH="$DIST_DIR/$BUNDLE_NAME.dmg"

INFO_SRC="$REPO_ROOT/Resources/Info.plist"
ENTITLEMENTS_SRC="$REPO_ROOT/Resources/App.entitlements"
ICON_SRC="$REPO_ROOT/Resources/AppIcon.icns"

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nPACKAGING FAILED: %s\n' "$*" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || die "missing required input file: $1"; }

printf 'Monospace Notes packaging — repo: %s\n' "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. Release build (arm64)
# ---------------------------------------------------------------------------
step "Release build (arm64)"
swift build -c release --arch arm64

# ---------------------------------------------------------------------------
# 2. Resolve the release executable
#    Swift 6.4 prints .build/out/Products/Release; the TRD-literal
#    .build/arm64-apple-macosx/release/ path is kept as a fallback.
# ---------------------------------------------------------------------------
step "Resolve the release executable"
BIN_DIR=""
if SHOW_BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)"; then
    if [[ -x "$SHOW_BIN_PATH/$EXECUTABLE_NAME" ]]; then
        BIN_DIR="$SHOW_BIN_PATH"
    fi
fi
for FALLBACK_DIR in "$REPO_ROOT/.build/arm64-apple-macosx/release" "$REPO_ROOT/.build/release"; do
    if [[ -z "$BIN_DIR" && -x "$FALLBACK_DIR/$EXECUTABLE_NAME" ]]; then
        BIN_DIR="$FALLBACK_DIR"
    fi
done
[[ -n "$BIN_DIR" ]] || die "release executable $EXECUTABLE_NAME not found (checked swift --show-bin-path, .build/arm64-apple-macosx/release, .build/release)"
BINARY="$BIN_DIR/$EXECUTABLE_NAME"
printf 'binary: %s\n' "$BINARY"

# ---------------------------------------------------------------------------
# 3. Architecture gate — a non-arm64 Mach-O is rejected
# ---------------------------------------------------------------------------
step "Architecture gate"
[[ -f "$BINARY" ]] || die "not a regular file: $BINARY"
ARCHS="$(lipo -archs "$BINARY" 2>/dev/null)" || die "lipo -archs failed on $BINARY"
printf 'lipo -archs: %s\n' "$ARCHS"
case " $ARCHS " in
    *" arm64 "*) ;;
    *) die "release executable is not arm64 (lipo reports: $ARCHS)" ;;
esac

# ---------------------------------------------------------------------------
# 4. Locked identity — the source Info.plist must already be correct
# ---------------------------------------------------------------------------
step "Verify Resources/Info.plist against the locked identity"
require_file "$INFO_SRC"
require_file "$ENTITLEMENTS_SRC"
require_file "$ICON_SRC"
/usr/bin/plutil -lint "$INFO_SRC" >/dev/null || die "Resources/Info.plist is not a valid plist"
/usr/bin/plutil -lint "$ENTITLEMENTS_SRC" >/dev/null || die "Resources/App.entitlements is not a valid plist"

check_plist_value() {
    local key="$1" expected="$2" actual
    actual="$(/usr/bin/plutil -extract "$key" raw -o - "$INFO_SRC" 2>/dev/null)" \
        || die "Resources/Info.plist is missing the key $key"
    [[ "$actual" == "$expected" ]] || die "Resources/Info.plist $key is '$actual', expected '$expected'"
}
check_plist_value CFBundleIdentifier          "$BUNDLE_ID"
check_plist_value CFBundleName                "$BUNDLE_NAME"
check_plist_value CFBundleExecutable          "$EXECUTABLE_NAME"
check_plist_value CFBundleIconFile            "$ICON_NAME"
check_plist_value CFBundlePackageType         "APPL"
check_plist_value CFBundleShortVersionString  "$SHORT_VERSION"
check_plist_value CFBundleVersion             "$BUILD_VERSION"
check_plist_value LSMinimumSystemVersion      "$MIN_SYSTEM_VERSION"
check_plist_value NSHighResolutionCapable     "true"
check_plist_value LSUIElement                 "false"
printf 'identity verified: %s / %s\n' "$BUNDLE_ID" "$BUNDLE_NAME"

# ---------------------------------------------------------------------------
# 5 + 6. Assemble the bundle and copy the resources
# ---------------------------------------------------------------------------
step "Assemble $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
install -m 755 "$BINARY" "$MACOS_DIR/$EXECUTABLE_NAME"
install -m 644 "$INFO_SRC" "$CONTENTS_DIR/Info.plist"
install -m 644 "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"

# The assembled layout is asserted at the exact declared paths.
[[ -x "$APP_DIR/Contents/MacOS/MonospaceNotes" ]] || die "bundle executable was not installed"
for RELATIVE_PATH in "Contents/Info.plist" "Contents/MacOS/MonospaceNotes" "Contents/Resources/AppIcon.icns"; do
    [[ -f "$APP_DIR/$RELATIVE_PATH" ]] || die "assembled bundle is missing $RELATIVE_PATH"
done
/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null || die "bundle Info.plist is not a valid plist"

# ---------------------------------------------------------------------------
# 7. Signing — Developer ID Application when available, otherwise ad-hoc
#    Exactly one signature, driven by Resources/App.entitlements only.
# ---------------------------------------------------------------------------
step "Sign the bundle"
SIGN_IDENTITY="-"
if DEVELOPER_ID_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -n 1)"; then
    if [[ -n "$DEVELOPER_ID_LINE" ]]; then
        SIGN_IDENTITY="$(printf '%s\n' "$DEVELOPER_ID_LINE" | sed -E 's/.*"(.*)".*/\1/')"
    fi
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'signing identity: ad-hoc (no Developer ID Application identity on this machine)\n'
else
    printf 'signing identity: %s\n' "$SIGN_IDENTITY"
fi

codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS_SRC" \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"

# The signed bundle must carry no sandbox key and no broad file/automation rights.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_DIR" 2>/dev/null || true)"
case "$SIGNED_ENTITLEMENTS" in
    *"com.apple.security.app-sandbox"*) die "signed bundle carries com.apple.security.app-sandbox" ;;
esac
case "$SIGNED_ENTITLEMENTS" in
    *"com.apple.security.files"*|*"com.apple.security.automation"*) die "signed bundle carries broad file/automation entitlements" ;;
esac
printf 'signature carries no sandbox and no broad file/automation entitlements\n'

# ---------------------------------------------------------------------------
# 8. Strict verification — failure here blocks the DMG
# ---------------------------------------------------------------------------
step "codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# ---------------------------------------------------------------------------
# 9. DMG
# ---------------------------------------------------------------------------
step "Create the DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$BUNDLE_NAME" \
    -srcfolder "$APP_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"
[[ -f "$DMG_PATH" ]] || die "DMG was not created at $DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null || die "hdiutil verify failed for $DMG_PATH"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Packaging complete"
printf 'app:  %s\n' "$APP_DIR"
printf 'dmg:  %s\n' "$DMG_PATH"
printf 'dmg sha256: %s\n' "$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf 'not installed: no copy targets the system applications folder (a separate, explicitly approved step)\n'
ls -la "$DIST_DIR"
exit 0
