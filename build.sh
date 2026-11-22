#!/bin/sh
# Build vmctl and sign it with the virtualization entitlement (ad-hoc signature).
# Builds to a temporary name and renames it into place, so a VM that is already
# running from bin/vmctl keeps its (unchanged) executable.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
	-framework Virtualization -framework AppKit \
	-o bin/vmctl.new vmctl/main.swift
codesign --force --sign - --entitlements vmctl/vmctl.entitlements bin/vmctl.new
mv -f bin/vmctl.new bin/vmctl
echo "built bin/vmctl"
