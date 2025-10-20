#!/bin/bash
set -e
LOGFILE="$(pwd)/archinstall.log"
exec > >(tee -a "$LOGFILE") 2>&1

mark_done() { touch ".step_$1"; }
is_done() { [[ -f ".step_$1" ]]; }

cleanup_steps() {
    rm -f .step_* .var_* 2>/dev/null || true
    echo "✔️ Cleanup complete — all step markers removed."
}

echo "=== Arch Linux Resumable Installer ==="
echo "Logs: $LOGFILE"

if ! is_done "env"; then
    read -rp "Enter target disk (e.g. /dev/sda or /dev/nvme0n1): " DISK
    read -rp "Enter hostname: " HOSTNAME
    read -rp "Enter username: " USERNAME
    read -rsp "Enter password for $USERNAME: " PASSWORD; echo
    read -rsp "Enter root password: " ROOTPASS; echo
    read -rp "Enter timezone (e.g. Europe/Athens, default UTC): " TIMEZONE
    TIMEZONE=${TIMEZONE:-UTC}
    echo "$DISK" > .var_disk
    echo "$HOSTNAME" > .var_hostname
    echo "$USERNAME" > .var_username
    echo "$PASSWORD" > .var_userpass
    echo "$ROOTPASS" > .var_rootpass
    echo "$TIMEZONE" > .var_timezone
    mark_done env
else
    DISK=$(<.var_disk)
    HOSTNAME=$(<.var_hostname)
    USERNAME=$(<.var_username)
    PASSWORD=$(<.var_userpass)
    ROOTPASS=$(<.var_rootpass)
    TIMEZONE=$(<.var_timezone)
fi

