#!/system/bin/sh
# Signed module updates; retry after network failures, never install unverifiable ZIPs.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
LOCK=$MODDIR/.module-update-lock
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
now=$(date +%s)
next=$(cat "$MODDIR/.module-update-next" 2>/dev/null)
case "$next" in ''|*[!0-9]*) next=0 ;; esac
[ "$now" -lt "$next" ] && exit 0
echo $((now + 3600)) > "$MODDIR/.module-update-next"
TMP=$MODDIR/.update-tmp
mkdir -p "$TMP"
status() { echo "$*" > "$MODDIR/update-status"; echo "update: $*"; }
dl() { curl -fLsS --proto '=https' --max-time 120 -o "$2" "$1"; }
URL=https://raw.githubusercontent.com/davnozdu/autoresponder-ksu-module/main/update.json
dl "$URL" "$TMP/update.json" || { status "Нет сети; повтор через час"; exit 0; }
cur=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop")
new=$(grep -o '"versionCode"[^,]*' "$TMP/update.json" | grep -o '[0-9][0-9]*' | head -1)
url=$(grep -o '"zipUrl"[^,]*' "$TMP/update.json" | sed 's/.*"zipUrl"[^"]*"//; s/".*//')
case "$new" in ''|*[!0-9]*) status "Неверный манифест"; exit 0 ;; esac
if [ "$new" -le "$cur" ]; then
  echo $((now + 86400)) > "$MODDIR/.module-update-next"
  status "Модуль актуален ($cur)"; exit 0
fi
case "$url" in https://github.com/davnozdu/autoresponder-ksu-module/releases/download/*/autoresponder-ksu-module.zip) : ;; *) status "Недоверенный URL"; exit 0 ;; esac
dl "$url" "$TMP/module.zip" && dl "$url.sig" "$TMP/module.zip.sig" || { status "Не удалось скачать обновление"; exit 0; }
APK=$(pm path "$PKG" | sed -n 's/^package://p' | head -1)
if [ -z "$APK" ] || ! CLASSPATH="$APK" app_process /system/bin com.davnozdu.autoresponder.update.ReleaseVerifier module "$TMP/module.zip" "$TMP/module.zip.sig" "$MODDIR/update-public.der"; then
  status "Подпись не подтверждена; установка отменена (нужен APK 0.15+)"; exit 0
fi
# Preserve last installed package for explicit recovery; no unsafe automatic DB downgrade.
if command -v ksud >/dev/null 2>&1; then
  ksud module install "$TMP/module.zip" || { status "Ошибка установки"; exit 0; }
elif command -v magisk >/dev/null 2>&1; then
  magisk --install-module "$TMP/module.zip" || { status "Ошибка установки"; exit 0; }
else status "Нет установщика модулей"; exit 0; fi
status "Подписанное обновление $new установлено; требуется перезагрузка"
echo $((now + 86400)) > "$MODDIR/.module-update-next"
rm -f "$TMP/module.zip" "$TMP/module.zip.sig"
