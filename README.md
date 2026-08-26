# Auto SMS/Call Responder — KernelSU module

Модуль-обёртка для приложения-автоответчика (`com.davnozdu.autoresponder`).
Сам логику не содержит — обеспечивает работу приложения на OxygenOS/ColorOS.

## Что делает при каждой загрузке
`service.sh` дожидается `sys.boot_completed` и запускает `watchdog.sh` под супервизором
(`setsid` + перезапуск через 60 с, если процесс убили). Watchdog ждёт готовности PackageManager
и RoleManager, доводит состояние до нужного и **перепроверяет каждые 15 минут**:

1. Ставит/восстанавливает вложенный `AutoResponder.apk` через `pm install -r -g`.
2. Выдаёт runtime-разрешения без диалогов (`pm grant`) — только те, что отозваны.
3. Назначает роль `android.app.role.CALL_SCREENING` (`cmd role add-role-holder`).
4. Включает слушателя уведомлений через `cmd notification allow_listener` и пере-привязывает
   его, если он числится включённым, но фактически не подключён.
5. Выдаёт доступ к политике «Не беспокоить» (`cmd notification allow_dnd`).
6. Добавляет приложение в Doze whitelist, разрешает фон/автозапуск и доступ ко всем файлам
   (`appops`, `MANAGE_EXTERNAL_STORAGE` — нужен для `/sdcard/AutoResponder`).

## Автообновление
- **Модуля**: `module.prop` содержит `updateJson` → менеджер KernelSU/Magisk предлагает апдейт;
  `update-check.sh` при загрузке сверяет `versionCode` с `update.json` и ставит новый zip.
- **Приложения**: `app-update.sh` раз в сутки сверяет установленную версию с последним релизом
  `autoresponder-app` и ставит новее под root.

`versionCode` считается из тега как `major*10000 + minor*100 + patch` (`v0.1.4` → `104`).
Раньше он получался отбрасыванием нецифровых символов, из-за чего `v0.1.2` давал `012` —
невалидный JSON, и самообновление не работало. Сравнение версий в скриптах сделано без
`sort -V`: в toybox его может не быть.

## Сборка
CI (`.github/workflows/release.yml`) на пуш тега `v*`:
- синхронизирует версию в `module.prop`,
- опционально подтягивает APK из релизов [autoresponder-app](https://github.com/davnozdu/autoresponder-app) (нужен secret `APP_REPO_TOKEN`),
- пакует zip, создаёт Release, обновляет `update.json`.

## Диагностика
- `provision.log` рядом с модулем — старт и self-update.
- `watchdog.log` — что именно чинилось (пишется только при изменениях, ротация 400 строк).
- Журнал самого приложения: `adb logcat -s AutoResp`.

## Целевое устройство (проверено)
OnePlus 15 (CPH2745), Android 16 / OxygenOS V16.1.0, KernelSU-Next. Роль `CALL_SCREENING`
была свободна. Проверено вживую: убийство watchdog и отбор роли — супервизор восстановил
состояние примерно за 80 секунд.

## Связанный репозиторий
Приложение: https://github.com/davnozdu/autoresponder-app
