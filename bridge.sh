#!/system/bin/sh
# bridge.sh — root-мост к базам мессенджеров.
#
# Приложение видит переписку WhatsApp и Telegram только через уведомления, а значит
# не видит ничего, что уведомления не показали: сообщения, которые владелец набрал
# сам в мессенджере, входящие при выключенном роботе, всё старше пяти минут. Из-за
# этого в контекст LLM уходил односторонний монолог клиента, и робот отвечал по
# кругу одно и то же.
#
# Настоящая переписка лежит в базах самих мессенджеров, но они под чужим uid и с
# правами 0600 — приложению их не открыть. Root есть у модуля, поэтому копирование
# делает он, а разбор схемы остаётся в приложении: схему WhatsApp и TL-блобы
# Telegram в shell не разобрать, а в Kotlin это тестируется.
#
# Протокол (весь внутри приватной папки приложения — на /sdcard переписка клиентов
# была бы видна любому приложению с доступом к хранилищу):
#   files/bridge/request   приложение трогает файл  -> просьба обновить копии
#   files/bridge/<db>      копии баз (db + -wal), chown и метка SELinux приложения
#   files/bridge/response  строка "<epoch> ok|partial|none <детали>"
#
# Ждём запрос через inotifyd — без опроса, то есть без расхода батареи. Плюс
# принудительный прогон по таймеру: если приложение убито, копии всё равно свежие.

MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
DIR=/data/data/$PKG/files/bridge
REQ=$DIR/request
RESP=$DIR/response
LOG="$MODDIR/bridge.log"

# Не чаще одного копирования в MIN_GAP секунд: приложение просит обновление перед
# каждым ответом, а клиент в переписке пишет очередями по несколько сообщений.
MIN_GAP=60
# Принудительный прогон, даже если никто не просил (приложение может быть убито).
FORCE_EVERY=1800

# Базы: <метка> <путь>. Метка = имя подпапки в bridge/ и канал в журнале.
DBS="whatsapp:/data/data/com.whatsapp.w4b/databases/msgstore.db
whatsapp2:/data/data/com.whatsapp/databases/msgstore.db
telegram:/data/data/org.telegram.messenger/files/cache4.db"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
trim() { tail -n 300 "$LOG" > "$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"; }

app_uid() {
  # stat приватной папки — единственный способ, не зависящий от формата dumpsys.
  stat -c %u "/data/data/$PKG/files" 2>/dev/null
}

# SELinux-метка приватной папки приложения. Метка несёт категории конкретного
# приложения (`...:s0:c27,c257,c512,c768`), и без них приложение не откроет даже
# собственный файл. restorecon эти категории не восстанавливает — он ставит
# политику по умолчанию, то есть голый s0, — поэтому копируем метку с папки.
# Читаем каждый раз: после переустановки приложения категории другие.
app_ctx() { ls -dZ "/data/data/$PKG/files" 2>/dev/null | awk '{print $1}'; }
relabel() {
  ctx=$(app_ctx)
  [ -n "$ctx" ] || return 0
  chcon -R "$ctx" "$@" 2>/dev/null
}

