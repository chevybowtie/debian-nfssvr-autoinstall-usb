#!/bin/bash
# Post-installation setup for NFS/DHCP server
# Runs in-target (chroot of the new system) at the end of the Debian install, so
# systemd is NOT running: services are enabled here and start on first boot.
# The server's own address switches from the installer's DHCP lease to STATIC_IP on the next boot.
# When run on an already-booted system, services are also (re)started.
# Called from preseed late_command with environment variables

set -e

# Variables passed from preseed (via environment)
NFS_EXPORT="${NFS_EXPORT:-/srv/nfs}"
NFS_SUBNET="${NFS_SUBNET:-192.168.99.0/24}"
STATIC_IP="${STATIC_IP:-192.168.99.1}"
NETMASK="${NETMASK:-255.255.255.0}"
SERVER_GATEWAY="${SERVER_GATEWAY:-}"           # empty = no default route (direct-cable use)
NAMESERVERS="${NAMESERVERS:-8.8.8.8}"
DHCP_SEND_GATEWAY="${DHCP_SEND_GATEWAY:-false}"  # true = tell clients to route via this server
DHCP_SEND_DNS="${DHCP_SEND_DNS:-false}"          # true = hand NAMESERVERS to clients
NFS_V4_ONLY="${NFS_V4_ONLY:-false}"              # true = serve NFSv4 only; no rpcbind/NFSv3
DHCP_RANGE_START="${DHCP_RANGE_START:-192.168.99.10}"
DHCP_RANGE_END="${DHCP_RANGE_END:-192.168.99.20}"

echo "Starting post-installation setup..."

# ===== SSH key =====
# d-i has no preseed question for authorized keys, so install it here.
if [[ -n "${SSH_KEY:-}" && -n "${TARGET_USERNAME:-}" ]]; then
  user_home=$(getent passwd "$TARGET_USERNAME" | cut -d: -f6)
  if [[ -n "$user_home" && -d "$user_home" ]]; then
    install -d -m 700 -o "$TARGET_USERNAME" -g "$TARGET_USERNAME" "$user_home/.ssh"
    touch "$user_home/.ssh/authorized_keys"
    grep -qxF "$SSH_KEY" "$user_home/.ssh/authorized_keys" || echo "$SSH_KEY" >> "$user_home/.ssh/authorized_keys"
    chown "$TARGET_USERNAME:$TARGET_USERNAME" "$user_home/.ssh/authorized_keys"
    chmod 600 "$user_home/.ssh/authorized_keys"
    echo "✓ SSH key installed for $TARGET_USERNAME"
  else
    echo "Warning: home directory for '$TARGET_USERNAME' not found; SSH key not installed" >&2
  fi
fi

# True when systemd is actually running (false inside the installer chroot)
systemd_running() { [[ -d /run/systemd/system ]]; }

# Interface to serve on: the one d-i configured (DHCP during install), else the first physical NIC
detect_interface() {
  local iface n
  iface=$(awk '$1=="iface" && $2!="lo" {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
  if [[ -z "$iface" ]]; then
    for n in /sys/class/net/*; do
      if [[ -e "$n/device" ]]; then iface=${n##*/}; break; fi
    done
  fi
  echo "$iface"
}

IFACE=$(detect_interface)
if [[ -z "$IFACE" ]]; then
  echo "Error: Could not detect network interface" >&2
  exit 1
fi
echo "Using network interface: $IFACE"

# ===== NFS Setup =====
echo "Configuring NFS server..."
mkdir -p "$NFS_EXPORT"
chown nobody:nogroup "$NFS_EXPORT"
chmod 755 "$NFS_EXPORT"

# Write NFS exports (nfs-server reads /etc/exports when it starts).
# all_squash maps every client user (root included) to nobody:nogroup, which owns
# the export, so any user on the connected PC can read and write. Files copied
# in end up owned by nobody, and clients can't chown them.
echo "$NFS_EXPORT $NFS_SUBNET(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534)" > /etc/exports

# Optional: NFSv4 only. Drops NFSv2/v3, so the rpcbind/statd helpers (and their open
# ports) aren't needed. nfs-server only Wants= rpcbind, so masking it is safe.
# Clients must use NFSv4 (mount -t nfs4 ...).
if [[ "$NFS_V4_ONLY" == "true" ]]; then
  mkdir -p /etc/nfs.conf.d
  printf '[nfsd]\nvers2=n\nvers3=n\nvers4=y\n' > /etc/nfs.conf.d/10-v4only.conf
  systemctl mask rpcbind.service rpcbind.socket rpc-statd.service
  echo "✓ NFS limited to v4 (rpcbind and rpc-statd masked)"
