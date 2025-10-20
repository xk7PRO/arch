#!/bin/bash
if grep -q $'\r' "$0"; then
    tmpfile=$(mktemp)
    tr -d '\r' < "$0" > "$tmpfile"
    mv "$tmpfile" "$0"
    chmod +x "$0"
    exec "$0" "$@"
fi
pacman -S --noconfirm hyprland kitty neovim nautilus \
noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-dejavu ttf-font-awesome
