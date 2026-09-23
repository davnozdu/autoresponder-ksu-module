#!/system/bin/sh
# answermachine.sh — root-демон голосового автоответчика.
#
# Проигрывает приветствие в ИСХОДЯЩИЙ канал активного вызова (incall-music,
# PAL_STREAM_VOICE_CALL_MUSIC) нативным `bin/pal_inject`. На этом AIDL-AHAL
# (libaudiocorehal.qti.so) incall-music выбирается ТОЛЬКО нативным output-флагом —
# из Java/AudioTrack его не запросить (проверено), поэтому нужен отдельный бинарь и root.
#
# Всё остальное (авто-ответ, мьют микрофона, громкость, отбой, копирование записи)
# делает само приложение своими правами — здесь только то, что требует root.
#
# Протокол (app-private, /data/data/$PKG/files/am/), одна команда на запись в req:
#   play <wav_abspath> <loops>   проиграть приветствие в линию
#   stop                          снять текущее проигрывание
#   muteout on|off                mixer-mute выходного RX-устройства (fallback; см. ниже)
#   screenoff                     выключить экран, если сейчас включён (input keyevent 26) —
#                                 обычному приложению недоступно, только через root
#   blockon <app_pid>             железно: подсветка в 0 + тачскрин выключен на уровне ядра
#   redim                         повторно погасить подсветку (см. комментарий у blockon)
#   blockoff                      вернуть подсветку и тач как было
# Ответ пишем в resp: "<epoch> ok|err <detail>" (chown+chcon под приложение, чтобы читалось).
#
# SELinux в enforcing НЕ мешает этому пути (проверено на устройстве): запись pal_stream_write
# блокировалась только при ручном тестировании через `adb shell` — PAL-сервис (hal_audio_default)
# получал в наследство файловый дескриптор сокета adbd (stdout интерактивной сессии) и получал
# на него avc denied. У демона, запущенного из service.sh (родитель — init, вывод в файл, без
# adb в предках), такого дескриптора нет — путь чист. sepolicy.rule оставлен пустым намеренно.
#
# ВАЖНО про расположение бинаря: запуск НАПРЯМУЮ из папки модуля (/data/adb/modules/...,
# файлы там помечены KernelSU как system_file) НЕ РАБОТАЕТ — линкер отказывается открыть
# /vendor/lib64/libpalclient.so: "not accessible for the namespace (default)". Дело не в
# SELinux-метке файла (chcon не помогает) и не в правах — linkerconfig выбирает пространство
# имён по ПУТИ, и /data/local/tmp/ — единственное проверенное место, где выдаётся namespace
# с доступом к /vendor/lib64 (исторически — для adb/shell отладочных бинарей). Поэтому при
# каждом старте копируем бинарь из модуля в /data/local/tmp и выполняем именно оттуда.

