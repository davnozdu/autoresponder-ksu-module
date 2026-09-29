#!/system/bin/sh
# Arm the VoIP audio policy under uid 2000 before any messenger call starts.
# The Java host blocks on a Unix socket when idle; no polling or microphone track.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
LOG="$MODDIR/msgr-host.log"
LOG_MAX=262144   # keep the log bounded (~256 KiB); crash loops must not fill the module partition

# A short-lived exit means the host is failing to start (missing priv-app perms, no APK, …);
# back off up to 60 s so a broken state does not spin the CPU or flood the log.
backoff=5

while :; do
  # Rotate: once over the cap, keep only the tail so recent failures stay visible.
  if [ -f "$LOG" ]; then
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$LOG_MAX" ]; then tail -c 65536 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
  fi

  apk=$(pm path "$PKG" 2>/dev/null | head -n 1)
  apk=${apk#package:}
  uid=$(stat -c %u "/data/data/$PKG" 2>/dev/null)
  case "$uid" in ''|*[!0-9]*) sleep 5; continue ;; esac
  if [ -r "$apk" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') starting shell host appUid=$uid apk=$apk" >> "$LOG"
    start=$(date +%s)
    su 2000 -c "CLASSPATH=$apk app_process /system/bin com.davnozdu.autoresponder.msgrec.MsgrShellHost $uid" >> "$LOG" 2>&1
    ran=$(( $(date +%s) - start ))
    echo "$(date '+%Y-%m-%d %H:%M:%S') shell host exited after ${ran}s; restarting" >> "$LOG"
    # Ran a healthy while (idle-blocking on the socket) -> reset backoff; died fast -> grow it.
    if [ "$ran" -ge 30 ]; then backoff=5; else backoff=$(( backoff * 2 )); [ "$backoff" -gt 60 ] && backoff=60; fi
  fi
  sleep "$backoff"
done
