#!/bin/bash

set -euo pipefail

# Debian unattended installer (hd-media method) USB creator
# Avoids remastering the ISO. It:
#  1. Partitions the USB (single FAT32 ESP)
#  2. Downloads the Debian netinst ISO if missing (kept untouched)
#  3. Downloads hd-media vmlinuz + initrd.gz and places them on the USB
#  4. Copies the untouched ISO file onto the USB root
#  5. Places preseed.cfg (and its helper scripts) in the USB top level; the
#     installer mounts the stick at /hd-media, so it reads /hd-media/preseed.cfg
#  6. Installs GRUB (UEFI removable) and adds an entry with iso-scan + preseed
# Result: Fully automated install with late_command configuring NFS/DHCP.

SECONDS=0

# Detect original user if running under sudo
ORIGINAL_USER="${SUDO_USER:-${USER:-root}}"
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
ORIGINAL_HOME=${ORIGINAL_HOME:-/root}

# Pick the config file: --env-file FILE (checked before parsing, since .env
# supplies the defaults), else .env. sudo strips environment variables, so this
# is a flag rather than a variable.
ENV_FILE=.env
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ ${args[i]} == --env-file ]]; then
    ENV_FILE=${args[i+1]:-}
    if [[ ! -f $ENV_FILE ]]; then
      echo "Error: --env-file '$ENV_FILE' not found" >&2
      exit 1
    fi
  fi
done

# Load the config file if it exists, otherwise use defaults
if [[ -f $ENV_FILE ]]; then
  echo "Using config: $ENV_FILE"
  # HOSTNAME/USERNAME were renamed; the old names are shell-owned and would be ignored or wrong
  if grep -qE '^(export +)?(HOSTNAME|USERNAME)=' "$ENV_FILE"; then
    echo "Error: $ENV_FILE sets HOSTNAME/USERNAME; rename them to TARGET_HOSTNAME/TARGET_USERNAME" >&2
    exit 1
  fi
  set +u; source "$ENV_FILE"; set -u
fi

# === CONFIGURABLE (with defaults) ===
ISO_FILE="${ISO_FILE:-}"  # Leave empty to auto-detect the current netinst ISO
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
HDMEDIA_BASE="${HDMEDIA_BASE:-https://deb.debian.org/debian/dists/${DEBIAN_RELEASE}/main/installer-amd64/current/images/hd-media}"
USB_DEVICE="${USB_DEVICE:-}"  # No default: pass --usb-device or let the script detect the inserted stick
MOUNT_USB="${MOUNT_USB:-}"  # Empty = private temp dir (created and removed by the script)
MOUNT_USB_CREATED=false
SSH_KEY_FILE="${SSH_KEY_FILE:-}"  # Empty = auto-detect (ed25519 preferred)
GRUB_VERBOSE="${GRUB_VERBOSE:-false}"
PROMPT_DEVICE="${PROMPT_DEVICE:-}"  # empty = prompt only when no USB_DEVICE was given
ALLOW_NON_USB="${ALLOW_NON_USB:-false}"
MAX_RETRIES="${MAX_RETRIES:-3}"
ALLOW_KERNEL_MISMATCH="${ALLOW_KERNEL_MISMATCH:-false}"  # true = continue if hd-media kernel != ISO kernel
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-false}"  # true = continue if checksums/signatures cannot be verified
DEBIAN_CD_KEY_FPR="${DEBIAN_CD_KEY_FPR:-DF9B9C49EAA9298432589D76DA87E80D6294BE9B}"  # Debian CD signing key

