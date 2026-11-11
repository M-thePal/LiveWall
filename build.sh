#!/bin/bash
# Builds LiveWall.app next to this script.
set -e
cd "$(dirname "$0")"
APP=LiveWall.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
# macOS 13 is the floor (SMAppService); Intel + Apple Silicon so it runs on any friend's Mac
for arch in arm64 x86_64; do swiftc -O -target $arch-apple-macos13.0 *.swift -o "/tmp/LiveWall-$arch"; done
lipo -create /tmp/LiveWall-arm64 /tmp/LiveWall-x86_64 -output "$APP/Contents/MacOS/LiveWall"; rm /tmp/LiveWall-arm64 /tmp/LiveWall-x86_64
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LiveWall</string>
<key>CFBundleIdentifier</key><string>local.livewall</string>
<key>CFBundleName</key><string>LiveWall</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
echo "Built $APP"
