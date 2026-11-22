#!/bin/sh
# Build vms/alpine from scratch: unattended Alpine install, then desktop,
# Chromium and Claude Code. Takes roughly ten minutes on a fast connection.
#
#   scripts/make-alpine.sh [stage1|stage2]     (default: both)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION=3.24.4
ISO_SHA256=c0e2e9a8cb2f4848c5dc56ba26f58fbe4fdabdd35780b25a6c36f217ef67359f
IMAGES=$ROOT/images/alpine
ISO=$IMAGES/alpine-standard-$VERSION-aarch64.iso
VM=$ROOT/vms/alpine
STAGE=${1:-all}

[ -x bin/vmctl ] || ./build.sh
mkdir -p "$IMAGES/boot" logs shared

if [ ! -f "$ISO" ]; then
	curl -fL --retry 3 -o "$ISO.part" \
		"https://dl-cdn.alpinelinux.org/alpine/v${VERSION%.*}/releases/aarch64/$(basename "$ISO")"
	mv "$ISO.part" "$ISO"
fi
echo "$ISO_SHA256  $ISO" | shasum -a 256 -c -

if [ "$STAGE" = all ] || [ "$STAGE" = stage1 ]; then
	# The host loads the installer kernel itself so it can put a login on the
	# virtio serial port (console=hvc0). console=tty0 has to stay in front of
	# it: the hvc driver is a module, and without an early console the
	# installer's init runs with no stdio and fails to unpack its root.
	# Virtualization.framework wants a raw arm64 Image; Alpine ships an EFI
	# zboot wrapper around a gzip stream, so unwrap it.
	bsdtar -xf "$ISO" -C "$IMAGES/boot" --strip-components 1 boot/vmlinuz-lts boot/initramfs-lts
	python3 -I - "$IMAGES/boot/vmlinuz-lts" "$IMAGES/boot/Image" <<'EOF'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
if data[4:8] == b"zimg":
    offset, size = struct.unpack_from("<II", data, 8)
    kind = data[24:32].rstrip(b"\0").decode()
    if kind != "gzip":
        sys.exit("unsupported zboot compression: " + kind)
    data = zlib.decompress(data[offset:offset + size], 31)
elif data[:2] == b"\x1f\x8b":
    data = zlib.decompress(data, 31)
if data[56:60] != b"ARM\x64":
    sys.exit("not an arm64 kernel Image")
open(sys.argv[2], "wb").write(data)
EOF

	[ -f "$VM/config.json" ] || bin/vmctl linux-create "$VM" --disk 32 --cpus 4 --mem 3
	echo "TIMEZONE=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')" > scripts/guest/host.env

	echo "== stage 1: installing Alpine (log: logs/alpine-stage1.log)"
	scripts/alpine-console.exp install.sh \
		bin/vmctl linux-run "$VM" --headless \
		--kernel "$IMAGES/boot/Image" --initrd "$IMAGES/boot/initramfs-lts" \
		--cmdline "console=tty0 console=hvc0 modules=loop,squashfs,sd-mod,usb-storage,virtio_blk" \
		--iso "$ISO" --share "$ROOT/scripts/guest" > logs/alpine-stage1.log 2>&1 ||
		{ tail -n 40 logs/alpine-stage1.log; exit 1; }
fi

if [ "$STAGE" = all ] || [ "$STAGE" = stage2 ]; then
	echo "== stage 2: desktop, Chromium, Claude Code (log: logs/alpine-stage2.log)"
	scripts/alpine-console.exp provision.sh \
		bin/vmctl linux-run "$VM" --headless \
		--share "$ROOT/scripts/guest" > logs/alpine-stage2.log 2>&1 ||
		{ tail -n 40 logs/alpine-stage2.log; exit 1; }
fi

# Share the kit's shared/ folder with the VM (VM Manager can change this later).
python3 -I - "$VM/config.json" "$ROOT/shared" <<'PY'
import json, sys
p, shared = sys.argv[1], sys.argv[2]
cfg = json.load(open(p))
cfg.setdefault("shares", [{"path": shared, "readOnly": False}])
json.dump(cfg, open(p, "w"), indent=2, sort_keys=True)
PY
echo "done — start it with ./alpine"
