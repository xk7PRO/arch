#!/bin/bash
if grep -q $'\r' "$0"; then
    tmpfile=$(mktemp)
    tr -d '\r' < "$0" > "$tmpfile"
    mv "$tmpfile" "$0"
    chmod +x "$0"
    exec "$0" "$@"
fi
pacman -S --noconfirm nvidia-dkms nvidia-utils lib32-nvidia-utils egl-wayland
echo "options nvidia_drm modeset=1" > /etc/modprobe.d/nvidia.conf
mkinitcpio -P
