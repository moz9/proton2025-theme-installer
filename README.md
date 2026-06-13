# Proton2025 Theme Installer for OpenWrt

Закрытый установщик темы LuCI Proton2025 для OpenWrt.

Скрипты не содержат паролей, ключей, Network ID или настроек роутера. Каждый запуск установки берет последнюю версию из GitHub Releases проекта `ChesterGoodiny/luci-theme-proton2025`.

## Установка

Так как репозиторий приватный, OpenWrt-роутеру нужен GitHub token с правом чтения этого репозитория. Токен не нужно сохранять в репозитории.

## Где взять GitHub token

1. Откройте GitHub: **Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens**.
2. Нажмите **Generate new token**.
3. Название: `openwrt-proton2025-read`.
4. Expiration: лучше `30` или `90` дней.
5. Resource owner: `moz9`.
6. Repository access: **Only select repositories** -> `proton2025-theme-installer`.
7. Repository permissions: **Contents** -> **Read-only**.
8. Нажмите **Generate token** и скопируйте токен. GitHub покажет его только один раз.

Реальный токен нельзя коммитить в репозиторий. В командах ниже замените `PASTE_TOKEN_HERE` на токен только у себя в SSH-сессии роутера.

Вариант через `curl`:

```sh
GITHUB_TOKEN='PASTE_TOKEN_HERE'
curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/install-proton2025-theme.sh | sh
unset GITHUB_TOKEN
```

Вариант через `wget`, если он поддерживает `--header`:

```sh
GITHUB_TOKEN='PASTE_TOKEN_HERE'
wget --header="Authorization: Bearer ${GITHUB_TOKEN}" -qO- \
  https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/install-proton2025-theme.sh | sh
unset GITHUB_TOKEN
```

Скрипт сам выбирает пакет:

- `.apk` для OpenWrt с `apk`;
- `_all.ipk` для OpenWrt с `opkg`.

После установки тема сразу включается через UCI:

```sh
uci set luci.main.mediaurlbase='/luci-static/proton2025'
uci commit luci
```

## Удаление

Вариант через `curl`:

```sh
GITHUB_TOKEN='PASTE_TOKEN_HERE'
curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/uninstall-proton2025-theme.sh | sh
unset GITHUB_TOKEN
```

Вариант через `wget`, если он поддерживает `--header`:

```sh
GITHUB_TOKEN='PASTE_TOKEN_HERE'
wget --header="Authorization: Bearer ${GITHUB_TOKEN}" -qO- \
  https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/uninstall-proton2025-theme.sh | sh
unset GITHUB_TOKEN
```

Удаление делает две вещи:

- переключает LuCI на стандартную тему `/luci-static/bootstrap`;
- удаляет пакет `luci-theme-proton2025` через `apk del` или `opkg remove`.

## Источник темы

[ChesterGoodiny/luci-theme-proton2025](https://github.com/ChesterGoodiny/luci-theme-proton2025)
