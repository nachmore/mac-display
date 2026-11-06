#!/bin/bash
# Build mac-display and install it as a LaunchDaemon (starts at boot, before anyone logs in).
# Run as your normal user; the install steps use sudo.
set -euo pipefail

LABEL="local.mac-display"
# The daemon runs as root, so its executable lives in a root-only directory. The
# /usr/local/bin entry is just a symlink for running the CLI.
HELPER="/Library/PrivilegedHelperTools/$LABEL"
BIN_DIR="/usr/local/bin"
BIN_LINK="$BIN_DIR/mac-display"
CONF_DIR="/usr/local/etc/mac-display"
CONF="$CONF_DIR/config.json"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/mac-display"
LOG="$LOG_DIR/mac-display.log"

cd "$(dirname "$0")"

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user (not with sudo); it asks for sudo when needed." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "mac-display needs an Apple silicon Mac." >&2
    exit 1
fi

echo "==> Building"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/mac-display"

if [[ -f "$CONF" ]]; then
    echo "==> Validating existing config"
    "$BIN" check-config --config "$CONF"
fi

echo "==> Installing (sudo)"
# Only create directories that don't exist; never re-own existing ones (e.g. a
# Homebrew-managed /usr/local/bin).
for d in /Library/PrivilegedHelperTools "$CONF_DIR" "$LOG_DIR"; do
    [[ -d "$d" ]] || sudo install -d -o root -g wheel -m 755 "$d"
done
[[ -d "$BIN_DIR" ]] || sudo mkdir -p "$BIN_DIR"
sudo install -o root -g wheel -m 755 "$BIN" "$HELPER"
sudo ln -sfn "$HELPER" "$BIN_LINK"
NEW_CONFIG=0
if [[ -f "$CONF" ]]; then
    echo "    keeping existing $CONF"
else
    TMP_CONF="$(mktemp)"
    "$BIN" default-config > "$TMP_CONF"
    sudo install -o root -g wheel -m 644 "$TMP_CONF" "$CONF"
    rm -f "$TMP_CONF"
    NEW_CONFIG=1
    echo "    created $CONF (no displays configured yet)"
fi
sudo install -o root -g wheel -m 644 "launchd/$LABEL.plist" "$PLIST"

echo "==> (Re)starting the daemon"
if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
    sudo launchctl bootout "system/$LABEL" || true
    for _ in $(seq 1 50); do
        sudo launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 0.1
    done
    if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
        echo "The previous instance is still unloading; wait a few seconds and re-run ./install.sh." >&2
        exit 1
    fi
fi
sudo launchctl enable "system/$LABEL"
if ! sudo launchctl bootstrap system "$PLIST"; then
    cat >&2 <<EOF
Could not start $LABEL. If "local.mac-display" is switched off in
System Settings > General > Login Items & Extensions (Allow in the Background), switch it
on and re-run ./install.sh. Details: sudo launchctl print system/$LABEL
EOF
    exit 1
fi
sleep 3

if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
    RUN="mac-display"
else
    RUN="$BIN_LINK"
fi

echo
echo "mac-display installed."
echo "    command: $BIN_LINK  (-> $HELPER)"
if [[ "$RUN" != "mac-display" ]]; then
    echo "             $BIN_DIR is not on your PATH; add it to type plain \"mac-display\""
fi
cat <<EOF
    daemon:  $PLIST
    config:  $CONF   (edit with sudo; changes apply within a few seconds)
    log:     $LOG  (self-rotating, ~4 MB max)

Try:
    $RUN setup             # pick a display, try modes live, save the one you want
    $RUN list              # displays, current mode, available modes
    $RUN status            # daemon health + what the config does to each display
    $RUN logs -f           # follow the daemon log
    $RUN help

EOF

if [[ $NEW_CONFIG == 1 ]]; then
    if [[ -t 0 && -t 1 ]]; then
        echo
        echo "==> No displays are configured yet; starting setup"
        "$HELPER" setup --config "$CONF" || true
    else
        echo
        echo "No displays are configured yet: run \`$RUN setup\`."
    fi
else
    echo
    echo "==> $RUN status"
    "$HELPER" status || true
fi