# Копия одной базы вместе с -wal. Без -wal копия неполна: свежие сообщения лежат
# именно там, а checkpoint мессенджер делает когда захочет.
#
# Порядок важен: сначала сама база, потом -wal. Если между копированиями мессенджер
# сделает checkpoint, в -wal окажутся кадры, уже применённые к базе, — это SQLite
# переживает. Обратный порядок дал бы -wal старее базы, то есть испорченную копию.
#
# -shm НЕ копируем и остаток от прошлого раза удаляем: это разделяемая память живой
# базы, к чужому снимку она не подходит, а SQLite соберёт её заново сам.
copy_db() {
  tag=$1; src=$2; uid=$3
  [ -f "$src" ] || return 1
  dst="$DIR/$tag"
  mkdir -p "$dst" || return 1
  base=$(basename "$src")
  rm -f "$dst/$base-shm" 2>/dev/null
  for ext in "" "-wal"; do
    [ -f "$src$ext" ] || continue
    cp -f "$src$ext" "$dst/$base$ext" 2>/dev/null || return 1
  done
  chown -R "$uid:$uid" "$dst" 2>/dev/null
  chmod -R 600 "$dst"/* 2>/dev/null
  chmod 700 "$dst" 2>/dev/null
  # Без метки приложения у копий остаётся контекст источника, и SELinux не даст
  # приложению открыть файл в собственной папке.
  relabel "$dst"
  return 0
}

sync_all() {
  uid=$(app_uid)
  if [ -z "$uid" ]; then log "нет uid приложения — пропуск"; return 1; fi
  ok=0; fail=0; names=""
  for entry in $DBS; do
    tag=${entry%%:*}; src=${entry#*:}
    # Мессенджера может просто не быть на телефоне (обычный WhatsApp против
    # WhatsApp Business) — это не сбой, а отсутствие источника.
    [ -f "$src" ] || continue
    if copy_db "$tag" "$src" "$uid"; then
      ok=$((ok+1)); names="$names $tag"
    else
      fail=$((fail+1)); log "не скопировалось: $tag ($src)"
    fi
  done
  if [ "$ok" = "0" ]; then status=none
  elif [ "$fail" = "0" ]; then status=ok
  else status=partial
  fi
  echo "$(date +%s) $status$names" > "$RESP"
  chown "$uid:$uid" "$RESP" 2>/dev/null; chmod 600 "$RESP" 2>/dev/null
  relabel "$RESP"
  log "sync $status:$names"
  return 0
}

# Отметка последнего копирования — в файле, а не в переменной: ветка inotifyd
# живёт в подоболочке, и присвоение в ней до остальных не доходит.
STAMP=$MODDIR/.bridge-stamp
# Пустой или испорченный файл отметки должен читаться как «никогда», иначе
# арифметика ниже падает и мост перестаёт копировать вовсе.
last_sync() {
  v=$(cat "$STAMP" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

handle() {
  now=$(date +%s)
  if [ $((now - $(last_sync))) -lt "$MIN_GAP" ]; then return 0; fi
  echo "$now" > "$STAMP"
  sync_all
  trim
}

# Папку и файл-запрос создаём сами: приложение могло ещё ни разу не запуститься,
# а inotifyd без существующего файла просто выходит.
prepare() {
  uid=$(app_uid)
  [ -n "$uid" ] || return 1
  mkdir -p "$DIR" || return 1
  chown "$uid:$uid" "$DIR"; chmod 700 "$DIR"
  [ -f "$REQ" ] || : > "$REQ"
  chown "$uid:$uid" "$REQ"; chmod 600 "$REQ"
  relabel "$DIR"
  return 0
}

# --- старт ---------------------------------------------------------------
: > "$LOG"; log "bridge start (pid $$)"

# Таймер в фоне — трогает request, чем будит ту же ветку, что и приложение.
# Нужен на случай, когда приложение убито: копии всё равно остаются свежими.
(
  while :; do
    sleep "$FORCE_EVERY"
    [ -f "$REQ" ] && touch "$REQ" 2>/dev/null
  done
) &

# Внешний цикл переживает переустановку приложения: при ней папка files пересоздаётся,
# inotifyd теряет inode и выходит — здесь мы просто заводим наблюдение заново.
while :; do
  if ! prepare; then
    log "приложение не установлено — ждём"
    sleep 60
    continue
  fi
  # Первый прогон сразу: после перезагрузки или переустановки контекст нужен
  # не через полчаса, а сейчас.
  handle
  # Маски: c — записан, e — тронут (touch), w — закрыт после записи.
  # inotifyd вызывается на каждое изменение request и не тратит батарею на опрос.
  inotifyd - "$REQ:cew" 2>/dev/null | while read -r _ev _rest; do
    handle
  done
  log "наблюдение прервано — перезапуск через 30с"
  sleep 30
done