# Preseed template variables (with defaults)
TARGET_HOSTNAME="${TARGET_HOSTNAME:-nfssvr}"  # not HOSTNAME: bash sets that to this machine's name
DOMAIN="${DOMAIN:-local}"
STATIC_IP="${STATIC_IP:-192.168.99.1}"
NETMASK="${NETMASK:-255.255.255.0}"
SERVER_GATEWAY="${SERVER_GATEWAY:-}"           # Server's own default route on the static link; empty for a direct cable
NAMESERVERS="${NAMESERVERS:-8.8.8.8 1.1.1.1}"  # Only handed to DHCP clients if DHCP_SEND_DNS=true
DHCP_SEND_GATEWAY="${DHCP_SEND_GATEWAY:-false}"  # true = DHCP clients get this server as their default route
DHCP_SEND_DNS="${DHCP_SEND_DNS:-false}"
TIMEZONE="${TIMEZONE:-America/Chicago}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYBOARD="${KEYBOARD:-us}"
MIRROR_COUNTRY="${MIRROR_COUNTRY:-US}"
MIRROR_HOST="${MIRROR_HOST:-deb.debian.org}"
MIRROR_PATH="${MIRROR_PATH:-/debian}"
TARGET_USERNAME="${TARGET_USERNAME:-backupadmin}"
USER_FULLNAME="${USER_FULLNAME:-Backup Admin}"
USER_PASSWORD_HASH="${USER_PASSWORD_HASH:-}"
TARGET_DISK="${TARGET_DISK:-}"  # Disk to install onto, e.g. /dev/disk/by-id/...; empty = first non-USB disk
INSTALL_RECOMMENDS="${INSTALL_RECOMMENDS:-true}"  # false = install without "Recommends" (leaner; test it)
EXTRA_PACKAGES="${EXTRA_PACKAGES:-nano less}"  # Installed besides openssh-server, nfs-kernel-server, isc-dhcp-server
NFS_EXPORT="${NFS_EXPORT:-/srv/nfs}"
NFS_SUBNET="${NFS_SUBNET:-192.168.99.0/24}"
DHCP_RANGE_START="${DHCP_RANGE_START:-192.168.99.10}"
DHCP_RANGE_END="${DHCP_RANGE_END:-192.168.99.20}"

if [[ -n ${GATEWAY:-} ]]; then
  echo "Note: GATEWAY is no longer used. The installer now gets its address by DHCP; the" >&2
  echo "      server's own default route is SERVER_GATEWAY (empty = none)." >&2
fi
for v in DHCP_SEND_GATEWAY DHCP_SEND_DNS INSTALL_RECOMMENDS; do
  [[ ${!v} == true || ${!v} == false ]] || { echo "Error: $v must be 'true' or 'false' (got '${!v}')" >&2; exit 1; }
done

