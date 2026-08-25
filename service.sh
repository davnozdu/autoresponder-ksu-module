#!/system/bin/sh
# service.sh — выполняется в late_start service на каждой загрузке.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
LOG="$MODDIR/provision.log"
NLS_COMPONENT="$PKG/$PKG.notif.NotifListenerService"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Ждём полной загрузки
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 10
: > "$LOG"; log "provision start"

app_installed() { pm path "$PKG" >/dev/null 2>&1; }

# 1) Установка/обновление bundled APK при необходимости
APK="$MODDIR/AutoResponder.apk"
if [ -f "$APK" ]; then
  need_install=1
  if app_installed; then
    inst=$(dumpsys package "$PKG" | grep -m1 versionCode | grep -o 'versionCode=[0-9]*' | cut -d= -f2)
    bund=$(cat "$MODDIR/apk.versionCode" 2>/dev/null)
    [ -n "$inst" ] && [ -n "$bund" ] && [ "$bund" -le "$inst" ] 2>/dev/null && need_install=0
  fi
  if [ "$need_install" = "1" ]; then
    log "installing/updating bundled apk"
    pm install -r -g "$APK" >> "$LOG" 2>&1
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

  # 3) Роль call screening (на устройстве роль была пустой)
  cmd role add-role-holder android.app.role.CALL_SCREENING "$PKG" >> "$LOG" 2>&1 && log "role CALL_SCREENING -> $PKG"

  # 4) Доступ к уведомлениям (WhatsApp/Telegram/RCS)
  cur=$(settings get secure enabled_notification_listeners 2>/dev/null)
  case "$cur" in
    *"$NLS_COMPONENT"*) log "notif listener already enabled" ;;
    null|"") settings put secure enabled_notification_listeners "$NLS_COMPONENT"; log "notif listener set (was empty)" ;;
    *) settings put secure enabled_notification_listeners "$cur:$NLS_COMPONENT"; log "notif listener appended" ;;
  esac
  cmd notification allow_listener "$NLS_COMPONENT" >> "$LOG" 2>&1

  # 5) Doze whitelist + фон
  dumpsys deviceidle whitelist +"$PKG" >> "$LOG" 2>&1 && log "doze whitelist +"
  cmd appops set "$PKG" RUN_IN_BACKGROUND allow >> "$LOG" 2>&1
  cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND allow >> "$LOG" 2>&1
  # ColorOS/OxygenOS автозапуск
  cmd appops set "$PKG" AUTO_START allow >> "$LOG" 2>&1
  log "provisioning done"
fi

# 6) Self-update модуля (в фоне, чтобы не задерживать загрузку)
(sh "$MODDIR/update-check.sh" >> "$LOG" 2>&1) &
