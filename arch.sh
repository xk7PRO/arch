#!/bin/bash
set -e
LOGFILE="$(pwd)/archinstall.log"
exec > >(tee -a "$LOGFILE") 2>&1
mark_done() { touch ".step_$1"; }
is_done() { [[ -f ".step_$1" ]]; }
cleanup_steps() { rm -f .step_* .var_* 2>/dev/null || true; }

mkdir -p /etc/pacman.d
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf 2>/dev/null || true
echo "XferCommand = /usr/bin/curl -L --fail --retry 3 --retry-delay 3 -o %o %u" >> /etc/pacman.conf

if ! is_done "env"; then
    read -rp "Disk: " DISK
    read -rp "Hostname: " HOSTNAME
    read -rp "Username: " USERNAME
    read -rsp "User password: " PASSWORD; echo
    read -rsp "Root password: " ROOTPASS; echo
    read -rp "Timezone (default UTC): " TIMEZONE
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
    [[ -z "$COUNTRY" ]] && read -rp "Country code: " COUNTRY
    COUNTRY=${COUNTRY^^}
    COUNTRY=${COUNTRY:-WORLDWIDE}
    cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = http://mirror.pkgbuild.com/$repo/os/$arch
Server = http://archlinux.thaller.ws/$repo/os/$arch
Server = http://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = http://mirror.pit.teraswitch.com/archlinux/$repo/os/$arch
EOF
    pacman -Sy --noconfirm reflector curl bc || true
    reflector --country "$COUNTRY" --protocol https,http --sort rate --latest 10 --save /etc/pacman.d/mirrorlist --threads 10 --connection-timeout 5 || true
    mark_done mirrors
fi

if ! is_done "partition"; then
    read -rp "Create swap? [y/N]: " CREATE_SWAP
    if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
        read -rp "Swap size (GB): " SWAP_SIZE
        SWAP_END=$(printf "%.0f" "$(echo "1024 + ($SWAP_SIZE * 1024)" | bc -l)")
    else
        SWAP_SIZE=0
    fi
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
    mkfs.fat -F32 "$BOOT" || true
    mkfs.ext4 -F "$ROOT" || true
    mount "$ROOT" /mnt || true
    mkdir -p /mnt/boot
    mount "$BOOT" /mnt/boot || true
    if [[ -n "$SWAP" ]]; then mkswap "$SWAP" || true; swapon "$SWAP" || true; fi
fi
mark_done format

if ! is_done "base"; then
    pacstrap /mnt base linux linux-firmware vim nano networkmanager grub efibootmgr sudo git base-devel python reflector curl bc
    genfstab -U /mnt >> /mnt/etc/fstab
    mark_done base
fi

if ! is_done "options"; then
    read -rp "Install NVIDIA? [y/N]: " INSTALL_NVIDIA
    read -rp "Install Hyprland? [y/N]: " INSTALL_HYPR
    read -rp "Install SDDM? [y/N]: " INSTALL_SDDM
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
127.0.0.1 localhost
::1 localhost
127.0.1.1 $(cat .var_hostname).localdomain $(cat .var_hostname)
H
echo "root:$(cat .var_rootpass)" | chpasswd
useradd -m -G wheel,video,audio,input -s /bin/bash $(cat .var_username)
echo "$(cat .var_username):$(cat .var_userpass)" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm
reflector --country "$(curl -s https://ipinfo.io/country || echo WORLDWIDE)" --protocol https,http --sort rate --latest 10 --save /etc/pacman.d/mirrorlist --threads 10 --connection-timeout 5 || true
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
echo "Installation complete. You can reboot after: umount -R /mnt && swapoff -a"
echo "Logs: $LOGFILE"