# Unmount the USB and remove our temp mount dir on any exit (error, Ctrl-C, success)
cleanup() {
  local rc=$?
  if [[ -n ${MOUNT_USB:-} ]] && mountpoint -q "$MOUNT_USB" 2>/dev/null; then
    sync
    umount "$MOUNT_USB" 2>/dev/null || echo "Warning: could not unmount $MOUNT_USB" >&2
  fi
  if [[ $MOUNT_USB_CREATED == true ]]; then
    rmdir "$MOUNT_USB" 2>/dev/null || true
  fi
  return $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

usage() { echo "Usage: $0 [--usb-device DEVICE] [--env-file FILE] [--grub-verbose] [--prompt]"; exit 1; }

die() { echo "Error: $*" >&2; exit 1; }

# Download a file with retries. Resumes partial downloads unless a third
# argument "noresume" is given (use that for small files that may change).
download_with_retry() {
  local url=$1
  local output=$2
  local mode=${3:-resume}
  local part="$output.part"
  local attempt=1
  local rc
  local -a progress=(-sS)
  [[ -t 2 ]] && progress=(--progress-bar)

  [[ $mode == noresume ]] && rm -f "$part"

  while [[ $attempt -le $MAX_RETRIES ]]; do
    echo "Downloading $output (attempt $attempt/$MAX_RETRIES)..."
    echo "  URL: $url"

    # -f: fail on HTTP errors instead of saving the error page
    # --connect-timeout/--speed-*: abort stalled transfers, but no cap on total time
    rc=0
    curl -fL "${progress[@]}" -C - \
      --connect-timeout 30 --speed-limit 1000 --speed-time 30 \
      -o "$part" "$url" || rc=$?

    if [[ $rc -eq 0 ]]; then
      mv -f "$part" "$output"
      echo "  ✓ Downloaded successfully"
      return 0
    fi

    echo "  ✗ Download failed (attempt $attempt/$MAX_RETRIES, curl exit $rc)" >&2
    # 33 = server rejected the resume range; start over next time
    [[ $rc -eq 33 ]] && rm -f "$part"
    ((attempt++))
    [[ $attempt -le $MAX_RETRIES ]] && { echo "  Retrying in 2 seconds..."; sleep 2; }
  done

  rm -f "$part"
  echo "Failed to download $url after $MAX_RETRIES attempts" >&2
  return 1
}

# Report that something could not be verified; fatal unless ALLOW_UNVERIFIED=true
_unverified() {
  if [[ $ALLOW_UNVERIFIED == true ]]; then
    echo "⚠ $1 (continuing: ALLOW_UNVERIFIED=true)" >&2
    return 0
  fi
  echo "✗ $1" >&2
  echo "  Set ALLOW_UNVERIFIED=true to skip verification." >&2
  return 1
}

# Authenticate <dir>/SHA256SUMS with Debian's CD signing key
_gpg_verify_sums() {
  local dir=$1 base=$2 gh="$1/gnupg" ok=1
  command -v gpg >/dev/null 2>&1 || { echo "  gpg is not installed" >&2; return 1; }
  download_with_retry "$base/SHA256SUMS.sign" "$dir/SHA256SUMS.sign" noresume >&2 || return 1
  mkdir -m 700 "$gh"
  if GNUPGHOME=$gh gpg --batch --quiet --keyserver hkps://keyring.debian.org \
       --recv-keys "$DEBIAN_CD_KEY_FPR" 2>/dev/null; then
    # VALIDSIG's last field is the primary key fingerprint
    GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "$dir/SHA256SUMS.sign" "$dir/SHA256SUMS" 2>/dev/null \
      | awk -v fpr="$DEBIAN_CD_KEY_FPR" '$2=="VALIDSIG" && $NF==fpr {found=1} END {exit !found}' && ok=0
  else
    echo "  could not fetch Debian CD signing key $DEBIAN_CD_KEY_FPR" >&2
  fi
  GNUPGHOME=$gh gpgconf --kill gpg-agent 2>/dev/null || true
  return $ok
}

_verify_sha256() {
  local tmp=$1 path=$2 base=${3%/} name=$4 signed=$5
  local expected actual

  echo "Verifying $name..."
  download_with_retry "$base/SHA256SUMS" "$tmp/SHA256SUMS" noresume \
    || { _unverified "Could not download $base/SHA256SUMS"; return $?; }

  if [[ $signed == signed ]]; then
    _gpg_verify_sums "$tmp" "$base" \
      || { _unverified "Could not verify the GPG signature on SHA256SUMS"; return $?; }
    echo "  ✓ SHA256SUMS signature valid (key $DEBIAN_CD_KEY_FPR)"
  fi

  # Entries look like "<hash>  name" or "<hash>  ./name"
  expected=$(awk -v n="$name" '{f=$2; sub(/^\*/,"",f); sub(/^\.\//,"",f); if (f==n) {print $1; exit}}' "$tmp/SHA256SUMS")
  [[ -n $expected ]] || { _unverified "$name is not listed in SHA256SUMS (outdated file?)"; return $?; }

  actual=$(sha256sum "$path" | cut -d' ' -f1)
  if [[ $actual != "$expected" ]]; then
    echo "✗ Checksum mismatch for $name" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    return 1
  fi
  echo "✓ Checksum verified for $name"
}

# verify_sha256 PATH BASE_URL [ENTRY_NAME] [signed|unsigned]
# Compares PATH against BASE_URL/SHA256SUMS (GPG-authenticated when "signed").
verify_sha256() {
  local tmp rc=0
  tmp=$(mktemp -d)
  _verify_sha256 "$tmp" "$1" "$2" "${3:-$(basename "$1")}" "${4:-signed}" || rc=$?
  rm -rf "$tmp"
  return $rc
}

# Kernel version string ("6.12.107+deb13-amd64") of a Linux bzImage
kernel_version() {
  file -b "$1" | grep -o 'version [^ ]*' | head -n1 | cut -d' ' -f2
}

# Kernel version of the ISO's own installer (/install.amd/vmlinuz); empty if undeterminable
iso_kernel_version() {
  local iso=$1 tmp ver=""
  tmp=$(mktemp -d)
  if command -v xorriso >/dev/null 2>&1; then
    xorriso -osirrox on -indev "$iso" -extract /install.amd/vmlinuz "$tmp/vmlinuz" >/dev/null 2>&1 || true
  elif command -v 7z >/dev/null 2>&1; then
    7z e -so "$iso" install.amd/vmlinuz > "$tmp/vmlinuz" 2>/dev/null || true
  fi
  [[ -s $tmp/vmlinuz ]] && ver=$(kernel_version "$tmp/vmlinuz")
  rm -rf "$tmp"
  echo "$ver"
}

# Path of partition N on a disk: /dev/sdb -> /dev/sdb1, /dev/nvme0n1 -> /dev/nvme0n1p1
part_path() {
  local dev=$1 n=$2
  if [[ $dev =~ [0-9]$ ]]; then echo "${dev}p${n}"; else echo "${dev}${n}"; fi
}

# Unmount every mounted partition of a disk (desktop automounters remount new partitions)
unmount_partitions() {
  local p
  while read -r p; do
    umount "$p" 2>/dev/null || true
  done < <(lsblk -lnpo NAME "$1" | tail -n +2)
}

# Verify USB was created successfully
verify_usb_contents() {
  local usb_dev=$1
  echo ""
  echo "Verifying USB contents..."

  # Remount USB for verification
  mkdir -p "$MOUNT_USB"
  if ! mount "$(part_path "$usb_dev" 1)" "$MOUNT_USB" 2>/dev/null; then
    echo "⚠ Could not remount USB for verification (may be in use)" >&2
    return 0
  fi

  local errors=0

  # Check critical files
  local required_files=(
    "vmlinuz"
    "initrd.gz"
    "$ISO_FILE"
    "preseed.cfg"
    "post-install.sh"
    "select-disk.sh"
    "boot/grub/grub.cfg"
    "EFI/BOOT/BOOTX64.EFI"
  )

  for file in "${required_files[@]}"; do
    if [[ -f "$MOUNT_USB/$file" ]]; then
      echo "✓ $file"
    else
      echo "✗ Missing: $file" >&2
      ((errors++))
    fi
  done

  # Verify filesystem integrity
  if fsck.vfat -n "$(part_path "$usb_dev" 1)" &>/dev/null; then
    echo "✓ Filesystem integrity OK"
  else
    echo "⚠ Filesystem check inconclusive (may still be OK)" >&2
  fi

  umount "$MOUNT_USB" 2>/dev/null || true

  if [[ $errors -gt 0 ]]; then
    echo ""
    echo "✗ USB verification failed with $errors missing files" >&2
    return 1
  fi

  echo "✓ USB verification successful"
  return 0
}

# Refuse targets that are not a whole removable/USB disk or that hold the running system
check_target_device() {
  local dev=$1 type tran removable mp

  [[ -b $dev ]] || die "$dev is not a block device"

  type=$(lsblk -dno TYPE "$dev" | tr -d ' ')
  [[ $type == disk ]] || die "$dev is a '$type', not a whole disk (use e.g. /dev/sdb, not /dev/sdb1)"

  tran=$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d ' ' || true)
  removable=$(lsblk -dno RM "$dev" 2>/dev/null | tr -d ' ' || true)
  if [[ $tran != usb && $removable != 1 && $ALLOW_NON_USB != true ]]; then
    die "$dev does not look like a USB/removable disk (TRAN='${tran:-?}', RM='${removable:-?}'). Set ALLOW_NON_USB=true to override."
  fi

  while read -r mp; do
    case $mp in
      /|/boot|/boot/*|/home|/usr|/var|"[SWAP]")
        die "$dev holds a system mount ($mp); refusing to erase it" ;;
    esac
  done < <(lsblk -nro MOUNTPOINT "$dev")
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --usb-device) [[ $# -ge 2 ]] || usage; USB_DEVICE="$2"; PROMPT_DEVICE=false; shift 2;;
    --env-file) [[ $# -ge 2 ]] || usage; shift 2;;  # handled before .env is loaded
    --grub-verbose) GRUB_VERBOSE=true; shift;;
    --prompt) PROMPT_DEVICE=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Required tools
for cmd in parted mkfs.vfat grub-install mount umount udevadm partprobe mkdir wipefs blkid curl envsubst lsblk comm dd blockdev fsck.vfat sha256sum; do
  command -v $cmd >/dev/null 2>&1 || { echo "Missing required tool: $cmd" >&2; exit 1; }
done

# grub-install --target=x86_64-efi needs this; better to fail now than after erasing the USB
[[ -d /usr/lib/grub/x86_64-efi ]] || die "GRUB EFI modules not found; install grub-efi-amd64-bin"

if [[ -z $PROMPT_DEVICE ]]; then
  if [[ -n $USB_DEVICE ]]; then PROMPT_DEVICE=false; else PROMPT_DEVICE=true; fi
fi

if [[ $PROMPT_DEVICE == true ]]; then
  # Snapshot BEFORE the stick goes in, so the diff identifies it
  before_devices=$(lsblk -dn -o NAME | sort)
  echo "Please insert the USB key and press Enter."
  read -r
  echo "Detecting USB device..."

  new_devices=""
  for _ in {1..15}; do
    sleep 1
    after_devices=$(lsblk -dn -o NAME | sort)
    new_devices=$(comm -13 <(echo "$before_devices") <(echo "$after_devices"))
    [[ -n $new_devices ]] && break
  done

  if [[ -z $new_devices ]]; then
    die "No new device detected. Re-run with --usb-device /dev/sdX"
  fi
  if [[ $(wc -l <<<"$new_devices") -gt 1 ]]; then
    echo "Multiple new devices appeared:" >&2
    echo "$new_devices" | sed 's|^|  /dev/|' >&2
    die "Ambiguous; re-run with --usb-device /dev/sdX"
  fi

  USB_DEVICE="/dev/$new_devices"
  echo "Detected USB device: $USB_DEVICE"
fi

[[ -n $USB_DEVICE ]] || die "No USB device specified"
# Resolve symlinks (e.g. /dev/disk/by-id/...) so partition names can be derived
USB_DEVICE=$(readlink -f "$USB_DEVICE")
check_target_device "$USB_DEVICE"

# Validate preseed template exists
PRESEED_TEMPLATE="preseed.cfg.template"
if [[ ! -f $PRESEED_TEMPLATE ]]; then
  echo "Error: preseed template '$PRESEED_TEMPLATE' not found" >&2
  exit 1
fi

# Find the first existing SSH public key, preferring ed25519
find_ssh_key() {
  local candidates=(
    "$ORIGINAL_HOME/.ssh/id_ed25519.pub"
    "$ORIGINAL_HOME/.ssh/id_rsa.pub"
    "/root/.ssh/id_ed25519.pub"
    "/root/.ssh/id_rsa.pub"
  )

  for key in "${candidates[@]}"; do
    if [[ -f "$key" ]]; then
      echo "$key"
      return 0
    fi
  done

  return 1
}

if [[ -n $SSH_KEY_FILE ]]; then
  # An explicitly configured key must exist; don't silently fall back to another
  [[ -f $SSH_KEY_FILE ]] || die "SSH_KEY_FILE '$SSH_KEY_FILE' does not exist"
else
  # '|| true': under set -e a failing lookup would otherwise exit before the message below
  SSH_KEY_FILE=$(find_ssh_key || true)
  if [[ -z $SSH_KEY_FILE ]]; then
    echo "Error: No SSH public key found" >&2
    echo "Checked:" >&2
    echo "  - $ORIGINAL_HOME/.ssh/id_ed25519.pub" >&2
    echo "  - $ORIGINAL_HOME/.ssh/id_rsa.pub" >&2
    echo "  - /root/.ssh/id_ed25519.pub" >&2
    echo "  - /root/.ssh/id_rsa.pub" >&2
    echo "" >&2
    echo "Generate a key with: ssh-keygen -t ed25519" >&2
    echo "Or set SSH_KEY_FILE in .env to use a custom key" >&2
    exit 1
  fi
  echo "Found SSH key: $SSH_KEY_FILE"
fi

# Use the first line only, keep just "<type> <base64>" (the comment could hold
# characters that break shell quoting in the preseed), and make sure it is a
# public key and not a private key
SSH_KEY_CONTENT=$(head -n1 "$SSH_KEY_FILE" | tr -d '\r' | awk '{print $1 " " $2}')
[[ $SSH_KEY_CONTENT =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+\ [A-Za-z0-9+/=]+$ ]] \
  || die "$SSH_KEY_FILE does not look like an SSH public key"

# Validate user password hash is set and looks like a crypt(3) hash
if [[ ! $USER_PASSWORD_HASH =~ ^\$(6|5|y|2[aby])\$ ]]; then
  echo "Error: USER_PASSWORD_HASH is missing or not a valid password hash in .env" >&2
  echo "Generate one with: openssl passwd -6   (prompts for the password)" >&2
  echo "Keep it in single quotes in .env, e.g. USER_PASSWORD_HASH='\$6\$salt\$...'" >&2
  exit 1
fi

ISO_BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

# Auto-detect the current netinst ISO name (old point releases are removed from mirrors)
if [[ -z $ISO_FILE ]]; then
  ISO_FILE=$(curl -fsSL --connect-timeout 30 --max-time 60 "$ISO_BASE_URL/" \
    | grep -o 'debian-[0-9.]*-amd64-netinst\.iso' | sort -uV | tail -n1) || true
  if [[ -z $ISO_FILE ]]; then
    echo "Error: could not detect current Debian netinst ISO name; set ISO_FILE in .env" >&2
    exit 1
  fi
  echo "Detected current ISO: $ISO_FILE"
fi

# Obtain netinst ISO if absent (untouched file, copied to USB root)
if [[ ! -f $ISO_FILE ]]; then
  ISO_URL="$ISO_BASE_URL/$ISO_FILE"
  download_with_retry "$ISO_URL" "$ISO_FILE" || exit 1
  verify_sha256 "$ISO_FILE" "$ISO_BASE_URL" || { rm -f "$ISO_FILE"; exit 1; }
else
  echo "Using existing ISO: $ISO_FILE"
  verify_sha256 "$ISO_FILE" "$ISO_BASE_URL" || { echo "Delete $ISO_FILE to download a fresh copy." >&2; exit 1; }
fi

# Fetch the hd-media kernel and initrd now, so a bad download or a kernel/ISO
# mismatch is caught before the USB is erased.
HDMEDIA_CACHE="cache/hd-media"
mkdir -p "$HDMEDIA_CACHE"
echo "Downloading hd-media kernel and initrd..."
for f in vmlinuz initrd.gz; do
  download_with_retry "$HDMEDIA_BASE/$f" "$HDMEDIA_CACHE/$f" noresume || exit 1
  # The installer SHA256SUMS sits one level up and is not GPG-signed (HTTPS only)
  verify_sha256 "$HDMEDIA_CACHE/$f" "${HDMEDIA_BASE%/*}" "${HDMEDIA_BASE##*/}/$f" unsigned || exit 1
