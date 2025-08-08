#!/bin/bash

set -euo pipefail

# Debian unattended installer (hd-media method) USB creator
# Avoids remastering the ISO. It:
#  1. Partitions the USB (single FAT32 ESP)
#  2. Downloads the Debian netinst ISO if missing (kept untouched)
#  3. Downloads hd-media vmlinuz + initrd.gz and places them on the USB
#  4. Copies the untouched ISO file onto the USB root
#  5. Places preseed.cfg at /hd-media/preseed.cfg
#  6. Installs GRUB (UEFI removable) and adds an entry with iso-scan + preseed
# Result: Fully automated install with late_command configuring NFS/DHCP.

SECONDS=0

# === CONFIGURABLE ===
ISO_FILE="debian-12.11.0-amd64-netinst.iso"
# hd-media kernel/initrd (matches Debian 12/bookworm installer)
HDMEDIA_BASE="https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/hd-media"
USB_DEVICE="/dev/sdb"   # override with --usb-device /dev/sdX
MOUNT_USB="/mnt/usb"
PRESEED_FILE="preseed.cfg"   # local preseed source
GRUB_VERBOSE=false
PROMPT_DEVICE=false

usage() { echo "Usage: $0 [--usb-device DEVICE] [--grub-verbose] [--prompt]"; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --usb-device) USB_DEVICE="$2"; shift 2;;
    --grub-verbose) GRUB_VERBOSE=true; shift;;
    --prompt) PROMPT_DEVICE=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

if $PROMPT_DEVICE; then
  echo "Please insert the USB key and press Enter."
  read -r
  echo "Detecting USB device..."
  before_devices=$(lsblk -dn -o NAME)
  sleep 5
  after_devices=$(lsblk -dn -o NAME)
  new_device=$(comm -13 <(echo "$before_devices") <(echo "$after_devices"))
  
  if [[ -z $new_device ]]; then
    echo "No new device detected via lsblk. Checking dmesg logs..."
    new_device=$(dmesg | grep -Eo 'sd[a-z]' | tail -1)
    if [[ -z $new_device ]]; then
      echo "No new device detected. Aborting." >&2
      exit 1
    fi
  fi

  USB_DEVICE="/dev/$new_device"
  echo "Detected USB device: $USB_DEVICE"
fi

# Required tools
for cmd in parted mkfs.vfat grub-install mount umount udevadm partprobe mkdir wipefs blkid rsync curl wget; do
  command -v $cmd >/dev/null 2>&1 || { echo "Missing required tool: $cmd" >&2; exit 1; }
done

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Obtain netinst ISO if absent (untouched file, copied to USB root)
if [[ ! -f $ISO_FILE ]]; then
  echo "Downloading $ISO_FILE ..."
  if command -v wget >/dev/null; then
    wget -O "$ISO_FILE" "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$ISO_FILE"
  else
    curl -L -o "$ISO_FILE" "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$ISO_FILE"
  fi
fi

read -rp "This will ERASE ALL DATA on $USB_DEVICE. Continue? (yes/NO) " confirm
[[ $confirm == "yes" ]] || { echo "Aborted."; exit 1; }

# Unmount anything mounted
umount ${USB_DEVICE}?* 2>/dev/null || true

echo "Wiping partition table signatures..."
wipefs --all "$USB_DEVICE"
# Nuke first/last few MB just in case
dd if=/dev/zero of="$USB_DEVICE" bs=1M count=8 status=none || true
blocksz=$(blockdev --getsz "$USB_DEVICE")
seekpos=$(( blocksz / 2048 - 8 ))
(( seekpos > 0 )) && dd if=/dev/zero of="$USB_DEVICE" bs=1M count=8 seek=$seekpos status=none || true

echo "Creating single FAT32 GPT ESP..."
parted --script "$USB_DEVICE" \
  mklabel gpt \
  mkpart primary fat32 1MiB 100% \
  set 1 esp on \
  set 1 boot on

partprobe "$USB_DEVICE"; udevadm settle

# Wait for partition node
for i in {1..10}; do [[ -b ${USB_DEVICE}1 ]] && break; sleep 1; done
[[ -b ${USB_DEVICE}1 ]] || { echo "Partition ${USB_DEVICE}1 not found" >&2; exit 1; }

mkfs.vfat -F32 -n NFSSVR_BOOT "${USB_DEVICE}1"

mkdir -p "$MOUNT_USB"
mount ${USB_DEVICE}1 "$MOUNT_USB"

# Fetch hd-media kernel and initrd directly to USB
echo "Downloading hd-media kernel and initrd..."
if command -v wget >/dev/null; then
  wget -O "$MOUNT_USB/vmlinuz" "$HDMEDIA_BASE/vmlinuz"
  wget -O "$MOUNT_USB/initrd.gz" "$HDMEDIA_BASE/initrd.gz"
else
  curl -L -o "$MOUNT_USB/vmlinuz" "$HDMEDIA_BASE/vmlinuz"
  curl -L -o "$MOUNT_USB/initrd.gz" "$HDMEDIA_BASE/initrd.gz"
fi

# Copy whole ISO to root (untouched) so iso-scan can find it
cp "$ISO_FILE" "$MOUNT_USB/$ISO_FILE"

# Place preseed in /hd-media (installer will mount the USB and we point preseed/file there)
mkdir -p "$MOUNT_USB/hd-media"
cp "$PRESEED_FILE" "$MOUNT_USB/hd-media/preseed.cfg"

# Create minimal GRUB config
mkdir -p "$MOUNT_USB/boot/grub"
cat > "$MOUNT_USB/boot/grub/grub.cfg" <<EOF
timeout=3
default=0

menuentry 'Automated Debian NFS/DHCP Install' {
    insmod part_gpt
    insmod fat
    linux /vmlinuz auto=true priority=critical locale=en_US.UTF-8 \\
        debian-installer/locale=en_US.UTF-8 \\
        console-setup/ask_detect=false console-setup/layoutcode=us \\
        keyboard-configuration/xkb-keymap=us \\
        preseed/file=/hd-media/preseed.cfg \\
        iso-scan/filename=$ISO_FILE iso-scan/ask=false \\
        iso-scan/scan-all=true cdrom-detect/try-usb=true \\
        netcfg/choose_interface=auto rootdelay=5 \\
        fb=false debian-installer=en_US \\
        quiet
    initrd /initrd.gz
}
EOF

# Install GRUB (UEFI removable path)
if $GRUB_VERBOSE; then set -x; fi

grub-install \
  --target=x86_64-efi \
  --efi-directory="$MOUNT_USB" \
  --boot-directory="$MOUNT_USB/boot" \
  --removable \
  --no-nvram

# Ensure fallback bootloader path exists
if [[ -f "$MOUNT_USB/EFI/BOOT/BOOTX64.EFI" ]]; then
  echo "UEFI fallback present." >/dev/null
else
  # Some distros place grubx64.efi under EFI/grub; copy if present
  if [[ -f "$MOUNT_USB/EFI/grub/grubx64.efi" ]]; then
    mkdir -p "$MOUNT_USB/EFI/BOOT"
    cp "$MOUNT_USB/EFI/grub/grubx64.efi" "$MOUNT_USB/EFI/BOOT/BOOTX64.EFI"
  fi
fi

sync
umount "$MOUNT_USB" || true

elapsed=$SECONDS
echo "Done. USB ready. Time: $((elapsed/60))m $((elapsed%60))s)"
echo "Boot target system with this USB (UEFI). The installer will find the ISO via iso-scan and run unattended."