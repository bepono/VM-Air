#!/bin/sh
# Stage 2 — runs as root inside the freshly installed Alpine system.
# Adds a small XFCE desktop, Chromium and Claude Code for the user "alpine".
set -eu

USER_NAME=alpine
USER_HOME=/home/$USER_NAME

apk update

# Prefer an ungoogled build if this Alpine release ships one; otherwise Chromium.
if [ -n "$(apk search -x ungoogled-chromium 2>/dev/null)" ]; then
	BROWSER=ungoogled-chromium
else
	BROWSER=chromium
fi
echo "browser package: $BROWSER"

# Xorg + udev (Alpine's own helper), then the desktop on top of it.
setup-xorg-base \
	xfce4 xfce4-terminal lightdm lightdm-gtk-greeter \
	elogind polkit-elogind dbus dbus-x11 gvfs \
	adwaita-icon-theme font-dejavu font-noto-emoji \
	spice-vdagent \
	"$BROWSER"

# Command-line tools; libgcc, libstdc++ and ripgrep are what Claude Code needs on musl.
apk add bash curl git ripgrep libgcc libstdc++ doas ca-certificates openssh-client nano

# User: no password (account is locked for password logins), signed in
# automatically by the display manager, passwordless doas via the wheel group.
id "$USER_NAME" >/dev/null 2>&1 || adduser -D -s /bin/bash -g "Alpine" "$USER_NAME"
addgroup -S autologin 2>/dev/null || true
for g in wheel audio video input netdev autologin; do
	addgroup "$USER_NAME" "$g" 2>/dev/null || true
done
mkdir -p /etc/doas.d
echo 'permit nopass :wheel' > /etc/doas.d/20-wheel.conf

mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=$USER_NAME
autologin-user-timeout=0
autologin-session=xfce
EOF

for svc in dbus elogind lightdm spice-vdagentd; do
	if rc-service --exists "$svc"; then rc-update add "$svc" default; fi
done

# Boot console: kernel messages on both the screen and the serial port, with the
# screen (tty0) last so it is /dev/console and exists before any module loads.
# GRUB itself only needs the screen.
sed -i \
	-e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/ *console=[^ "]*//g' \
	-e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ console=hvc0 console=tty0"/' \
	-e '/^GRUB_SERIAL_COMMAND=/d' \
	-e 's/^GRUB_TERMINAL_INPUT=.*/GRUB_TERMINAL_INPUT=console/' \
	-e 's/^GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT=console/' \
	/etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Host folder share: the VM runner exposes a directory under the tag "shared".
# (Also drop the installer's own mount of it, which setup-disk copied into fstab.)
sed -i '/^shared[[:space:]]\/setup[[:space:]]/d' /etc/fstab
umount /setup 2>/dev/null || true
rmdir /setup 2>/dev/null || true
grep -qx virtiofs /etc/modules || echo virtiofs >> /etc/modules
mkdir -p /mnt/shared
grep -q '^shared ' /etc/fstab || echo 'shared /mnt/shared virtiofs rw,nofail 0 0' >> /etc/fstab

# Claude Code environment for login shells and for terminals opened in the desktop.
cat > /etc/profile.d/claude-code.sh <<'EOF'
case ":$PATH:" in
	*":$HOME/.local/bin:"*) ;;
	*) export PATH="$HOME/.local/bin:$PATH" ;;
esac
export USE_BUILTIN_RIPGREP=0
EOF

BROWSER_CMD=$BROWSER
[ "$BROWSER" = chromium ] || BROWSER_CMD=$(basename "$(apk info -L "$BROWSER" | grep -m1 '^usr/bin/')")

su - "$USER_NAME" -c "sh -s" <<EOF
set -eu
grep -qs claude-code.sh ~/.bashrc || echo '. /etc/profile.d/claude-code.sh' >> ~/.bashrc
ln -sfn /mnt/shared ~/shared

# Use the stock panel layout instead of asking on first login, and make
# the browser the desktop's default.
mkdir -p ~/.config/xfce4/xfconf/xfce-perchannel-xml
[ -e ~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml ] ||
	cp /etc/xdg/xfce4/panel/default.xml ~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
printf 'WebBrowser=%s\nTerminalEmulator=xfce4-terminal\n' "$BROWSER_CMD" > ~/.config/xfce4/helpers.rc

curl -fsSL https://claude.ai/install.sh | bash
EOF

echo "--- installed"
su "$USER_NAME" -c 'cd && bash -lc "claude --version"'
"$BROWSER_CMD" --version 2>/dev/null || apk info -e "$BROWSER"
echo "stage 2 complete"
