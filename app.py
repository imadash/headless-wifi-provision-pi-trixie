#!/usr/bin/env python3
"""
WiFi Provisioning Web Portal
Captive portal for customers to input WiFi credentials on a headless Raspberry Pi.
Designed for Pi 4 B running Trixie Full (Debian 13) with NetworkManager.

Key design notes:
- Runs on port 8080 (lighttpd uses 80 for MagicMirror/Senses)
- iptables redirects port 80 → 8080 during AP mode
- When wlan0 is in AP mode, live scans return nothing → falls back to cached scan
- Handles "2437 MHz" frequency format from nmcli
"""

import os
import subprocess
import json
import time
import threading
from flask import Flask, request, redirect, render_template_string, jsonify

app = Flask(__name__)

AP_IP = os.environ.get("AP_IP", "192.168.50.1")
PORTAL_PORT = int(os.environ.get("PORTAL_PORT", "8080"))
AP_SSID = os.environ.get("AP_SSID", "AdamsMirror")
STATUS_FILE = "/tmp/wifi-provision-status"
CACHE_FILE = "/tmp/wifi-scan-cache.json"
AP_CON_NAME = "WifiProvisionAP"


# ─── Helpers ────────────────────────────────────────────────────────────────

def scan_networks():
    """
    Scan for available WiFi networks.
    Falls back to cached results when wlan0 is in AP mode (can't scan).
    """
    networks = []

    try:
        subprocess.run(
            ["nmcli", "device", "wifi", "rescan", "ifname", "wlan0"],
            capture_output=True, timeout=10
        )
        time.sleep(2)

        result = subprocess.run(
            ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY,FREQ",
             "device", "wifi", "list", "ifname", "wlan0"],
            capture_output=True, text=True, timeout=10
        )

        seen_ssids = set()
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split(":")
            if len(parts) < 3:
                continue

            ssid = parts[0].strip()
            if not ssid or ssid in seen_ssids or ssid == AP_SSID:
                continue

            try:
                signal = int(parts[1])
            except (ValueError, IndexError):
                signal = 0

            security = parts[2].strip() if len(parts) > 2 else ""
            freq_str = parts[3].strip() if len(parts) > 3 else ""

            # Handle "2437 MHz" format — extract only digits
            freq_num = int("".join(c for c in freq_str if c.isdigit()) or "0")
            band = "5 GHz" if freq_num > 3000 else "2.4 GHz"

            seen_ssids.add(ssid)
            networks.append({
                "ssid": ssid,
                "signal": signal,
                "security": security,
                "band": band,
                "has_password": "WPA" in security or "WEP" in security
            })

        networks.sort(key=lambda x: x["signal"], reverse=True)

    except Exception as e:
        print(f"Live scan error (expected in AP mode): {e}")

    # If live scan returned nothing (AP mode), use cached results
    if not networks:
        try:
            with open(CACHE_FILE, "r") as f:
                cached = json.load(f)
                cached_nets = cached.get("networks", [])
                if cached_nets:
                    print(f"Using cached scan: {len(cached_nets)} networks")
                    return cached_nets
        except FileNotFoundError:
            print("No scan cache file found")
        except Exception as e:
            print(f"Cache read error: {e}")

    return networks