done

# The ISO supplies the installer's kernel modules, so its kernel must match the
# hd-media kernel or the installer fails with "no kernel modules were found".
hd_kver=$(kernel_version "$HDMEDIA_CACHE/vmlinuz" || true)
iso_kver=$(iso_kernel_version "$ISO_FILE" || true)
if [[ -z $hd_kver || -z $iso_kver ]]; then
  echo "⚠ Could not compare kernel versions (need file plus xorriso or 7z); skipping check" >&2
elif [[ $hd_kver != "$iso_kver" ]]; then
  echo "✗ Kernel mismatch: hd-media is $hd_kver but $ISO_FILE ships $iso_kver" >&2
  echo "  The installer would not find matching kernel modules. Use an ISO and hd-media" >&2
  echo "  files from the same installer build (pin HDMEDIA_BASE to a matching build" >&2
  echo "  directory under .../installer-amd64/, or set ISO_FILE to a matching ISO)." >&2
  if [[ $ALLOW_KERNEL_MISMATCH != true ]]; then
    echo "  Set ALLOW_KERNEL_MISMATCH=true to continue anyway." >&2
    exit 1
  fi
else
  echo "✓ hd-media kernel matches ISO kernel ($hd_kver)"
fi

echo ""
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT "$USB_DEVICE"
echo ""
read -rp "This will ERASE ALL DATA on $USB_DEVICE (shown above). Continue? (yes/NO) " confirm
[[ $confirm == "yes" ]] || { echo "Aborted."; exit 1; }

