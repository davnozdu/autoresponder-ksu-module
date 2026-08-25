#!/system/bin/sh
# service.sh — выполняется в late_start service на каждой загрузке.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
LOG="$MODDIR/provision.log"
NLS_COMPONENT="$PKG/$PKG.notif.NotifListenerService"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Ждём полной загрузки
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
: > "$LOG"; log "boot completed"

# Ждём готовности PackageManager (иначе pm install падает Failed transaction)
i=0
until pm path android >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -ge 60 ] && { log "pm not ready after 3min"; break; }
  sleep 3
done
log "package service ready (after ${i}x3s)"
sleep 3

app_installed() { pm path "$PKG" >/dev/null 2>&1; }

# 1) Установка/обновление bundled APK с ретраями
APK="$MODDIR/AutoResponder.apk"
if [ -f "$APK" ]; then
  need_install=1
  if app_installed; then
    inst=$(dumpsys package "$PKG" | grep -m1 versionCode | grep -o 'versionCode=[0-9]*' | cut -d= -f2)
    bund=$(cat "$MODDIR/apk.versionCode" 2>/dev/null)
    [ -n "$inst" ] && [ -n "$bund" ] && [ "$bund" -le "$inst" ] 2>/dev/null && need_install=0
  fi
  if [ "$need_install" = "1" ]; then
    n=0
    until app_installed && [ "$need_install" = "0" ]; do
      n=$((n+1)); [ "$n" -gt 10 ] && { log "apk install failed after 10 tries"; break; }
      out=$(pm install -r -g "$APK" 2>&1)
      if echo "$out" | grep -qi Success; then log "apk installed (try $n)"; need_install=0; break; fi
      log "apk install try $n: $out"
      sleep 6
    done
  else
    log "apk up-to-date"
  fi
fi

if ! app_installed; then
  log "app not installed, skip provisioning"
else
  # 2) Runtime-разрешения без диалогов
  for p in \
    android.permission.RECEIVE_SMS \
    android.permission.SEND_SMS \
    android.permission.READ_SMS \
    android.permission.READ_PHONE_STATE \
    android.permission.READ_CALL_LOG \
    android.permission.READ_CONTACTS \
    android.permission.POST_NOTIFICATIONS \
    android.permission.READ_PHONE_NUMBERS ; do
    pm grant "$PKG" "$p" >> "$LOG" 2>&1 && log "granted $p"
  done

  # 3) Роль call screening
  cmd role add-role-holder android.app.role.CALL_SCREENING "$PKG" >> "$LOG" 2>&1 && log "role CALL_SCREENING -> $PKG"

  # 4) Доступ к уведомлениям (для v2: WhatsApp/Telegram/RCS)
  cur=$(settings get secure enabled_notification_listeners 2>/dev/null)
  case "$cur" in
    *"$NLS_COMPONENT"*) log "notif listener already enabled" ;;
    null|"") settings put secure enabled_notification_listeners "$NLS_COMPONENT"; log "notif listener set" ;;
    *) settings put secure enabled_notification_listeners "$cur:$NLS_COMPONENT"; log "notif listener appended" ;;
  esac
  cmd notification allow_listener "$NLS_COMPONENT" >> "$LOG" 2>&1

  # 5) Doze whitelist + фон
  dumpsys deviceidle whitelist +"$PKG" >> "$LOG" 2>&1 && log "doze whitelist +"
  cmd appops set "$PKG" RUN_IN_BACKGROUND allow >> "$LOG" 2>&1
  cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND allow >> "$LOG" 2>&1
  cmd appops set "$PKG" AUTO_START allow >> "$LOG" 2>&1
  log "provisioning done"
fi

# 6) Self-update модуля в фоне
(sh "$MODDIR/update-check.sh" >> "$LOG" 2>&1) &
