#!/system/bin/sh
# app-update.sh — раз в сутки проверяет релиз приложения на GitHub и ставит новее под root.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
STAMP=$MODDIR/.app_upd_stamp
LOG=$MODDIR/provision.log
log() { echo "$(date '+%m-%d %H:%M:%S') app-update: $*" >> "$LOG"; }

# throttle 24ч
now=$(date +%s)
last=$(cat "$STAMP" 2>/dev/null || echo 0)
[ $((now - last)) -lt 86400 ] && exit 0

have() { command -v "$1" >/dev/null 2>&1; }
have curl || exit 0

inst=$(dumpsys package $PKG 2>/dev/null | grep -m1 versionName | sed 's/.*versionName=//; s/ .*//')
[ -z "$inst" ] && exit 0

json=$(curl -sL --max-time 30 https://api.github.com/repos/davnozdu/autoresponder-app/releases/latest)
tag=$(echo "$json" | grep -o '"tag_name"[^,]*' | head -1 | sed 's/.*"tag_name"[^"]*"//; s/".*//; s/^v//')
url=$(echo "$json" | grep -o '"browser_download_url"[^,]*\.apk"' | head -1 | sed 's/.*"browser_download_url"[^"]*"//; s/".*//')
[ -z "$tag" ] && exit 0
echo "$now" > "$STAMP"

# Сравнение версий без `sort -V`: в toybox/busybox на телефоне его может не быть, и раньше
# пустой результат означал «up-to-date» — обновление молча не ставилось никогда.
# major.minor.patch -> одно число (major*10000 + minor*100 + patch).
num() { n=$(echo "$1" | tr -cd '0-9' | sed 's/^0*//'); echo "${n:-0}"; }
vcode() {
  v=$(echo "$1" | sed 's/^[vV]//')
  echo $(( $(num "$(echo "$v" | cut -d. -f1)") * 10000 \
         + $(num "$(echo "$v" | cut -d. -f2)") * 100 \
         + $(num "$(echo "$v" | cut -d. -f3)") ))
}
new_code=$(vcode "$tag"); cur_code=$(vcode "$inst")
if [ "$new_code" -le "$cur_code" ]; then
  log "up-to-date (inst=$inst/$cur_code, latest=$tag/$new_code)"; exit 0
fi
[ -z "$url" ] && { log "no apk asset"; exit 0; }

log "update $inst -> $tag, downloading"
curl -sL --max-time 120 -o /data/local/tmp/ar_upd.apk "$url" || { log "download failed"; exit 0; }
out=$(pm install -r -d /data/local/tmp/ar_upd.apk 2>&1)
if echo "$out" | grep -qi Success; then
  cp /data/local/tmp/ar_upd.apk "$MODDIR/AutoResponder.apk"
  echo "$tag" | tr -dc '0-9' > "$MODDIR/apk.versionCode"
  log "installed $tag"
else
  log "install failed: $out"
fi
rm -f /data/local/tmp/ar_upd.apk
