#!/bin/sh
# Run this INSIDE the macOS VM, after finishing Setup Assistant:
#
#   sh "/Volumes/My Shared Files/setup-mac-guest.sh"
#
# Installs Google Chrome into /Applications and Claude Code into ~/.local/bin.
set -eu

tmp=$(mktemp -d)
trap 'hdiutil detach -quiet "$tmp/mnt" 2>/dev/null || true; rm -rf "$tmp"' EXIT

if [ ! -d "/Applications/Google Chrome.app" ]; then
	echo "Downloading Google Chrome..."
	curl -fL -o "$tmp/chrome.dmg" \
		https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg
	hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$tmp/chrome.dmg"
	ditto "$tmp/mnt/Google Chrome.app" "/Applications/Google Chrome.app"
	hdiutil detach -quiet "$tmp/mnt"
fi

if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
	echo "Installing Claude Code..."
	curl -fsSL https://claude.ai/install.sh | bash
fi

if ! grep -qs '\.local/bin' "$HOME/.zprofile"; then
	echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
fi

echo
"$HOME/.local/bin/claude" --version
echo "Chrome: /Applications/Google Chrome.app"
echo "Open a new Terminal window, then run: claude"
