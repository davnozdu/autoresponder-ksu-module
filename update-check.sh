#!/system/bin/sh
# update-check.sh — self-update: сверяет versionCode с update.json на GitHub,
# при новой версии скачивает zip и ставит через менеджер модулей.
MODDIR=${0%/*}
UPDATE_JSON_URL="https://raw.githubusercontent.com/davnozdu/autoresponder-ksu-module/main/update.json"
TMP=/data/local/tmp/autoresp_update

have() { command -v "$1" >/dev/null 2>&1; }
dl() { # dl <url> <out>
  if have curl; then curl -Ls --max-time 60 -o "$2" "$1"; 
  elif have wget; then wget -q -T 60 -O "$2" "$1"; 
  else return 1; fi
}

cur=$(grep '^versionCode=' "$MODDIR/module.prop" | cut -d= -f2)
mkdir -p "$TMP"
dl "$UPDATE_JSON_URL" "$TMP/update.json" || { echo "update: no network"; exit 0; }

new=$(grep -o '"versionCode"[^,]*' "$TMP/update.json" | grep -o '[0-9]\+' | head -1)
url=$(grep -o '"zipUrl"[^,]*' "$TMP/update.json" | sed 's/.*"zipUrl"[^"]*"//; s/".*//')
[ -z "$new" ] && exit 0
if [ "$new" -le "$cur" ] 2>/dev/null; then echo "update: up-to-date ($cur)"; exit 0; fi

echo "update: $cur -> $new, downloading $url"
dl "$url" "$TMP/module.zip" || { echo "update: download failed"; exit 0; }

# Установка модуля: KernelSU (ksud) или Magisk
if have ksud; then ksud module install "$TMP/module.zip" && echo "update: installed via ksud (reboot needed)";
elif have magisk; then magisk --install-module "$TMP/module.zip" && echo "update: installed via magisk (reboot needed)";
else echo "update: no module manager cli found"; fi
rm -f "$TMP/module.zip"
