# Auto SMS/Call Responder — KernelSU module

Модуль-обёртка для приложения-автоответчика (`com.davnozdu.autoresponder`).
Сам логику не содержит — обеспечивает работу приложения на OxygenOS/ColorOS.

## Что делает при каждой загрузке (`service.sh`)
1. Ставит/обновляет вложенный `AutoResponder.apk` через `pm install -r -g`.
2. Выдаёт runtime-разрешения без диалогов (`pm grant`).
3. Назначает роль `android.app.role.CALL_SCREENING` приложению (`cmd role add-role-holder`).
4. Включает доступ к уведомлениям (`enabled_notification_listeners`).
5. Добавляет приложение в Doze whitelist и разрешает фон/автозапуск (`appops`).

## Автообновление
- `module.prop` содержит `updateJson` → менеджер KernelSU/Magisk предлагает апдейт.
- `update-check.sh` при загрузке сам сверяет версию и ставит новый zip.

## Сборка
CI (`.github/workflows/release.yml`) на пуш тега `v*`:
- синхронизирует версию в `module.prop`,
- опционально подтягивает APK из релизов [autoresponder-app](https://github.com/davnozdu/autoresponder-app) (нужен secret `APP_REPO_TOKEN`),
- пакует zip, создаёт Release, обновляет `update.json`.

## Целевое устройство (проверено)
OnePlus 15 (CPH2745), Android 16 / OxygenOS V16.1.0, KernelSU. Роль `CALL_SCREENING` была свободна.

## Связанный репозиторий
Приложение: https://github.com/davnozdu/autoresponder-app
