#!/bin/bash
set +e

if grep -q $'\r' "$0"; then
    tmpfile=$(mktemp)
    tr -d '\r' < "$0" > "$tmpfile"
    mv "$tmpfile" "$0"
    chmod +x "$0"
    exec "$0" "$@"
fi

retry() {
    local cmd="$1"
    until bash -c "$cmd"; do
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

read -rp "Install Hyprland? [y/N]: " INSTALL_HYPR
read -rp "Install NVIDIA drivers? [y/N]: " INSTALL_NVIDIA
read -rp "Install SDDM? [y/N]: " INSTALL_SDDM

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

if [[ "$DISK" == *"nvme"* ]]; then
    P1="${DISK}p1"
    P2="${DISK}p2"
    P3="${DISK}p3"
else
    P1="${DISK}1"
    P2="${DISK}2"
    P3="${DISK}3"
fi

if (( $(echo "$SWAP_SIZE > 0" | bc -l) )); then
    retry "parted -s \"$DISK\" mkpart primary linux-swap 1025MiB ${SWAP_END}MiB"
    retry "parted -s \"$DISK\" mkpart primary ext4 ${SWAP_END}MiB 100%"
    SWAP="$P2"
    ROOT="$P3"
else
    retry "parted -s \"$DISK\" mkpart primary ext4 1025MiB 100%"
    SWAP=""
    ROOT="$P2"
fi

BOOT="$P1"

retry "mkfs.fat -F32 \"$BOOT\""
retry "mkfs.ext4 -F \"$ROOT\""
retry "mount \"$ROOT\" /mnt"
retry "mkdir -p /mnt/boot"
retry "mount \"$BOOT\" /mnt/boot"
if [[ -n "$SWAP" ]]; then retry "mkswap \"$SWAP\""; retry "swapon \"$SWAP\""; fi

retry "pacstrap /mnt base linux linux-firmware linux-headers vim nano networkmanager grub efibootmgr sudo python reflector curl bc"
retry "genfstab -U /mnt >> /mnt/etc/fstab"

mkdir -p /mnt/root
echo "$TIMEZONE" > /mnt/root/tmp_timezone
echo "$HOSTNAME" > /mnt/root/tmp_hostname
echo "$USERNAME" > /mnt/root/tmp_username
echo "$PASSWORD" > /mnt/root/tmp_userpass
echo "$ROOTPASS" > /mnt/root/tmp_rootpass
echo "$COUNTRY" > /mnt/root/tmp_country
echo "$INSTALL_HYPR" > /mnt/root/tmp_hypr
echo "$INSTALL_NVIDIA" > /mnt/root/tmp_nvidia
echo "$INSTALL_SDDM" > /mnt/root/tmp_sddm

retry "arch-chroot /mnt /bin/bash -e" <<'CHROOT'
set -e
ln -sf /usr/share/zoneinfo/$(cat /root/tmp_timezone) /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$(cat /root/tmp_hostname)" > /etc/hostname
cat <<H >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $(cat /root/tmp_hostname).localdomain $(cat /root/tmp_hostname)
H
echo "root:$(cat /root/tmp_rootpass)" | chpasswd
useradd -m -G wheel,audio,video,input -s /bin/bash $(cat /root/tmp_username)
echo "$(cat /root/tmp_username):$(cat /root/tmp_userpass)" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm git
cd /root
git clone https://github.com/xk7PRO/arch
echo "KEYMAP=us" > /etc/vconsole.conf
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable NetworkManager

if [[ "$(cat /root/tmp_hypr)" =~ ^[Yy]$ ]]; then bash /root/arch/hypr.sh; fi
if [[ "$(cat /root/tmp_nvidia)" =~ ^[Yy]$ ]]; then bash /root/arch/nvidia.sh; fi
if [[ "$(cat /root/tmp_sddm)" =~ ^[Yy]$ ]]; then bash /root/arch/sddm.sh; fi
CHROOT

echo "Run: umount -R /mnt && swapoff -a && reboot"