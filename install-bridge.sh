#!/usr/bin/env bash
# Install the Hermes Agent Widget Bridge as a systemd user service.
#
# Run this script from a reviewed clone of the widget repository.
# It installs bridge.py from that checkout and sets up a
# systemd --user service so it starts automatically and survives reboots.
# The bridge reads ~/.hermes/state.db and ~/.hermes/config.yaml directly
# and serves usage data on port 8643.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$HOME/.local/share/hermes-agent-widget-bridge"
CONFIG_DIR="$HOME/.config/hermes-agent-widget-bridge"
STATE_DIR="$HOME/.local/state/hermes-agent-widget"
ENV_FILE="$CONFIG_DIR/env"
SERVICE_NAME="hermes-agent-widget-bridge.service"

# Pre-marketplace names are read only to migrate existing installations.
LEGACY_CONFIG_DIR="$HOME/.config/echo-bridge"
LEGACY_STATE_DIR="$HOME/.local/state/echo-model"
LEGACY_ENV_FILE="$LEGACY_CONFIG_DIR/env"
LEGACY_SERVICE="$HOME/.config/systemd/user/echo-bridge.service"

echo "==> Creating bridge directory: $BRIDGE_DIR"
install -d -m 0755 "$BRIDGE_DIR"
install -m 0644 "$SOURCE_DIR/bridge.py" "$BRIDGE_DIR/bridge.py"

echo "==> Creating authenticated Remote-mode configuration..."
install -d -m 0700 "$CONFIG_DIR"
TOKEN_VALUE=""
if [ -f "$ENV_FILE" ]; then
  TOKEN_VALUE="$(sed -n -e 's/^HERMES_WIDGET_TOKEN=//p' -e '/^HERMES_WIDGET_TOKEN=/q' "$ENV_FILE")"
fi
if [ -z "$TOKEN_VALUE" ] && [ -f "$LEGACY_ENV_FILE" ]; then
  TOKEN_VALUE="$(sed -n -e 's/^ECHO_USAGE_TOKEN=//p' -e '/^ECHO_USAGE_TOKEN=/q' "$LEGACY_ENV_FILE")"
fi
if [ -z "$TOKEN_VALUE" ]; then
  umask 077
  TOKEN_VALUE="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
fi
if ! grep -q '^HERMES_WIDGET_TOKEN=.' "$ENV_FILE" 2>/dev/null; then
  printf 'HERMES_WIDGET_HOST=0.0.0.0\nHERMES_WIDGET_PORT=8643\nHERMES_WIDGET_TOKEN=%s\n' \
    "$TOKEN_VALUE" > "$ENV_FILE"
fi
chmod 0600 "$ENV_FILE"
PORT_VALUE="$(sed -n -e 's/^HERMES_WIDGET_PORT=//p' -e '/^HERMES_WIDGET_PORT=/q' "$ENV_FILE")"
PORT_VALUE="${PORT_VALUE:-8643}"

echo "==> Creating state directory for the bridge..."
install -d -m 0700 "$STATE_DIR"
if [ -d "$LEGACY_STATE_DIR" ]; then
  cp -an "$LEGACY_STATE_DIR/." "$STATE_DIR/"
fi

echo "==> Setting up systemd user service..."
SERVICE_DIR="$HOME/.config/systemd/user"
mkdir -p "$SERVICE_DIR"

systemctl --user disable --now echo-bridge.service 2>/dev/null || true
rm -f "$LEGACY_SERVICE"

cat > "$SERVICE_DIR/$SERVICE_NAME" << 'SYSTEMD'
[Unit]
Description=Hermes Agent Widget Bridge
After=network.target
Documentation=https://github.com/r3pc0n/hermes-agent-widget

[Service]
Type=simple
EnvironmentFile=%h/.config/hermes-agent-widget-bridge/env
ExecStart=/usr/bin/env python3 %h/.local/share/hermes-agent-widget-bridge/bridge.py
Restart=on-failure
RestartSec=5
# Soft limit; bridge will run on any port, no strong isolation needed
ProtectSystem=strict
ReadWritePaths=%h/.local/state/hermes-agent-widget
ReadOnlyPaths=-%h/.hermes/state.db -%h/.hermes/config.yaml -%h/.hermes/.env
NoNewPrivileges=true

[Install]
WantedBy=default.target
SYSTEMD
chmod 0644 "$SERVICE_DIR/$SERVICE_NAME"

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

echo "==> Waiting for bridge to start..."
sleep 2
if systemctl --user is-active --quiet "$SERVICE_NAME"; then
  echo ""
  echo "  ✓ Bridge installed and running on port $PORT_VALUE"
  echo ""
  echo "  Next step: configure the Hermes Agent Widget to use Remote mode"
  echo "  and enter this server's IP/domain plus the access token below:"
  echo ""
  echo "    http://<this-server-ip>:$PORT_VALUE"
  echo "    $TOKEN_VALUE"
  echo ""
  echo "  Keep this token private. The bridge is intended for a trusted LAN or VPN."
else
  echo "  ⚠ Bridge service failed to start. Run to debug:"
  echo "    systemctl --user status $SERVICE_NAME"
  echo "    journalctl --user -u $SERVICE_NAME --no-pager -n 30"
fi
