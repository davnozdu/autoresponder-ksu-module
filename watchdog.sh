#!/system/bin/sh
# watchdog.sh — самовосстановление: ждёт готовности системных сервисов,
# доставляет недостающее (APK/роль/права/Doze/listener) и периодически перепроверяет.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
NLS="$PKG/$PKG.notif.NotifListenerService"
ROLE=android.app.role.CALL_SCREENING
APK="$MODDIR/AutoResponder.apk"
LOG="$MODDIR/watchdog.log"
INTERVAL=600   # период перепроверки, сек

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
trim() { tail -n 400 "$LOG" > "$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"; }

app_installed() { pm path "$PKG" >/dev/null 2>&1; }
svc_fail() { echo "$1" | grep -qi 'Failure\|Exception'; }

# Ждём готовности PackageManager и RoleManager (иначе Failed transaction)
wait_ready() {
  i=0
  while :; do
    pm path android >/dev/null 2>&1 && \
      ! svc_fail "$(cmd role get-role-holders $ROLE 2>&1)" && return 0
    i=$((i+1)); [ "$i" -ge 60 ] && { log "services not ready after 5min"; return 1; }
    sleep 5
  done
}

perm_granted() { dumpsys package "$PKG" 2>/dev/null | grep -A0 "$1: granted=true" | grep -q "$1"; }

assert_all() {
  local changed=0

  # 1) APK установлен?
  if ! app_installed; then
    if [ -f "$APK" ]; then
      out=$(pm install -r -g "$APK" 2>&1)
      echo "$out" | grep -qi Success && { log "recover: apk reinstalled"; changed=1; } \
        || log "recover: apk install failed: $out"
    fi
  fi
  app_installed || return 0

  # 2) Роль call screening
  holder=$(cmd role get-role-holders $ROLE 2>&1)
  case "$holder" in
    *"$PKG"*) : ;;
    *) if ! svc_fail "$holder"; then
         cmd role add-role-holder $ROLE "$PKG" 2>/dev/null && { log "recover: role re-added"; changed=1; }
       fi ;;
  esac

  # 3) Runtime-права (грантим только отозванные)
  for p in RECEIVE_SMS SEND_SMS READ_SMS READ_PHONE_STATE READ_CALL_LOG \
           READ_CONTACTS POST_NOTIFICATIONS READ_PHONE_NUMBERS WRITE_CALL_LOG; do
    full="android.permission.$p"
    if ! perm_granted "$full"; then
      pm grant "$PKG" "$full" 2>/dev/null && { log "recover: granted $p"; changed=1; }
    fi
  done

  # 4) Doze whitelist
  if ! dumpsys deviceidle whitelist 2>/dev/null | grep -q "$PKG"; then
    dumpsys deviceidle whitelist +"$PKG" >/dev/null 2>&1 && { log "recover: doze +"; changed=1; }
  fi

  # 5) Notification listener (для v2)
  # allow_listener сам пишет в enabled_notification_listeners; прямая правка
  # settings молча не закрепляется и заставляла watchdog «чинить» это каждый цикл.
  cur=$(settings get secure enabled_notification_listeners 2>/dev/null)
  case "$cur" in
    *"$NLS"*) : ;;
    *)
      if cmd notification allow_listener "$NLS" >/dev/null 2>&1; then
        log "recover: notification listener allowed"; changed=1
      else
        case "$cur" in
          null|"") settings put secure enabled_notification_listeners "$NLS" 2>/dev/null ;;
          *) settings put secure enabled_notification_listeners "$cur:$NLS" 2>/dev/null ;;
        esac
      fi ;;
  esac

  # 5b) Доступ к политике «Не беспокоить» (чтобы уважать приоритетных отправителей)
  cmd notification allow_dnd "$PKG" 2>/dev/null

  # 6) appops автозапуск/фон (идемпотентно, без шумного лога)
  cmd appops set "$PKG" RUN_IN_BACKGROUND allow 2>/dev/null
  cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND allow 2>/dev/null
  cmd appops set "$PKG" AUTO_START allow 2>/dev/null

  [ "$changed" = "1" ] && log "state changed -> re-asserted"
  return 0
}

: > "$LOG"; log "watchdog start (pid $$)"
wait_ready || true
assert_all
log "initial provisioning done"

while :; do
  sleep "$INTERVAL"
  assert_all
  trim
done
