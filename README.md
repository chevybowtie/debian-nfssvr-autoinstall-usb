# debian-nfssvr-autoinstall-usb

Create a UEFI-bootable USB that performs an unattended Debian install and comes up as a small backup appliance:

- Static IP: `192.168.99.1/24` (after the install; the install itself uses DHCP)
- NFS export: `/srv/nfs`
- DHCP server for the connected PC: `192.168.99.10–20`
- SSH enabled for user `backupadmin`, with your public key installed

Status

- Debian: Working via the official hd-media method (no ISO remastering).
- Ubuntu/Alpine attempts: Deprecated and no longer needed here.

What the script does

The script `make-autoinstall-usb-debian-fat32-efi-clean.sh`:

- Partitions the USB as a single FAT32 ESP (UEFI bootable).
- Downloads the Debian netinst ISO if missing and copies it unchanged to the USB root.
- Downloads the hd-media installer kernel (`vmlinuz`) and `initrd.gz` and places them on the USB.
- Copies the rendered `preseed.cfg`, `select-disk.sh` and `post-install.sh` to the top level of the USB (the installer mounts the stick at `/hd-media`, so `preseed/file=/hd-media/preseed.cfg` finds it).
- Writes a minimal `grub.cfg` to boot Debian Installer with:
  - `iso-scan/filename=<netinst.iso>` so d-i finds the ISO on the USB.
  - keyboard and locale set to US to avoid prompts.
  - preseed path to run unattended configuration and late setup (NFS/DHCP).

Requirements

- Linux host, run as root (sudo).
- Tools: `parted`, `grub-install` (grub-efi-amd64-bin), `mount`, `umount`, `udevadm`, `partprobe`, `wipefs`, `curl`, `lsblk`, `sha256sum`, `envsubst`.
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
   - “Automated Debian NFS/DHCP Install (ERASES THE TARGET DISK)” (it also starts by itself after 10 s)

Default behavior

- Keyboard: preset to US (no prompt).
- Networking during install: **DHCP** (plug the server into a normal router: it needs the internet to fetch packages). On the first boot after install it switches to the fixed `192.168.99.1/24`.
- Disk partitioning: by default the preseed is set up to automatically wipe and use the first disk.
  - If you prefer being asked about partitioning, comment/remove the `partman-auto` lines in `preseed.cfg` (the ones that set method/recipe/confirm).
- After first boot on the installed system:
  - NFS server exports `/srv/nfs` to `192.168.99.0/24`.
  - DHCP server (isc-dhcp-server) serves `192.168.99.10–20`.
  - User `backupadmin` exists; SSH enabled, with the key from `SSH_KEY_FILE` installed.

Verify after install

- IP: `ip a` (expect `192.168.99.1/24`)
- NFS: `systemctl status nfs-server` and `showmount -e 192.168.99.1`
- DHCP: `systemctl status isc-dhcp-server`

Configuration

- Copy `.env.example` to `.env` and customize settings (network, hostname, timezone, etc.)
- The script loads `.env` automatically if it exists
- **Preseed templating:** `preseed.cfg.template` is automatically substituted with `.env` variables before being written to the USB
  - All hardcoded values (IP, hostname, timezone, NFS subnet, SSH key, etc.) are now configurable
  - SSH public key is read from `SSH_KEY_FILE` (default: your ed25519, then RSA key) and installed for the new user by `post-install.sh`
  - User password hash must be set in `.env` before running (generate with `openssl passwd -6`, which prompts for the password)
- **Post-install script:** `post-install.sh` handles NFS/DHCP setup after Debian installation
  - Much cleaner and more maintainable than inline preseed late_command chains
  - Can be tested independently before USB creation
  - Runs inside the installer chroot (copied in by `late_command`), so it enables services but starts them only on a booted system; they come up on first boot
  - Uses the interface the installer configured statically; the static IP itself comes from the preseed `netcfg/*` settings (Debian uses ifupdown, not netplan)
- Key variables: `STATIC_IP`, `TARGET_HOSTNAME`, `TARGET_USERNAME`, `TIMEZONE`, `NFS_SUBNET`, `DHCP_RANGE_START`/`END`, `SSH_KEY_FILE`, `USER_PASSWORD_HASH`, and more

Download validation and verification

