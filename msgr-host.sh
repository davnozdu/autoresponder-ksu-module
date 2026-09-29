#!/system/bin/sh
# Arm the VoIP audio policy under uid 2000 before any messenger call starts.
# The Java host blocks on a Unix socket when idle; no polling or microphone track.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
LOG="$MODDIR/msgr-host.log"

while :; do
  apk=$(pm path "$PKG" 2>/dev/null | head -n 1)
  apk=${apk#package:}
  uid=$(stat -c %u "/data/data/$PKG" 2>/dev/null)
  case "$uid" in ''|*[!0-9]*) sleep 5; continue ;; esac
  if [ -r "$apk" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') starting shell host appUid=$uid apk=$apk" >> "$LOG"
    su 2000 -c "CLASSPATH=$apk app_process /system/bin com.davnozdu.autoresponder.msgrec.MsgrShellHost $uid" >> "$LOG" 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S') shell host exited; restarting" >> "$LOG"
  fi
  sleep 5
done
