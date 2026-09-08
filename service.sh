#!/system/bin/sh

MODDIR=${0%/*}
DATADIR="/data/adb/yuki_bootanim_installer"
CONF="$DATADIR/device.conf"
LOG="$DATADIR/service.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG" 2>/dev/null
}

# Wait until /data is completely ready to be read/written (usually at late_start).
[ -d /data/adb ] || exit 0

[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"

log "=== Boot check ==="
log "ROOT_MGR=$ROOT_MGR API=$API IS_SAMSUNG=$IS_SAMSUNG"

CURRENT_HAS_METAMODULE=false
CURRENT_METAMODULE_NAME=""
if [ -e "/data/adb/metamodule" ]; then
  CURRENT_HAS_METAMODULE=true
  CURRENT_METAMODULE_NAME=$(basename "$(readlink -f /data/adb/metamodule 2>/dev/null)" 2>/dev/null)
fi

if [ "$CURRENT_HAS_METAMODULE" != "$HAS_METAMODULE" ] || [ "$CURRENT_METAMODULE_NAME" != "$METAMODULE_NAME" ]; then
  log "Metamodule status changed since last detection: was=$HAS_METAMODULE/$METAMODULE_NAME now=$CURRENT_HAS_METAMODULE/$CURRENT_METAMODULE_NAME"
  # Rewrite device.conf with the new HAS_METAMODULE & METAMODULE_NAME values
  # without touching any other lines.
  TMP_CONF="$DATADIR/.device.conf.tmp"
  {
    grep -v '^HAS_METAMODULE=' "$CONF" | grep -v '^METAMODULE_NAME='
    echo "HAS_METAMODULE=$CURRENT_HAS_METAMODULE"
    echo "METAMODULE_NAME=$CURRENT_METAMODULE_NAME"
  } > "$TMP_CONF" 2>/dev/null
  if [ -s "$TMP_CONF" ]; then
    mv -f "$TMP_CONF" "$CONF" 2>/dev/null
    chmod 0644 "$CONF" 2>/dev/null
  fi
fi

if [ -f "$DATADIR/state.conf" ]; then
  # shellcheck disable=SC1090
  . "$DATADIR/state.conf" 2>/dev/null
  log "Last installed: $LAST_APPLIED_FILE -> $LAST_APPLIED_DEST on $LAST_APPLIED_TIME"
  if [ -n "$LAST_APPLIED_DEST" ] && [ -f "$LAST_APPLIED_DEST" ]; then
    log "Verification: the destination file still exists in $LAST_APPLIED_DEST"
  elif [ -n "$LAST_APPLIED_DEST" ]; then
    log "WARNING: destination file $LAST_APPLIED_DEST was not found (perhaps the overlay is not mounted or was overwritten by a system update)"
  fi
fi

log "=== Boot check done ==="