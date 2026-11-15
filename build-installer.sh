#!/bin/zsh
set -eu
cd "${0:A:h}"
appPath="${VOLTRA_PACKAGE_APP:-build/package/Voltra.app}"
imagePath="${VOLTRA_DMG_OUTPUT:-build/Voltra-0.1.0-macOS.dmg}"
staging="$(mktemp -d "${TMPDIR:-/tmp}/voltra-dmg.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
VOLTRA_BUILD_OUTPUT="$appPath" ./build-app.sh
codesign --verify --deep --strict "$appPath"
cp -R "$appPath" "$staging/Voltra.app"
ln -s /Applications "$staging/Applications"
mkdir -p "${imagePath:h}"
hdiutil create -ov -format UDZO -volname "Voltra" -srcfolder "$staging" "$imagePath"
print "Imagem criada em $imagePath"
