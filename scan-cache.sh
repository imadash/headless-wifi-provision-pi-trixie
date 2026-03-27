#!/bin/bash
# Scan for WiFi networks and cache results.
# CRITICAL: Never overwrites existing cache with empty results.
CACHE_FILE="/tmp/wifi-scan-cache.json"

# Only scan if WiFi radio is on and interface is available
if ! nmcli radio wifi 2>/dev/null | grep -q "enabled"; then
    echo "WiFi radio not enabled, skipping scan"
    exit 0
fi

# Check if wlan0 is in AP mode — can't scan in AP mode
WLAN_MODE=$(nmcli -t -f GENERAL.CONNECTION dev show wlan0 2>/dev/null | cut -d: -f2)
if [ "$WLAN_MODE" = "WifiProvisionAP" ]; then
    echo "wlan0 is in AP mode, skipping scan"
    exit 0
fi

nmcli device wifi rescan ifname wlan0 2>/dev/null || true
sleep 3

python3 << 'PYEOF'
import subprocess, json, sys

CACHE_FILE = "/tmp/wifi-scan-cache.json"
AP_SSID = "AdamsMirror"  # Filter out our own AP

try:
    result = subprocess.run(
        ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY,FREQ", "device", "wifi", "list", "ifname", "wlan0"],
        capture_output=True, text=True, timeout=15
    )
except Exception as e:
    print(f"nmcli failed: {e}")
    sys.exit(0)  # Don't touch cache

networks = []
seen = set()
for line in result.stdout.strip().split("\n"):
    if not line.strip():
        continue
    parts = line.split(":")
    if len(parts) >= 3:
        ssid = parts[0].strip()
        if not ssid or ssid in seen or ssid == AP_SSID:
            continue
        try:
            signal = int(parts[1]) if parts[1].isdigit() else 0
        except ValueError:
            signal = 0
        security = parts[2].strip()
        freq_str = parts[3].strip() if len(parts) > 3 else ""
        # Extract just digits from freq (handles "2437 MHz" format)
        freq_num = int("".join(c for c in freq_str if c.isdigit()) or "0")
        band = "5 GHz" if freq_num > 3000 else "2.4 GHz"
        seen.add(ssid)
        networks.append({
            "ssid": ssid,
            "signal": signal,
            "security": security,
            "band": band,
            "has_password": "WPA" in security or "WEP" in security
        })

networks.sort(key=lambda x: x["signal"], reverse=True)

# CRITICAL: Only write cache if we actually found networks
if len(networks) > 0:
    with open(CACHE_FILE, "w") as f:
        json.dump({"networks": networks, "count": len(networks)}, f)
    print(f"Cached {len(networks)} networks")
else:
    print("Scan returned 0 networks — keeping existing cache intact")
PYEOF