# Unmount anything mounted
unmount_partitions "$USB_DEVICE"

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
USB_PART=$(part_path "$USB_DEVICE" 1)
for i in {1..10}; do [[ -b $USB_PART ]] && break; sleep 1; done
[[ -b $USB_PART ]] || { echo "Partition $USB_PART not found" >&2; exit 1; }

# A desktop automounter may have mounted the fresh partition; mkfs refuses a mounted one
unmount_partitions "$USB_DEVICE"
mkfs.vfat -F32 -n NFSSVR_BOOT "$USB_PART"
udevadm settle
unmount_partitions "$USB_DEVICE"

if [[ -z $MOUNT_USB ]]; then
  MOUNT_USB=$(mktemp -d -t nfssvr-usb.XXXXXX)
  MOUNT_USB_CREATED=true
else
  mkdir -p "$MOUNT_USB"
fi
mount "$USB_PART" "$MOUNT_USB"

# Place the verified hd-media kernel and initrd on the USB
cp "$HDMEDIA_CACHE/vmlinuz" "$MOUNT_USB/vmlinuz"
cp "$HDMEDIA_CACHE/initrd.gz" "$MOUNT_USB/initrd.gz"

# Copy whole ISO to root (untouched) so iso-scan can find it
cp "$ISO_FILE" "$MOUNT_USB/$ISO_FILE"

