# debian-nfssvr-autoinstall-usb

Create a UEFI-bootable USB that performs an unattended Debian install and comes up as a small backup appliance:

- Static IP: `192.168.99.1/24` (after the install; the install itself uses DHCP)
- NFS export: `/srv/nfs`
- DHCP server for the connected PC: `192.168.99.10–20`
- SSH enabled for user `backupadmin`, with your public key installed

Status

- Debian: Working via the official hd-media method (no ISO remastering).
- Ubuntu/Alpine attempts: Deprecated and no longer needed here.
- Tested end to end in a UEFI VM (QEMU/OVMF): unattended install, switch to the fixed address, NFS write from a client with `all_squash`, SSH key login. **Not yet tested on real hardware:** a real PC receiving a DHCP lease from the server over the direct cable.

What the script does

The script `make-autoinstall-usb-debian-fat32-efi-clean.sh`:

- Partitions the USB as a single FAT32 ESP (UEFI bootable).
- Detects the current Debian netinst ISO (old point releases vanish from the mirror), downloads it if missing, verifies its checksum and GPG signature, and copies it unchanged to the USB root.
- Downloads the hd-media installer kernel (`vmlinuz`) and `initrd.gz` into `cache/`, verifies them, checks their kernel matches the ISO's, and places them on the USB. All of this happens before anything is erased.
- Copies the rendered `preseed.cfg`, `select-disk.sh` and `post-install.sh` to the top level of the USB (the installer mounts the stick at `/hd-media`, so `preseed/file=/hd-media/preseed.cfg` finds it).
- Writes a minimal `grub.cfg` to boot Debian Installer with:
  - `iso-scan/filename=<netinst.iso>` so d-i finds the ISO on the USB.
  - `LOCALE` and `KEYBOARD` from `.env` (default US) to avoid prompts.
  - preseed path to run unattended configuration and late setup (NFS/DHCP).

Requirements

- Linux host, run as root (sudo).
- Tools: `parted`, `grub-install` (with the `grub-efi-amd64-bin` package), `mkfs.vfat`/`fsck.vfat` (dosfstools), `mount`, `umount`, `udevadm`, `partprobe`, `wipefs`, `blkid`, `lsblk`, `blockdev`, `dd`, `curl`, `sha256sum`, `envsubst`.
- Recommended: `gpg` (verifies the ISO's signature), `xorriso` or `7z` plus `file` (kernel match check). If missing, the checks say so and either skip (kernel check) or stop (signature; `ALLOW_UNVERIFIED=true` overrides).
- Internet access on the build machine (ISO and checksums) and, later, on the target during install.
- A USB drive that can be erased.
- Target system boots in UEFI mode.
- SSH public key: auto-detected from your user's `~/.ssh/` (Ed25519 preferred, then RSA), or set `SSH_KEY_FILE` in `.env`. Only the first line of the file is used.

Usage

1) Copy `.env.example` to `.env` and set at least `USER_PASSWORD_HASH` (see Configuration).
2) Write the USB (this erases the device):
   - `sudo ./make-autoinstall-usb-debian-fat32-efi-clean.sh --usb-device /dev/sdX`
   - Or run it with no device (or with `--prompt`): it asks you to insert the stick and detects the one that appears.
   - Safety checks: it refuses a device that is not a whole USB/removable disk, or that holds `/`, `/boot`, `/home`, `/usr`, `/var` or swap (`ALLOW_NON_USB=true` overrides the first check). It shows the device's model, size and mounts before asking you to type `yes`.
   - Other options: `--env-file FILE` (use another config instead of `.env`), `--grub-verbose`.
3) Boot the target from this USB (UEFI) and choose:
   - “Automated Debian NFS/DHCP Install (ERASES THE TARGET DISK)” (it also starts by itself after 10 s)

Default behavior

- Keyboard and locale: from `KEYBOARD`/`LOCALE` in `.env` (default US), no prompts.
- Networking during install: **DHCP** (plug the server into a normal router: it needs the internet to fetch packages). On the first boot after install it switches to the fixed `192.168.99.1/24`.
- Disk partitioning: the installer automatically wipes and uses one disk on the target machine: `TARGET_DISK` if you set it, otherwise the first disk that is not USB-attached and not the installer stick (`select-disk.sh`).
  - If you prefer being asked about partitioning, comment/remove the `partman-auto` lines in `preseed.cfg.template` and rebuild the stick.
