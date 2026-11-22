#!/bin/sh
# Stage 1 — runs as root inside the Alpine live environment (booted from the ISO).
# Installs Alpine onto the VM's disk with an EFI/GRUB layout, unattended.
set -eu

TIMEZONE=UTC
[ -r /mnt/setup/host.env ] && . /mnt/setup/host.env

# Target: the one writable virtio disk that is not the (read-only) install media.
DISK=
for d in /sys/block/vd*; do
	[ "$(cat "$d/ro")" = 0 ] || continue
	grep -q "^/dev/${d##*/}" /proc/mounts && continue
	DISK=/dev/${d##*/}
done
[ -n "$DISK" ] || { echo "no writable target disk found"; exit 1; }
echo "installing to $DISK"

cat > /tmp/answers <<EOF
KEYMAPOPTS="us us"
HOSTNAMEOPTS=alpine
DEVDOPTS=mdev
INTERFACESOPTS="auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
"
TIMEZONEOPTS="$TIMEZONE"
PROXYOPTS=none
NTPOPTS=chrony
APKREPOSOPTS="-1 -c"
USEROPTS=none
SSHDOPTS=none
DISKOPTS="-m sys $DISK"
LBUOPTS=none
APKCACHEOPTS=none
EOF

# The installer was booted by the host loading the kernel directly, so there is
# no EFI in this boot; USE_EFI forces the GPT + ESP + GRUB layout the VM's EFI
# firmware needs afterwards. ERASE_DISKS answers the "erase disk?" prompt.
export USE_EFI=1 ERASE_DISKS="$DISK"
setup-alpine -e -f /tmp/answers

# Make sure the installed system offers a login on the virtio console.
root_part=$(blkid | awk -F: -v d="$DISK" 'index($1, d) == 1 && /TYPE="ext4"/ {print $1}' | tail -n 1)
[ -n "$root_part" ] || { echo "cannot find installed root partition"; exit 1; }
mkdir -p /mnt/target
mount "$root_part" /mnt/target
grep -q '^hvc0:' /mnt/target/etc/inittab ||
	echo 'hvc0::respawn:/sbin/getty -L 0 hvc0 vt100' >> /mnt/target/etc/inittab
grep -q '^hvc0$' /mnt/target/etc/securetty 2>/dev/null || echo hvc0 >> /mnt/target/etc/securetty
# setup-disk records every mount it sees, including this script's own share.
sed -i '/^shared[[:space:]]/d' /mnt/target/etc/fstab
umount /mnt/target
sync
echo "stage 1 complete"
