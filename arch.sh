#!/bin/bash
set +e

if grep -q $'\r' "$0"; then
    tmpfile=$(mktemp)
    tr -d '\r' < "$0" > "$tmpfile"
    mv "$tmpfile" "$0"
    chmod +x "$0"
    exec "$0" "$@"
fi

LOGFILE="$(dirname "$0")/arch_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

retry() {
    local cmd="$1"
    until $cmd; do
        echo "Command failed: $cmd"
        read -rp "Retry? [y/N]: " retry
        [[ "$retry" =~ ^[Yy]$ ]] || return 1
    done
}

read -rp "Enter target disk (e.g. /dev/sda or /dev/nvme0n1): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
read -rsp "Enter password for $USERNAME: " PASSWORD
echo
read -rsp "Enter root password: " ROOTPASS
echo
read -rp "Enter timezone (e.g. Europe/Athens, default UTC): " TIMEZONE
TIMEZONE=${TIMEZONE:-UTC}

COUNTRY=$(curl -s https://ipinfo.io/country || echo "")
if [ -z "$COUNTRY" ]; then
    read -rp "Enter your 2-letter country code (e.g. GR, DE, US): " COUNTRY
fi
COUNTRY=${COUNTRY^^}
COUNTRY=${COUNTRY:-WORLDWIDE}

retry "pacman -Sy --noconfirm python reflector curl bc || true"
if [[ "$COUNTRY" != "WORLDWIDE" ]]; then
    if ! reflector --country "$COUNTRY" --protocol http,https --sort rate --latest 10 --save /etc/pacman.d/mirrorlist; then
        cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://mirror.pkgbuild.com/$repo/os/$arch
Server = http://mirror.pkgbuild.com/$repo/os/$arch
Server = https://cloudflaremirrors.com/archlinux/$repo/os/$arch
Server = http://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirror.pit.teraswitch.com/archlinux/$repo/os/$arch
Server = http://archlinux.thaller.ws/$repo/os/$arch
EOF
    fi
else
    cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://mirror.pkgbuild.com/$repo/os/$arch
Server = http://mirror.pkgbuild.com/$repo/os/$arch
Server = https://cloudflaremirrors.com/archlinux/$repo/os/$arch
Server = http://mirror.osbeck.com/archlinux/$repo/os/$arch
Server = https://mirror.pit.teraswitch.com/archlinux/$repo/os/$arch
EOF
fi

read -rp "Create swap partition? [y/N]: " CREATE_SWAP
if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
    read -rp "Enter swap size in GB (can be decimal, e.g. 4.5): " SWAP_SIZE
    SWAP_END=$(printf "%.0f" "$(echo "1024 + ($SWAP_SIZE * 1024)" | bc -l)")
else
    SWAP_SIZE=0
fi

retry "parted -s \"$DISK\" mklabel gpt"
retry "parted -s \"$DISK\" mkpart ESP fat32 1MiB 1025MiB"
retry "parted -s \"$DISK\" set 1 boot on"

if (( $(echo "$SWAP_SIZE > 0" | bc -l) )); then
    retry "parted -s \"$DISK\" mkpart primary linux-swap 1025MiB ${SWAP_END}MiB"
    retry "parted -s \"$DISK\" mkpart primary ext4 ${SWAP_END}MiB 100%"
    SWAP="${DISK}2"
    ROOT="${DISK}3"
else
    retry "parted -s \"$DISK\" mkpart primary ext4 1025MiB 100%"
    SWAP=""
    ROOT="${DISK}2"
fi

BOOT="${DISK}1"

retry "mkfs.fat -F32 \"$BOOT\""
retry "mkfs.ext4 -F \"$ROOT\""
retry "mount \"$ROOT\" /mnt"
retry "mkdir -p /mnt/boot"
retry "mount \"$BOOT\" /mnt/boot"
if [[ -n "$SWAP" ]]; then retry "mkswap \"$SWAP\""; retry "swapon \"$SWAP\""; fi

retry "pacstrap /mnt base linux linux-firmware vim nano networkmanager grub efibootmgr sudo git base-devel python reflector curl bc"
retry "genfstab -U /mnt >> /mnt/etc/fstab"

read -rp "Install NVIDIA drivers? [y/N]: " INSTALL_NVIDIA
if [[ "$INSTALL_NVIDIA" =~ ^[Yy]$ ]]; then
    NVIDIA_PKGS="nvidia-dkms nvidia-utils lib32-nvidia-utils egl-wayland"
else
    NVIDIA_PKGS=""
fi

read -rp "Install Hyprland (Wayland compositor)? [y/N]: " INSTALL_HYPR
if [[ "$INSTALL_HYPR" =~ ^[Yy]$ ]]; then
    HYPR_PKGS="hyprland"
else
    HYPR_PKGS=""
fi

read -rp "Install SDDM (login manager)? [y/N]: " INSTALL_SDDM
if [[ "$INSTALL_SDDM" =~ ^[Yy]$ ]]; then
    SDDM_PKGS="sddm"
else
    SDDM_PKGS=""
fi

retry "arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo \"LANG=en_US.UTF-8\" > /etc/locale.conf
echo \"$HOSTNAME\" > /etc/hostname
cat <<H >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
H
echo \"root:$ROOTPASS\" | chpasswd
useradd -m -G wheel,video,audio,input -s /bin/bash $USERNAME
echo \"$USERNAME:$PASSWORD\" | chpasswd
echo \"%wheel ALL=(ALL:ALL) ALL\" > /etc/sudoers.d/wheel
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm
if command -v reflector >/dev/null 2>&1; then reflector --country \"$COUNTRY\" --protocol http,https --sort rate --latest 10 --save /etc/pacman.d/mirrorlist || true; fi
pacman -S --noconfirm ${HYPR_PKGS} ${SDDM_PKGS} kitty neovim nano nautilus noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-dejavu ttf-font-awesome ${NVIDIA_PKGS}
if [[ -n \"${NVIDIA_PKGS}\" ]]; then echo \"options nvidia_drm modeset=1\" > /etc/modprobe.d/nvidia.conf; mkinitcpio -P; fi
echo \"alias vim='nvim'\" >> /etc/bash.bashrc
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable NetworkManager
if [[ -n \"${SDDM_PKGS}\" ]]; then systemctl enable sddm.service; fi
sudo -u $USERNAME bash <<Y
cd /home/$USERNAME
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si --noconfirm
yay -S --noconfirm brave-bin
Y
EOF"

echo "Run: umount -R /mnt && swapoff -a && reboot"
echo "Log saved to: $LOGFILE"
