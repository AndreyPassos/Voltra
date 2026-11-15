#!/bin/zsh
set -eu
cd "${0:A:h}"
outputPath="${VOLTRA_BUILD_OUTPUT:-build/Voltra.app}"
iconTemp="$(mktemp -d "${TMPDIR:-/tmp}/voltra-icon.XXXXXX")"
trap 'rm -rf -- "$iconTemp"' EXIT
swift build -c release
mkdir -p "$outputPath/Contents/MacOS" "$outputPath/Contents/Resources"
swift scripts/make-icon.swift "$iconTemp/Voltra.iconset"
iconutil -c icns "$iconTemp/Voltra.iconset" -o "$outputPath/Contents/Resources/Voltra.icns"
cp .build/release/Voltra "$outputPath/Contents/MacOS/Voltra"
cp Info.plist "$outputPath/Contents/Info.plist"
cp -R Resources/*.lproj "$outputPath/Contents/Resources/"
cp Resources/CaffeeeLabs.png "$outputPath/Contents/Resources/CaffeeeLabs.png"
codesign --force --deep --sign "${VOLTRA_SIGN_IDENTITY:--}" "$outputPath"
print "Aplicativo criado em $outputPath"
