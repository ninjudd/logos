#!/bin/sh
# Checks that the agent prompt shown on the site, in the <pre id="prompt">
# block of web/index.html, is the same text as web/install.md. The site's
# Copy prompt button copies the block, and agents fetch install.md, so both
# must say the same thing. Vercel runs this before every deploy.
set -eu
cd "$(dirname "$0")/.."

# Prints the block's text, with the page's HTML escapes undone.
embedded() {
  awk '
    !on && /<pre id="prompt">/ { on = 1; sub(/.*<pre id="prompt">/, "") }
    on && /<\/pre>/ { sub(/<\/pre>.*/, ""); print; exit }
    on { print }
  ' web/index.html | sed 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'
}

# Vercel's build image has no diff, so compare in the shell and show a diff
# only where one is installed.
if [ "$(embedded)" != "$(cat web/install.md)" ]; then
  if command -v diff >/dev/null; then embedded | diff -u web/install.md - >&2 || true; fi
  echo "check-prompt: the prompt in web/index.html differs from web/install.md." >&2
  echo "Copy web/install.md into the <pre id=\"prompt\"> block, escaping &, <, and >." >&2
  exit 1
fi
echo "check-prompt: web/index.html and web/install.md match"
