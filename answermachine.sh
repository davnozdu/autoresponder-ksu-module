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
# Протокол (app-private, /data/data/$PKG/files/am/), одна команда на запись в req,
# ПЕРВЫЙ токен строки — id команды (произвольная строка без пробелов, ставит приложение):
#   <id> play <wav_abspath> <loops>   проиграть приветствие в линию
#   stop                          снять текущее проигрывание
#   muteout on|off                mixer-mute выходного RX-устройства (fallback; см. ниже)
#   screenoff                     выключить экран, если сейчас включён (input keyevent 26) —
#                                 обычному приложению недоступно, только через root
#   blockon <app_pid>             железно: подсветка в 0 + тачскрин выключен на уровне ядра;
#                                 сам же держит подсветку в 0 локальным циклом (redim_loop.sh,
#                                 см. комментарий там) — DisplayManager перебивает её через
#                                 пару секунд, без отдельной IPC-команды с той же стороны
#   blockoff                      вернуть подсветку и тач как было, остановить оба цикла
#   recstart <max_sec>            своя запись звонка через `bin/pal_record` (incall-record
#                                 тап, uplink+downlink) — на случай, если штатный рекордер
#                                 OxygenOS не подхватится (видели ~1 звонок из 4 без файла
#                                 вовсе). Пишем ПАРАЛЛЕЛЬНО штатному с самого начала звонка, не
#                                 дожидаясь проверки — тап INCALL_RECORD рассчитан на несколько
#                                 слушателей, конфликтовать физически нечему. Буфер — в ОЗУ
#                                 (tmpfs моста мессенджеров, files/bridge — уже смонтирован; на
#                                 флеш ничего не пишется, пока не понадобится).
#   recstop                       остановить свою запись, дождаться корректного WAV-заголовка
#   recsave <dst_abspath>         штатный рекордер не сработал — скопировать буфер на диск
#   recdiscard                    штатный рекордер сработал — стереть буфер, диск не трогаем
# Ответ пишем в resp: "<epoch> <id> ok|err <detail>" (id — тот же, что был в req; chown+chcon
# под приложение, чтобы читалось). id в ответе — чтобы приложение не приняло за ACK старый
# resp от предыдущей команды или ответ на одинаковую команду, посланную секундой раньше
# (раньше ack сверяли просто "текст resp изменился").
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
REC_SRC=$MODDIR/bin/pal_record
REC_BIN=/data/local/tmp/.autoresp_pal_record
DIR=/data/data/$PKG/files/am
REQ=$DIR/req
RESP=$DIR/resp
PIDF=$DIR/.playpid
RECPIDF=$DIR/.recpid
RECSTOPF=$DIR/.recstop
# Буфер своей записи: предпочтительно в tmpfs, который уже монтирует bridge.sh поверх
# files/bridge (см. ensure_ram там) — здесь его только используем, повторно не монтируем.
# Не смонтирован (мост выключен/не успел) — падаем на диск в $ST/callrec, там же и чистим
# после смерти процесса. Один слот на файл: одновременно больше одного звонка не бывает.
BRIDGE_DIR=/data/data/$PKG/files/bridge
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

reply() { # <status> <detail> — REQID (id текущей команды) ставит handle() перед разбором
  printf '%s %s %s %s\n' "$(date +%s)" "$REQID" "$1" "$2" > "$RESP" 2>/dev/null || return
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
  # DisplayManager перебивает первую запись в подсветку через пару секунд (проверено в
  # vr-usb-monitor) — раньше приложение перебивало её обратно IPC-командой redim на каждом
  # тике своего цикла ожидания (файл + ответ + chown/chcon + лог — до ~33 раз в секунду на
  # весь звонок); теперь тот же тик крутит локальный цикл демона без всякого IPC. Тот же
  # $STOPF, что и у сторожа, глушит оба разом.
  nohup sh "$MODDIR/redim_loop.sh" "$STOPF" "$bl" >/dev/null 2>&1 &
  reply ok "blocked touch=$touchp bl=$bl"
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

# Своя запись звонка — fallback, если штатный рекордер OxygenOS не подхватится (см. верх
# файла). devid=0: устройство PAL берёт из активной голосовой сессии, как и play().
stage_rec_bin() {
  [ -f "$REC_SRC" ] || return 1
  if [ ! -x "$REC_BIN" ] || [ "$(bin_hash "$REC_SRC")" != "$(bin_hash "$REC_BIN")" ]; then
    cp -f "$REC_SRC" "$REC_BIN" 2>/dev/null || return 1
    chmod 755 "$REC_BIN" 2>/dev/null
    chcon u:object_r:shell_data_file:s0 "$REC_BIN" 2>/dev/null
  fi
  [ -x "$REC_BIN" ]
}

# Буфер в tmpfs моста, если он смонтирован (тогда на флеш ничего не пишется, пока не
# понадобится recsave), иначе на диск в $ST — тот же принцип, что и у самого моста
# (ensure_ram в bridge.sh): не смонтировалось — работаем как раньше, не ломаем функцию
# ради экономии флеша.
is_bridge_ram() {
  awk -v d="$BRIDGE_DIR" '$5==d && index($0," - tmpfs ")>0 {f=1} END{exit !f}' \
    /proc/self/mountinfo 2>/dev/null
}
rec_wav_path() {
  if is_bridge_ram; then echo "$BRIDGE_DIR/callrec/rec.wav"
  else echo "$ST/callrec/rec.wav"; fi
}

recstart() { # <max_sec>
  maxsec=${1:-300}
  case "$maxsec" in ''|*[!0-9]*) maxsec=300 ;; esac
  # inotifyd иногда доставляет несколько событий на одну запись в req (см. FIFO-цикл внизу
  # файла) — recstart без этой проверки на живом звонке отработала 3 раза подряд на одну
  # команду: три process'а pal_record гонялись за одним и тем же incall-record тапом, второй
  # и третий падали pal_stream_open=-22. Уже идущая запись — не повод переоткрывать поток.
  if [ -f "$RECPIDF" ] && [ -d "/proc/$(cat "$RECPIDF" 2>/dev/null)" ]; then
    reply ok "recstart:already"; return
  fi
  [ -x "$REC_BIN" ] || { stage_rec_bin || { reply err nobin; return; }; }
  w=$(rec_wav_path)
  mkdir -p "${w%/*}" 2>/dev/null
  rm -f "$RECSTOPF" "$w"
  "$REC_BIN" "$w" "$maxsec" "$RECSTOPF" 0 >> "$LOG" 2>&1 &
  echo $! > "$RECPIDF"
  log "recstart: max=${maxsec}s (pid $!) -> $w"
  reply ok "recstart"
}

