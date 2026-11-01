#!/system/bin/sh

MANAGER_LOCALE_READY=false

resolve_manager_locale() {
  _candidate="$1"
  [ -n "$_candidate" ] || return 1

  _clean_locale=$(printf '%s' "$_candidate" | tr '_' '-')
  _exact_locale=$(printf '%s' "$_clean_locale" | tr '[:upper:]' '[:lower:]')
  _locale_file="$_manager_module_dir/webroot/locales/manager-${_exact_locale}.sh"
  if [ -f "$_locale_file" ]; then
    MANAGER_LOCALE="$_exact_locale"
    return 0
  fi

  _short_locale=$(printf '%s' "$_clean_locale" | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')
  _locale_file="$_manager_module_dir/webroot/locales/manager-${_short_locale}.sh"
  if [ -f "$_locale_file" ]; then
    MANAGER_LOCALE="$_short_locale"
    return 0
  fi
  return 1
}

load_manager_locale() {
  _manager_module_dir="$1"
  MANAGER_LOCALE=""

  _system_locales=$(settings get system system_locales 2>/dev/null | cut -d',' -f1)
  resolve_manager_locale "$_system_locales" || :

  if [ -z "$MANAGER_LOCALE" ]; then
    resolve_manager_locale "$(getprop persist.sys.locale 2>/dev/null)" || :
  fi
  if [ -z "$MANAGER_LOCALE" ]; then
    resolve_manager_locale "$(getprop ro.product.locale 2>/dev/null)" || :
  fi
  if [ -z "$MANAGER_LOCALE" ]; then
    _config=$(cmd activity get-config 2>/dev/null | grep -m1 '^config:' | sed 's/^config:[[:space:]]*//' | cut -d',' -f1)
    _config_language=$(printf '%s' "$_config" | tr '-' '\n' | grep -m1 -E '^[a-zA-Z]{2,3}$' | tr '[:upper:]' '[:lower:]')
    _config_region=$(printf '%s' "$_config" | tr '-' '\n' | grep -m1 -E '^r[A-Z]{2}$' | cut -c2-)
    if [ -n "$_config_language" ]; then
      resolve_manager_locale "${_config_language}${_config_region:+-$_config_region}" || :
    fi
  fi

  if [ -z "$MANAGER_LOCALE" ]; then
    MANAGER_LOCALE="en"
  fi

  _locale_file="$_manager_module_dir/webroot/locales/manager-${MANAGER_LOCALE}.sh"
  if [ ! -f "$_locale_file" ]; then
    MANAGER_LOCALE_READY=false
    return 1
  fi
  # shellcheck disable=SC1090
  . "$_locale_file" || {
    MANAGER_LOCALE_READY=false
    return 1
  }
  MANAGER_LOCALE_READY=true
}

update_module_desc() {
  _ok="$1"
  _detail="$2"
  _module_dir="$3"
  [ "$MANAGER_LOCALE_READY" = "true" ] || return 1
  [ -f "$_module_dir/module.prop" ] || return 1

  if [ "$_ok" = "true" ]; then
    _status="[✅ ${MANAGER_STATUS_WORKING}] ${MANAGER_STATUS_PATH}: ${_detail}"
  else
    _status="[❌ ${MANAGER_STATUS_FAILED}: ${_detail}] ${MANAGER_DEFAULT_DESC}"
  fi

  _status_escaped=$(printf '%s' "$_status" | sed 's/[\\&|]/\\&/g') || return 1
  if ! sed "s|^description=.*|description=${_status_escaped}|" "$_module_dir/module.prop" > "$_module_dir/module.prop.tmp" 2>/dev/null; then
    rm -f "$_module_dir/module.prop.tmp" 2>/dev/null
    return 1
  fi
  if ! cat "$_module_dir/module.prop.tmp" > "$_module_dir/module.prop" 2>/dev/null; then
    rm -f "$_module_dir/module.prop.tmp" 2>/dev/null
    return 1
  fi
  rm -f "$_module_dir/module.prop.tmp" 2>/dev/null
}
