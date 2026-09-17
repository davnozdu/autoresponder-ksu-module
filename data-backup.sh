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
  apk=$(pm path "$PKG" | sed -n 's/^package://p' | head -1)
  CLASSPATH="$apk" app_process /system/bin com.davnozdu.autoresponder.update.ReleaseVerifier database "$DST/history.db" || exit 1
  cp -f "$DST/history.db" "$DATA/databases/history.db" 2>/dev/null || exit 1
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
  ctx=$(ls -dZ "$DATA" 2>/dev/null | awk '{print $1}')
  [ -n "$ctx" ] && chcon -R "$ctx" "$DATA/databases" "$DATA/shared_prefs" 2>/dev/null
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
    if ! sqlite3 "$DATA/databases/history.db" ".backup '$DST/history.db.tmp'" 2>/dev/null; then
      rm -f "$DST/history.db.tmp" 2>/dev/null
      log "backup skipped: sqlite3 snapshot failed"
      exit 0
    fi
  else
    # Обычный cp живой SQLite может сохранить смесь старых и новых страниц.
    # Если приложение уже сделало собственную согласованную копию на общем
    # хранилище, берём только файл старше минуты; иначе оставляем последнюю
    # корректную root-копию и ждём следующего цикла.
    latest=$(ls -1t /sdcard/AutoResponder/backups/history-*.db 2>/dev/null | head -1)
    if [ -n "$latest" ] && [ -f "$latest" ]; then
      age=$((now - $(stat -c %Y "$latest" 2>/dev/null || echo 0)))
      if [ "$age" -ge 60 ]; then
        cp -f "$latest" "$DST/history.db.tmp" 2>/dev/null || exit 0
        log "backup ok (copied stable app snapshot, sqlite3 unavailable)"
      else
        log "backup skipped: newest app snapshot is still being written"
        exit 0
      fi
    else
      log "backup skipped: sqlite3 unavailable and no app snapshot"
      exit 0
    fi
  fi
  apk=$(pm path "$PKG" | sed -n 's/^package://p' | head -1)
  if ! CLASSPATH="$apk" app_process /system/bin com.davnozdu.autoresponder.update.ReleaseVerifier database "$DST/history.db.tmp"; then
    rm -f "$DST/history.db.tmp"
    log "backup skipped: snapshot validation failed"
    exit 0
  fi
  mv -f "$DST/history.db.tmp" "$DST/history.db" || exit 0
  for f in "$DATA"/shared_prefs/*.xml; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DST/prefs_$(basename "$f")" 2>/dev/null
  done
  chmod 600 "$DST"/* 2>/dev/null
  echo "$now" > "$STAMP"
  log "backup ok ($(du -k "$DST/history.db" 2>/dev/null | cut -f1) KB)"
  ;;
esac
