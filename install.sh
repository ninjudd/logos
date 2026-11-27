#!/bin/bash
# Installs or updates Logos. It builds Logos from source on this Mac, installs
# /Applications/Logos.app, links the `logos` command, and restarts the app.
#
#   From a checkout:    ./install.sh
#   The latest release: curl -fsSL https://logosvoice.dev/install.sh | bash
#
# Environment:
#   LOGOS_REF       Tag or branch to build. Defaults to the latest release, or to
#                   the checkout itself when run from one.
#   LOGOS_REPO      GitHub repository to build from (default: ninjudd/logos).
#   LOGOS_APP_DIR   Where Logos.app goes (default: /Applications).
#   LOGOS_BIN_DIR   Where the `logos` command goes (default: ~/.local/bin).
#   LOGOS_NO_LAUNCH Set to 1 to install without starting the app.
#   GH_TOKEN        GitHub token for a private repository. Without it, the
#                   installer uses `gh` when it's logged in.
set -euo pipefail

repo="${LOGOS_REPO:-ninjudd/logos}"
app_dir="${LOGOS_APP_DIR:-/Applications}"
bin_dir="${LOGOS_BIN_DIR:-$HOME/.local/bin}"
dest="$app_dir/Logos.app"

die() {
  echo "logos install: $*" >&2
  exit 1
}

[[ "$(uname)" == Darwin ]] || die "Logos runs only on macOS."
macos="$(sw_vers -productVersion)"
(( ${macos%%.*} >= 26 )) || die "Logos needs macOS 26 or later; this Mac has $macos."
xcrun --find swift >/dev/null 2>&1 \
  || die "Logos builds with Apple's Command Line Tools. Install them with: xcode-select --install"

# Fetches a GitHub API path to stdout, with a token when one is available.
github() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "User-Agent: logos-install" "https://api.github.com/$1"
  elif command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh api "$1"
  else
    curl -fsSL -H "User-Agent: logos-install" "https://api.github.com/$1"
  fi
}

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -z "${LOGOS_REF:-}" && -n "$script_dir" && -f "$script_dir/Package.swift" ]]; then
  src="$script_dir"
  echo "Building Logos from $src"
else
  ref="${LOGOS_REF:-}"
  if [[ -z "$ref" ]]; then
    ref="$(github "repos/$repo/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)" \
      || die "couldn't read the latest release of $repo"
    [[ -n "$ref" ]] || die "$repo has no release yet. Set LOGOS_REF to a branch, such as LOGOS_REF=main."
  fi
  work="$(mktemp -d -t logos-install)"
  trap 'rm -rf "$work"' EXIT
  echo "Downloading Logos $ref from $repo"
  github "repos/$repo/tarball/$ref" > "$work/source.tar.gz" || die "couldn't download $repo at $ref"
  mkdir "$work/src"
  tar -xzf "$work/source.tar.gz" -C "$work/src" --strip-components 1
  src="$work/src"
fi

"$src/scripts/build.sh"
built="$src/build/Logos.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built/Contents/Info.plist")"

# Quit the installed app, and wait until it has exited so the new one can start.
running="^$dest/Contents/MacOS/Logos$"
if pgrep -f "$running" >/dev/null; then
  pkill -f "$running" || true
  for _ in $(seq 50); do
    pgrep -f "$running" >/dev/null || break
    sleep 0.1
  done
fi

mkdir -p "$app_dir"
rm -rf "$dest.new"
ditto "$built" "$dest.new"
rm -rf "$dest"
mv "$dest.new" "$dest"

mkdir -p "$bin_dir"
ln -sf "$dest/Contents/MacOS/Logos" "$bin_dir/logos"
echo "Installed Logos $version at $dest, with the logos command in $bin_dir"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Add $bin_dir to your PATH to run logos from a terminal." ;;
esac

if [[ "${LOGOS_NO_LAUNCH:-}" != 1 ]]; then
  open "$dest"
  echo "Started Logos"
fi
