#!/usr/bin/env bash
# install-bridge.sh — Install the Echo Usage Bridge as a systemd user service
#
# Usage:
#   bash <(curl -s https://raw.githubusercontent.com/r3pc0n/hermes-agent-widget/main/install-bridge.sh)
#
# This installs bridge.py from the echo.model widget repo and sets up a
# systemd --user service so it starts automatically and survives reboots.
# The bridge reads ~/.hermes/state.db and ~/.hermes/config.yaml directly
# and serves usage data on port 8643.

set -euo pipefail

REPO="https://github.com/r3pc0n/hermes-agent-widget.git"
BRIDGE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/echo-bridge"

echo "==> Creating bridge directory: $BRIDGE_DIR"
mkdir -p "$BRIDGE_DIR"

echo "==> Cloning widget repo..."
if [ -d "$BRIDGE_DIR/.git" ]; then
  cd "$BRIDGE_DIR" && git pull --ff-only origin main
else
  git clone --depth 1 "$REPO" "$BRIDGE_DIR"
  cd "$BRIDGE_DIR"
fi

echo "==> Creating state directory for the bridge..."
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/echo-model"

echo "==> Setting up systemd user service..."
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_DIR/echo-bridge.service" << 'SYSTEMD'
[Unit]
Description=Echo Usage Bridge — serves Hermes usage data on port 8643
After=network.target
Documentation=https://github.com/r3pc0n/hermes-agent-widget

[Service]
Type=simple
ExecStart=/usr/bin/env python3 %h/.local/share/echo-bridge/bridge.py
Restart=on-failure
RestartSec=5
# Soft limit; bridge will run on any port, no strong isolation needed
ProtectSystem=strict
ReadWritePaths=%h/.local/state/echo-model
ReadOnlyPaths=%h/.hermes/state.db %h/.hermes/config.yaml %h/.hermes/.env
NoNewPrivileges=true

[Install]
WantedBy=default.target
SYSTEMD

systemctl --user daemon-reload
systemctl --user enable --now echo-bridge.service

echo "==> Waiting for bridge to start..."
sleep 2
if systemctl --user is-active --quiet echo-bridge.service; then
  echo ""
  echo "  ✓ Bridge installed and running on port 8643"
  echo ""
  echo "  Next step: configure the echo.model Omarchy widget to use Remote mode"
  echo "  and enter this server's IP/domain as the bridge URL, e.g.:"
  echo ""
  echo "    http://<this-server-ip>:8643"
  echo ""
else
  echo "  ⚠ Bridge service failed to start. Run to debug:"
  echo "    systemctl --user status echo-bridge.service"
  echo "    journalctl --user -u echo-bridge.service --no-pager -n 30"
fi