MODDIR=${0%/*}
PKG=com.davnozdu.autoresponder
SRC=$MODDIR/bin/pal_inject
BIN=/data/local/tmp/.autoresp_pal_inject
DIR=/data/data/$PKG/files/am
REQ=$DIR/req
RESP=$DIR/resp
PIDF=$DIR/.playpid
LOG="$MODDIR/answermachine.log"
# Состояние железной блокировки экрана/тача — пути и сохранённая яркость между blockon/blockoff.
ST="$MODDIR/.block"
STOPF="$ST/stop"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

# uid и SELinux-метка приватной папки приложения — как в bridge.sh: без категорий
# ("...:s0:c27,c257,...") приложение не откроет даже собственный файл, а restorecon их
# не восстанавливает. Читаем каждый раз: после переустановки категории другие.
app_uid() { stat -c %u "/data/data/$PKG/files" 2>/dev/null; }
app_ctx() { ls -dZ "/data/data/$PKG/files" 2>/dev/null | awk '{print $1}'; }

reply() { # <status> <detail>
  printf '%s %s %s\n' "$(date +%s)" "$1" "$2" > "$RESP" 2>/dev/null || return
  u=$(app_uid); [ -n "$u" ] && chown "$u:$u" "$RESP" 2>/dev/null
  c=$(app_ctx); [ -n "$c" ] && chcon "$c" "$RESP" 2>/dev/null
  chmod 600 "$RESP" 2>/dev/null
}

stop_play() {
  [ -f "$PIDF" ] && { kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; rm -f "$PIDF"; }
  pkill -f "$BIN" 2>/dev/null
}

play() { # <wav> <loops>
  wav=$1; loops=${2:-3}
  case "$loops" in ''|*[!0-9]*) loops=3 ;; esac
  [ -f "$wav" ] || { log "play: нет файла $wav"; reply err nofile; return; }
  [ -x "$BIN" ] || { stage_bin || { reply err nobin; return; }; }
  stop_play
  # devid=0: устройство PAL берёт из активной голосовой сессии.
  "$BIN" "$wav" "$loops" 0 >> "$LOG" 2>&1 &
  echo $! > "$PIDF"
  log "play: $wav x$loops (pid $!)"
  reply ok "play:$loops"
}

# Заглушить вывод RX на владельца, оставив тап INCALL_RECORD (запись не проседает).
# Приложение сначала пробует setStreamVolume(VOICE_CALL,0); этот root-fallback нужен,
# если у прошивки минимальный индекс громкости > 0. Конкретный mixer-контрол earpiece
# RX gain уточняется на устройстве — до тех пор no-op, чтобы не трогать чужой звук вслепую.
muteout() { # on|off
  log "muteout $1 (заглушка — контрол уточняется на устройстве)"
  reply ok "muteout:$1:noop"
}

# KEYCODE_POWER — переключатель, поэтому шлём только если экран сейчас ВКЛЮЧЁН (иначе бы
# наоборот разбудили). Состояние экрана надёжнее спрашивает приложение (PowerManager) и решает
# слать команду или нет — но на всякий случай подстрахуемся тем же способом и здесь.
screenoff() {
  st=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=')
  case "$st" in *Awake*) input keyevent 26; log "screenoff: отправлено"; reply ok sent ;;
  *) log "screenoff: экран и так не Awake ($st), пропуск"; reply ok "already-off" ;; esac
}

# ── Железная блокировка экрана/тача ──────────────────────────────────────────────
# Портировано из github.com/davnozdu/vr-usb-monitor (тот же телефон, там уже проверено).
#
# Тач — через inhibit-интерфейс input-подсистемы ядра: убирает события НА УРОВНЕ
# ДРАЙВЕРА, поэтому даже системный экран разблокировки (Keyguard — он защищён от чужих
# окон) перестаёт на них реагировать. Никакой борьбы за то, чьё окно поверх.
# Подсветка — напрямую в /sys/class/backlight, а не через Android Settings: не зависит
# от состояния «проснулся/уснул» и не задевает то, что при обычном гашении экрана во
# время звонка меняет маршрут звука на динамик владельца (см. AnswerMachineService).

find_touch_inhibit() {
  for pat in touchpanel touchscreen touch_panel touch; do
    np=$(grep -rl "$pat" /sys/class/input/*/name 2>/dev/null | head -1)
    [ -n "$np" ] || continue
    ih="${np%name}inhibited"
    [ -f "$ih" ] && { echo "$ih"; return; }
  done
}