# The installer mounts the stick at /hd-media, so files in the USB top level
# appear as /hd-media/<file> (Debian's documented preseed/file location)
# Variables substituted into the template (an explicit list keeps envsubst from
# blanking any other $word that appears in the preseed)
TEMPLATE_VARS=(
  TARGET_HOSTNAME DOMAIN STATIC_IP NETMASK SERVER_GATEWAY NAMESERVERS
  DHCP_SEND_GATEWAY DHCP_SEND_DNS
  TIMEZONE LOCALE KEYBOARD MIRROR_COUNTRY MIRROR_HOST MIRROR_PATH
  TARGET_USERNAME USER_FULLNAME USER_PASSWORD_HASH SSH_KEY_CONTENT TARGET_DISK
  NFS_EXPORT NFS_SUBNET DHCP_RANGE_START DHCP_RANGE_END EXTRA_PACKAGES INSTALL_RECOMMENDS
)
export "${TEMPLATE_VARS[@]}"

# Template preseed.cfg and write to USB
envsubst "$(printf '${%s} ' "${TEMPLATE_VARS[@]}")" < "$PRESEED_TEMPLATE" > "$MOUNT_USB/preseed.cfg"
if grep -qE '\$\{[A-Za-z_]+\}' "$MOUNT_USB/preseed.cfg"; then
  echo "Error: unsubstituted variables remain in preseed.cfg:" >&2
  grep -nE '\$\{[A-Za-z_]+\}' "$MOUNT_USB/preseed.cfg" >&2
  exit 1
