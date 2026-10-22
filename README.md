# debian-nfssvr-autoinstall-usb

Create a UEFI-bootable USB that performs an unattended Debian install and comes up as a small backup appliance:

- Static IP: `192.168.99.1/24`
- NFS export: `/srv/nfs`
- Optional DHCP server: `192.168.99.10–20`
- SSH enabled for user `backupadmin` (replace the key in `preseed.cfg`)

Status

- Debian: Working via the official hd-media method (no ISO remastering).
- Ubuntu/Alpine attempts: Deprecated and no longer needed here.

What the script does

The script `make-autoinstall-usb-debian-fat32-efi-clean.sh`:

- Partitions the USB as a single FAT32 ESP (UEFI bootable).
- Downloads the Debian netinst ISO if missing and copies it unchanged to the USB root.
- Downloads the hd-media installer kernel (`vmlinuz`) and `initrd.gz` and places them on the USB.
- Copies your `preseed.cfg` to `/hd-media/preseed.cfg` on the USB.
- Writes a minimal `grub.cfg` to boot Debian Installer with:
  - `iso-scan/filename=<netinst.iso>` so d-i finds the ISO on the USB.
  - keyboard and locale set to US to avoid prompts.
  - preseed path to run unattended configuration and late setup (NFS/DHCP).

Requirements

- Linux host, run as root (sudo).
- Tools: `parted`, `grub-install` (grub-efi-amd64-bin), `mount`, `umount`, `udevadm`, `partprobe`, `wipefs`, `wget` or `curl`, `envsubst`.
- A USB drive that can be erased.
- Target system boots in UEFI mode.
- SSH public key: auto-detected from your user's `~/.ssh/` (RSA or Ed25519), or set `SSH_KEY_FILE` in `.env`.

Usage

1) Detect the USB device:
   - Use `--prompt` to automatically detect the USB device after inserting it:
     - `sudo ./make-autoinstall-usb-debian-fat32-efi-clean.sh --prompt`
   - Alternatively, identify the USB device manually:
     - `lsblk` before/after plugging the stick (typically `/dev/sdb`).
2) Write the USB (this will erase the device):
   - `sudo ./make-autoinstall-usb-debian-fat32-efi-clean.sh --usb-device /dev/sdX`
3) Boot the target from this USB (UEFI) and choose:
   - “Automated Debian NFS/DHCP Install”

Default behavior

- Keyboard: preset to US (no prompt).
- Networking during install: static `192.168.99.1/24` (as in `preseed.cfg`).
- Disk partitioning: by default the preseed is set up to automatically wipe and use the first disk.
  - If you prefer being asked about partitioning, comment/remove the `partman-auto` lines in `preseed.cfg` (the ones that set method/recipe/confirm).
- After first boot on the installed system:
  - NFS server exports `/srv/nfs` to `192.168.99.0/24`.
  - DHCP server (isc-dhcp-server) serves `192.168.99.10–20`.
  - User `backupadmin` exists; SSH enabled. Replace the `authorized-keys` in `preseed.cfg`.

Verify after install

- IP: `ip a` (expect `192.168.99.1/24`)
- NFS: `systemctl status nfs-server` and `showmount -e 192.168.99.1`
- DHCP: `systemctl status isc-dhcp-server`

Configuration

- Copy `.env.example` to `.env` and customize settings (network, hostname, timezone, etc.)
- The script loads `.env` automatically if it exists
- **Preseed templating:** `preseed.cfg.template` is automatically substituted with `.env` variables before being written to the USB
  - All hardcoded values (IP, hostname, timezone, NFS subnet, SSH key, etc.) are now configurable
  - SSH public key is read from `SSH_KEY_FILE` and embedded in the preseed
  - User password hash must be set in `.env` before running (generate with `openssl passwd -6`, which prompts for the password)
- **Post-install script:** `post-install.sh` handles NFS/DHCP setup after Debian installation
  - Much cleaner and more maintainable than inline preseed late_command chains
  - Can be tested independently before USB creation
  - Dynamically detects network interface (more robust than grep)
  - Includes error checking and proper logging
- Key variables: `STATIC_IP`, `TARGET_HOSTNAME`, `TARGET_USERNAME`, `TIMEZONE`, `NFS_SUBNET`, `DHCP_RANGE_START`/`END`, `SSH_KEY_FILE`, `USER_PASSWORD_HASH`, and more

Download validation and verification

- The script validates ISO and kernel downloads with checksums (when available)
- After USB creation, key files are verified: vmlinuz, initrd.gz, preseed.cfg, GRUB config, and bootloader
- If verification fails, the script exits with an error

Troubleshooting

- Installer can’t find installation media (/cdrom):
  - Ensure the ISO filename on the USB matches exactly the downloaded ISO name (e.g. `debian-13.7.0-amd64-netinst.iso`).
  - This project uses the hd-media kernel/initrd and passes `iso-scan/filename` and `iso-scan/ask=false`.
  - Some firmware/USB sticks need: add `modules=usb-storage,sd-mod,loop` to the kernel line.
  - Prefer a USB2 port on quirky hardware.
- Keyboard prompt appears: the GRUB entry forces US; regenerate the USB if you changed it.
- Partitioning prompts: expected only if you trimmed `partman` lines in `preseed.cfg`.
- Download failed after retries: check your internet connection and mirror accessibility.
- Verification failed: the USB may have been disconnected or corrupted during setup.

Notes

- All configuration (hostname, network, NFS, DHCP, SSH key, password) is templated from `.env` into `preseed.cfg.template`
- The generated `preseed.cfg` is written only to the USB and is never committed to git
- To update settings, edit `.env` and create a new USB — the preseed is regenerated each time
- Password hash: generate with `openssl passwd -6` (prompts for the password, so it stays out of shell history) and set as `USER_PASSWORD_HASH='$6$...'` in `.env` (single quotes required)
