#!/bin/sh
# Choose the install target disk for the preseed (runs from partman/early_command, just before partitioning).
# Usage: select-disk.sh [TARGET_DISK]
# An explicit TARGET_DISK wins. Otherwise pick the first disk that is neither
# USB-attached nor the device the installer media was loaded from, so the
# installer never repartitions its own stick.

TARGET="$1"

if [ -z "$TARGET" ]; then
  src=$(mount | grep -E ' on /(hd-media|cdrom)( |$)' | head -n1 | cut -d' ' -f1)

  for d in $(list-devices disk); do
    n=${d##*/}
    case "$src" in "$d"*) continue ;; esac
    case "$(readlink -f "/sys/block/$n" 2>/dev/null)" in */usb*) continue ;; esac
    TARGET=$d
    break
  done
fi

if [ -z "$TARGET" ]; then
  logger -t select-disk "no suitable non-USB target disk found; set TARGET_DISK in .env"
  exit 1
fi

logger -t select-disk "install target: $TARGET"
echo "$TARGET" > /tmp/target_disk
debconf-set partman-auto/disk "$TARGET"
debconf-set grub-installer/bootdev "$TARGET"

# Clear stale signatures on the target only
dd if=/dev/zero of="$TARGET" bs=1M count=8 || true
