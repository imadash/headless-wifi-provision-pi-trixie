#!/bin/bash
# =============================================================================
# WiFi Provisioning Controller — Bulletproof Edition
# Trixie Full Desktop, Pi 4 B
#
# Key design decisions:
# - NO set -e (silent crashes kill the monitoring loop)
# - NO prescan in start_ap_mode (WiFi is already gone by then)
# - Scan cache runs ONLY when confirmed connected, BEFORE checking for drops
# - All variables exported for child scripts
# - No exit calls in functions (would kill the whole controller)
# - lighttpd stopped during AP mode to free port 80
# =============================================================================

# --- Config (from systemd environment, with sane defaults) ---
export AP_SSID="${AP_SSID:-AdamsMirror}"
export AP_IP="${AP_IP:-192.168.50.1}"
export PORTAL_PORT="${PORTAL_PORT:-8080}"
export INSTALL_DIR="${INSTALL_DIR:-/opt/wifi-provisioning}"
export AP_CON_NAME="WifiProvisionAP"
BOOT_WAIT="${BOOT_WAIT:-25}"
CHECK_INTERVAL=30
CONNECTION_TIMEOUT=30
STATUS_FILE="/tmp/wifi-provision-status"
CACHE_FILE="/tmp/wifi-scan-cache.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

set_status() {
    echo "$1" > "${STATUS_FILE}"
    log "Status → $1"
}

# ── Check if wlan0 has a real WiFi client connection (not our AP) ──
is_wifi_connected() {
    local state con
    state=$(nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | cut -d: -f2 || echo "")
    con=$(nmcli -t -f GENERAL.CONNECTION dev show wlan0 2>/dev/null | cut -d: -f2 || echo "")

    if [ "$state" = "100 (connected)" ] && \
       [ "$con" != "$AP_CON_NAME" ] && \
       [ "$con" != "--" ] && \
       [ -n "$con" ]; then
        return 0
    fi
    return 1
}

# ── Update the scan cache (only if WiFi is actually working) ──
update_scan_cache() {
    # Double-check we're really connected before scanning
    if is_wifi_connected; then
        bash "${INSTALL_DIR}/scan-cache.sh" 2>/dev/null || true
    else
        log "Skipping scan cache update — not connected"
    fi
}

# ── Start AP mode ──
start_ap_mode() {
    log "=== STARTING AP MODE ==="

    # Do NOT run prescan here — WiFi is already dead by this point.
    # The monitoring loop keeps the cache fresh while connected.

    # Check if cache has data
    if [ -f "$CACHE_FILE" ]; then
        local count
        count=$(python3 -c "import json; print(json.load(open('$CACHE_FILE')).get('count',0))" 2>/dev/null || echo "0")
        log "Scan cache has ${count} networks from last good scan"
    else
        log "WARNING: No scan cache exists — portal will show empty network list"
    fi

    set_status "starting_ap"

    # Stop lighttpd during AP mode to free port 80 for iptables redirect
    systemctl stop lighttpd 2>/dev/null || true
    log "lighttpd stopped for AP mode"

    # Disconnect wlan0 from any current connection
    nmcli device disconnect wlan0 2>/dev/null || true
    sleep 2

    # Cycle WiFi radio to clear NM applet's autoconnect queue
    nmcli radio wifi off 2>/dev/null || true
    sleep 1
    nmcli radio wifi on 2>/dev/null || true
    sleep 2

    # Activate the AP
    if nmcli connection up "$AP_CON_NAME" 2>/dev/null; then
        log "AP connection activated"
    else
        log "AP activation failed, retrying in 5s..."
        sleep 5
        if ! nmcli connection up "$AP_CON_NAME" 2>/dev/null; then
            log "FATAL: Cannot activate AP after retry"
            # Don't exit — fall through and let the loop retry
            return 1
        fi
    fi
    sleep 2

    # Start dnsmasq for DHCP + DNS redirect
    systemctl start wifi-provision-dns 2>/dev/null || {
        log "WARNING: dnsmasq service failed"
    }
    sleep 1

    # Set up iptables captive portal redirect
    bash "${INSTALL_DIR}/captive-iptables.sh" start 2>/dev/null || {
        log "WARNING: iptables setup failed"
    }

    # Start the Flask web portal
    systemctl start wifi-portal 2>/dev/null || {
        log "WARNING: portal service failed"
    }
    sleep 1

    set_status "ap_active"
    log "=== AP MODE ACTIVE === SSID: ${AP_SSID}, Portal: http://${AP_IP}"
}