fi

# Enable NFS; start it only on a booted system (no systemd in the installer chroot)
systemctl enable nfs-server
if systemd_running; then
  exportfs -ra
  systemctl restart nfs-server
fi
echo "✓ NFS server configured"

# ===== DHCP Setup =====
echo "Configuring DHCP server..."

# Calculate network address from STATIC_IP and NETMASK
IFS='.' read -r -a ip_parts <<< "$STATIC_IP"
IFS='.' read -r -a mask_parts <<< "$NETMASK"

network_addr=""
for ((i=0; i<4; i++)); do
  octet=$((ip_parts[i] & mask_parts[i]))
  if [[ -z "$network_addr" ]]; then
    network_addr="$octet"
  else
    network_addr="$network_addr.$octet"
  fi
done

# Optional options. Off by default: on a direct cable this server has no route
# anywhere, and handing out a default route/DNS could hijack the client's
# internet traffic (e.g. over Wi-Fi) while the cable is plugged in.
dhcp_options=""
if [[ "$DHCP_SEND_GATEWAY" == "true" ]]; then
  dhcp_options+="  option routers $STATIC_IP;"$'\n'
fi
if [[ "$DHCP_SEND_DNS" == "true" ]]; then
  # dhcpd wants a comma-separated list: "8.8.8.8 1.1.1.1" -> "8.8.8.8, 1.1.1.1"
  NAMESERVERS_CSV=$(echo $NAMESERVERS | sed 's/  */, /g')
  dhcp_options+="  option domain-name-servers $NAMESERVERS_CSV;"$'\n'
fi

# Write DHCP configuration
cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet $network_addr netmask $NETMASK {
  range $DHCP_RANGE_START $DHCP_RANGE_END;
${dhcp_options}  default-lease-time 600;
  max-lease-time 7200;
}
EOF

# Configure interface for DHCP server
echo "INTERFACESv4=\"$IFACE\"" > /etc/default/isc-dhcp-server

# With no cable at boot the interface may not be ready when dhcpd starts; retry
# instead of staying down until someone restarts it.
mkdir -p /etc/systemd/system/isc-dhcp-server.service.d
cat > /etc/systemd/system/isc-dhcp-server.service.d/retry.conf <<EOF
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=5
EOF

# Enable DHCP; start it only on a booted system
systemctl enable isc-dhcp-server
if systemd_running; then
  systemctl restart isc-dhcp-server
fi
echo "✓ DHCP server configured"

# ===== Static IP =====
# The installer got its address by DHCP (it needs the internet to fetch
# packages). For its real job the server uses a fixed address on the cable to
# the client PC. Takes effect on the next boot.
netmask_to_cidr() {
  local o b cidr=0
  for o in ${1//./ }; do
    for ((b = 7; b >= 0; b--)); do
      if (( (o >> b) & 1 )); then cidr=$((cidr + 1)); fi
    done
  done
  echo "$cidr"
}
CIDR=$(netmask_to_cidr "$NETMASK")

if dpkg -s ifupdown >/dev/null 2>&1; then
  # Debian's default for non-desktop installs; replaces the DHCP stanza d-i wrote.
  # 'auto' (not allow-hotplug) so the address is set even when no cable is attached.
  {
    echo "# Written by post-install.sh: fixed address for the NFS/DHCP server role"
    echo "source /etc/network/interfaces.d/*"
    echo ""
    echo "auto lo"
    echo "iface lo inet loopback"
    echo ""
    echo "auto $IFACE"
    echo "iface $IFACE inet static"
    echo "    address $STATIC_IP"
    echo "    netmask $NETMASK"
    if [[ -n "$SERVER_GATEWAY" ]]; then echo "    gateway $SERVER_GATEWAY"; fi
  } > /etc/network/interfaces
  echo "✓ Static $STATIC_IP/$CIDR on $IFACE via /etc/network/interfaces"
else
  # No ifupdown: use systemd-networkd
  mkdir -p /etc/systemd/network
  {
    echo "[Match]"
    echo "Name=$IFACE"
    echo ""
    echo "[Network]"
    echo "Address=$STATIC_IP/$CIDR"
    if [[ -n "$SERVER_GATEWAY" ]]; then echo "Gateway=$SERVER_GATEWAY"; fi
    echo "ConfigureWithoutCarrier=yes"
  } > /etc/systemd/network/10-nfssvr.network
  systemctl enable systemd-networkd
  echo "✓ Static $STATIC_IP/$CIDR on $IFACE via systemd-networkd"
fi

echo "Post-installation setup complete!"
