#!/system/bin/sh
# app-update.sh — раз в сутки проверяет релиз приложения на GitHub и ставит новее под root.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
NEXT=$MODDIR/.app_upd_next
LOG=$MODDIR/provision.log
LOCK=$MODDIR/.app-update-lock
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
log() { echo "$(date '+%m-%d %H:%M:%S') app-update: $*" >> "$LOG"; }

# Расписание попыток, как в update-check.sh: сутки после ясного результата, час после сбоя.
# Watchdog зовёт нас каждые INTERVAL (900с), и раньше любой отказ — непройденная проверка
# подписанта, неудачный pm install — оставался без отметки: APK тянулся заново каждые 15 минут.
now=$(date +%s)
next=$(cat "$NEXT" 2>/dev/null)
case "$next" in ''|*[!0-9]*) next=0 ;; esac
[ "$now" -lt "$next" ] && exit 0
echo $((now + 3600)) > "$NEXT"

have() { command -v "$1" >/dev/null 2>&1; }
have curl || exit 0

inst=$(dumpsys package $PKG 2>/dev/null | grep -m1 versionName | sed 's/.*versionName=//; s/ .*//')
[ -z "$inst" ] && exit 0

json=$(curl -fsSL --proto '=https' --max-time 30 https://api.github.com/repos/davnozdu/autoresponder-app/releases/latest)
tag=$(echo "$json" | grep -o '"tag_name"[^,]*' | head -1 | sed 's/.*"tag_name"[^"]*"//; s/".*//; s/^v//')
url=$(echo "$json" | grep -o '"browser_download_url"[^,]*\.apk"' | head -1 | sed 's/.*"browser_download_url"[^"]*"//; s/".*//')
[ -z "$tag" ] && exit 0


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
  echo $((now + 86400)) > "$NEXT"; log "up-to-date (inst=$inst/$cur_code, latest=$tag/$new_code)"; exit 0
fi
[ -z "$url" ] && { log "no apk asset"; exit 0; }

log "update $inst -> $tag, downloading"
# Качаем и проверяем в каталоге модуля (0700, root). Раньше и загрузка, и проверка шли в
# /data/local/tmp — каталоге, доступном на запись uid 2000, под которым работает msgr-host.sh.
# Между проверкой подписи и `pm install` файл можно было подменить, и установка пошла бы с
# правами root. Теперь в общий каталог попадает только уже проверенный файл, и его хэш
# сверяется ещё раз непосредственно перед установкой.
UPD=$MODDIR/.app-upd
rm -rf "$UPD" 2>/dev/null
mkdir -p "$UPD"
curl -fsSL --proto '=https' --max-time 120 -o "$UPD/ar.apk" "$url" || { log "download failed"; rm -rf "$UPD"; exit 0; }
installed_apk=$(pm path "$PKG" | sed -n 's/^package://p' | head -1)
if ! CLASSPATH="$installed_apk" app_process /system/bin com.davnozdu.autoresponder.update.ReleaseVerifier apk "$UPD/ar.apk"; then
  log "APK verification failed; not installed"
  rm -rf "$UPD"
  exit 0
fi
h1=$(sha256sum "$UPD/ar.apk" 2>/dev/null | cut -d' ' -f1)
cp "$installed_apk" "$MODDIR/previous.apk" || exit 0
cp -f "$UPD/ar.apk" /data/local/tmp/ar_upd.apk || { log "copy to tmp failed"; rm -rf "$UPD"; exit 0; }
h2=$(sha256sum /data/local/tmp/ar_upd.apk 2>/dev/null | cut -d' ' -f1)
if [ -z "$h1" ] || [ "$h1" != "$h2" ]; then
  log "APK изменился после проверки подписи — установка отменена"
  rm -f /data/local/tmp/ar_upd.apk
  rm -rf "$UPD"
  exit 0
fi
out=$(pm install -r /data/local/tmp/ar_upd.apk 2>&1)
if echo "$out" | grep -qi Success; then
  cp "$UPD/ar.apk" "$MODDIR/AutoResponder.apk"
  echo $((now + 86400)) > "$NEXT"
  log "installed verified $tag"
else
  log "install failed: $out"
fi
rm -f /data/local/tmp/ar_upd.apk
rm -rf "$UPD"