- The ISO is checked against Debian's `SHA256SUMS` and its GPG signature (Debian CD signing key); the hd-media kernel/initrd are checked against the installer `SHA256SUMS`
- The hd-media kernel version must match the ISO's kernel, otherwise the installer can't find its modules (`ALLOW_KERNEL_MISMATCH=true` overrides)
- Verification failures abort before anything is erased (`ALLOW_UNVERIFIED=true` skips an unreachable checksum/signature)
- After USB creation, key files are verified: vmlinuz, initrd.gz, preseed.cfg, GRUB config, and bootloader
- If verification fails, the script exits with an error

Troubleshooting

- Installer can’t find installation media (/cdrom):
  - Ensure the ISO filename on the USB matches exactly the downloaded ISO name (e.g. `debian-13.7.0-amd64-netinst.iso`).
  - This project uses the hd-media kernel/initrd and passes `iso-scan/filename` and `iso-scan/ask=false`.
  - Some firmware/USB sticks need: add `modules=usb-storage,sd-mod,loop` to the kernel line.
  - Prefer a USB2 port on quirky hardware.
- Keyboard prompt appears: the GRUB entry uses `LOCALE`/`KEYBOARD` from `.env`; regenerate the USB if you changed them.
- Partitioning prompts: expected only if you trimmed `partman` lines in `preseed.cfg`.
- Download failed after retries: check your internet connection and mirror accessibility.
- Verification failed: the USB may have been disconnected or corrupted during setup.

Notes

- All configuration (hostname, network, NFS, DHCP, SSH key, password) is templated from `.env` into `preseed.cfg.template`
- The generated `preseed.cfg` is written only to the USB and is never committed to git
- To update settings, edit `.env` and create a new USB — the preseed is regenerated each time
- Password hash: generate with `openssl passwd -6` (prompts for the password, so it stays out of shell history) and set as `USER_PASSWORD_HASH='$6$...'` in `.env` (single quotes required)

Important behaviour of the unattended install

- **It erases the target machine's install disk without asking.** The GRUB entry auto-boots after 10 s. Set `TARGET_DISK` (e.g. `/dev/disk/by-id/...`) if the server has more than one disk; otherwise the first non-USB disk is used.
- The server **powers off** when the install finishes (so it doesn't reboot into the still-inserted stick and reinstall). Remove the USB, then power it on.
- The server needs working internet during install, via DHCP from your router (packages like `nfs-kernel-server` and `isc-dhcp-server` come from the mirror).
- The GRUB on the stick is unsigned: **disable Secure Boot** on the target machine. Legacy BIOS boot is not supported (UEFI only).
- The USB layout is: `vmlinuz`, `initrd.gz`, the ISO, `preseed.cfg`, `select-disk.sh`, `post-install.sh` at the top level (the installer mounts the stick at `/hd-media`).

Using it as a portable NFS "drive"

1. Install with the server plugged into your normal router (DHCP + internet). It powers off when done.
2. Cable the server directly to the PC (no router), power it on, and set the PC's NIC to automatic/DHCP. The server hands it an address in `DHCP_RANGE_START`–`DHCP_RANGE_END`.
3. On the PC: `sudo mount -t nfs 192.168.99.1:/srv/nfs /mnt/nfs`
- By default the DHCP server does **not** hand out a default route or DNS (`DHCP_SEND_GATEWAY`/`DHCP_SEND_DNS=false`), so the PC's other connections keep working. Set them to `true` only if this server should act as a gateway.
- The export uses `all_squash`: every user on the PC (root included) is mapped to `nobody:nogroup`, which owns `/srv/nfs`, so anyone on the PC can read and write. Files you copy in are owned by `nobody` and can't be `chown`ed from the client.
- No authentication: keep it on the private cable.

Slimming the install

- The install skips Debian's `standard` task (exim4, man pages, bash-completion, dnsutils, ...). It installs the base system, `openssh-server`, `nfs-kernel-server`, `isc-dhcp-server` and `EXTRA_PACKAGES` (default `nano less`).
- Opt-in, in `.env`:
  - `INSTALL_RECOMMENDS=false`: skip apt "Recommends" (leaner; test an install before relying on it).
  - `NFS_V4_ONLY=true`: serve NFSv4 only and mask `rpcbind`/`rpc-statd`. Clients must mount with `-t nfs4`.
- Already the defaults, so no change needed: no unattended-upgrades, no system upgrade during install, and the installer cleans apt's package cache itself.