recstop() {
  [ -f "$RECPIDF" ] || { reply ok "recstop:noop"; return; }
  touch "$RECSTOPF" 2>/dev/null
  pid=$(cat "$RECPIDF" 2>/dev/null)
  # Не убиваем сигналом — pal_record должен сам дописать реальные размеры в WAV-заголовок
  # (при старте они неизвестны), иначе файл останется нечитаемым (dataSize=0).
  i=0
  while [ -d "/proc/$pid" ] && [ "$i" -lt 15 ]; do sleep 1; i=$((i+1)); done
  rm -f "$RECPIDF" "$RECSTOPF"
  log "recstop: done"
  reply ok "recstop"
}

# Штатный рекордер не сработал — переносим буфер из ОЗУ на диск (единственная реальная
# запись на флеш ради этой функции, и только тогда, когда она правда нужна).
recsave() { # <dst_abspath>
  dst=$1
  w=$(rec_wav_path)
  [ -n "$dst" ] || { reply err nopath; return; }
  [ -f "$w" ] || { log "recsave: нет буфера ($w)"; reply err nofile; return; }
  mkdir -p "${dst%/*}" 2>/dev/null
  if cp -f "$w" "$dst" 2>/dev/null; then
    rm -f "$w"
    log "recsave: $w -> $dst"
    reply ok "recsave"
  else
    log "recsave: cp не удался $w -> $dst"
    reply err copyfail
  fi
}

# Штатный рекордер сработал — свой буфер больше не нужен, диск не трогаем вовсе.
recdiscard() {
  w=$(rec_wav_path)
  rm -f "$w"
  log "recdiscard: $w удалён"
  reply ok "recdiscard"
}

handle() {
  line=$(head -n1 "$REQ" 2>/dev/null) || return
  [ -n "$line" ] || return
  log "recv: $line"
  # shellcheck disable=SC2086
  set -- $line
  REQID=$1; shift
  cmd=$1; shift
  case "$cmd" in
    play)      play "$1" "$2" ;;
    stop)      stop_play; reply ok stopped ;;
    muteout)   muteout "$1" ;;
    screenoff) screenoff ;;
    blockon)   blockon "$1" ;;
    blockoff)  blockoff ;;
    recstart)  recstart "$1" ;;
    recstop)   recstop ;;
    recsave)   recsave "$1" ;;
    recdiscard) recdiscard ;;
    *)       log "неизвестная команда: $cmd" ;;
  esac
}

# sha256, не размер: обновлённый бинарь той же длины (частый случай — пересборка без
# смены функциональности) раньше проходил бы как "не изменился" и модуль продолжал бы
# работать со старым.
bin_hash() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Копирует бинарь из модуля в /data/local/tmp (см. комментарий выше про linkerconfig).
# Перекопируем, если ещё не сделано или source изменился (обновление модуля).
stage_bin() {
  [ -f "$SRC" ] || return 1
  if [ ! -x "$BIN" ] || [ "$(bin_hash "$SRC")" != "$(bin_hash "$BIN")" ]; then
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
  stage_rec_bin
  return 0
}

FIFO="$MODDIR/.req_fifo"

: > "$LOG"; log "answermachine start (pid $$)"
# ОЗУ-буфер (files/bridge/callrec) сам исчезает при перезагрузке — чистить нечего. А вот
# дисковый fallback ($ST/callrec) мог остаться от аварийно прерванной сессии (краш
# приложения/модуля между recstart и recsave/recdiscard) — на флеше он бы копился незаметно.
rm -rf "$ST/callrec" 2>/dev/null
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
