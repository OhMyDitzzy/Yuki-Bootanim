#!/system/bin/sh

MODDIR=${0%/*}
DATADIR="/data/adb/yuki_bootanim_installer"
BACKUPDIR="$DATADIR/backup"
STAGING="$DATADIR/staging"
CONF="$DATADIR/device.conf"
LOG="$DATADIR/apply.log"
PROPFILE="$MODDIR/module.prop"
DEFAULT_DESC="Install custom boot animations (.zip / Samsung .qmg) via WebUI. Supports KernelSU, KernelSU Next, APatch, and Magisk. Automatically selects remount method (Android 9-) or overlay via metamodule (Android 10+)."

update_module_desc() {
  _ok="$1"
  _detail="$2"
  [ -f "$PROPFILE" ] || return 0

  if [ "$_ok" = "true" ]; then
    _status="[✅ Working] Path: ${_detail}"
  else
    _status="[❌ Failed: ${_detail}] ${DEFAULT_DESC}"
  fi

  # Escape characters that would otherwise break the sed replacement (sed
  # delimiter, & backreference, and any literal backslash in the path).
  _status_escaped=$(printf '%s' "$_status" | sed 's/[&/\]/\\&/g')

  if sed "s|^description=.*|description=${_status_escaped}|" "$PROPFILE" > "$PROPFILE.tmp" 2>/dev/null; then
    cat "$PROPFILE.tmp" > "$PROPFILE" 2>/dev/null
  fi
  rm -f "$PROPFILE.tmp" 2>/dev/null
}

emit() {
  # emit ok stage message [extra_json_fields]
  _ok="$1"; _stage="$2"; _msg="$3"; _extra="$4"
  _msg_escaped=$(printf '%s' "$_msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')

  if [ -n "$DESC_DETAIL" ]; then
    update_module_desc "$_ok" "$DESC_DETAIL"
  fi

  if [ -n "$_extra" ]; then
    printf '{"ok":%s,"stage":"%s","message":"%s",%s}\n' "$_ok" "$_stage" "$_msg_escaped" "$_extra"
  else
    printf '{"ok":%s,"stage":"%s","message":"%s"}\n' "$_ok" "$_stage" "$_msg_escaped"
  fi
  exit 0
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG" 2>/dev/null
}

mkdir -p "$DATADIR" "$BACKUPDIR" "$STAGING" 2>/dev/null

sanitize_id() {
  # Keep upload IDs to a safe filename character set so they can't be used
  # to escape STAGING via ../ or similar.
  printf '%s' "$1" | tr -cd 'a-zA-Z0-9_-'
}

CMD="$1"

case "$CMD" in
  chunk)
    UPLOAD_ID=$(sanitize_id "$2")
    CHUNK_INDEX="$3"
    CHUNK_DATA="$4"

    if [ -z "$UPLOAD_ID" ]; then
      emit false "transfer" "Invalid upload_id."
    fi
    if [ -z "$CHUNK_DATA" ]; then
      emit false "transfer" "Empty chunk (index $CHUNK_INDEX) was received."
    fi

    B64_FILE="$STAGING/$UPLOAD_ID.b64"

    # Chunk 0 starts a fresh file so a retried upload never appends onto
    # leftovers from a previous failed attempt with the same id.
    if [ "$CHUNK_INDEX" = "0" ]; then
      : > "$B64_FILE" 2>/dev/null
    fi

    if ! printf '%s' "$CHUNK_DATA" >> "$B64_FILE" 2>/dev/null; then
      emit false "transfer" "Failed to write chunk $CHUNK_INDEX to staging."
    fi

    emit true "transfer" "Chunk $CHUNK_INDEX received." "\"upload_id\":\"$UPLOAD_ID\""
    ;;

  abort)
    UPLOAD_ID=$(sanitize_id "$2")
    [ -n "$UPLOAD_ID" ] && rm -f "$STAGING/$UPLOAD_ID.b64" 2>/dev/null
    emit true "transfer" "Upload cancelled."
    ;;

  finish)
    UPLOAD_ID=$(sanitize_id "$2")
    ORIG_NAME="$3"
    B64_FILE="$STAGING/$UPLOAD_ID.b64"

    if [ -z "$UPLOAD_ID" ] || [ ! -f "$B64_FILE" ]; then
      emit false "transfer" "No chunks were found for this upload — the file may need to be re-selected."
    fi
    if [ ! -s "$B64_FILE" ]; then
      rm -f "$B64_FILE" 2>/dev/null
      emit false "transfer" "The assembled data is empty (0 bytes)."
    fi

    # Preserve the extension from the name the user actually picked so the
    # .zip vs .qmg checks below still see the right thing.
    case "$ORIG_NAME" in
      *.*) DECODED_EXT=$(printf '%s' "$ORIG_NAME" | sed -n 's/.*\.\([a-zA-Z0-9]*\)$/\1/p' | tr '[:upper:]' '[:lower:]') ;;
      *) DECODED_EXT="" ;;
    esac
    [ -z "$DECODED_EXT" ] && DECODED_EXT="zip"

    SRC="$STAGING/$UPLOAD_ID.$DECODED_EXT"

    if ! base64 -d "$B64_FILE" > "$SRC" 2>/dev/null; then
      # Some minimal toybox/busybox base64 builds don't support -d; try the
      # BusyBox-style flag as a fallback before giving up.
      if ! base64 -dc "$B64_FILE" > "$SRC" 2>/dev/null; then
        rm -f "$B64_FILE" "$SRC" 2>/dev/null
        emit false "transfer" "Failed to decode the assembled file (base64 decode error)."
      fi
    fi

    rm -f "$B64_FILE" 2>/dev/null

    if [ ! -s "$SRC" ]; then
      rm -f "$SRC" 2>/dev/null
      emit false "transfer" "Decoding produced an empty file — the upload is likely corrupt, try again."
    fi

    log "Chunk upload $UPLOAD_ID assembled -> $SRC (from $ORIG_NAME)"
    ;;

  chunk|abort|finish)
    # Unreachable: handled by the matching arm above. Kept only so the
    # fallthrough default below is unambiguous about what it covers.
    ;;

  *)
    SRC="$1"
    ;;
esac

log "=== apply.sh proceeding to install with SRC=$SRC ==="

if [ -z "$SRC" ]; then
  emit false "validate" "No files were given."
fi

if [ ! -f "$SRC" ]; then
  emit false "validate" "Staging file not found: $SRC"
fi

if [ ! -s "$SRC" ]; then
  emit false "validate" "The selected file is empty (0 bytes)."
fi

if [ ! -f "$CONF" ]; then
  emit false "validate" "device.conf not found. Reboot after module installation to allow device detection to work."
fi

# shellcheck disable=SC1090
. "$CONF"

if [ -z "$API" ]; then
  emit false "validate" "device.conf corrupt: API level unreadable"
fi

FILENAME=$(basename "$SRC")
EXT=$(printf '%s' "$FILENAME" | sed -n 's/.*\.\([a-zA-Z0-9]*\)$/\1/p' | tr '[:upper:]' '[:lower:]')

if [ "$EXT" != "zip" ] && [ "$EXT" != "qmg" ]; then
  emit false "validate" "The .$EXT extension is not supported. Use a .zip or .qmg file."
fi

if [ "$IS_SAMSUNG" = "true" ] && [ "$EXT" = "zip" ]; then
  emit false "samsung_guard" "This device is detected by Samsung (One UI). .zip files are NOT supported and may cause the boot animation to not appear or the device to loop during boot. Use a .qmg file instead.."
fi

if [ "$IS_SAMSUNG" != "true" ] && [ "$EXT" = "qmg" ]; then
  emit false "samsung_guard" "This device is not a Samsung. The .qmg format is specific to Samsung One UI and will not be read by the standard boot animation system. Use the .zip file."
fi

if [ "$EXT" = "zip" ]; then
  if ! unzip -l "$SRC" >/dev/null 2>&1; then
    emit false "validate" "The .zip file is corrupted or not a valid ZIP file."
  fi
  if ! unzip -l "$SRC" 2>/dev/null | grep -qi 'desc\.txt'; then
    emit false "validate" "The .zip file does not contain desc.txt — this is not a valid bootanimation.zip structure."
  fi
fi

# /oem/media is a current, first-class AOSP boot-animation search path
# (frameworks/base cmds/bootanimation/BootAnimation.cpp, findBootAnimationFile())
# that was missing from this list entirely.
ROM_MEDIA_CANDIDATES="${ROM_MEDIA_CANDIDATES:-/product/media /product/etc/media /oem/media /system/media /system/product/media}"

candidate_has_existing_bootanim() {
  # True if this candidate directory already ships a boot animation file —
  # the clearest sign the running ROM actually reads from here.
  [ -f "$1/bootanimation.zip" ] && return 0
  [ -f "$1/bootsamsung.qmg" ] && return 0
  [ -f "$1/bootsamsungloop.qmg" ] && return 0
  return 1
}

# Sets RESOLVED_SYSTEM_MEDIA and MEDIA_MATCH_TYPE as a side effect. Called
# directly (not via $()) — command substitution runs in a subshell on every
# /system/bin/sh Android ships (mksh, toybox sh, busybox ash), so a second
# output variable set inside $() would not survive outside of it.
resolve_system_media() {
  _chosen=""
  _first_existing_dir=""
  MEDIA_MATCH_TYPE="hardcoded_fallback"

  for _cand in $ROM_MEDIA_CANDIDATES; do
    if [ -d "$_cand" ]; then
      [ -z "$_first_existing_dir" ] && _first_existing_dir="$_cand"
      if candidate_has_existing_bootanim "$_cand"; then
        log "Candidate $_cand already has an existing boot animation file — using it."
        _chosen="$_cand"
        MEDIA_MATCH_TYPE="existing_bootanim"
        break
      fi
    fi
  done

  if [ -z "$_chosen" ] && [ -n "$_first_existing_dir" ]; then
    log "No candidate has an existing boot animation file; falling back to first existing directory: $_first_existing_dir"
    _chosen="$_first_existing_dir"
    MEDIA_MATCH_TYPE="existing_dir_fallback"
  fi
  
  if [ -z "$_chosen" ]; then
    _chosen="${SYSTEM_MEDIA:-/system/media}"
    log "None of the ROM_MEDIA_CANDIDATES exist as directories yet; falling back to $_chosen"
    MEDIA_MATCH_TYPE="hardcoded_fallback"
  fi

  RESOLVED_SYSTEM_MEDIA="$_chosen"
}

resolve_system_media
SYSTEM_MEDIA="$RESOLVED_SYSTEM_MEDIA"
REMOUNTED_BY_US=false
USE_OVERLAY=false

do_remount_rw() {
  # Try remounting /system to RW, then VERIFY that it is truly writable
  # (Don't assume success just because the mount command doesn't error out) —
  # On many devices with AVB/dm-verity enabled, the physical block device remains
  #RO even though the mount command "succeeds" without an error message.
  mount -o rw,remount /system 2>/dev/null
  mount -o rw,remount / 2>/dev/null

  _testfile="$1/.bootanim_installer_writetest"
  if ! mkdir -p "$1" 2>/dev/null; then
    return 1
  fi
  if echo test > "$_testfile" 2>/dev/null; then
    rm -f "$_testfile" 2>/dev/null
    return 0
  fi
  return 1
}

if do_remount_rw "$SYSTEM_MEDIA"; then
  REMOUNTED_BY_US=true
  log "Direct-write successfully verified to $SYSTEM_MEDIA (API $API)"
else
  log "Direct-write failed to $SYSTEM_MEDIA (API $API). Trying overlay module path as fallback."
  if [ "$API" -lt 29 ]; then
    # Android 9 shouldn't need an overlay at all; if even remounting RW fails here, it's likely that dm-verity hasn't been fully disabled in the root setup of this device.
    DESC_DETAIL="dm-verity/AVB still active"
    emit false "remount_failed" "Failed to remount /system to writable. It's possible that dm-verity is still enabled on this device even though it's rooted. Ensure the root process correctly disabled verity, then reboot and try again."
  fi

  # Android 10+ without direct-write works: use overlay path.
  if [ "$ROOT_MGR" = "ksu" ] && [ "$HAS_METAMODULE" != "true" ]; then
    DESC_DETAIL="no metamodule installed"
    emit false "no_metamodule" "Direct remount to /system fails (likely dm-verity/AVB is still active) and KernelSU delegates the installation of the /system module to a third-party metamodule. — Nothing detected is installed. Install the metamodule first. Hybrid-Mount is recommended (more modern, supports KernelSU & APatch), or Mountify is an alternative, If you are using Magisk, You can try use Magisk OverlayFS module. Once installed and rebooted, try installing the boot animation again." "\"suggest_metamodules\":[\"Hybrid-Mount\",\"Mountify\"]"
  fi

  USE_OVERLAY=true
  DEVICE_MEDIA_PATH="$SYSTEM_MEDIA"
  TARGET_BASE="$MODDIR$SYSTEM_MEDIA"
  mkdir -p "$TARGET_BASE" 2>/dev/null
  SYSTEM_MEDIA="$TARGET_BASE"
  log "Writing via overlay module path: $SYSTEM_MEDIA (new results are active after reboot)"
fi

mkdir -p "$SYSTEM_MEDIA" 2>/dev/null

backup_key_for() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  else
    # Fallback for the rare toolbox without md5sum: still deterministic and
    # collision-safe enough for a handful of well-known candidate paths.
    printf '%s' "$1" | busybox md5sum 2>/dev/null | cut -d' ' -f1
  fi
}

backup_if_needed() {
  [ "$USE_OVERLAY" = "true" ] && return 0
  _target="$1"
  _id=$(backup_key_for "$_target")
  _bak="$BACKUPDIR/$_id.orig"
  _pathfile="$BACKUPDIR/$_id.path"
  if [ -f "$_target" ] && [ ! -f "$_bak" ] && [ ! -f "$_bak.none" ]; then
    if cp -f "$_target" "$_bak" 2>/dev/null; then
      printf '%s' "$_target" > "$_pathfile" 2>/dev/null
      log "Backup created: $_bak (from $_target)"
    fi
  elif [ ! -f "$_target" ] && [ ! -f "$_bak" ] && [ ! -f "$_bak.none" ]; then
    # Mark that this file doesn't actually exist, so the uninstaller knows
    # must DELETE (not restore) the file.
    touch "$_bak.none" 2>/dev/null
    printf '%s' "$_target" > "$BACKUPDIR/$_id.none.path" 2>/dev/null
  fi
}

if [ "$EXT" = "zip" ]; then
  DEST="$SYSTEM_MEDIA/bootanimation.zip"
  backup_if_needed "$DEST"
  if ! cp -f "$SRC" "$DEST" 2>/dev/null; then
    [ "$REMOUNTED_BY_US" = "true" ] && mount -o ro,remount /system 2>/dev/null
    DESC_DETAIL="copy to $DEST failed"
    emit false "commit" "Failed to copy file to $DEST"
  fi
  chmod 0644 "$DEST" 2>/dev/null
  chcon u:object_r:system_file:s0 "$DEST" 2>/dev/null
  log "bootanimation.zip successfully installed to $DEST"
  RESULT_PATH="$DEST"
else
  # .qmg — Samsung. Official One UI convention: bootsamsung.qmg plays once,
  # bootsamsungloop.qmg plays repeatedly until boot completes. We commit
  # user-selected file as LOOP (most commonly customized) and
  # leave the "one-play" file, if any, as is, UNLESS
  # the user explicitly marks it as a non-loop version with the suffix
  # filename "_boot" (E.g: mymotion_boot.qmg -> bootsamsung.qmg).
  case "$FILENAME" in
    *_boot.[qQ][mM][gG]|*[Bb]ootup*.[qQ][mM][gG])
      DEST="$SYSTEM_MEDIA/bootsamsung.qmg"
      ;;
    *)
      DEST="$SYSTEM_MEDIA/bootsamsungloop.qmg"
      ;;
  esac
  backup_if_needed "$DEST"
  if ! cp -f "$SRC" "$DEST" 2>/dev/null; then
    [ "$REMOUNTED_BY_US" = "true" ] && mount -o ro,remount /system 2>/dev/null
    DESC_DETAIL="copy to $DEST failed"
    emit false "commit" "Failed to copy file to $DEST"
  fi
  chmod 0644 "$DEST" 2>/dev/null
  chcon u:object_r:system_file:s0 "$DEST" 2>/dev/null
  log "$FILENAME successfully installed as $(basename "$DEST")"
  RESULT_PATH="$DEST"
fi

# Remount RO again if we're remounting RW (direct-write path only,
# A9- or A10+ fallback without metamodule). The metamodule path is NOT necessary.
if [ "$REMOUNTED_BY_US" = "true" ]; then
  mount -o ro,remount /system 2>/dev/null
  log "Remount /system back to RO"
fi

{
  echo "LAST_APPLIED_FILE=\"$FILENAME\""
  echo "LAST_APPLIED_DEST=\"$RESULT_PATH\""
  echo "LAST_APPLIED_TIME=\"$(date '+%Y-%m-%d %H:%M:%S')\""
  echo "LAST_APPLIED_SYSTEM_MEDIA=\"$SYSTEM_MEDIA\""
  echo "LAST_APPLIED_USE_OVERLAY=\"$USE_OVERLAY\""
} > "$DATADIR/state.conf" 2>/dev/null

rm -f "$SRC" 2>/dev/null

# DEVICE_MEDIA_PATH is only set on the overlay branch; on the direct-write
# branch SYSTEM_MEDIA was never overwritten, so it's already the real
# on-device path and doubles as the fallback here.
DISPLAY_MEDIA_PATH="${DEVICE_MEDIA_PATH:-$SYSTEM_MEDIA}"

case "$MEDIA_MATCH_TYPE" in
  existing_bootanim)
    PATH_CONFIRMED=true
    MATCH_WARNING=""
    CONFIDENCE_TAG=""
    ;;
  existing_dir_fallback)
    PATH_CONFIRMED=false
    MATCH_WARNING=" WARNING: no existing boot animation was found under ${DISPLAY_MEDIA_PATH} before this install, so this path is a guess, not a confirmed match. If the animation doesn't change after reboot, this ROM likely reads its boot animation from a path this module doesn't know about yet."
    CONFIDENCE_TAG=", unconfirmed path"
    ;;
  *)
    PATH_CONFIRMED=false
    MATCH_WARNING=" WARNING: none of this module's known candidate paths exist yet on this device, so ${DISPLAY_MEDIA_PATH} is a hardcoded guess. If the animation doesn't change after reboot, this ROM likely stores its boot animation somewhere this module doesn't know about."
    CONFIDENCE_TAG=", unconfirmed path"
    ;;
esac

if [ "$USE_OVERLAY" = "true" ]; then
  DESC_DETAIL="${DISPLAY_MEDIA_PATH} (Overlay${CONFIDENCE_TAG})"
  emit true "done" "The file is stored as $(basename "$RESULT_PATH") via the overlay module path. This only becomes active after REBOOT — direct remounting to /system is not available on this device.${MATCH_WARNING}" "\"installed_as\":\"$(basename "$RESULT_PATH")\",\"reboot_required\":true,\"via_overlay\":true,\"media_match_type\":\"$MEDIA_MATCH_TYPE\",\"path_confirmed\":$PATH_CONFIRMED"
else
  DESC_DETAIL="${DISPLAY_MEDIA_PATH} (Direct-write${CONFIDENCE_TAG})"
  emit true "done" "Successfully installed as $(basename "$RESULT_PATH"). Reboot to see the new boot animation.${MATCH_WARNING}" "\"installed_as\":\"$(basename "$RESULT_PATH")\",\"reboot_required\":true,\"via_overlay\":false,\"media_match_type\":\"$MEDIA_MATCH_TYPE\",\"path_confirmed\":$PATH_CONFIRMED"
fi