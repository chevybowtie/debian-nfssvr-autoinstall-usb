#!/bin/bash

set -euo pipefail

# === CONFIGURABLE ===
UBUNTU_VERSION="24.04"
ISO_NAME="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
ISO_URL="https://old-releases.ubuntu.com/releases/24.04/ubuntu-24.04-live-server-amd64.iso"
PATCHED_ISO="ubuntu-autoinstall-nfssvr.iso"
USB_DEVICE="/dev/sdb" # ⚠ Replace this with your actual USB device (e.g., /dev/sdb)

USERNAME="backupadmin"
HASHED_PASS='REMOVED_PASSWORD_HASH'
SSH_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCXaWT8FBcf9JBWFthF6A66wotwe+kCiUrCyJokJL0aVjbi1NuqY1iA4JWo1DHZ4SgnpPWou2w0MCteRl/fGKLUyvx+K7VDEPYZYCupvP+E'
STATIC_IP="192.168.99.1/24"
NIC_NAME="enp1s0"

WORK_DIR="./iso-root"
NOCLOUD_DIR="$WORK_DIR/nocloud"

# === Check for required tools ===
REQUIRED_TOOLS=("wget" "xorriso" "dd" "mount" "umount" "sed" "tee" "cp" "cat")
echo "Checking for required tools..."
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ Required tool '$tool' is not installed. Please install it and try again."
    exit 1
  fi
done

# === Download ISO ===
if [ -f "$ISO_NAME" ]; then
  echo "ISO already exists: $ISO_NAME — skipping download."
else
  echo "Downloading Ubuntu Server ISO..."
  wget -c "$ISO_URL"
fi

# === Skip if patched ISO already exists ===
if [ -f "$PATCHED_ISO" ]; then
  echo "Patched ISO already exists: $PATCHED_ISO — skipping repack."
else
  echo "Patching ISO with nocloud and updated grub.cfg..."

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  mkdir -p mnt

  echo "Mounting original ISO..."
  sudo mount -o loop "$ISO_NAME" mnt
  cp -rT mnt "$WORK_DIR"
  sudo umount mnt
  rm -rf mnt

  echo "Injecting autoinstall config..."
  mkdir -p "$NOCLOUD_DIR"

  cat <<EOF > "$NOCLOUD_DIR/user-data"
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: nfs-backup-box
    username: ${USERNAME}
    password: ${HASHED_PASS}
  ssh:
    install-server: true
    authorized-keys:
      - ${SSH_KEY}
  locale: en_US
  keyboard:
    layout: us
  timezone: America/Chicago
  storage:
    layout:
      name: direct
    wipe: true
  network:
    version: 2
    ethernets:
      ${NIC_NAME}:
        dhcp4: false
        addresses: [${STATIC_IP}]
        gateway4: ${STATIC_IP%/*}
        nameservers:
          addresses: [8.8.8.8, 1.1.1.1]
  packages:
    - nfs-kernel-server
    - isc-dhcp-server
  late-commands:
    - curtin in-target -- mkdir -p /srv/nfs
    - curtin in-target -- chown nobody:nogroup /srv/nfs
    - curtin in-target -- bash -c 'echo "/srv/nfs 192.168.99.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports'
    - curtin in-target -- systemctl enable nfs-server
    - curtin in-target -- bash -c 'cat <<EOL > /etc/dhcp/dhcpd.conf
subnet 192.168.99.0 netmask 255.255.255.0 {
  range 192.168.99.10 192.168.99.20;
  option routers 192.168.99.1;
  option domain-name-servers 8.8.8.8;
  default-lease-time 600;
  max-lease-time 7200;
}
EOL'
    - curtin in-target -- bash -c 'echo "INTERFACESv4=\\"${NIC_NAME}\\"" > /etc/default/isc-dhcp-server'
    - curtin in-target -- systemctl enable isc-dhcp-server
EOF

  touch "$NOCLOUD_DIR/meta-data"

  echo "Replacing GRUB config with custom autoinstall entry..."
  GRUB_CFG="$WORK_DIR/boot/grub/grub.cfg"
  cat <<EOF > "$GRUB_CFG"
set timeout=5
menuentry 'Automated Ubuntu NFS Server Install' {
    linux /casper/vmlinuz autoinstall ds=nocloud;s=/cdrom/nocloud/ ---
    initrd /casper/initrd
}
EOF

  echo "Rebuilding ISO..."
  xorriso -as mkisofs -r -V "UBUNTU_NFSSVR" \
    -o "$PATCHED_ISO" \
    -J -l \
    -eltorito-boot boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-catalog boot/grub/boot.cat \
    "$WORK_DIR" 2> >(grep -v "symbolic links were omitted from Joliet tree" \
                      | grep -v "Cannot add" \
                      | grep -v "Joliet")

  echo "✅ Patched ISO created: $PATCHED_ISO"
fi

# === Write ISO to USB ===
echo "Writing patched ISO to USB ($USB_DEVICE)..."
sudo dd if="$PATCHED_ISO" of="$USB_DEVICE" bs=4M status=progress oflag=sync
