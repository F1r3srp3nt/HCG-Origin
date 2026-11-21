#!/usr/bin/env bash
# Build "HCG Origin.app" on macOS and package it as a zip named with version and commit.
#
#   ./scripts/build-macos-app.sh                       release build (arm64)
#   HCG_ORIGIN_ARCHS="arm64 x86_64" ./scripts/build-macos-app.sh   universal
#   HCG_ORIGIN_VARIANT=automation ./scripts/build-macos-app.sh     UI-automation build (CI screenshots/E2E)
#
# Output: build/<variant>/HCG Origin.app, build/<variant>/HCG-Origin-<version>-<commit>-macOS[-automation].zip,
#         build/tools/ (hcg-central-devservice, hcg-connector-testclient — development tools, not shipped in the app)
#
# Signing is ad hoc (local development). Not Developer ID signed, not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "error: $*" >&2; exit 1; }
[[ "$(uname)" == "Darwin" ]] || fail "build-macos-app.sh must run on macOS (found $(uname))."
for t in swift codesign plutil ditto iconutil sips lipo git; do
  command -v "$t" >/dev/null || fail "'$t' is required (install Xcode or the Command Line Tools: xcode-select --install)."
done

VARIANT="${HCG_ORIGIN_VARIANT:-release}"
[[ "$VARIANT" == release || "$VARIANT" == automation ]] || fail "HCG_ORIGIN_VARIANT must be release or automation"
ARCHS="${HCG_ORIGIN_ARCHS:-arm64}"
VERSION=$(grep -o 'marketing = "[^"]*"' Sources/HCGOriginCore/Models.swift | cut -d'"' -f2)
COMMIT=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then COMMIT="$COMMIT-dirty"; fi
BUILD_NUMBER="${HCG_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT="$ROOT/build/$VARIANT"
APP="$OUT/HCG Origin.app"
SUFFIX=""; [[ "$VARIANT" == automation ]] && SUFFIX="-automation"
ZIP="$OUT/HCG-Origin-$VERSION-$COMMIT-macOS$SUFFIX.zip"

ARCH_ARGS=()
for a in $ARCHS; do ARCH_ARGS+=(--arch "$a"); done
SWIFT_ARGS=(-c release --build-path "$ROOT/.build/$VARIANT" "${ARCH_ARGS[@]}")
[[ "$VARIANT" == automation ]] && SWIFT_ARGS+=(-Xswiftc -DHCG_UI_AUTOMATION)

echo "==> HCG Origin $VERSION ($BUILD_NUMBER) commit $COMMIT, variant $VARIANT, archs: $ARCHS"
swift --version 2>&1 | grep -m1 "Swift version" || true
echo "==> swift build"
swift build "${SWIFT_ARGS[@]}" --product HCGOrigin
swift build "${SWIFT_ARGS[@]}" --product hcg-central-devservice
swift build "${SWIFT_ARGS[@]}" --product hcg-connector-testclient
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
[[ -x "$BIN/HCGOrigin" ]] || fail "HCGOrigin binary missing at $BIN"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/tools"
cp "$BIN/HCGOrigin" "$APP/Contents/MacOS/HCGOrigin"
cp "$ROOT/Resources/Brand/hcg-wordmark.png" "$APP/Contents/Resources/"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/Resources/Brand/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$ROOT/Resources/Brand/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace HCGSourceCommit -string "$COMMIT" "$APP/Contents/Info.plist"
plutil -replace HCGBuildDate -string "$BUILD_DATE" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is invalid"
for tool in hcg-central-devservice hcg-connector-testclient; do
  cp "$BIN/$tool" "$ROOT/build/tools/$tool"
  codesign --force --sign - --timestamp=none "$ROOT/build/tools/$tool"
done

echo "==> ad-hoc signature (local development; not Developer ID, not notarized)"
codesign --force --sign - --timestamp=none "$APP"

echo "==> verify"
codesign --verify --strict --verbose=1 "$APP"
[[ "$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" == HCGOrigin ]] || fail "bad CFBundleExecutable"
echo "    archs: $(lipo -archs "$APP/Contents/MacOS/HCGOrigin")"
echo "    version: $(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")), commit $(plutil -extract HCGSourceCommit raw "$APP/Contents/Info.plist")"
for k in HCGConnectIssuer HCGConnectClientID HCGConnectRedirectURI HCGCentralOriginAPIBase HCGEcosystemAPIBase; do
  v=$(plutil -extract "$k" raw "$APP/Contents/Info.plist" 2>/dev/null || true)
  [[ -z "$v" ]] || fail "$k must be empty until issued (found '$v')"
done
if [[ "$VARIANT" == release ]] && strings "$APP/Contents/MacOS/HCGOrigin" | grep -q "HCG_ORIGIN_AUTOMATION_DIR"; then
  fail "release build contains UI-automation code"
fi

rm -f "$OUT"/HCG-Origin-*.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
cat > "$OUT/BUILD-INFO.txt" <<INFO
HCG Origin $VERSION (build $BUILD_NUMBER)
Source commit: $COMMIT
Variant: $VARIANT$( [[ "$VARIANT" == automation ]] && echo " (contains UI-automation hooks; for verification only)")
Architectures: $(lipo -archs "$APP/Contents/MacOS/HCGOrigin")
Built: $BUILD_DATE on $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m)), $(swift --version 2>&1 | grep -m1 'Swift version')
Signing: ad hoc (development). Not notarized.
Production HCG integration: not configured (no issued HCG Connect client or central API).
INFO
echo
echo "Built:   $APP"
echo "Archive: $ZIP"
echo "Tools:   $ROOT/build/tools (development service and test client)"
