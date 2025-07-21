# debian-nfssvr-autoinstall-usb

This project automates the creation of a bootable Debian Server USB drive that performs a **fully unattended installation**. The installed system will act as a **backup server** with:

- A static IP address (`192.168.99.1`)
- An **NFS server** at `/srv/nfs`
- A **DHCP server** that assigns addresses in the range `192.168.99.10–20`
- SSH enabled (via your provided public key)

---

## 🔧 What This Script Does

The `make-autoinstall-usb-debian-fat32-efi-clean.sh` script:

1. Downloads the Debian 12.11.0 netinst ISO
2. Mounts and unpacks the ISO
3. Injects preseed configuration:
   - Disk wipe + partitioning
   - Static IP
   - NFS and DHCP server installation
   - SSH key-based login
4. Replaces the default GRUB configuration with a custom one to trigger autoinstall
5. Writes the final ISO to a specified USB device

---

## ▶️ Running the Script

You must run the script with root privileges:

```bash
sudo ./make-autoinstall-usb-debian-fat32-efi-clean.sh
```

---

## 🚀 Using the USB Installer

1. **Plug the USB drive into your mini PC**
2. Boot from USB (UEFI)
3. The installer will:
   - Wipe the internal disk
   - Install Debian 12.11.0 Server with your config
   - Set up NFS and DHCP
4. When finished, the mini PC will:
   - Have a user named `backupadmin`
   - Be accessible via SSH at `192.168.99.1`
   - Serve `/srv/nfs` over NFS
   - Provide DHCP to clients on the `192.168.99.0/24` subnet

---

## 🖥️ How to Connect from a Client

Assuming the client has a second NIC:

### 📌 Option 1: Automatically via DHCP

1. Connect an Ethernet cable from the client to the mini PC
2. Set the NIC to use DHCP
3. Verify IP assignment:

```bash
ip a  # Look for an address in 192.168.99.10–20
```

Then mount the NFS share:

```bash
sudo mount 192.168.99.1:/srv/nfs /mnt
```

To make it persistent:

```text
192.168.99.1:/srv/nfs /mnt nfs defaults 0 0
```

### 📌 Option 2: Static IP

1. Set static IP on client NIC (e.g., `192.168.99.2/24`)
2. Mount NFS as above

---

## 🔐 SSH Access

If you added your SSH public key, connect like this:

```bash
ssh backupadmin@192.168.99.1
```

---

## ⚠️ Warning

- This script **wipes the internal drive** of the target machine.
- This script **wipes the USB drive** of the build machine
- Double-check your USB target (e.g., `/dev/sdX`) to avoid destroying data.
- The current script defaults to `/dev/sdb` 

---

## 🧪 Tested On

- Debian 12.11.0 ISO
- GRUB-based UEFI systems
- Headless mini PCs with one or more NICs

---

## 💡 Future Ideas

- Add Borg or rsnapshot for scheduled backups
- Export multiple NFS volumes
- Add cron jobs or `rsync` hooks
- Use `.env.secrets` to manage config separately
- Add device picker to choose USB target interactively
- More precise partitioning 
  - sdb1: \
  - sdb2: nfs-share that could be expanded with LVM later across other additional disks
