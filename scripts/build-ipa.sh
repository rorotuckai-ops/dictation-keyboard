#!/bin/sh
# Builds an unsigned .ipa for SideStore / AltStore, which sign it with your Apple ID.
set -eu
cd "$(dirname "$0")/.."
[ -d DictationKeyboard.xcodeproj ] || xcodegen generate
xcodebuild -project DictationKeyboard.xcodeproj -scheme DictationKeyboard -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DD \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
rm -rf build/Payload && mkdir -p build/Payload
cp -R build/DD/Build/Products/Release-iphoneos/DictationKeyboard.app build/Payload/
(cd build && rm -f DictationKeyboard.ipa && zip -qry DictationKeyboard.ipa Payload)
echo "Wrote build/DictationKeyboard.ipa"
