#!/bin/sh
# First-time setup on a Mac: make the scripts executable (a download or web upload
# can drop that flag), build the VM runner, and build and install VM Manager in
# /Applications. Safe to run again after updating.
#
#   sh install.sh
set -eu
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
	echo "The Xcode Command Line Tools are needed. Starting their installer;"
	echo "run this script again when it has finished."
	xcode-select --install
	exit 1
fi
[ "$(uname -m)" = arm64 ] || { echo "VM Manager needs a Mac with Apple silicon."; exit 1; }

chmod +x install.sh build.sh build-app.sh alpine mac \
	scripts/*.sh scripts/*.exp scripts/vm-activity scripts/vm-prompt \
	scripts/guest/*.sh scripts/kiosk/*.sh scripts/kiosk/vm-agent scripts/kiosk/vm-link-sessions \
	scripts/netguard/*.sh scripts/netguard/vm-netguard scripts/kiosk-check/*.sh \
	shared/setup-mac-guest.sh
mkdir -p vms shared/projects

./build.sh
./build-app.sh
echo
echo "VM Manager is in /Applications. Next, build the VMs you want:"
echo "  scripts/make-kiosk.sh     Debian Claude kiosk (Claude Desktop, Chromium, Claude Code)"
echo "  scripts/make-alpine.sh    Alpine with XFCE, Chromium and Claude Code"
echo "  scripts/make-mac.sh       macOS (downloads Apple's ~25 GB restore image)"