# ── Stop AP mode ──
stop_ap_mode() {
    log "=== STOPPING AP MODE ==="
    set_status "stopping_ap"

    systemctl stop wifi-portal 2>/dev/null || true
    bash "${INSTALL_DIR}/captive-iptables.sh" stop 2>/dev/null || true
    systemctl stop wifi-provision-dns 2>/dev/null || true
    nmcli connection down "$AP_CON_NAME" 2>/dev/null || true

    # Restart lighttpd (MagicMirror/Senses needs it)
    systemctl start lighttpd 2>/dev/null || true
    log "lighttpd restarted"

    sleep 2
    log "=== AP MODE STOPPED ==="
}

# ── Try saved WiFi connections ──
try_saved_connections() {
    log "Trying saved WiFi connections..."

    nmcli device wifi rescan ifname wlan0 2>/dev/null || true
    sleep 3

    local saved
    saved=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless$' | grep -v "$AP_CON_NAME" | cut -d: -f1)

    if [ -z "$saved" ]; then
        log "No saved WiFi connections found"
        return 1
    fi

    local visible
    visible=$(nmcli -t -f SSID device wifi list ifname wlan0 2>/dev/null | sort -u)

    while IFS= read -r conn_name; do
        [ -z "$conn_name" ] && continue
        local ssid
        ssid=$(nmcli -t -f 802-11-wireless.ssid connection show "$conn_name" 2>/dev/null | cut -d: -f2)

        if echo "$visible" | grep -qF "$ssid" 2>/dev/null; then
            log "Trying: ${conn_name} (SSID: ${ssid})"
            if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$conn_name" 2>/dev/null; then
                sleep 3
                if is_wifi_connected; then
                    log "Connected to: ${ssid}"
                    return 0
                fi
            fi
            log "Failed: ${ssid}"
        fi
    done <<< "$saved"

    return 1
}

# =============================================================================
# MAIN
# =============================================================================
log "╔══════════════════════════════════════════════╗"
log "║  WiFi Provisioning Controller Starting       ║"
log "╚══════════════════════════════════════════════╝"
log "Waiting ${BOOT_WAIT}s for NetworkManager to settle..."
sleep "$BOOT_WAIT"

# Initial state
if is_wifi_connected; then
    log "WiFi is connected. Building initial scan cache..."
    update_scan_cache
    set_status "connected"
else
    log "No WiFi connection detected."
    if try_saved_connections; then
        log "Connected via saved credentials. Building scan cache..."
        update_scan_cache
        set_status "connected"
    else
        log "No saved connections available. Starting AP mode."
        start_ap_mode
    fi
fi

# =============================================================================
# MONITORING LOOP
# =============================================================================
log "Entering monitoring loop (interval: ${CHECK_INTERVAL}s)..."

while true; do
    sleep "$CHECK_INTERVAL"

    current_status=$(cat "${STATUS_FILE}" 2>/dev/null || echo "unknown")
    log "Loop: status=${current_status}"

    case "$current_status" in

        connected)
            # FIRST: update cache while we know WiFi is still good
            # (This must happen BEFORE we check for drops)
            if is_wifi_connected; then
                update_scan_cache
            else
                # WiFi just dropped — DO NOT update cache (would write empty)
                log "WiFi connection LOST!"
                set_status "reconnecting"
                log "Waiting 10s for auto-reconnect..."
                sleep 10

                if is_wifi_connected; then
                    set_status "connected"
                    log "Auto-reconnected successfully"
                elif try_saved_connections; then
                    set_status "connected"
                    log "Reconnected via saved credentials"
                else
                    log "All reconnection attempts failed. Starting AP..."
                    start_ap_mode
                fi
            fi
            ;;

        ap_active)
            # Verify AP is still broadcasting
            local_state=$(nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | cut -d: -f2 || echo "")
            if [ "$local_state" != "100 (connected)" ]; then
                log "AP dropped unexpectedly. Restarting..."
                start_ap_mode
            fi
            ;;

        connecting)
            # Web portal submitted credentials — check result
            log "Connection attempt in progress..."
            sleep 5
            if is_wifi_connected; then
                stop_ap_mode
                log "Customer WiFi connected! Building scan cache..."
                update_scan_cache
                set_status "connected"
            else
                log "Connection attempt failed. Restarting AP..."
                start_ap_mode
            fi
            ;;

        reconnecting)
            # We're in the middle of reconnecting — check again
            if is_wifi_connected; then
                set_status "connected"
                log "Reconnected"
            else
                log "Still not connected. Starting AP..."
                start_ap_mode
            fi
            ;;

        *)
            log "Unknown status: ${current_status}. Checking WiFi..."
            if is_wifi_connected; then
                set_status "connected"
            else
                start_ap_mode
            fi
            ;;
    esac
done
