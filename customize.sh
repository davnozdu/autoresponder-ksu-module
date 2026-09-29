#!/system/bin/sh
# customize.sh — выполняется установщиком KernelSU/Magisk при флэше модуля.

PKG=com.davnozdu.autoresponder

ui_print "- Auto SMS/Call Responder module"
ui_print "- Target app package: $PKG"

# APK кладётся CI в корень модуля; здесь раскладываем его как ПРИВИЛЕГИРОВАННОЕ
# системное приложение (/system/priv-app), чтобы приложение держало
# signature|privileged-разрешения захвата аудио (CAPTURE_AUDIO_OUTPUT и др.) через
# privapp-permissions (system/etc/permissions/privapp-permissions-*.xml). Обычному
# /data-приложению их выдать нельзя даже под root. Запись звонков в мессенджерах
# Системные разрешения и скрытые API доступны приложению; сам двухканальный
# захват выполняет shell-хост модуля, так как Android глушит MIC у фонового UID.
APK="$MODPATH/AutoResponder.apk"
if [ -f "$APK" ]; then
  ui_print "- Bundled APK found; staging as privileged system app (priv-app)"
  mkdir -p "$MODPATH/system/priv-app/AutoResponder"
  cp -f "$APK" "$MODPATH/system/priv-app/AutoResponder/AutoResponder.apk"
  set_perm_recursive "$MODPATH/system/priv-app" 0 0 0755 0644
  [ -d "$MODPATH/system/etc/permissions" ] && set_perm_recursive "$MODPATH/system/etc/permissions" 0 0 0755 0644
  [ -d "$MODPATH/system/etc/sysconfig" ] && set_perm_recursive "$MODPATH/system/etc/sysconfig" 0 0 0755 0644
  ui_print "- Staged to /system/priv-app; privapp-permissions applied on reboot"
else
  ui_print "! No bundled APK in module. Install the app manually (adb/apk)."
  ui_print "! Module will still provision permissions once the app is present."
fi

# Нативный помощник голосового автоответчика — должен быть исполняемым (aarch64).
PAL="$MODPATH/bin/pal_inject"
if [ -f "$PAL" ]; then
  set_perm "$PAL" 0 0 0755
  ui_print "- Voice answering machine helper (pal_inject) installed"
else
  ui_print "! pal_inject helper missing — voice greeting will be unavailable"
fi

# Своя запись звонка (fallback на случай, если штатный рекордер OxygenOS не подхватится).
PALREC="$MODPATH/bin/pal_record"
if [ -f "$PALREC" ]; then
  set_perm "$PALREC" 0 0 0755
  ui_print "- Own call recording fallback (pal_record) installed"
else
  ui_print "! pal_record helper missing — no fallback call recording"
fi

# Keep root recovery snapshots when the manager replaces the module directory.
OLD=/data/adb/modules/autoresp_ksu
if [ -d "$OLD/backup" ] && [ "$OLD" != "$MODPATH" ]; then
  cp -a "$OLD/backup" "$MODPATH/backup"
  [ -f "$OLD/.data_bk_stamp" ] && cp "$OLD/.data_bk_stamp" "$MODPATH/.data_bk_stamp"
fi
ui_print "- Done. Reboot to apply."
