#!/bin/zsh
set -eu
cd "${0:A:h}"
appPath="${VOLTRA_PACKAGE_APP:-build/package/Voltra.app}"
imagePath="${VOLTRA_DMG_OUTPUT:-build/Voltra-0.1.0-macOS.dmg}"
if [[ "${VOLTRA_REUSE_APP:-0}" != 1 ]]; then
  VOLTRA_BUILD_OUTPUT="$appPath" ./build-app.sh
fi
codesign --verify --deep --strict "$appPath"
if ! command -v dmgbuild >/dev/null 2>&1; then
  print -u2 'dmgbuild is required: python3 -m pip install dmgbuild==1.6.5'
  exit 1
fi
mkdir -p "${imagePath:h}"
dmgbuild -s scripts/dmg-settings.py -D "app=${appPath:A}" Voltra "$imagePath"
print "Imagem criada em $imagePath"