def connect_to_network(ssid, password):
    """
    Attempt to connect to the specified WiFi network using NetworkManager.
    Returns (success: bool, message: str)
    """
    try:
        # Signal the controller that we're attempting a connection
        with open(STATUS_FILE, "w") as f:
            f.write("connecting")

        # Delete any old connection with this name
        subprocess.run(
            ["nmcli", "connection", "delete", ssid],
            capture_output=True, timeout=10
        )
        time.sleep(1)

        # Bring down the AP
        subprocess.run(
            ["nmcli", "connection", "down", AP_CON_NAME],
            capture_output=True, timeout=10
        )
        time.sleep(2)

        # Attempt the connection
        cmd = ["nmcli", "device", "wifi", "connect", ssid, "ifname", "wlan0"]
        if password:
            cmd.extend(["password", password])

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

        time.sleep(3)

        # Check if connected
        check = subprocess.run(
            ["nmcli", "-t", "-f", "GENERAL.STATE", "dev", "show", "wlan0"],
            capture_output=True, text=True, timeout=10
        )

        if "100 (connected)" in check.stdout:
            # Get the assigned IP
            ip_check = subprocess.run(
                ["nmcli", "-t", "-f", "IP4.ADDRESS", "dev", "show", "wlan0"],
                capture_output=True, text=True, timeout=10
            )
            ip_addr = ""
            for line in ip_check.stdout.strip().split("\n"):
                if "IP4.ADDRESS" in line:
                    ip_addr = line.split(":")[1].split("/")[0] if ":" in line else ""
                    break

            with open(STATUS_FILE, "w") as f:
                f.write("connected")

            return True, f"Connected to {ssid}! Device IP: {ip_addr}"
        else:
            # Connection failed — re-enable AP
            subprocess.run(
                ["nmcli", "connection", "up", AP_CON_NAME],
                capture_output=True, timeout=15
            )
            with open(STATUS_FILE, "w") as f:
                f.write("ap_active")

            error_msg = result.stderr.strip() if result.stderr else "Connection failed"
            return False, f"Could not connect to {ssid}. {error_msg}"

    except subprocess.TimeoutExpired:
        subprocess.run(
            ["nmcli", "connection", "up", AP_CON_NAME],
            capture_output=True, timeout=15
        )
        with open(STATUS_FILE, "w") as f:
            f.write("ap_active")
        return False, "Connection timed out. Please try again."

    except Exception as e:
        with open(STATUS_FILE, "w") as f:
            f.write("ap_active")
        return False, f"Error: {str(e)}"


# ─── HTML Template ──────────────────────────────────────────────────────────

