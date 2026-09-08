#!/system/bin/sh

DATADIR="/data/adb/yuki_bootanim_installer"
BACKUPDIR="$DATADIR/backup"
CONF="$DATADIR/device.conf"
LOG="$DATADIR/uninstall.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG" 2>/dev/null
}

log "=== Uninstall started ==="

if [ ! -d "$BACKUPDIR" ]; then
  log "No backup folder, nothing to restore."
  exit 0
fi

SYSTEM_MEDIA="/system/media"
STATE="$DATADIR/state.conf"
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  SYSTEM_MEDIA="${SYSTEM_MEDIA:-/system/media}"
fi
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
  # LAST_APPLIED_SYSTEM_MEDIA is the actual candidate apply.sh resolved and
  # wrote to for the most recent install — more trustworthy than the static
  # device.conf value now that multiple ROM_MEDIA_CANDIDATES exist.
  SYSTEM_MEDIA="${LAST_APPLIED_SYSTEM_MEDIA:-$SYSTEM_MEDIA}"
fi

# Check if there is anything to restore before bothering to remount.
RESTORE_NEEDED=false
for f in "$BACKUPDIR"/*.orig "$BACKUPDIR"/*.none; do
  [ -e "$f" ] && RESTORE_NEEDED=true
done

if [ "$RESTORE_NEEDED" != "true" ]; then
  log "There is no backup file to restore (probably only ever installed via the overlay path)."
  exit 0
fi

mount -o rw,remount /system 2>/dev/null
mount -o rw,remount / 2>/dev/null

resolve_backup_target() {
  # $1 = full path to the .orig or .none file
  _bak_file="$1"
  _dir=$(dirname "$_bak_file")
  _base=$(basename "$_bak_file")
  case "$_base" in
    *.none) _id=${_base%.none}; _sidecar="$_dir/$_id.none.path" ;;
    *.orig) _id=${_base%.orig}; _sidecar="$_dir/$_id.path" ;;
    *) _id="$_base"; _sidecar="" ;;
  esac

  if [ -n "$_sidecar" ] && [ -f "$_sidecar" ]; then
    cat "$_sidecar" 2>/dev/null
    return 0
  fi

  case "$_id" in
    _*)
      printf '%s' "$_id" | tr '_' '/'
      ;;
    *)
      printf '%s/%s' "$SYSTEM_MEDIA" "$_id"
      ;;
  esac
}

for bak in "$BACKUPDIR"/*.orig; do
  [ -e "$bak" ] || continue
  target=$(resolve_backup_target "$bak")
  if cp -f "$bak" "$target" 2>/dev/null; then
    chmod 0644 "$target" 2>/dev/null
    chcon u:object_r:system_file:s0 "$target" 2>/dev/null
    log "Successfully restored $target from backup"
  else
    log "FAILED to restore $target — possibly /system is still read-only"
  fi
done

for marker in "$BACKUPDIR"/*.none; do
  [ -e "$marker" ] || continue
  target=$(resolve_backup_target "$marker")
  if [ -f "$target" ]; then
    rm -f "$target" 2>/dev/null
    log "Successfully removed $target (originally this file did not exist before the module was installed)"
  fi
done

mount -o ro,remount /system 2>/dev/null

log "=== Uninstall done ==="