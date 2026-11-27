#!/bin/bash
# Redraws the app icon, the site's share image, and its favicon from the glyph
# in Sources/Logos/Glyph.swift, so they always match the menu bar icon.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/artwork scripts/artwork/main.swift Sources/Logos/Glyph.swift
build/artwork
