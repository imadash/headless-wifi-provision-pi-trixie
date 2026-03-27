#!/bin/bash
# =============================================================================
# WiFi Provisioning Portal — Installer
# Raspberry Pi 4 B + Trixie Full (Desktop) / Debian 13
#
# Usage:
#   AP_SSID="YourBrand" AP_PASS="password123" sudo -E bash install.sh
#
# Handles:
#   - lighttpd on port 80 (portal uses 8080, iptables redirects)
#   - systemd-resolved port 53 conflict
#   - Desktop NM applet interference
#   - Single WiFi chip scan-while-AP limitation (pre-cached scan)
# =============================================================================

set -e

INSTALL_DIR="/opt/wifi-provisioning"
AP_SSID="${AP_SSID:-SetupDevice}"
AP_PASS="${AP_PASS:-}"
AP_IP="192.168.50.1"
AP_SUBNET="24"
PORTAL_PORT=8080

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Pre-flight ---
[ "$EUID" -ne 0 ] && error "Run as root: sudo -E bash install.sh"

if ! nmcli general status &>/dev/null; then
    error "NetworkManager is not running."
fi

log "Installing WiFi Provisioning Portal..."
log "  SSID: ${AP_SSID}"
log "  Port: ${PORTAL_PORT} (iptables redirects 80 → ${PORTAL_PORT})"

# --- Dependencies ---
log "Installing packages..."
apt-get update -qq
apt-get install -y -qq python3 python3-flask dnsmasq iptables network-manager > /dev/null 2>&1

systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
log "Packages installed."

# --- systemd-resolved (Trixie Full) ---
if systemctl is-active systemd-resolved &>/dev/null; then
    log "Configuring systemd-resolved..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/wifi-provision.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    log "systemd-resolved configured."
fi

# --- NM dispatcher (prevents desktop applet interference) ---
log "Installing NM dispatcher..."
mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d

cat > /etc/NetworkManager/conf.d/wifi-provision.conf << 'EOF'
[connection-wifi-provision-ap]
match-device=interface-name:wlan0
connection.autoconnect-priority=-999
EOF

cat > /etc/NetworkManager/dispatcher.d/50-wifi-provision << 'EOF'
#!/bin/bash
[ "$1" = "wlan0" ] || exit 0
STATUS=$(cat /tmp/wifi-provision-status 2>/dev/null || echo "")
if [ "$STATUS" = "ap_active" ] && [ "$2" = "down" ]; then
    logger "wifi-provision: AP brought down externally"
fi
exit 0
EOF
chmod +x /etc/NetworkManager/dispatcher.d/50-wifi-provision
log "NM dispatcher installed."

# --- Deploy files ---
log "Deploying to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp "$(dirname "$0")/app.py" "${INSTALL_DIR}/"
cp "$(dirname "$0")/wifi-provision.sh" "${INSTALL_DIR}/"
cp "$(dirname "$0")/scan-cache.sh" "${INSTALL_DIR}/"
cp "$(dirname "$0")/captive-iptables.sh" "${INSTALL_DIR}/"
cp "$(dirname "$0")/uninstall.sh" "${INSTALL_DIR}/" 2>/dev/null || true
chmod +x "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/app.py

# Update AP_SSID in scan-cache.sh to match configured SSID
sed -i "s/AP_SSID = \"AdamsMirror\"/AP_SSID = \"${AP_SSID}\"/" "${INSTALL_DIR}/scan-cache.sh" 2>/dev/null || true

log "Files deployed."

# --- dnsmasq config ---
cat > /etc/dnsmasq.d/wifi-provision.conf << EOF
interface=wlan0
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,24h
dhcp-option=option:router,${AP_IP}
dhcp-option=option:dns-server,${AP_IP}
address=/#/${AP_IP}
dhcp-option=option:T1,30
dhcp-option=option:T2,60
EOF
log "dnsmasq configured."

# --- AP connection profile ---
nmcli connection delete "WifiProvisionAP" 2>/dev/null || true

if [ -n "${AP_PASS}" ] && [ ${#AP_PASS} -ge 8 ]; then
    nmcli connection add \
        con-name "WifiProvisionAP" type wifi ifname wlan0 \
        ssid "${AP_SSID}" \
        802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${AP_PASS}" \
        ipv4.method manual ipv4.addresses "${AP_IP}/${AP_SUBNET}" \
        connection.autoconnect no > /dev/null 2>&1
    log "AP profile: WPA2 (SSID: ${AP_SSID})"
else
    nmcli connection add \
        con-name "WifiProvisionAP" type wifi ifname wlan0 \
        ssid "${AP_SSID}" \
        802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
        ipv4.method manual ipv4.addresses "${AP_IP}/${AP_SUBNET}" \
        connection.autoconnect no > /dev/null 2>&1
    log "AP profile: OPEN (SSID: ${AP_SSID})"
fi

# --- Systemd services ---
cat > /etc/systemd/system/wifi-provision.service << EOF
[Unit]
Description=WiFi Provisioning Controller
After=NetworkManager.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/wifi-provision.sh
Restart=always
RestartSec=10
Environment=AP_SSID=${AP_SSID}
Environment=AP_IP=${AP_IP}
Environment=PORTAL_PORT=${PORTAL_PORT}
Environment=INSTALL_DIR=${INSTALL_DIR}
Environment=BOOT_WAIT=25

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/wifi-portal.service << EOF
[Unit]
Description=WiFi Provisioning Web Portal
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py
Restart=on-failure
RestartSec=5
Environment=AP_IP=${AP_IP}
Environment=PORTAL_PORT=${PORTAL_PORT}
Environment=AP_SSID=${AP_SSID}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/wifi-provision-dns.service << 'EOF'
[Unit]
Description=WiFi Provisioning DNS/DHCP
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --no-daemon --conf-file=/etc/dnsmasq.d/wifi-provision.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wifi-provision.service
log "Systemd services installed."

# --- Clean start ---
rm -f /tmp/wifi-scan-cache.json /tmp/wifi-provision-status

echo ""
echo "============================================================"
echo -e "${GREEN}  WiFi Provisioning Portal — Installed${NC}"
echo "============================================================"
echo ""
echo "  SSID:        ${AP_SSID}"
[ -n "${AP_PASS}" ] && echo "  Password:    ${AP_PASS}"
echo "  Portal:      http://${AP_IP} (redirects to :${PORTAL_PORT})"
echo "  Install Dir: ${INSTALL_DIR}"
echo ""
echo "  Start now:   sudo systemctl start wifi-provision"
echo "  View logs:   journalctl -u wifi-provision -f"
echo "  Reboot:      sudo reboot"
echo "============================================================"
