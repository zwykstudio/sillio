#!/bin/sh
# Fabrique un DMG prêt à partager : dist/Sillio-<version>.dmg
#
#   ./package.sh            reprend la version de App/Info.plist
#   ./package.sh 1.1        passe l'app en 1.1, puis fabrique le DMG
#
# Signature Apple (facultative, évite l'avertissement Gatekeeper chez les autres) :
#   SILLIO_SIGN_ID="Developer ID Application: Prénom Nom (TEAMID)" \
#   SILLIO_NOTARY_PROFILE="mon-profil-notarytool" ./package.sh
#
# SILLIO_LAYOUT_OPTIONAL=1 : si le Finder refuse de ranger la fenêtre (machine sans session
# graphique, CI capricieuse), livrer quand même le DMG, sans mise en page, au lieu d'échouer.
set -e
cd "$(dirname "$0")"

PLIST=App/Info.plist
if [ -n "$1" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$PLIST"
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
DMG="dist/Sillio-$VERSION.dmg"

echo "→ Compilation universelle (Apple Silicon + Intel)"
SILLIO_ARCHS="arm64 x86_64" ./build.sh

if [ -n "$SILLIO_SIGN_ID" ]; then
  codesign --verify --strict --verbose=1 Sillio.app
else
  echo "→ Signature locale : la personne qui reçoit l'app devra l'ouvrir une fois par clic droit"
fi

echo "→ Assemblage du DMG"
mkdir -p dist
STAGE=$(mktemp -d)
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -force -quiet 2>/dev/null
  rm -rf "$STAGE"
}
trap cleanup EXIT

# Fond de la fenêtre, en 1x et 2x réunis dans un seul TIFF pour les écrans Retina.
swiftc -swift-version 5 -O -o "$STAGE/make-background" Tools/make-dmg-background/main.swift
mkdir -p "$STAGE/root/.background"
"$STAGE/make-background" 1 "$STAGE/background.png"
"$STAGE/make-background" 2 "$STAGE/background@2x.png"
tiffutil -cathidpicheck "$STAGE/background.png" "$STAGE/background@2x.png" \
  -out "$STAGE/root/.background/fond.tiff" 2>/dev/null

cp -R Sillio.app "$STAGE/root/Sillio.app"
ln -s /Applications "$STAGE/root/Applications"

# Un DMG en lecture-écriture d'abord : le Finder doit pouvoir y enregistrer la mise en page.
VOLNAME="Sillio $VERSION"
hdiutil detach "/Volumes/$VOLNAME" -force -quiet 2>/dev/null || true
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE/root" -ov -format UDRW -fs HFS+ \
  -quiet "$STAGE/rw.dmg"
layout_window() {
  MOUNT=$(hdiutil attach "$STAGE/rw.dmg" -readwrite -noverify -noautoopen \
    | awk -F'\t' '/\/Volumes\// { print $NF }')

  # Positions à garder en accord avec Tools/make-dmg-background/main.swift.
  # Les fichiers cachés sont repoussés hors de la fenêtre : un Finder réglé pour tout montrer les
  # afficherait sinon par-dessus le fond, et décalerait les icônes pour leur faire de la place.
  # La première fois, macOS demande d'autoriser le terminal à piloter le Finder.
  cp App/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
  SetFile -a V "$MOUNT/.background" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT"
  osascript <<APPLESCRIPT
with timeout of 60 seconds
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 478}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set shows item info of viewOptions to false
    set background picture of viewOptions to file ".background:fond.tiff"
    set hiddenX to 900
    repeat with hiddenName in {".background", ".VolumeIcon.icns", ".fseventsd", ".Trashes"}
      if exists item hiddenName then
        set position of item hiddenName of container window to {hiddenX, 900}
        set hiddenX to hiddenX + 150
      end if
    end repeat
    set extension hidden of item "Sillio.app" to true
    set position of item "Sillio.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    -- Surtout pas « update » : il efface .VolumeIcon.icns.
    delay 2
    close
  end tell
end tell
end timeout
APPLESCRIPT
  sleep 1
  sync
  hdiutil detach "$MOUNT" -quiet
  MOUNT=""
}

# La mise en page (.DS_Store) n'est écrite par le Finder qu'au démontage, et il lui arrive de la
# rater : la fenêtre s'ouvrirait alors nue. On relit donc l'image sans passer par le Finder, et on
# recommence si la référence à l'image de fond manque (pBBk sur les macOS récents,
# backgroundImageAlias sur les plus anciens).
layout_saved() {
  check=$(mktemp -d)
  hdiutil attach "$STAGE/rw.dmg" -readonly -nobrowse -noverify -noautoopen -quiet -mountpoint "$check"
  found=$(grep -acE 'pBBk|backgroundImageAlias' "$check/.DS_Store" 2>/dev/null || true)
  hdiutil detach "$check" -quiet
  rmdir "$check"
  [ "${found:-0}" -gt 0 ]
}

echo "→ Mise en page de la fenêtre (Finder)"
attempt=1
until layout_window && layout_saved; do
  if [ $attempt -ge 3 ]; then
    if [ -n "$SILLIO_LAYOUT_OPTIONAL" ]; then
      echo "⚠ Le Finder n'a pas enregistré la mise en page : DMG livré sans fenêtre rangée." >&2
      break
    fi
    echo "✗ Le Finder n'a pas enregistré la mise en page de la fenêtre après 3 essais." >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "  la mise en page n'a pas été enregistrée, nouvel essai ($attempt/3)"
done

rm -f "$DMG"
hdiutil convert "$STAGE/rw.dmg" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"

if [ -n "$SILLIO_NOTARY_PROFILE" ]; then
  echo "→ Notarisation Apple"
  xcrun notarytool submit "$DMG" --keychain-profile "$SILLIO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo
echo "✅ $DMG  ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
