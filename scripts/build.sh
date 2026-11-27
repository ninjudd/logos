#!/bin/bash
# Builds build/Logos.app. With --install, also copies it to /Applications and launches it.
#
# macOS ties Accessibility and Microphone permission to the app's code signature.
# Signing with your Apple Development certificate keeps that signature stable across
# rebuilds, so you grant the permissions once. Set CODESIGN_IDENTITY to choose a
# certificate; with none found, the app is signed ad hoc and macOS may ask again
# after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app=build/Logos.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Logos" "$app/Contents/MacOS/Logos"
cp Resources/Info.plist "$app/Contents/Info.plist"

identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app (signed with ${identity:-ad hoc signature})"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Logos"' 2>/dev/null || true
  rm -rf /Applications/Logos.app
  cp -R "$app" /Applications/Logos.app
  open /Applications/Logos.app
  echo "Installed and launched /Applications/Logos.app"
fi
