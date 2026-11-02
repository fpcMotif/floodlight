#!/bin/sh
# Wraps the compiled executable and the platform library in
# "Floodlight GPUIX.app": its own bundle id and data folder, so it runs beside
# the Swift app, and LSUIElement, so it never shows in the Dock. The Full Disk
# Access grant belongs to this bundle.
#
#   scripts/bundle.sh BUILD_DIR
set -eu

build=$1
app="$build/Floodlight GPUIX.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$build/floodlight-gpuix" "$app/Contents/MacOS/floodlight-gpuix"
cp "$build/libfloodlight_gpuix.dylib" "$app/Contents/MacOS/"
# GPUIX's renderer: the compiled executable cannot embed it (src/main.tsx).
cp node_modules/@gpuix/native-darwin-*/gpuix-native.darwin-*.node "$app/Contents/MacOS/"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>floodlight-gpuix</string>
  <key>CFBundleIdentifier</key><string>com.floodlight.gpuix</string>
  <key>CFBundleName</key><string>Floodlight GPUIX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Copying into the bundle invalidates the linker's ad-hoc signature. macOS
# ties the Full Disk Access grant to this signature's code hash, so every
# rebuild needs `tccutil reset SystemPolicyAllFiles com.floodlight.gpuix`.
codesign --force --sign - "$app/Contents/MacOS/libfloodlight_gpuix.dylib" "$app/Contents/MacOS/"gpuix-native.*.node
codesign --force --sign - "$app"
echo "bundle: $app"
