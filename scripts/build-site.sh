#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

installer=Voltra-0.1.0-macOS.dmg
package_dir=build/site
if [ ! -s "build/$installer" ]; then
    printf 'Missing build/%s. Run ./build-installer.sh first.\n' "$installer" >&2
    exit 1
fi

mkdir -p "$package_dir/downloads"
cp site/index.html site/styles.css site/language.js "$package_dir/"
cp -R site/assets "$package_dir/"
cp "build/$installer" "$package_dir/downloads/"
(cd "$package_dir/downloads" && shasum -a 256 "$installer" > "$installer.sha256")
printf 'Static site ready at %s\n' "$package_dir"