PORTAL_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>WiFi Setup</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #0f172a 0%, #1e293b 50%, #0f172a 100%);
            min-height: 100vh;
            color: #e2e8f0;
            display: flex;
            justify-content: center;
            align-items: flex-start;
            padding: 20px;
        }

        .container {
            width: 100%;
            max-width: 420px;
            margin-top: 20px;
        }

        .header {
            text-align: center;
            margin-bottom: 24px;
        }

        .header .icon {
            width: 64px;
            height: 64px;
            background: linear-gradient(135deg, #3b82f6, #8b5cf6);
            border-radius: 16px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin: 0 auto 16px;
            font-size: 28px;
        }

        .header h1 {
            font-size: 22px;
            font-weight: 700;
            margin-bottom: 6px;
        }

        .header p {
            font-size: 14px;
            color: #94a3b8;
        }

        .card {
            background: rgba(30, 41, 59, 0.8);
            border: 1px solid rgba(71, 85, 105, 0.4);
            border-radius: 16px;
            padding: 20px;
            margin-bottom: 16px;
            backdrop-filter: blur(10px);
        }

        .card h2 {
            font-size: 15px;
            font-weight: 600;
            margin-bottom: 14px;
            color: #94a3b8;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .network-list { list-style: none; }

        .network-item {
            display: flex;
            align-items: center;
            padding: 12px 14px;
            border-radius: 10px;
            cursor: pointer;
            transition: background 0.2s;
            margin-bottom: 4px;
        }

        .network-item:hover, .network-item.selected {
            background: rgba(59, 130, 246, 0.15);
        }

        .network-item.selected {
            border: 1px solid rgba(59, 130, 246, 0.4);
        }

        .network-info { flex: 1; }

        .network-name {
            font-size: 15px;
            font-weight: 500;
        }

        .network-detail {
            font-size: 12px;
            color: #64748b;
            margin-top: 2px;
        }

        .signal-bars {
            display: flex;
            align-items: flex-end;
            gap: 2px;
            height: 18px;
            margin-left: 10px;
        }

        .signal-bar {
            width: 4px;
            border-radius: 1px;
            background: #334155;
        }

        .signal-bar.active { background: #3b82f6; }

        .lock-icon {
            margin-left: 8px;
            font-size: 14px;
            color: #64748b;
        }

        .password-section {
            display: none;
            margin-top: 16px;
        }

        .password-section.visible { display: block; }

        .input-group { position: relative; }

        .input-group input {
            width: 100%;
            padding: 14px 50px 14px 16px;
            background: rgba(15, 23, 42, 0.6);
            border: 1px solid rgba(71, 85, 105, 0.4);
            border-radius: 10px;
            color: #e2e8f0;
            font-size: 16px;
            outline: none;
            transition: border-color 0.2s;
        }

        .input-group input:focus { border-color: #3b82f6; }

        .input-group .toggle-pass {
            position: absolute;
            right: 14px;
            top: 50%;
            transform: translateY(-50%);
            background: none;
            border: none;
            color: #64748b;
            cursor: pointer;
            font-size: 13px;
        }

        .connect-btn {
            width: 100%;
            padding: 14px;
            background: linear-gradient(135deg, #3b82f6, #2563eb);
            border: none;
            border-radius: 10px;
            color: white;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            margin-top: 16px;
            transition: opacity 0.2s;
        }

        .connect-btn:hover { opacity: 0.9; }
        .connect-btn:disabled { opacity: 0.5; cursor: not-allowed; }

        .refresh-btn {
            display: block;
            width: 100%;
            padding: 10px;
            background: transparent;
            border: 1px solid rgba(71, 85, 105, 0.4);
            border-radius: 10px;
            color: #94a3b8;
            font-size: 14px;
            cursor: pointer;
            margin-top: 8px;
        }

        .refresh-btn:hover { background: rgba(71, 85, 105, 0.2); }

        .status-msg {
            padding: 12px 16px;
            border-radius: 10px;
            font-size: 14px;
            margin-top: 12px;
            display: none;
        }

        .status-msg.success {
            display: block;
            background: rgba(34, 197, 94, 0.15);
            border: 1px solid rgba(34, 197, 94, 0.3);
            color: #4ade80;
        }

        .status-msg.error {
            display: block;
            background: rgba(239, 68, 68, 0.15);
            border: 1px solid rgba(239, 68, 68, 0.3);
            color: #f87171;
        }

        .status-msg.info {
            display: block;
            background: rgba(59, 130, 246, 0.15);
            border: 1px solid rgba(59, 130, 246, 0.3);
            color: #60a5fa;
        }

        .spinner {
            display: inline-block;
            width: 16px;
            height: 16px;
            border: 2px solid rgba(255,255,255,0.3);
            border-top-color: white;
            border-radius: 50%;
            animation: spin 0.6s linear infinite;
            vertical-align: middle;
            margin-right: 8px;
        }

        @keyframes spin { to { transform: rotate(360deg); } }

        .empty-state {
            text-align: center;
            padding: 30px 10px;
            color: #64748b;
        }

        .manual-entry { margin-top: 12px; }

        .manual-entry input {
            width: 100%;
            padding: 14px 16px;
            background: rgba(15, 23, 42, 0.6);
            border: 1px solid rgba(71, 85, 105, 0.4);
            border-radius: 10px;
            color: #e2e8f0;
            font-size: 16px;
            outline: none;
            margin-bottom: 8px;
        }

        .manual-entry input:focus { border-color: #3b82f6; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="icon">📶</div>
            <h1>WiFi Setup</h1>
            <p>Connect your device to your home WiFi network</p>
        </div>

        <div class="card">
            <h2>Available Networks</h2>
            <div id="networkListContainer">
                <div class="empty-state">
                    <div class="spinner"></div> Scanning for networks...
                </div>
            </div>
            <button class="refresh-btn" onclick="refreshNetworks()">↻ Refresh Networks</button>
        </div>

        <div class="card" id="connectCard" style="display:none;">
            <h2>Connect to: <span id="selectedSSID" style="color:#3b82f6"></span></h2>

            <div class="password-section visible" id="passwordSection">
                <div class="input-group">
                    <input type="password" id="wifiPassword" placeholder="Enter WiFi password"
                           autocomplete="off" autocapitalize="off">
                    <button class="toggle-pass" onclick="togglePassword()">Show</button>
                </div>
            </div>

            <button class="connect-btn" id="connectBtn" onclick="connectWifi()">Connect</button>
            <div id="statusMsg" class="status-msg"></div>
        </div>

        <div class="card">
            <h2>Hidden Network?</h2>
            <div class="manual-entry">
                <input type="text" id="manualSSID" placeholder="Enter network name (SSID)"
                       autocomplete="off" autocapitalize="off">
                <div class="input-group">
                    <input type="password" id="manualPassword" placeholder="Enter password"
                           autocomplete="off" autocapitalize="off">
                    <button class="toggle-pass" onclick="toggleManualPassword()">Show</button>
                </div>
                <button class="connect-btn" onclick="connectManual()">Connect to Hidden Network</button>
            </div>
        </div>
    </div>

    <script>
        let selectedSSID = '';
        let selectedHasPassword = true;

        window.addEventListener('load', refreshNetworks);

        function refreshNetworks() {
            const container = document.getElementById('networkListContainer');
            container.innerHTML = '<div class="empty-state"><div class="spinner"></div> Scanning for networks...</div>';
            document.getElementById('connectCard').style.display = 'none';

            fetch('/api/scan')
                .then(r => r.json())
                .then(data => {
                    if (data.networks.length === 0) {
                        container.innerHTML = '<div class="empty-state">No networks found. Try refreshing.</div>';
                        return;
                    }

                    let html = '<ul class="network-list">';
                    data.networks.forEach(net => {
                        const bars = getSignalBars(net.signal);
                        html += `
                            <li class="network-item" onclick="selectNetwork('${escapeHtml(net.ssid)}', ${net.has_password})"
                                data-ssid="${escapeHtml(net.ssid)}">
                                <div class="network-info">
                                    <div class="network-name">${escapeHtml(net.ssid)}</div>
                                    <div class="network-detail">${net.band} · ${net.security || 'Open'}</div>
                                </div>
                                ${bars}
                                ${net.has_password ? '<span class="lock-icon">🔒</span>' : ''}
                            </li>`;
                    });
                    html += '</ul>';
                    container.innerHTML = html;
                })
                .catch(() => {
                    container.innerHTML = '<div class="empty-state">Scan failed. Please refresh.</div>';
                });
        }

        function getSignalBars(signal) {
            const level = signal > 75 ? 4 : signal > 50 ? 3 : signal > 25 ? 2 : 1;
            let bars = '<div class="signal-bars">';
            [6, 9, 12, 16].forEach((h, i) => {
                bars += `<div class="signal-bar ${i < level ? 'active' : ''}" style="height:${h}px"></div>`;
            });
            return bars + '</div>';
        }

        function selectNetwork(ssid, hasPassword) {
            selectedSSID = ssid;
            selectedHasPassword = hasPassword;

            document.querySelectorAll('.network-item').forEach(el => el.classList.remove('selected'));
            document.querySelector(`[data-ssid="${CSS.escape(ssid)}"]`)?.classList.add('selected');

            document.getElementById('connectCard').style.display = 'block';
            document.getElementById('selectedSSID').textContent = ssid;
            document.getElementById('statusMsg').className = 'status-msg';
            document.getElementById('statusMsg').style.display = 'none';

            const pwSection = document.getElementById('passwordSection');
            if (hasPassword) {
                pwSection.style.display = 'block';
                document.getElementById('wifiPassword').value = '';
                document.getElementById('wifiPassword').focus();
            } else {
                pwSection.style.display = 'none';
            }

            document.getElementById('connectCard').scrollIntoView({ behavior: 'smooth' });
        }

        function connectWifi() {
            const password = document.getElementById('wifiPassword').value;
            if (selectedHasPassword && !password) {
                showStatus('error', 'Please enter the WiFi password.');
                return;
            }
            doConnect(selectedSSID, password);
        }

        function connectManual() {
            const ssid = document.getElementById('manualSSID').value.trim();
            const password = document.getElementById('manualPassword').value;
            if (!ssid) { alert('Please enter a network name.'); return; }
            doConnect(ssid, password);
        }

        function doConnect(ssid, password) {
            const btn = document.getElementById('connectBtn');
            btn.disabled = true;
            btn.innerHTML = '<div class="spinner"></div> Connecting...';
            showStatus('info', 'Connecting to ' + ssid + '... This may take up to 30 seconds.');

            fetch('/api/connect', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ ssid: ssid, password: password })
            })
            .then(r => r.json())
            .then(data => {
                if (data.success) {
                    showStatus('success', data.message + '<br><br>This portal will now close.');
                    btn.innerHTML = '✓ Connected!';
                } else {
                    showStatus('error', data.message + '<br><br>Please check the password and try again.');
                    btn.disabled = false;
                    btn.innerHTML = 'Connect';
                }
            })
            .catch(() => {
                showStatus('info', 'Connection in progress... If the portal disappears, your device has connected successfully!');
                setTimeout(() => { btn.disabled = false; btn.innerHTML = 'Connect'; }, 10000);
            });
        }

        function showStatus(type, msg) {
            const el = document.getElementById('statusMsg');
            el.className = 'status-msg ' + type;
            el.innerHTML = msg;
            el.style.display = 'block';
        }

        function togglePassword() {
            const input = document.getElementById('wifiPassword');
            const btn = input.parentNode.querySelector('.toggle-pass');
            input.type = input.type === 'password' ? 'text' : 'password';
            btn.textContent = input.type === 'password' ? 'Show' : 'Hide';
        }

        function toggleManualPassword() {
            const input = document.getElementById('manualPassword');
            const btn = input.parentNode.querySelector('.toggle-pass');
            input.type = input.type === 'password' ? 'text' : 'password';
            btn.textContent = input.type === 'password' ? 'Show' : 'Hide';
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }
    </script>
</body>
</html>
"""


# ─── Routes ─────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template_string(PORTAL_HTML)


# Captive portal detection endpoints — return 302 to trigger "Sign in" popup
@app.route("/generate_204")               # Android
@app.route("/gen_204")                     # Android alt
@app.route("/ncsi.txt")                    # Windows
@app.route("/connecttest.txt")             # Windows 10+
@app.route("/redirect")                    # Windows
@app.route("/hotspot-detect.html")         # Apple iOS/macOS
@app.route("/library/test/success.html")   # Apple alt
@app.route("/success.txt")                 # Firefox
@app.route("/canonical.html")              # Ubuntu
@app.route("/check_network_status.txt")    # Various
def captive_portal_detect():
    return redirect(f"http://{AP_IP}:{PORTAL_PORT}/", code=302)


@app.route("/api/scan")
def api_scan():
    networks = scan_networks()
    return jsonify({"networks": networks})


@app.route("/api/connect", methods=["POST"])
def api_connect():
    data = request.get_json()
    ssid = data.get("ssid", "").strip()
    password = data.get("password", "").strip()

    if not ssid:
        return jsonify({"success": False, "message": "No network name provided."})

    result = {"success": False, "message": ""}

    def do_connect():
        s, m = connect_to_network(ssid, password)
        result["success"] = s
        result["message"] = m

    t = threading.Thread(target=do_connect)
    t.start()
    t.join(timeout=35)

    return jsonify(result)


@app.route("/api/status")
def api_status():
    try:
        with open(STATUS_FILE, "r") as f:
            status = f.read().strip()
    except Exception:
        status = "unknown"
    return jsonify({"status": status})


# Catch-all: redirect everything to portal
@app.route("/<path:path>")
def catch_all(path):
    return redirect(f"http://{AP_IP}:{PORTAL_PORT}/", code=302)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORTAL_PORT, debug=False)
