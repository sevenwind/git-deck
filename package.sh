#!/bin/bash
# Собирает GitDeck.app и упаковывает в GitDeck.dmg (перетащить в «Программы»)
set -e
cd "$(dirname "$0")"
./build.sh
STAGE=$(mktemp -d)
cp -R GitDeck.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f GitDeck.dmg
hdiutil create -volname "GitDeck" -srcfolder "$STAGE" -ov -format UDZO GitDeck.dmg >/dev/null
rm -rf "$STAGE"
echo "Готово: $PWD/GitDeck.dmg"
