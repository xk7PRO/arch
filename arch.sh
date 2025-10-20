#!/bin/bash
set -e

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

pacman -Sy --noconfirm python reflector curl || true
if [[ "$COUNTRY" != "WORLDWIDE" ]]; then
    if ! reflector --country "$COUNTRY" --protocol https --sort rate --latest 10 --save /etc/pacman.d/mirrorlist; then
        cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://mirror.pkgbuild.com/$repo/os/$arch
Server = https://cloudflaremirrors.com/archlinux/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirror.pit.teraswitch.com/archlinux/$repo/os/$arch
Server = https://archlinux.thaller.ws/$repo/os/$arch
EOF
    fi
else
    cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://mirror.pkgbuild.com/$repo/os/$arch
Server = https://cloudflaremirrors.com/archlinux/$repo/os/$arch
Server = https://mirror.osbeck.com/archlinux/$repo/os/$arch
Server = https://mirror.pit.teraswitch.com/archlinux/$repo/os/$arch
EOF
fi

parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
parted -s "$DISK" set 1 boot on
parted -s "$DISK" mkpart primary linux-swap 1025MiB 5121MiB
parted -s "$DISK" mkpart primary ext4 5121MiB 100%

BOOT="${DISK}1"
SWAP="${DISK}2"
ROOT="${DISK}3"

mkfs.fat -F32 "$BOOT"
mkswap "$SWAP"
mkfs.ext4 -F "$ROOT"

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot
swapon "$SWAP"

pacstrap /mnt base linux linux-firmware vim nano networkmanager grub efibootmgr sudo git base-devel python reflector curl
genfstab -U /mnt >> /mnt/etc/fstab

read -rp "Install NVIDIA drivers (nvidia-dkms + 32-bit libs + egl-wayland)? [y/N]: " INSTALL_NVIDIA
if [[ "$INSTALL_NVIDIA" =~ ^[Yy]$ ]]; then
    NVIDIA_PKGS="nvidia-dkms nvidia-utils lib32-nvidia-utils egl-wayland"
else
    NVIDIA_PKGS=""
fi

arch-chroot /mnt /bin/bash <<EOF
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat <<H >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
H

echo "root:$ROOTPASS" | chpasswd
useradd -m -G wheel,video,audio,input -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm

if command -v reflector >/dev/null 2>&1; then
    reflector --country "$COUNTRY" --protocol https --sort rate --latest 10 --save /etc/pacman.d/mirrorlist || true
fi

pacman -S --noconfirm hyprland sddm kitty neovim nano nautilus noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ttf-dejavu ttf-font-awesome ${NVIDIA_PKGS}

if [[ -n "${NVIDIA_PKGS}" ]]; then
    echo "options nvidia_drm modeset=1" > /etc/modprobe.d/nvidia.conf
    mkinitcpio -P
fi

echo "alias vim='nvim'" >> /etc/bash.bashrc

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable NetworkManager
systemctl enable sddm.service

sudo -u $USERNAME bash <<Y
cd /home/$USERNAME
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si --noconfirm
yay -S --noconfirm brave-bin
Y
EOF

echo "Run: umount -R /mnt && swapoff $SWAP && reboot"
