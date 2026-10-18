#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
configuration=${RELIO_BUILD_CONFIGURATION:-release}
app=dist/Prism.app
swift build -c "$configuration"
mkdir -p $app/Contents/MacOS
cp .build/"$configuration"/Relio $app/Contents/MacOS/Relio
cp packaging/Info.plist $app/Contents/Info.plist
mkdir -p dist/Prism.iconset $app/Contents/Resources/Fonts
cp THIRD-PARTY-NOTICES.md $app/Contents/Resources/
cp licenses/OpenShorts-MIT.txt $app/Contents/Resources/
# Prism brand fonts (SIL Open Font License; each license ships beside its font).
cp packaging/Fonts/*.ttf packaging/Fonts/OFL-*.txt $app/Contents/Resources/Fonts/
swift scripts/generate-icon.swift dist/Prism.iconset/icon_512x512@2x.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" dist/Prism.iconset/icon_512x512@2x.png --out "dist/Prism.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" dist/Prism.iconset/icon_512x512@2x.png --out "dist/Prism.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns dist/Prism.iconset -o $app/Contents/Resources/Prism.icns
# The generated bundle can inherit Finder/File Provider attributes from an existing artifact.
# Clear metadata from this build output before signing so codesign sees only app resources.
xattr -cr $app
if [[ -n "${RELIO_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$RELIO_SIGNING_IDENTITY" $app
else
  codesign --force --sign - $app
fi
codesign --verify --strict $app
echo "Created $app"
