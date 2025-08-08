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
- Tools: `parted`, `grub-install` (grub-efi-amd64-bin), `mount`, `umount`, `udevadm`, `partprobe`, `wipefs`, `wget` or `curl`.
- A USB drive that can be erased.
- Target system boots in UEFI mode.

Usage
1) Identify the USB device (double-check):
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

Troubleshooting
- Installer can’t find installation media (/cdrom):
  - Ensure the ISO filename on the USB matches exactly `debian-12.11.0-amd64-netinst.iso`.
  - This project uses the hd-media kernel/initrd and passes `iso-scan/filename` and `iso-scan/ask=false`.
  - Some firmware/USB sticks need: add `modules=usb-storage,sd-mod,loop` to the kernel line.
  - Prefer a USB2 port on quirky hardware.
- Keyboard prompt appears: the GRUB entry forces US; regenerate the USB if you changed it.
- Partitioning prompts: expected only if you trimmed `partman` lines in `preseed.cfg`.

Notes
- Replace the placeholder SSH public key in `preseed.cfg` before use.
