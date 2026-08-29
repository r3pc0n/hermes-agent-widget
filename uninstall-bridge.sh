#!/usr/bin/env bash
# Remove the optional Remote-mode Hermes Usage Bridge service and its files.
set -euo pipefail

systemctl --user disable --now hermes-agent-widget-bridge.service 2>/dev/null || true
systemctl --user disable --now echo-bridge.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/hermes-agent-widget-bridge.service"
rm -f "$HOME/.config/systemd/user/echo-bridge.service"
systemctl --user daemon-reload

rm -rf "$HOME/.local/share/hermes-agent-widget-bridge"
rm -rf "$HOME/.local/state/hermes-agent-widget"
rm -rf "$HOME/.config/hermes-agent-widget-bridge"

# Also remove paths used by pre-marketplace builds.
rm -rf "$HOME/.local/share/echo-bridge"
rm -rf "$HOME/.local/state/echo-model"
rm -rf "$HOME/.config/echo-bridge"

echo "Hermes Usage Bridge removed."
