#!/bin/bash
# iptables rules for captive portal redirect
# Redirects HTTP/HTTPS/DNS from AP clients to the portal

ACTION=${1:-start}
AP_IP="${AP_IP:-192.168.50.1}"
PORTAL_PORT="${PORTAL_PORT:-8080}"

if [ "$ACTION" = "start" ]; then
    # Clear any old rules first
    iptables -t nat -F PREROUTING 2>/dev/null || true

    # Redirect HTTP (port 80) → portal
    iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT --to-destination ${AP_IP}:${PORTAL_PORT}

    # Redirect HTTPS (port 443) → portal (triggers captive portal detection)
    iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 443 -j DNAT --to-destination ${AP_IP}:${PORTAL_PORT}

    # Redirect DNS → local dnsmasq
    iptables -t nat -A PREROUTING -i wlan0 -p udp --dport 53 -j DNAT --to-destination ${AP_IP}:53
    iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 53 -j DNAT --to-destination ${AP_IP}:53

    echo "iptables captive portal rules ACTIVE (portal on ${AP_IP}:${PORTAL_PORT})"

elif [ "$ACTION" = "stop" ]; then
    iptables -t nat -F PREROUTING 2>/dev/null || true
    echo "iptables captive portal rules CLEARED"
fi
