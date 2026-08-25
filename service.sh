#!/system/bin/sh
# service.sh — late_start service, каждый boot.
# Логика провижининга и самовосстановления вынесена в watchdog.sh.
MODDIR=${0%/*}
LOG="$MODDIR/provision.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
: > "$LOG"; log "boot completed, launching watchdog"

# Супервизор: держит watchdog живым. Если процесс убьют — перезапуск через 60с.
# setsid отвязывает от service.sh, чтобы жил самостоятельно.
(
  while :; do
    setsid sh "$MODDIR/watchdog.sh"
    log "watchdog exited, restart in 60s"
    sleep 60
  done
) &

# Self-update модуля в фоне
( sh "$MODDIR/update-check.sh" >> "$LOG" 2>&1 ) &
