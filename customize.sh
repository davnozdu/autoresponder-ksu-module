#!/system/bin/sh
# customize.sh — выполняется установщиком KernelSU/Magisk при флэше модуля.

PKG=com.davnozdu.autoresponder

ui_print "- Auto SMS/Call Responder module"
ui_print "- Target app package: $PKG"

# APK кладётся CI в system/priv-app/AutoResponder/AutoResponder.apk
APK="$MODPATH/AutoResponder.apk"
if [ -f "$APK" ]; then
  ui_print "- Bundled APK found; will be installed via pm on boot"
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
