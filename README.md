# Proton2025 Theme Installer for OpenWrt

Установщик темы LuCI Proton2025 для OpenWrt.

Скрипты не содержат паролей, ключей, Network ID или настроек роутера. Каждый запуск установки берет последнюю версию из GitHub Releases проекта `ChesterGoodiny/luci-theme-proton2025`.

## Установка

Запустите на OpenWrt-роутере от `root`:

```sh
wget -qO- https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/install-proton2025-theme.sh | sh
```

Если на прошивке нет `wget`, но есть `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/install-proton2025-theme.sh | sh
```

Скрипт каждый раз берет последний релиз из `ChesterGoodiny/luci-theme-proton2025`.

Скрипт сам выбирает пакет:

- `.apk` для OpenWrt с `apk`;
- `_all.ipk` для OpenWrt с `opkg`.

После установки тема сразу включается через UCI:

```sh
uci set luci.main.mediaurlbase='/luci-static/proton2025'
uci commit luci
```

## Удаление

Запустите на OpenWrt-роутере:

```sh
wget -qO- https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/uninstall-proton2025-theme.sh | sh
```

Если на прошивке нет `wget`, но есть `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/uninstall-proton2025-theme.sh | sh
```

Удаление делает две вещи:

- переключает LuCI на стандартную тему `/luci-static/bootstrap`;
- удаляет пакет `luci-theme-proton2025` через `apk del` или `opkg remove`.

## Источник темы

[ChesterGoodiny/luci-theme-proton2025](https://github.com/ChesterGoodiny/luci-theme-proton2025)