fi

# Disk-selection helper (called from preseed early_command)
cp select-disk.sh "$MOUNT_USB/select-disk.sh"

# Copy post-install script to USB (called from preseed late_command)
[[ -f post-install.sh ]] || die "post-install.sh not found; the installer's late_command would fail"
cp post-install.sh "$MOUNT_USB/post-install.sh"

# Create minimal GRUB config
mkdir -p "$MOUNT_USB/boot/grub"
cat > "$MOUNT_USB/boot/grub/grub.cfg" <<EOF
# Unattended: after the timeout this ERASES the target machine's install disk
timeout=10
default=0

menuentry 'Automated Debian NFS/DHCP Install (ERASES THE TARGET DISK)' {
    insmod part_gpt
    insmod fat
    linux /vmlinuz auto=true priority=critical locale=$LOCALE \\
        debian-installer/locale=$LOCALE \\
        console-setup/ask_detect=false console-setup/layoutcode=$KEYBOARD \\
        keyboard-configuration/xkb-keymap=$KEYBOARD \\
        preseed/file=/hd-media/preseed.cfg \\
        iso-scan/filename=$ISO_FILE iso-scan/ask=false \\
        iso-scan/scan-all=true cdrom-detect/try-usb=true \\
        netcfg/choose_interface=auto rootdelay=5 \\
        fb=false debian-installer=$LOCALE \\
        quiet
    initrd /initrd.gz
}
EOF

# Install GRUB (UEFI removable path)
if [[ $GRUB_VERBOSE == true ]]; then set -x; fi

grub-install \
  --target=x86_64-efi \
  --efi-directory="$MOUNT_USB" \
  --boot-directory="$MOUNT_USB/boot" \
  --removable \
  --no-nvram

# --removable writes EFI/BOOT/BOOTX64.EFI; verify_usb_contents checks for it below
sync
umount "$MOUNT_USB" || die "Failed to unmount $MOUNT_USB; do not remove the USB until it is unmounted"

# Verify USB contents
verify_usb_contents "$USB_DEVICE" || exit 1

elapsed=$SECONDS
echo ""
echo "✓ Done. USB ready. Time: $((elapsed/60))m $((elapsed%60))s"
echo "Boot target system with this USB (UEFI). The installer will find the ISO via iso-scan and run unattended."