find_backlight() { ls /sys/class/backlight/*/brightness 2>/dev/null | head -1; }

blockon() { # <app_pid>
  pid=$1
  mkdir -p "$ST" 2>/dev/null
  rm -f "$STOPF"
  touchp=$(find_touch_inhibit); bl=$(find_backlight)
  blval=-1; [ -n "$bl" ] && blval=$(cat "$bl" 2>/dev/null)

  # На этом телефоне тот же узел inhibited держит модуль vr_display_mode/VR Monitor
  # (для VR-гарнитуры). Если тач УЖЕ инхибирован кем-то до нас — это не наша блокировка:
  # не трогаем узел ни сейчас, ни при откате, иначе наш blockoff снял бы чужую блокировку
  # (например, сорвал бы активный VR-сеанс, когда наш звонок просто закончился раньше).
  touch_was=0
  [ -n "$touchp" ] && touch_was=$(cat "$touchp" 2>/dev/null)
  echo "$touchp" > "$ST/touch"; echo "$bl" > "$ST/bl"; echo "$blval" > "$ST/blval"
  echo "$touch_was" > "$ST/touch_was"

  settings put system screen_off_timeout 2147483647 2>/dev/null
  settings put system screen_brightness_mode 0 2>/dev/null
  settings put system screen_brightness 0 2>/dev/null
  [ -n "$bl" ] && echo 0 > "$bl" 2>/dev/null
  if [ -n "$touchp" ] && [ "$touch_was" != "1" ]; then
    echo 1 > "$touchp" 2>/dev/null
  elif [ "$touch_was" = "1" ]; then
    log "blockon: тач уже инхибирован кем-то другим (VR Monitor?) — не трогаем узел"
  fi
  log "blockon: touch=$touchp(was $touch_was) bl=$bl(was $blval) app_pid=$pid"

  # Сторож — ОТДЕЛЬНЫЙ файл через nohup, не инлайн `(...)&`: последний спавнился из
  # pipe-подшелла (inotifyd | while read, см. низ файла) и не отрабатывал предсказуемо —
  # внешний скрипт снимает саму неоднозначность (см. watchdog_block.sh, тот же приём
  # что в vr-usb-monitor).
  nohup sh "$MODDIR/watchdog_block.sh" "$pid" "$STOPF" "$touchp" "$touch_was" "$bl" "$blval" "$PKG" \
    >/dev/null 2>&1 &
  reply ok "blocked touch=$touchp bl=$bl"
}

# DisplayManager перебивает первую запись в подсветку через пару секунд (проверено в
# vr-usb-monitor) — приложение шлёт эту команду на каждом тике своего цикла, пока
# блокировка активна.
redim() {
  [ -f "$ST/bl" ] || return
  bl=$(cat "$ST/bl" 2>/dev/null)
  [ -n "$bl" ] && echo 0 > "$bl" 2>/dev/null
  reply ok redimmed
}

blockoff() {
  touch "$STOPF" 2>/dev/null   # сторож увидит и выйдет сам, не восстанавливая повторно
  t=$(cat "$ST/touch" 2>/dev/null); tw=$(cat "$ST/touch_was" 2>/dev/null)
  b=$(cat "$ST/bl" 2>/dev/null); v=$(cat "$ST/blval" 2>/dev/null)
  # Тач включаем обратно только если инхибировали его МЫ (см. blockon) — иначе снимем чужую
  # блокировку (VR Monitor).
  if [ -n "$t" ] && [ "$tw" != "1" ]; then echo 0 > "$t" 2>/dev/null; fi
  if [ -n "$b" ] && [ "${v:-0}" -ge 0 ] 2>/dev/null; then echo "$v" > "$b" 2>/dev/null; fi
  settings put system screen_brightness_mode 1 2>/dev/null
  settings put system screen_off_timeout 30000 2>/dev/null
  log "blockoff: восстановлено"
  reply ok unblocked
}

handle() {
  line=$(head -n1 "$REQ" 2>/dev/null) || return
  [ -n "$line" ] || return
  # shellcheck disable=SC2086
  set -- $line
  cmd=$1; shift
  case "$cmd" in
    play)      play "$1" "$2" ;;
    stop)      stop_play; reply ok stopped ;;
    muteout)   muteout "$1" ;;
    screenoff) screenoff ;;
    blockon)   blockon "$1" ;;
    redim)     redim ;;
    blockoff)  blockoff ;;
    *)       log "неизвестная команда: $cmd" ;;
  esac
}

# Копирует бинарь из модуля в /data/local/tmp (см. комментарий выше про linkerconfig).
# Перекопируем, если ещё не сделано или source изменился (обновление модуля) — сверяем
# размер, дешёво и достаточно для целостности при апдейте.
stage_bin() {
  [ -f "$SRC" ] || return 1
  if [ ! -x "$BIN" ] || [ "$(stat -c %s "$SRC" 2>/dev/null)" != "$(stat -c %s "$BIN" 2>/dev/null)" ]; then
    cp -f "$SRC" "$BIN" 2>/dev/null || return 1
    chmod 755 "$BIN" 2>/dev/null
    chcon u:object_r:shell_data_file:s0 "$BIN" 2>/dev/null
  fi
  [ -x "$BIN" ]
}

prepare() {
  uid=$(app_uid); [ -n "$uid" ] || return 1
  mkdir -p "$DIR" 2>/dev/null || return 1
  chown "$uid:$uid" "$DIR" 2>/dev/null; chmod 700 "$DIR" 2>/dev/null
  [ -f "$REQ" ] || : > "$REQ"
  chown "$uid:$uid" "$REQ" 2>/dev/null; chmod 600 "$REQ" 2>/dev/null
  ctx=$(app_ctx); [ -n "$ctx" ] && chcon -R "$ctx" "$DIR" 2>/dev/null
  stage_bin
  return 0
}

FIFO="$MODDIR/.req_fifo"

: > "$LOG"; log "answermachine start (pid $$)"
# inotifyd будит демон на каждую запись req — без опроса, без расхода батареи.
# Если inode req пересоздан (переустановка приложения), inotifyd выходит — заводим заново.
#
# ВАЖНО: читаем события через именованный FIFO с `<`, а не через pipe `|`. В POSIX-шеллах
# (в т.ч. toybox sh на Android) правая часть `|` выполняется в ПОДШЕЛЛЕ. handle() (через
# blockon) спавнит фоновый job (`nohup sh watchdog_block.sh ... &`) — запуск фонового job'а
# из такого подшелла ломает дальнейшее чтение этого же pipe: последующие команды (play,
# muteout, повторные redim) молча теряются на десятки секунд. Redirect `< "$FIFO"` НЕ создаёт
# подшелл для тела цикла — читает в основном процессе демона, — поэтому фоновые job'ы внутри
# handle() больше не мешают чтению следующих строк.
while :; do
  if ! prepare; then sleep 5; continue; fi
  [ -p "$FIFO" ] || mkfifo "$FIFO" 2>/dev/null
  inotifyd - "$REQ:cew" > "$FIFO" 2>/dev/null &
  INOTPID=$!
  while read -r _ev _rest; do
    handle
  done < "$FIFO"
  kill "$INOTPID" 2>/dev/null
  sleep 1
done
