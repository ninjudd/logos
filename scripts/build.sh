#!/bin/bash
# Builds build/Logos.app from this checkout. With --install, also installs it
# the way install.sh does: in /Applications, with the logos command, restarted.
#
# macOS ties Accessibility and Microphone permission to the app's signature, so
# every build is signed with the same identity:
#   - CODESIGN_IDENTITY, when set.
#   - Otherwise an Apple Development or Developer ID certificate, when you have one.
#   - Otherwise a self-signed "Logos Local Signing" certificate, created once in
#     its own keychain at ~/Library/Keychains/logos-signing.keychain-db.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--install" ]]; then
  exec ./install.sh
fi

swift build -c release

app=build/Logos.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Logos" "$app/Contents/MacOS/Logos"
cp Resources/Info.plist "$app/Contents/Info.plist"

local_identity="Logos Local Signing"
keychain="$HOME/Library/Keychains/logos-signing.keychain-db"
password_file="$HOME/Library/Application Support/Logos/signing-keychain-password"

# Creates the self-signed signing certificate. The key signs only this app on
# this Mac, so its keychain's password is kept in a file readable only by you.
create_local_identity() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$(dirname "$password_file")"
  uuidgen > "$password_file"
  chmod 600 "$password_file"
  # The system's LibreSSL writes a PKCS#12 file that `security import` can read;
  # newer OpenSSL builds default to a format it rejects.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$local_identity" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout pass:logos -name "$local_identity"
  security create-keychain -p "$(cat "$password_file")" "$keychain"
  security unlock-keychain -p "$(cat "$password_file")" "$keychain"
  security import "$tmp/id.p12" -k "$keychain" -P logos -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$password_file")" "$keychain" >/dev/null
  rm -rf "$tmp"
  echo "Created the $local_identity certificate in $keychain"
}

identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
keychain_args=()
if [[ -z "$identity" ]]; then
  identity="$local_identity"
  [[ -f "$keychain" && -f "$password_file" ]] || create_local_identity
  security unlock-keychain -p "$(cat "$password_file")" "$keychain"
  keychain_args=(--keychain "$keychain")
fi
codesign --force ${keychain_args[@]+"${keychain_args[@]}"} --sign "$identity" "$app"
echo "Built $app (signed with $identity)"
