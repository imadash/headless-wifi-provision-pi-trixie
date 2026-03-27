# wifi-provision-pi

**Headless WiFi provisioning for Raspberry Pi 4 B on Trixie Full (Debian 13)**

When the Pi has no WiFi connection, it broadcasts an access point with a captive portal. Customers connect from their phone or laptop, select their WiFi network, enter the password, and the Pi joins their network automatically. No keyboard, monitor, or SSH required.

Built specifically for **Raspberry Pi OS Trixie Full (Desktop)** because existing tools (balena wifi-connect, comitup, RaspAP) have compatibility issues with Trixie's netplan + NetworkManager stack.

## How It Works

```
Pi boots → WiFi found? → YES → Monitor connection (rebuild scan cache every 30s)
                                    ↓
                              WiFi drops?
                                    ↓
              NO ← ─ ─ ─ ─ ─ ─ ─ ─ ┘
               ↓
     Start Access Point ("YourBrand")
               ↓
     Customer connects from phone
               ↓
     Captive portal shows cached network list
               ↓
     Customer selects WiFi + enters password
               ↓
     Pi connects → AP shuts down → Monitor loop resumes
```

### The Single-Chip Problem

The Pi 4's built-in WiFi chip cannot scan for networks while in AP mode — it can only do one at a time. This project solves it by **continuously caching scan results while connected**, so when WiFi drops and AP mode starts, the portal has a fresh list of nearby networks ready to display.

## Requirements

- Raspberry Pi 4 Model B (also works with Pi 3B+, Pi Zero 2 W)
- Raspberry Pi OS Trixie Full (Desktop) — Debian 13
- NetworkManager (included by default)

## Quick Start

```bash
# On your Pi (via SSH):
git clone https://github.com/YOUR_USERNAME/wifi-provision-pi.git
cd wifi-provision-pi

# Install with your custom AP name and password
AP_SSID="MyProduct Setup" AP_PASS="setup1234" sudo -E bash install.sh

# Reboot to activate
sudo reboot
```

The AP password must be at least 8 characters. Omit `AP_PASS` for an open network.

## Testing

1. Ensure the controller is running and caching networks:
   ```bash
   journalctl -u wifi-provision --no-pager | tail -10
   # Should show "Cached N networks" entries
   ```

2. Turn off your router/modem (do NOT reboot the Pi)

3. Wait 1-2 minutes — the monitoring loop detects the drop and starts the AP

4. Connect to your AP from a phone/PC, open http://192.168.50.1

5. Select your WiFi, enter the password, tap Connect

## Architecture

| Component | Role |
|---|---|
| `wifi-provision.sh` | Main controller — monitors WiFi, switches between AP and client mode |
| `app.py` | Flask web portal on port 8080 — serves the captive portal UI |
| `scan-cache.sh` | Scans networks via nmcli, caches results (never overwrites with empty data) |
| `captive-iptables.sh` | Redirects HTTP/HTTPS/DNS to the portal during AP mode |
| NetworkManager (nmcli) | Manages AP and client connections natively (no hostapd needed) |
| dnsmasq | DHCP + DNS redirect for captive portal detection (only runs during AP mode) |

### Why Port 8080?

Many Pi projects (MagicMirror, Senses, lighttpd) use port 80. The portal runs on 8080, and iptables redirects port 80 → 8080 during AP mode only. When the Pi is in normal client mode, port 80 is untouched.

### Trixie-Specific Handling

| Issue | Solution |
|---|---|
| systemd-resolved holds port 53 | `DNSStubListener=no` in resolved.conf.d |
| Desktop NM applet races to manage WiFi | NM dispatcher + conf.d priority config |
| netplan stores connections differently | Works with nmcli, which handles netplan automatically |
| lighttpd on port 80 | Portal on 8080, lighttpd stopped during AP mode, restarted after |

### Key Design Decision: Cache-First Scanning

```
While connected:
  Every 30s → scan networks → cache has data? → write cache
  (Only writes if scan returned >0 networks — never overwrites with empty)

When WiFi drops:
  → DO NOT scan (WiFi is gone, would get 0 results)
  → Start AP mode
  → Portal reads cached scan data
```

## Files

```
/opt/wifi-provisioning/
├── app.py                  # Flask portal (port 8080)
├── wifi-provision.sh       # Main controller
├── scan-cache.sh           # Network scanner + cache manager
├── captive-iptables.sh     # iptables rules
└── uninstall.sh            # Clean removal

/etc/systemd/system/
├── wifi-provision.service      # Controller (enabled on boot)
├── wifi-portal.service         # Flask server (started by controller)
└── wifi-provision-dns.service  # dnsmasq (started by controller)
```

## Troubleshooting

```bash
# Service status
sudo systemctl status wifi-provision
sudo systemctl status wifi-portal
sudo systemctl status wifi-provision-dns

# Live logs
journalctl -u wifi-provision -f

# Manual AP test
sudo nmcli connection up WifiProvisionAP

# Force reconnect to WiFi
sudo nmcli connection down WifiProvisionAP
sudo nmcli device wifi connect "YourSSID" password "YourPassword"

# Uninstall
sudo bash /opt/wifi-provisioning/uninstall.sh
```

## Customer Experience

1. Customer plugs in the Pi
2. After ~45 seconds, a WiFi network appears (your branded name)
3. Customer connects from their phone/laptop
4. A web page opens (or they browse to http://192.168.50.1)
5. They see nearby WiFi networks, pick theirs, enter password, tap Connect
6. Pi connects, setup network disappears
7. If WiFi drops later, the setup network re-appears automatically

## License

MIT
