#!/bin/bash
# Stop and remove the mac-display LaunchDaemon, binary and command symlink.
# Pass --purge to also delete the config and logs.
set -euo pipefail

LABEL="local.mac-display"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
BIN_LINK="/usr/local/bin/mac-display"
CONF_DIR="/usr/local/etc/mac-display"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/mac-display"

sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo rm -f "$PLIST" "$HELPER"
# Only remove the command if it is our symlink.
if [[ -L "$BIN_LINK" && "$(readlink "$BIN_LINK")" == "$HELPER" ]]; then
    sudo rm -f "$BIN_LINK"
fi
echo "Removed $PLIST, $HELPER and $BIN_LINK"

if [[ "${1:-}" == "--purge" ]]; then
    sudo rm -f "$CONF_DIR/config.json" "$CONF_DIR/config.json.bak" /var/run/mac-display.pause
    sudo rmdir "$CONF_DIR" 2>/dev/null || true
    sudo rm -f "$LOG_DIR"/mac-display.log "$LOG_DIR"/mac-display.log.*
    sudo rmdir "$LOG_DIR" 2>/dev/null || true
    echo "Removed $CONF_DIR (config and backup) and the logs in $LOG_DIR"
else
    echo "Kept $CONF_DIR/config.json and $LOG_DIR (use --purge to delete them)"
fi
