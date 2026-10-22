#!/bin/bash
# Post-installation setup for NFS/DHCP server
# Runs in-target (chroot of the new system) at the end of the Debian install, so
# systemd is NOT running: services are enabled here and start on first boot.
# When run on an already-booted system, services are also (re)started.
# Called from preseed late_command with environment variables

set -e

# Variables passed from preseed (via environment)
NFS_EXPORT="${NFS_EXPORT:-/srv/nfs}"
NFS_SUBNET="${NFS_SUBNET:-192.168.99.0/24}"
STATIC_IP="${STATIC_IP:-192.168.99.1}"
NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-192.168.99.254}"
NAMESERVERS="${NAMESERVERS:-8.8.8.8}"
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

# Interface to serve DHCP on: the one d-i configured statically, else the first physical NIC
detect_interface() {
  local iface n
  iface=$(awk '$1=="iface" && $3=="inet" && $4=="static" {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
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

# Write NFS exports (nfs-server reads /etc/exports when it starts)
echo "$NFS_EXPORT $NFS_SUBNET(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports

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

# dhcpd wants a comma-separated list: "8.8.8.8 1.1.1.1" -> "8.8.8.8, 1.1.1.1"
NAMESERVERS_CSV=$(echo $NAMESERVERS | sed 's/  */, /g')

# Write DHCP configuration
cat > /etc/dhcp/dhcpd.conf <<EOF
subnet $network_addr netmask $NETMASK {
  range $DHCP_RANGE_START $DHCP_RANGE_END;
  option routers $STATIC_IP;
  option domain-name-servers $NAMESERVERS_CSV;
  default-lease-time 600;
  max-lease-time 7200;
}
EOF

# Configure interface for DHCP server
echo "INTERFACESv4=\"$IFACE\"" > /etc/default/isc-dhcp-server

# Enable DHCP; start it only on a booted system
systemctl enable isc-dhcp-server
if systemd_running; then
  systemctl restart isc-dhcp-server
fi
echo "✓ DHCP server configured"

# ===== Static IP =====
# Debian uses ifupdown, not netplan. The installer's netcfg (preseed
# netcfg/get_ipaddress etc.) already wrote the static address to
# /etc/network/interfaces, so nothing is configured here; just sanity-check it.
if ! grep -qE "^iface +$IFACE +inet +static" /etc/network/interfaces 2>/dev/null; then
  echo "Warning: no static config for $IFACE in /etc/network/interfaces;" >&2
  echo "         the DHCP server needs $STATIC_IP on that interface." >&2
fi

echo "Post-installation setup complete!"
