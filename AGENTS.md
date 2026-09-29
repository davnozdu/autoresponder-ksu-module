# Контекст для LLM: независимость KSU-модуля от meta-overlayfs

**СТАТУС 2026-09-29 (v0.4.0): overlay-free РЕАЛИЗОВАНО и проверено.** Модуль больше НЕ поставляет `system/`-overlay (нет priv-app, privapp-permissions, hiddenapi) и НЕ зависит от `meta-overlayfs`. Приложение ставится обычным `pm install -r -g` (watchdog.sh) как `/data`-приложение; захват ведёт shell-хост под uid 2000; звонящий мессенджер приложение определяет по уведомлению звонка (путь B). Проверено живыми звонками WhatsApp/Telegram с выключенным метамодулем. Подтверждено: KSU Next 3.4+ без метамодуля module `system/` overlay не монтирует вообще — но нам он теперь и не нужен. Ниже — историческая записка исследования; сверяйте с текущим кодом. Подробности в `../autoresponder-app/AGENTS.md` (`davnozdu/autoresponder-app`).

В этой задаче пользователь исключил разделение голосов «я/вы», метки важных моментов, поиск фраз и переход к их месту. Не расширять миграцию этими функциями. Цели: стабильная запись обеих сторон, низкий расход батареи и отказ от зависимости от `meta-overlayfs`.

## Рабочая схема

- OnePlus 15 CPH2745IN, OxygenOS/Android 16, KernelSU Next. Этот модуль запускает `msgr-host.sh`, который под UID `shell` (2000) держит `app_process`/`MsgrShellHost` и заранее регистрирует AudioPolicy `ROUTE_FLAG_LOOP_BACK_RENDER`. `MIC` + `REMOTE_SUBMIX` проверены на реальных звонках WhatsApp и Telegram. Между звонками процесс спит на локальном сокете; отдельного опроса нет.
- **Основной KSU-модуль нужен и после отказа от overlay.** Он запускает shell-хост, watchdog, bridge, автоответчик, выдаёт runtime-права и роли, обслуживает бэкапы и обновления. Предлагается убрать зависимость только от **отдельного метамодуля `meta-overlayfs`**, который на этой версии KernelSU нужен для наложения каталога `system/`.
- Сейчас `customize.sh` копирует APK в `system/priv-app`, а `system/etc/permissions` и `system/etc/sysconfig` дают приложению привилегированный UID-доступ к сведениям об аудиоплеерах. Сам звук уже захватывает shell-хост; app-side privilege используется для определения пакета звонящего через `getClientUid`.

## Вариант без system/ overlay

- Приложение уже получает публичные события `AudioManager.OnModeChangedListener` для `MODE_IN_COMMUNICATION`. Нужно перенести определение UID активного звонящего в существующий shell-хост и вернуть его приложению по проверяемому сокету. CallVault делает это через активные playback-конфигурации (`IAudioService`) и запасной разбор `dumpsys audio` (`VoipAppIdentity.kt`). На этом устройстве история `dumpsys audio` содержит пакеты/UID WhatsApp и Telegram; решение в момент начала звонка ещё не валидировано.
- Приложение должно сопоставлять UID с выбранными мессенджерами, исключать managed сотовый звонок через `TelecomManager.isInManagedCall`, учитывать гонку до появления voice-плеера и сохранять дебаунс окончания звонка. Имя собеседника из уведомления не должно определять пакет звонящего.
- AudioPolicy остаётся заранее зарегистрированной под UID 2000. Не переносить MIC обратно в UID приложения: на OnePlus 15 он заглушался даже у priv-app.
- После тестов можно перестать укладывать APK в `system/priv-app` и удалить privapp-XML/sysconfig из модуля. `watchdog.sh` уже умеет установить APK обычным `pm install` и выдать runtime-права; перепроверить его и обновления перед миграцией. Не удалять данные приложения.

## Порядок проверки

1. Сначала «теневой» UID-резолвер под действующим overlay и сравнение с текущим app-side `getClientUid` на WhatsApp, Telegram и SIM-звонке. Нужны проверки после reboot, при блокировке экрана и при кратком провале аудиорежима. Никаких двух одновременных sink: повторное открытие может нарушить маршрут дальней стороны.
2. Затем отдельная сборка без `system/`, установка и reboot. Проверить host ready, AudioPolicy до звонка, отсутствие `PRIVILEGED` у `/data`-приложения, обе стороны WAV, журнал, watchdog/роли/bridge/автоответчик.
3. Только после успешных настоящих звонков решить, можно ли удалить `meta-overlayfs`: он может быть нужен другим модулям. Сохранить рабочий вариант с overlay для возврата.

Источники: <https://github.com/madkongo/CallVault> (`VoipCallDetector.kt`, `VoipAppIdentity.kt`, `VoipTelephonyGate.kt`); <https://developer.android.com/reference/android/media/AudioManager.OnModeChangedListener>; <https://android.googlesource.com/platform/frameworks/base/+/master/services/core/java/com/android/server/audio/PlaybackActivityMonitor.java>.
