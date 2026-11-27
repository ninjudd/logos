#!/bin/bash
# Builds build/Logos.app from this checkout. With --install, also installs it
# the way install.sh does: in /Applications, with the logos command, restarted.
#
# macOS ties Accessibility and Microphone permission to the app's signature, so
# every build is signed with the same identity:
#   - CODESIGN_IDENTITY, when set.
#   - Otherwise an Apple Development or Developer ID certificate, when you have one.
#   - Otherwise a self-signed "Logos Local Signing" certificate, created once in
#     its own keychain in ~/Library/Application Support/Logos, or in
#     LOGOS_SIGNING_DIR. Set CODESIGN_IDENTITY="Logos Local Signing" to use it
#     even when you have another certificate.
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
signing_dir="${LOGOS_SIGNING_DIR:-$HOME/Library/Application Support/Logos}"
keychain="$signing_dir/signing.keychain-db"
password_file="$signing_dir/signing-keychain-password"

# Creates the self-signed signing certificate. The key signs only this app on
# this Mac, so its keychain's password is kept in a file readable only by you.
create_local_identity() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$signing_dir"
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
identity="${identity:-$local_identity}"
keychain_args=()
if [[ "$identity" == "$local_identity" ]]; then
  [[ -f "$keychain" && -f "$password_file" ]] || create_local_identity
  security unlock-keychain -p "$(cat "$password_file")" "$keychain"
  keychain_args=(--keychain "$keychain")
fi
codesign --force ${keychain_args[@]+"${keychain_args[@]}"} --sign "$identity" "$app"
echo "Built $app (signed with $identity)"
