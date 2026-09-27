#!/bin/sh
# Compile le CLI (./sillio) et l'app (./Sillio.app).
#
#   ./build.sh                               développement, architecture de la machine
#   SILLIO_ARCHS="arm64 x86_64" ./build.sh   binaire universel (utilisé par package.sh)
set -e
cd "$(dirname "$0")"

ARCHS="${SILLIO_ARCHS:-$(uname -m)}"
MIN_MACOS=14.2
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ENGINE="Sources/Localization.swift Sources/Engine.swift"
CLI_SOURCES="$ENGINE Sources/CLI/main.swift"
APP_SOURCES="$ENGINE Sources/Mark.swift Sources/App/Design.swift Sources/App/Panel.swift Sources/App/Overlay.swift Sources/App/Main.swift"

# build_binary <sortie> <drapeaux supplémentaires> <sources…>
build_binary() {
  out=$1
  extra=$2
  shift 2
  slices=""
  for arch in $ARCHS; do
    slice="$TMP/$(basename "$out").$arch"
    # shellcheck disable=SC2086
    swiftc -O -swift-version 5 -target "$arch-apple-macosx$MIN_MACOS" $extra -o "$slice" "$@"
    slices="$slices $slice"
  done
  # shellcheck disable=SC2086
  if [ "$(echo $ARCHS | wc -w)" -gt 1 ]; then
    lipo -create $slices -output "$out"
  else
    cp $slices "$out"
  fi
}

# --- CLI : Info.plist embarqué dans le binaire pour la permission de capture audio.
# shellcheck disable=SC2086
# Signé dans le dossier temporaire : un binaire « sillio » posé dans un dossier « sillio » est pris
# par codesign pour un paquet, qui inspecte alors tout le dépôt (et refuse les attributs du Finder).
build_binary "$TMP/sillio" "-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist" $CLI_SOURCES
codesign --force --sign - --identifier studio.zwyk.sillio.cli "$TMP/sillio"
mv "$TMP/sillio" sillio
echo "OK → $(pwd)/sillio"

# --- App
APP="Sillio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# shellcheck disable=SC2086
build_binary "$APP/Contents/MacOS/Sillio" "-parse-as-library" $APP_SOURCES
cp App/Info.plist "$APP/Contents/Info.plist"
[ -f App/AppIcon.icns ] && cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Les dossiers de langue : macOS y lit le texte de la demande d'autorisation, et s'en sert pour
# savoir que l'app parle anglais et français (ses propres boutons suivent alors la même langue).
cp -R App/en.lproj App/fr.lproj "$APP/Contents/Resources/"

# Signature : identité Developer ID si elle est fournie, sinon signature locale (ad-hoc).
if [ -n "$SILLIO_SIGN_ID" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SILLIO_SIGN_ID" "$APP"
else
  codesign --force --deep --sign - --identifier studio.zwyk.sillio "$APP"
fi
echo "OK → $(pwd)/$APP  ($(lipo -archs "$APP/Contents/MacOS/Sillio"))"
