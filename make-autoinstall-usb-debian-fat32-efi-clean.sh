#!/bin/bash

set -euo pipefail

# Start timing the script
SECONDS=0

# === CONFIGURABLE ===
ISO_FILE="debian-12.11.0-amd64-netinst.iso"
USB_DEVICE="/dev/sdb" # <-- double check this
MOUNT_ISO="/mnt/iso"
MOUNT_USB="/mnt/usb"
PRESEED_FILE="preseed.cfg"
GRUB_CFG_FILE="grub.cfg"

# === Parse Command-Line Arguments ===
GRUB_VERBOSE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --grub-verbose)
      GRUB_VERBOSE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# === Check for required tools ===
for cmd in parted mkfs.vfat grub-install mount umount rsync udevadm partprobe mkdir cat wipefs; do
  command -v $cmd >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done

# === Confirm device ===
echo "This will ERASE ALL DATA on $USB_DEVICE. Continue? (yes/NO)"
read confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

# === Unmount and prepare USB ===
umount ${USB_DEVICE}* || true

# === Remove RAID metadata (if any) ===
echo "Removing any existing RAID metadata from $USB_DEVICE..."
wipefs --all "$USB_DEVICE"


# === Remove RAID metadata (if any) ===
echo "Removing any existing RAID metadata from $USB_DEVICE..."
wipefs --all "$USB_DEVICE"
dd if=/dev/zero of="$USB_DEVICE" bs=1M count=10 status=progress
dd if=/dev/zero of="$USB_DEVICE" bs=1M count=10 seek=$(( $(blockdev --getsz "$USB_DEVICE") / 2048 - 10 )) status=progress



echo "Partitioning USB..."
parted --script "$USB_DEVICE" \
  mklabel gpt \
  mkpart primary fat32 1MiB 100% \
  set 1 boot on \
  set 1 esp on

partprobe "$USB_DEVICE"
udevadm settle

echo "Waiting for ${USB_DEVICE}1 to appear..."
for i in {1..10}; do
  [ -b ${USB_DEVICE}1 ] && break
  sleep 1
done

[ -b ${USB_DEVICE}1 ] || { echo "❌ Partition ${USB_DEVICE}1 not found."; exit 1; }

mkfs.vfat -F32 -n "NFSSVR_BOOT" "${USB_DEVICE}1"

# === Mount points ===
mkdir -p "$MOUNT_ISO" "$MOUNT_USB"
mount "$ISO_FILE" "$MOUNT_ISO"
mount ${USB_DEVICE}1 "$MOUNT_USB"

# === Copy ISO contents ===
echo "Copying files..."
rsync -aHAX --no-links --info=progress2 "$MOUNT_ISO/" "$MOUNT_USB/"

# === Inject preseed ===
echo "Injecting preseed..."
mkdir -p "$MOUNT_USB/preseed"
cp "./$PRESEED_FILE" "$MOUNT_USB/preseed.cfg"

# === Write custom GRUB config ===
echo "Creating GRUB config..."
cat > "$MOUNT_USB/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "Automated NFS Server Install" {
    set gfxpayload=keep
    linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg console=tty0 ipv6.disable=1 efi=runtime quiet
    initrd /install.amd/initrd.gz
}
EOF

echo "Disabling RAID scanning in GRUB..."
mkdir -p "$MOUNT_USB/boot/grub"
echo 'GRUB_DISABLE_LINUX_MDRAID=true' >> "$MOUNT_USB/boot/grub/grub.cfg"


# === Install GRUB ===
echo "Installing GRUB..."
if [[ "$GRUB_VERBOSE" == true ]]; then
  grub-install \
    --target=x86_64-efi \
    --efi-directory="$MOUNT_USB" \
    --boot-directory="$MOUNT_USB/boot" \
    --removable \
    --no-nvram \
    --verbose
else
  grub-install \
    --target=x86_64-efi \
    --efi-directory="$MOUNT_USB" \
    --boot-directory="$MOUNT_USB/boot" \
    --removable \
    --no-nvram
fi

echo "GRUB installation completed."

# === Cleanup ===
umount "$MOUNT_USB"
umount "$MOUNT_ISO"

# Calculate and display the total time taken
total_time=$SECONDS
echo "⏱️ Total time taken: $((total_time / 60)) minutes and $((total_time % 60)) seconds."
echo "✅ USB key is ready for UEFI boot with automated Debian install."