- After first boot on the installed system:
  - NFS server exports `/srv/nfs` to `192.168.99.0/24`.
  - DHCP server (isc-dhcp-server) serves `192.168.99.10–20`.
  - User `backupadmin` exists; SSH enabled, with the key from `SSH_KEY_FILE` installed.

Verify after install

- IP: `ip a` (expect `192.168.99.1/24`)
- NFS: `systemctl status nfs-server` and `showmount -e 192.168.99.1` (`showmount` needs NFSv3/`rpcbind`, so it fails with `NFS_V4_ONLY=true`; use `ss -tln | grep 2049` instead)
- DHCP: `systemctl status isc-dhcp-server`
- SSH: `ssh backupadmin@192.168.99.1` with your key

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
  - Switches the server from the installer's DHCP lease to the fixed `STATIC_IP` for its real role (via `/etc/network/interfaces`, or systemd-networkd if ifupdown is absent; Debian does not use netplan). It takes effect on the next boot.
  - Writes the NFS export and the DHCP configuration, and installs your SSH key for the new user
- Key variables (all documented in `.env.example`): `STATIC_IP`, `NETMASK`, `TARGET_HOSTNAME`, `TARGET_USERNAME`, `TARGET_DISK`, `TIMEZONE`, `NFS_SUBNET`, `DHCP_RANGE_START`/`END`, `DHCP_SEND_GATEWAY`/`DHCP_SEND_DNS`, `SERVER_GATEWAY`, `EXTRA_PACKAGES`, `SSH_KEY_FILE`, `USER_PASSWORD_HASH`, and more
- **Upgrading an old `.env`:** `HOSTNAME`/`USERNAME` were renamed to `TARGET_HOSTNAME`/`TARGET_USERNAME` (the script stops if the old names are still set, because bash owns `HOSTNAME`). `GATEWAY` is gone: the installer now uses DHCP, and the server's own default route is `SERVER_GATEWAY` (empty by default). A leftover `GATEWAY` prints a note and is ignored.

Download validation and verification

- The ISO is checked against Debian's `SHA256SUMS` and its GPG signature (Debian CD signing key); the hd-media kernel/initrd are checked against the installer `SHA256SUMS`
- The hd-media kernel version must match the ISO's kernel, otherwise the installer can't find its modules (`ALLOW_KERNEL_MISMATCH=true` overrides)
- Verification failures abort before anything is erased (`ALLOW_UNVERIFIED=true` skips an unreachable checksum/signature)
- After USB creation, key files are verified: vmlinuz, initrd.gz, the ISO, preseed.cfg, select-disk.sh, post-install.sh, GRUB config, and bootloader
- If verification fails, the script exits with an error

Troubleshooting

- Installer can’t find installation media (/cdrom):
  - Ensure the ISO filename on the USB matches exactly the downloaded ISO name (e.g. `debian-13.7.0-amd64-netinst.iso`).
  - This project uses the hd-media kernel/initrd and passes `iso-scan/filename` and `iso-scan/ask=false`.
  - Some firmware/USB sticks need: add `modules=usb-storage,sd-mod,loop` to the kernel line.
  - Prefer a USB2 port on quirky hardware.
- Keyboard prompt appears: the GRUB entry uses `LOCALE`/`KEYBOARD` from `.env`; regenerate the USB if you changed them.
- Partitioning prompts: expected only if you trimmed `partman` lines in `preseed.cfg.template`.
- Installer stalls on the network step: the server needs a DHCP server (your router) during install, and a working internet connection for the package download.
- Installer reports an error at partitioning: `select-disk.sh` found no suitable non-USB disk. Set `TARGET_DISK` in `.env`.
- Something fails late in the install: press `Alt+F4` in the installer for its log (look for lines tagged `select-disk` and `late_command`). A failing `post-install.sh` stops the install with an error rather than hiding it.
- The stick won't boot: Secure Boot must be off (the GRUB on the stick is unsigned) and the machine must boot in UEFI mode.
- Download failed after retries: check your internet connection and mirror accessibility.
- Verification failed: the USB may have been disconnected or corrupted during setup.

Notes

- All configuration (hostname, network, NFS, DHCP, SSH key, password) is templated from `.env` into `preseed.cfg.template`
- The rendered `preseed.cfg` is written only to the USB. (The `preseed.cfg` tracked in the repo root is an old leftover that the script does not use; it contains an outdated example password hash and should not be reused.)
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
