# AGENTS.md

Инструкции для AI-агентов (Codex, Claude Code и др.), работающих с этим репозиторием.

## О проекте

- `install-proton2025-theme.sh` — ставит последний релиз LuCI-темы
  [ChesterGoodiny/luci-theme-proton2025](https://github.com/ChesterGoodiny/luci-theme-proton2025)
  на OpenWrt (`apk` или `opkg`), включает тему через UCI и патчит встроенный апдейтер темы
  (`/usr/share/rpcd/ucode/luci.proton-settings`), чтобы он качал пакет через `/usr/bin/proton2025-download`
  с фолбэком на IP `release-assets.githubusercontent.com`.
- `uninstall-proton2025-theme.sh` — переключает LuCI на `bootstrap` и удаляет пакет.
- Скрипты запускаются как `wget -qO- .../main/<script>.sh | sh` на роутере от root.

## Правила

- Только POSIX `sh` (busybox ash на OpenWrt): без bash-измов, без `local`, `[[ ]]`, массивов.
- Не полагаться на `curl`: на стоковом OpenWrt обычно есть только `uclient-fetch` (он же `wget`).
- Сообщения пользователю — на русском.
- Не коммитить секреты, бэкапы роутеров, пакеты `.apk`/`.ipk` (см. `.gitignore`, `SECURITY.md`).
- Проверка перед коммитом: `sh -n *.sh` и, если доступен, `shellcheck -s sh *.sh`.

## Открытые замечания ревью (2026-09-26)

Найдены при ревью кода и сверке с upstream `luci-theme-proton2025` 1.4.2. Когда пункт исправлен —
удалите его из списка в том же коммите.

### Баги

1. **Патч апдейтера убирает кавычки вокруг URL** — `install-proton2025-theme.sh`, функция
   `patch_theme_updater` (awk-строка с `proton2025-download`). В upstream
   (`luci.proton-settings`, строка с `const downloadResult`) `packagePath` и `assetUrl` обёрнуты в
   одинарные кавычки; патч подставляет их без кавычек, и спецсимволы из `assetUrl` (берётся из
   ответа GitHub API) выполнятся shell'ом от root внутри rpcd. Вернуть кавычки:
   `"proton2025-download '" + packagePath + "' '" + assetUrl + "' >/tmp/... 2>&1 && echo ok || echo fail"`.
2. **Ctrl+C / SIGTERM не прерывают установку** — `trap cleanup EXIT INT TERM`: обработчик не
   делает `exit`, поэтому после сигнала скрипт удаляет `$TMP_DIR` и продолжает работу (проверено в
   dash: rc=0, выполнение продолжилось). Исправление: `trap cleanup EXIT` + `trap 'exit 1' INT TERM`.
3. **Молчаливое падение при ошибке загрузки** — `download "$API_URL" ...` и `download "$url" ...`
   при неудаче завершают скрипт через `set -e` без сообщения. Добавить
   `|| { echo "Не удалось скачать ..." >&2; exit 1; }`.
4. **uninstall неполный**:
   - не удаляет `/usr/bin/proton2025-download`;
   - `apk del ... || true` / `opkg remove ... || true` глушат ошибку, а скрипт всё равно пишет «Готово»;
   - не перезапускает `rpcd` (пакет удаляет его ucode-плагины);
   - принудительно ставит `bootstrap`, даже если его нет. Лучше проверять `/www/luci-static/bootstrap`
     или брать другую тему из `uci show luci.themes`.

### Надёжность

5. **Частичное выполнение при обрыве `wget | sh`** — основной код на верхнем уровне файла. Обернуть
   в `main() { ... }` и вызвать `main "$@"` последней строкой (в обоих скриптах).
6. **Фолбэк по IP работает только с curl**, которого на стоковом OpenWrt обычно нет. Как минимум
   написать об этом в README или выводить предупреждение, если `curl` отсутствует.
7. **Нет таймаута у wget/uclient-fetch** в `download_once` — может висеть бесконечно. `-T 30`
   понимают busybox wget, uclient-fetch и GNU wget.
8. **Слишком широкий выбор пакета** — `asset_url '\.apk$'` / `'_all\.ipk$'` берут первый попавшийся
   файл. Upstream ищет по имени (`luci-theme-proton2025[^"]*\.apk`) и анонсирует отдельный пакет
   `luci-app-proton2025-dashboard`. Добавить имя пакета в шаблон.
9. **Лимит GitHub API (60 запросов/час на IP без токена)** — за CGNAT легко упереться. Upstream
   `install.sh` в этом случае использует `https://github.com/<repo>/releases.atom` для получения тега
   и собирает URL сам (`<pkg>-<ver>-r1.apk` / `<pkg>_<ver>_all.ipk`). Сделать такой же фолбэк.
10. **Патч апдейтера одноразовый и хрупкий** — после самообновления темы файл
    `luci.proton-settings` перезаписывается оригиналом, и фолбэк пропадает; если строка в upstream
    изменится, awk молча ничего не заменит. Проверять, что замена произошла (маркер есть в
    результате), и выводить предупреждение, если нет.

### Прочее

11. `rpcd` перезапускается дважды (`enable_theme` и `patch_theme_updater`) — вызвать
    `patch_theme_updater` до `enable_theme` и убрать лишний перезапуск.
12. `SECURITY.md` советует ставить по тегу или конкретному коммиту, но тегов нет. Создать `v1.0.0`
    и дать в README команду с URL по тегу.
13. Добавить GitHub Actions workflow с `shellcheck -s sh *.sh`.
14. Подумать, не предложить ли фолбэк на IP и доработку апдейтера в upstream
    (`ChesterGoodiny/luci-theme-proton2025` уже имеет свой `install.sh`), чтобы не поддерживать
    параллельную логику.