if ! is_done "mirrors"; then
    COUNTRY=$(curl -s https://ipinfo.io/country || echo "")
    [[ -z "$COUNTRY" ]] && read -rp "Enter your 2-letter country code: " COUNTRY
    COUNTRY=${COUNTRY^^}
    COUNTRY=${COUNTRY:-WORLDWIDE}
    pacman -Sy --noconfirm python reflector curl bc || true
    echo "Setting up mirrors for $COUNTRY..."
    if ! reflector --country "$COUNTRY" --protocol https --sort rate --latest 10 --save /etc/pacman.d/mirrorlist; then
        echo "⚠️ Reflector failed, using fallback mirrors."
        cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://mirror.pkgbuild.com/$repo/os/$arch
Server = https://cloudflaremirrors.com/archlinux/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirror.osbeck.com/archlinux/$repo/os/$arch
EOF
    fi
    mark_done mirrors
fi

if ! is_done "partition"; then
    read -rp "Create swap partition? [y/N]: " CREATE_SWAP
    if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
        read -rp "Enter swap size in GB (can be decimal, e.g. 4.5): " SWAP_SIZE
        SWAP_END=$(printf "%.0f" "$(echo "1024 + ($SWAP_SIZE * 1024)" | bc -l)")
    else
        SWAP_SIZE=0
    fi

    echo "Partitioning $DISK..."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
    parted -s "$DISK" set 1 boot on

    if (( $(echo "$SWAP_SIZE > 0" | bc -l) )); then
        parted -s "$DISK" mkpart primary linux-swap 1025MiB ${SWAP_END}MiB
        parted -s "$DISK" mkpart primary ext4 ${SWAP_END}MiB 100%
        echo "$DISK 1 2 3" > .var_parts
    else
        parted -s "$DISK" mkpart primary ext4 1025MiB 100%
        echo "$DISK 1 0 2" > .var_parts
    fi
    mark_done partition
else
    read d b s r <<<"$(<.var_parts)"
fi

read d b s r <<<"$(<.var_parts)"
BOOT="${d}${b}"
SWAP=$([[ "$s" != 0 ]] && echo "${d}${s}" || echo "")
ROOT="${d}${r}"

if ! mountpoint -q /mnt; then
    echo "Mounting partitions..."
    mkfs.fat -F32 "$BOOT" || true
    mkfs.ext4 -F "$ROOT" || true
    mount "$ROOT" /mnt || true
    mkdir -p /mnt/boot
    mount "$BOOT" /mnt/boot || true
    if [[ -n "$SWAP" ]]; then
        mkswap "$SWAP" || true
        swapon "$SWAP" || true
    fi
else
    echo "/mnt already mounted — skipping format/mount."
fi
mark_done format

if ! is_done "base"; then
    echo "Installing base system..."
    pacstrap /mnt base linux linux-firmware vim nano networkmanager grub efibootmgr sudo git base-devel python reflector curl bc || {
        echo "⚠️ pacstrap failed — you can rerun the script to retry."
        exit 1
    }
    genfstab -U /mnt >> /mnt/etc/fstab
    mark_done base
fi

if ! is_done "options"; then
    read -rp "Install NVIDIA drivers? [y/N]: " INSTALL_NVIDIA
    read -rp "Install Hyprland (Wayland compositor)? [y/N]: " INSTALL_HYPR
    read -rp "Install SDDM (login manager)? [y/N]: " INSTALL_SDDM
    echo "$INSTALL_NVIDIA $INSTALL_HYPR $INSTALL_SDDM" > .var_opts
    mark_done options
else
    read INSTALL_NVIDIA INSTALL_HYPR INSTALL_SDDM <<<"$(<.var_opts)"
fi

if ! is_done "chroot"; then
arch-chroot /mnt /bin/bash <<EOF
set -e
exec > >(tee -a "$LOGFILE") 2>&1
ln -sf /usr/share/zoneinfo/$(<.var_timezone) /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$(cat .var_hostname)" > /etc/hostname
cat <<H >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $(cat .var_hostname).localdomain $(cat .var_hostname)
H
echo "root:$(cat .var_rootpass)" | chpasswd
useradd -m -G wheel,video,audio,input -s /bin/bash $(cat .var_username)
echo "$(cat .var_username):$(cat .var_userpass)" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm
if command -v reflector >/dev/null 2>&1; then reflector --country "$(curl -s https://ipinfo.io/country || echo WORLDWIDE)" --protocol https --sort rate --latest 10 --save /etc/pacman.d/mirrorlist || true; fi
NVIDIA_PKGS=""
HYPR_PKGS=""
SDDM_PKGS=""
[[ "$INSTALL_NVIDIA" =~ ^[Yy]$ ]] && NVIDIA_PKGS="nvidia-dkms nvidia-utils lib32-nvidia-utils egl-wayland"
[[ "$INSTALL_HYPR" =~ ^[Yy]$ ]] && HYPR_PKGS="hyprland"
[[ "$INSTALL_SDDM" =~ ^[Yy]$ ]] && SDDM_PKGS="sddm"
pacman -S --noconfirm \$HYPR_PKGS \$SDDM_PKGS kitty neovim nano nautilus noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-dejavu ttf-font-awesome \$NVIDIA_PKGS || true
if [[ -n "\$NVIDIA_PKGS" ]]; then echo "options nvidia_drm modeset=1" > /etc/modprobe.d/nvidia.conf; mkinitcpio -P; fi
echo "alias vim='nvim'" >> /etc/bash.bashrc
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable NetworkManager
if [[ -n "\$SDDM_PKGS" ]]; then systemctl enable sddm.service; fi
sudo -u $(cat .var_username) bash <<Y
cd /home/$(cat .var_username)
git clone https://aur.archlinux.org/yay-bin.git || cd yay-bin
makepkg -si --noconfirm || true
yay -S --noconfirm brave-bin || true
Y
EOF
    mark_done chroot
fi

cleanup_steps
echo "✅ Installation complete!"
echo "You can reboot after: umount -R /mnt && swapoff -a"
echo "Logs: $LOGFILE"
