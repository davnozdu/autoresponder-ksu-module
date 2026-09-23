#!/system/bin/sh
# watchdog_block.sh — root-сторож железной блокировки экрана/тача (см. blockon в
# answermachine.sh). Отдельный файл, а не инлайн `(...)&` внутри демона: тот же приём
# спавнился из pipe-подшелла (inotifyd | while read) и не отрабатывал предсказуемо —
# внешний скрипт, запускаемый через `nohup sh ... &`, устраняет саму неоднозначность
# (портировано из github.com/davnozdu/vr-usb-monitor, там ровно так и сделано).
#
# Следит за /proc/<pid> приложения, а не за пульсом от него — не зависит от таймеров,
# которые Doze может не пустить. Если приложение исчезнет (OOM/краш) без команды
# blockoff, телефон не должен остаться намертво чёрным и нетрогаемым.
#
# Аргументы: pid приложения, файл штатной остановки, узел touch, «наш ли» тач (см.
# ownership-проверку в blockon — 0=наш/можно включать обратно, 1=чужой/не трогаем),
# узел backlight, сохранённая яркость, имя пакета (для проверки /proc/<pid>/cmdline —
# pid мог быть переиспользован после смерти приложения).

PID="$1"; STOPF="$2"; TOUCH="$3"; TOUCH_WAS="$4"; BL="$5"; BLVAL="$6"; PKG="$7"

while [ -d "/proc/$PID" ]; do
  [ -f "$STOPF" ] && exit 0
  grep -q "$PKG" "/proc/$PID/cmdline" 2>/dev/null || break
  sleep 2
done
# Ещё одна проверка на случай гонки: приложение успело завершиться штатно (blockoff).
[ -f "$STOPF" ] && exit 0

if [ -n "$TOUCH" ] && [ "$TOUCH_WAS" != "1" ]; then echo 0 > "$TOUCH" 2>/dev/null; fi
if [ -n "$BL" ] && [ "${BLVAL:-0}" -ge 0 ] 2>/dev/null; then echo "$BLVAL" > "$BL" 2>/dev/null; fi
settings put system screen_brightness_mode 1 2>/dev/null
settings put system screen_off_timeout 30000 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog_block: приложение (pid $PID) исчезло — откатил сам" \
  >> "${STOPF%/*}/../answermachine.log" 2>/dev/null
