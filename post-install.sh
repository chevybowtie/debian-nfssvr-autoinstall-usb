#!/bin/bash
# Post-installation setup for NFS/DHCP server
# Runs in-target after Debian installation completes
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
HOSTNAME_NET="${HOSTNAME_NET:-nfssvr}"

echo "Starting post-installation setup..."

# Detect primary network interface (exclude loopback and virtual interfaces)
detect_interface() {
  local iface
  iface=$(ip -o link show | grep -v "lo\|docker\|vir" | awk '{print $2}' | sed 's/:$//' | head -n1)
  if [[ -z "$iface" ]]; then
    iface=$(ls /sys/class/net | grep -v "^lo$" | head -n1)
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

# Write NFS exports
echo "$NFS_EXPORT $NFS_SUBNET(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
exportfs -a

# Enable and start NFS
systemctl enable nfs-server
systemctl start nfs-server
echo "✓ NFS server configured and started"

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

# Write DHCP configuration
cat > /etc/dhcp/dhcpd.conf <<EOF
subnet $network_addr netmask $NETMASK {
  range $DHCP_RANGE_START $DHCP_RANGE_END;
  option routers $STATIC_IP;
  option domain-name-servers $NAMESERVERS;
  default-lease-time 600;
  max-lease-time 7200;
}
EOF

# Configure interface for DHCP server
echo "INTERFACESv4=\"$IFACE\"" > /etc/default/isc-dhcp-server

# Enable and start DHCP
systemctl enable isc-dhcp-server
systemctl start isc-dhcp-server
echo "✓ DHCP server configured and started"

# ===== Netplan Static IP Setup =====
echo "Configuring static IP via netplan..."

# Convert netmask to CIDR notation
netmask_to_cidr() {
  local mask=$1
  local binary=""
  IFS='.' read -r -a octets <<< "$mask"
  for octet in "${octets[@]}"; do
    binary=$(printf "%08b" "$octet")$binary
  done
  echo "${binary//0/}" | wc -c
  echo $(($(echo "${binary//0/}" | wc -c) - 1))
}

CIDR=$(netmask_to_cidr "$NETMASK")

# Create netplan configuration
mkdir -p /etc/netplan
cat > /etc/netplan/01-nfssvr.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      addresses:
        - ${STATIC_IP}/${CIDR}
      gateway4: $GATEWAY
      nameservers:
        addresses: [$(echo $NAMESERVERS | tr ' ' ',')]
      dhcp4: false
EOF

# Generate and apply netplan
netplan generate || true
netplan apply || true
echo "✓ Static IP configured via netplan"

echo "Post-installation setup complete!"
