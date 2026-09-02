#!/system/bin/sh
# data-backup.sh — копия данных приложения ПОД ROOT, рядом с модулем.
#
# Бэкап самого приложения лежит в /sdcard/AutoResponder/backups и переживает
# переустановку, но не переживает сброс телефона и чистку раздела: вместе с ним
# исчезает вся история переписки, то есть контекст, которым живёт LLM. Здесь копия
# хранится в /data, куда пользователь не заглядывает, и восстанавливается сама
# при первой установке на чистое приложение.
MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
DATA=/data/data/$PKG
DST=$MODDIR/backup
STAMP=$MODDIR/.data_bk_stamp
LOG=$MODDIR/provision.log
log() { echo "$(date '+%m-%d %H:%M:%S') data-backup: $*" >> "$LOG"; }

[ -d "$DATA" ] || exit 0

case "$1" in
restore)
  # Восстанавливаем ТОЛЬКО в пустое приложение: перетереть свежую базу старой копией
  # хуже, чем не восстановить ничего.
  [ -f "$DST/history.db" ] || exit 0
  [ -f "$DATA/databases/history.db" ] && exit 0
  mkdir -p "$DATA/databases" "$DATA/shared_prefs"
  cp -f "$DST/history.db" "$DATA/databases/history.db" 2>/dev/null
  # WAL и SHM не копируем: они относятся к прошлой сессии SQLite и с чужой базой
  # только мешают — SQLite восстановит их сам.
  for f in "$DST"/prefs_*.xml; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DATA/shared_prefs/$(basename "$f" | sed 's/^prefs_//')" 2>/dev/null
  done
  # Владелец и SELinux-контекст: файлы созданы root'ом, приложение их иначе не откроет
  # (и упадёт при старте с EACCES).
  uid=$(stat -c %u "$DATA" 2>/dev/null)
  [ -n "$uid" ] && chown -R "$uid:$uid" "$DATA/databases" "$DATA/shared_prefs" 2>/dev/null
  restorecon -R "$DATA" 2>/dev/null
  log "restored history.db + prefs into fresh install"
  ;;
*)
  # throttle 24ч — база небольшая, но писать её каждые 15 минут незачем
  now=$(date +%s)
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  [ $((now - last)) -lt 86400 ] && exit 0
  [ -f "$DATA/databases/history.db" ] || exit 0
  mkdir -p "$DST"
  # Копию делаем через sqlite3, если он есть: простой cp во время записи даёт
  # обрезанный файл, а WAL остаётся в стороне и часть истории теряется.
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DATA/databases/history.db" ".backup '$DST/history.db.tmp'" 2>/dev/null \
      && mv -f "$DST/history.db.tmp" "$DST/history.db" \
      || cp -f "$DATA/databases/history.db" "$DST/history.db" 2>/dev/null
  else
    cp -f "$DATA/databases/history.db" "$DST/history.db" 2>/dev/null
  fi
  for f in "$DATA"/shared_prefs/*.xml; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DST/prefs_$(basename "$f")" 2>/dev/null
  done
  chmod 600 "$DST"/* 2>/dev/null
  echo "$now" > "$STAMP"
  log "backup ok ($(du -k "$DST/history.db" 2>/dev/null | cut -f1) KB)"
  ;;
esac
