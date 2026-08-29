#!/usr/bin/env bash
# Install / re-install the Hermes Agent bar widget from this checkout.
# Most users should use `omarchy plugin add`; this is a development/manual
# fallback and is idempotent after local edits.
set -euo pipefail

PLUGIN_ID="io.github.r3pc0n.hermes-agent-widget"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "== Hermes Agent Widget installer =="
echo "  source: $SRC_DIR"
echo "  dest:   $DEST"

for required in manifest.json Widget.qml bridge.py assets; do
  [[ -e "$SRC_DIR/$required" ]] || {
    echo "missing required plugin file: $SRC_DIR/$required" >&2
    exit 1
  }
done

# Validate the checkout before replacing the installed copy.
if command -v omarchy >/dev/null 2>&1; then
  echo "== validating manifest"
  omarchy plugin validate "$SRC_DIR"
fi

if [[ "$SRC_DIR" != "$DEST" ]]; then
  mkdir -p "$DEST/assets"
  install -m 0644 \
    "$SRC_DIR/manifest.json" \
    "$SRC_DIR/Widget.qml" \
    "$SRC_DIR/bridge.py" \
    "$DEST/"
  cp -R "$SRC_DIR/assets/." "$DEST/assets/"
fi

# Load the copied QML. A plugin rescan discovers new plugins but does not
# re-execute an already-loaded widget, so updates need a shell restart.
if command -v omarchy >/dev/null 2>&1; then
  echo "== restarting shell to load plugin code"
  omarchy restart shell
else
  echo "== rescanning shell plugins"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

# Add the widget to the right section of the bar.
if omarchy plugin list --json 2>/dev/null | grep -q "\"$PLUGIN_ID\""; then
  echo "== enabling bar widget"
  omarchy plugin enable "$PLUGIN_ID" --section right >/dev/null
else
  echo "!! plugin not discovered — check for QML errors above" >&2
  exit 1
fi

# Report.
echo
echo "done. The bar should now show the Hermes icon in the right section."
echo "Verify:"
echo "  omarchy plugin list --json | grep $PLUGIN_ID"
echo "  grep -A2 hermes-agent-widget ~/.config/omarchy/shell.json"
echo
echo "If the icon is missing, reload with: omarchy restart shell"
echo "Remove with: omarchy plugin remove $PLUGIN_ID"
