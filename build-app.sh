#!/bin/sh
# Build "VM Manager.app" and install it in /Applications.
#
#   ./build-app.sh            build and install
#   ./build-app.sh --no-install   build into ./build only
#
# Layout of the bundle:
#   VM Manager.app/Contents/MacOS/VM Manager              the manager (SwiftUI)
#   VM Manager.app/Contents/Helpers/VM Runner.app         vmctl, one process per running VM
set -eu
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

BUILD=$ROOT/build
APP=$BUILD/VM\ Manager.app
RUNNER=$APP/Contents/Helpers/VM\ Runner.app
VERSION=1.0
SWIFTC="swiftc -O -swift-version 5 -target arm64-apple-macos14.0"

mkdir -p "$BUILD"
[ -d "$APP" ] && rm -r "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
	"$RUNNER/Contents/MacOS" "$RUNNER/Contents/Resources"

echo "== icon"
[ -d "$BUILD/AppIcon.iconset" ] && rm -r "$BUILD/AppIcon.iconset"
swift manager/make-icon.swift "$BUILD/AppIcon.iconset"
iconutil -c icns -o "$BUILD/AppIcon.icns" "$BUILD/AppIcon.iconset"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD/AppIcon.icns" "$RUNNER/Contents/Resources/AppIcon.icns"

echo "== VM Runner (vmctl)"
$SWIFTC -framework Virtualization -framework AppKit \
	-o "$RUNNER/Contents/MacOS/vmctl" vmctl/main.swift

echo "== VM Manager"
$SWIFTC -parse-as-library -framework SwiftUI -framework AppKit \
	-o "$APP/Contents/MacOS/VM Manager" manager/App.swift manager/Model.swift manager/Views.swift

plist() { # file key value...
	f=$1; shift
	/usr/libexec/PlistBuddy -c "Clear dict" "$f" >/dev/null 2>&1 || true
	while [ $# -ge 3 ]; do
		/usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$f" >/dev/null
		shift 3
	done
}
plist "$RUNNER/Contents/Info.plist" \
	CFBundleIdentifier string local.vmmanager.runner \
	CFBundleName string "VM Runner" \
	CFBundleDisplayName string "VM Runner" \
	CFBundleExecutable string vmctl \
	CFBundleIconFile string AppIcon \
	CFBundlePackageType string APPL \
	CFBundleShortVersionString string "$VERSION" \
	CFBundleVersion string "$VERSION" \
	LSMinimumSystemVersion string 14.0 \
	NSHighResolutionCapable bool true
plist "$APP/Contents/Info.plist" \
	CFBundleIdentifier string local.vmmanager \
	CFBundleName string "VM Manager" \
	CFBundleDisplayName string "VM Manager" \
	CFBundleExecutable string "VM Manager" \
	CFBundleIconFile string AppIcon \
	CFBundlePackageType string APPL \
	CFBundleShortVersionString string "$VERSION" \
	CFBundleVersion string "$VERSION" \
	LSMinimumSystemVersion string 14.0 \
	LSApplicationCategoryType string public.app-category.developer-tools \
	NSHighResolutionCapable bool true \
	VMFolderDefault string "$ROOT/vms"

echo "== sign (ad-hoc)"
codesign --force --sign - --entitlements vmctl/vmctl.entitlements "$RUNNER"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

if [ "${1:-}" != "--no-install" ]; then
	echo "== install"
	# Swap the bundle in place. A running VM Manager (and any VM it started) keeps
	# running on the old copy; the new one is used from its next launch.
	DEST="/Applications/VM Manager.app"
	NEW="/Applications/.VM Manager.app.new"
	[ -d "$NEW" ] && rm -r "$NEW"
	ditto "$APP" "$NEW"
	[ -d "$DEST" ] && rm -r "$DEST"
	mv "$NEW" "$DEST"
	pgrep -qf "$DEST/Contents/MacOS/VM Manager" && echo "VM Manager is open: quit and reopen it to use the new version (running VMs are not affected)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
	echo "installed $DEST"
fi
