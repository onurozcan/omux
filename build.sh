#!/bin/zsh
# Builds omux.app into ./build.
#   ./build.sh            builds and installs /Applications/omux.app, signed for development.
#   ./build.sh --beta     builds and installs "omux Beta" instead: a separate app with its own
#                         preferences and workspace, so you can try a branch next to the release build.
#   ./build.sh --dist     builds a universal (Apple Silicon + Intel) distributable release:
#                         signed with the Developer ID certificate,
#                         hardened runtime, notarized and stapled; produces build/omux-<version>.dmg
#                         and build/omux-<version>.zip. Doesn't install anything.
#                         Needs a notarytool keychain profile (see NOTARY_PROFILE below).
#   ./build.sh --dist --no-notarize   same, but skips notarization (for checking the build).
set -e
setopt null_glob
cd "$(dirname "$0")"

NAME=omux
BUNDLE_ID=net.pf1.omux
MODE=install
NOTARIZE=1
NOTARY_PROFILE=${NOTARY_PROFILE:-omux-notary}
for arg in "$@"; do
  case "$arg" in
    --beta) NAME="omux Beta"; BUNDLE_ID=net.pf1.omux.beta ;;
    --dist) MODE=dist ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" == dist ]]; then
  # Keep the output paths: SwiftPM's .build/release symlink changes with the last architecture built.
  swift build -c release --arch arm64
  ARM_BIN=$(swift build -c release --arch arm64 --show-bin-path)
  swift build -c release --arch x86_64
  INTEL_BIN=$(swift build -c release --arch x86_64 --show-bin-path)
  BIN_DIR="$ARM_BIN"
else
  swift build -c release
  BIN_DIR=$(swift build -c release --show-bin-path)
fi

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$MODE" == dist ]]; then
  lipo -create "$ARM_BIN/omux" "$INTEL_BIN/omux" -output "$APP/Contents/MacOS/omux"
else
  cp "$BIN_DIR/omux" "$APP/Contents/MacOS/omux"
fi
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName $NAME" \
  -c "Set :NSServices:0:NSMenuItem:default Open in $NAME" -c "Set :NSServices:0:NSPortName $NAME" "$APP/Contents/Info.plist"
cp Resources/omux.icns "$APP/Contents/Resources/"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# Sparkle, for updates. The binary looks for it in Contents/Frameworks (see Package.swift).
SPARKLE_DIR=.build/artifacts/sparkle/Sparkle
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/"

if [[ "$MODE" == dist ]]; then
  # Check every Mach-O, including Sparkle's nested helpers, before signing or packaging.
  while IFS= read -r -d '' binary; do
    if [[ "$(file -b "$binary")" == *Mach-O* ]]; then
      if ! lipo "$binary" -verify_arch arm64 x86_64; then
        echo "Missing arm64 or x86_64 architecture in $binary" >&2
        exit 1
      fi
    fi
  done < <(find "$APP" -type f -print0)
fi

# Signs Sparkle's nested helpers with our identity, inside out, so library validation and
# notarization accept them. $1 identity, remaining args extra codesign options.
sign_sparkle() {
  local identity=$1; shift
  local fw="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for item in "$fw/XPCServices/Installer.xpc" "$fw/XPCServices/Downloader.xpc" "$fw/Autoupdate" "$fw/Updater.app"; do
    codesign --force --sign "$identity" --preserve-metadata=entitlements "$@" "$item" 2>&1 | grep -v "replacing existing signature" || true
  done
  codesign --force --sign "$identity" "$@" "$APP/Contents/Frameworks/Sparkle.framework" 2>&1 | grep -v "replacing existing signature" || true
}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [[ "$MODE" == "install" ]]; then
  # A stable signing identity keeps macOS from re-asking permissions after each rebuild.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
  sign_sparkle "${IDENTITY:--}"
  codesign --force --sign "${IDENTITY:--}" "$APP" 2>&1 | grep -v "replacing existing signature" || true
  # Install to /Applications so Finder's "Open in omux" service and Dock stay registered.
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" "/Applications/$NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$NAME.app"
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
  echo "Built and installed /Applications/$NAME.app ($(du -sh "$APP" | cut -f1))"
  exit 0
fi

# --- Distribution build ---
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}')
if [[ -z "$IDENTITY" ]]; then
  echo "No 'Developer ID Application' certificate in the keychain. Create one in Xcode › Settings › Accounts › Manage Certificates." >&2
  exit 1
fi
if [[ "$NOTARIZE" == 1 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<MSG
No notarytool credentials stored as '$NOTARY_PROFILE'. Store them once (asks for an app-specific
password from account.apple.com › Sign-In and Security › App-Specific Passwords):

  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id L3DA4MMSS3

Or run with --no-notarize to only sign.
MSG
  exit 1
fi

# Hardened runtime and a secure timestamp are required for notarization.
sign_sparkle "$IDENTITY" --options runtime --timestamp
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

ARTIFACT="build/${NAME// /-}-$VERSION"
ZIP="$ARTIFACT.zip"
DMG="$ARTIFACT.dmg"
rm -f "$ZIP" "$DMG"

notarize() {
  echo "Notarizing $1…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | grep -E "status:|id:" | tail -2
}

if [[ "$NOTARIZE" == 1 ]]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP" >/dev/null
  rm -f "$ZIP"
fi
# The zip carries the stapled app, so it works offline too.
ditto -c -k --keepParent "$APP" "$ZIP"

# DMG: the app next to an Applications shortcut, so users drag one onto the other.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [[ "$NOTARIZE" == 1 ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG" >/dev/null
fi

# Appcast for Sparkle: the release notes come from this version's CHANGELOG section, embedded.
# generate_appcast signs the zip with the EdDSA key in the Keychain and merges into site/appcast.xml.
if [[ "$NAME" == omux ]]; then
  STAGE=$(mktemp -d)
  cp "$ZIP" "$STAGE/"
  python3 - "$VERSION" > "$STAGE/omux-$VERSION.html" <<'PY'
import html, re, sys
version = sys.argv[1]
text = open("CHANGELOG.md").read()
start = text.find(f"## [{version}]")
end = text.find("\n## [", start + 1)
section = text[start:end if end > 0 else None].split("\n", 1)[1]
def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    return re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', t)
out = []
for line in section.splitlines():
    if line.startswith("### "): out.append(f"<h3>{html.escape(line[4:])}</h3>")
    elif line.startswith("- "): out.append(f"<li>{inline(line[2:])}</li>")
    elif line.strip(): out.append(f"<p>{inline(line.strip())}</p>")
body = "\n".join(out).replace("</h3>\n<li>", "</h3>\n<ul>\n<li>").replace("</li>\n<h3>", "</li>\n</ul>\n<h3>")
if body.endswith("</li>"): body += "\n</ul>"
print(f"<html><body style=\"font: 13px -apple-system, sans-serif\">\n{body}\n</body></html>")
PY
  "$SPARKLE_DIR/bin/generate_appcast" --embed-release-notes --link https://omux.app \
    --download-url-prefix "https://github.com/onurozcan/omux/releases/download/v$VERSION/" \
    -o site/appcast.xml "$STAGE" | grep -vE "^\s*$" || true
  rm -rf "$STAGE"
  echo "Updated site/appcast.xml (deploy the site to publish the update)"
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1)) and $ZIP ($(du -h "$ZIP" | cut -f1))"
[[ "$NOTARIZE" == 1 ]] && spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tail -1 || true
