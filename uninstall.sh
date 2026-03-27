#!/bin/bash
# Uninstall WiFi Provisioning Portal

[ "$EUID" -ne 0 ] && echo "Run as root: sudo bash uninstall.sh" && exit 1

echo "Uninstalling WiFi Provisioning Portal..."

systemctl stop wifi-provision wifi-portal wifi-provision-dns 2>/dev/null || true
systemctl disable wifi-provision wifi-portal wifi-provision-dns 2>/dev/null || true

rm -f /etc/systemd/system/wifi-provision.service
rm -f /etc/systemd/system/wifi-portal.service
rm -f /etc/systemd/system/wifi-provision-dns.service
rm -f /etc/dnsmasq.d/wifi-provision.conf
rm -f /etc/NetworkManager/conf.d/wifi-provision.conf
rm -f /etc/NetworkManager/dispatcher.d/50-wifi-provision
rm -f /etc/systemd/resolved.conf.d/wifi-provision.conf
rm -f /tmp/wifi-provision-status /tmp/wifi-scan-cache.json

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
systemctl restart systemd-resolved 2>/dev/null || true
iptables -t nat -F PREROUTING 2>/dev/null || true
nmcli connection delete "WifiProvisionAP" 2>/dev/null || true
systemctl start lighttpd 2>/dev/null || true

rm -rf /opt/wifi-provisioning
systemctl daemon-reload

echo "Uninstalled. Re-enable desktop: sudo systemctl set-default graphical.target"
