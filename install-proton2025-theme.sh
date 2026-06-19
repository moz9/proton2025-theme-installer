#!/bin/sh
set -eu

REPO="${PROTON2025_REPO:-ChesterGoodiny/luci-theme-proton2025}"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
TMP_DIR="$(mktemp -d /tmp/proton2025.XXXXXX)"
RELEASE_ASSET_IPS="${PROTON2025_RELEASE_ASSET_IPS:-185.199.108.133 185.199.109.133 185.199.111.133 185.199.110.133}"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

need_root() {
	if [ "$(id -u)" != 0 ]; then
		echo "Запустите скрипт от root на OpenWrt." >&2
		exit 1
	fi
}

need_openwrt() {
	if [ ! -f /etc/openwrt_release ]; then
		echo "Это не похоже на OpenWrt: нет /etc/openwrt_release." >&2
		exit 1
	fi
}

download_once() {
	url="$1"
	dest="$2"
	resolve_ip="${3:-}"

	if command -v curl >/dev/null 2>&1; then
		if [ -n "$resolve_ip" ]; then
			curl -fsSL --connect-timeout 10 -m 120 \
				-H 'User-Agent: openwrt-proton2025-installer' \
				--resolve "release-assets.githubusercontent.com:443:${resolve_ip}" \
				"$url" -o "$dest"
		else
			curl -fsSL --connect-timeout 10 -m 120 \
				-H 'User-Agent: openwrt-proton2025-installer' \
				"$url" -o "$dest"
		fi
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$dest" "$url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$dest" "$url"
	else
		echo "Не найдена команда для скачивания: нужен wget, curl или uclient-fetch." >&2
		exit 1
	fi
}

download() {
	url="$1"
	dest="$2"

	rm -f "$dest"
	if download_once "$url" "$dest" && [ -s "$dest" ]; then
		return 0
	fi

	case "$url" in
		*github.com*/releases/download/*)
			if command -v curl >/dev/null 2>&1; then
				for ip in $RELEASE_ASSET_IPS; do
					rm -f "$dest"
					echo "Retry download via release-assets.githubusercontent.com ${ip}..." >&2
					if download_once "$url" "$dest" "$ip" && [ -s "$dest" ]; then
						return 0
					fi
				done
			fi
			;;
	esac

	return 1
}

json_value() {
	key="$1"
	tr ',' '\n' < "$TMP_DIR/release.json" | sed -n 's/^[[:space:]]*"'$key'":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

asset_url() {
	pattern="$1"
	tr ',' '\n' < "$TMP_DIR/release.json" | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' | grep "$pattern" | head -n 1
}

install_package() {
	package_file="$1"

	if command -v apk >/dev/null 2>&1; then
		apk add --allow-untrusted "$package_file"
	elif command -v opkg >/dev/null 2>&1; then
		opkg install "$package_file"
	else
		echo "Не найден пакетный менеджер: нужен apk или opkg." >&2
		exit 1
	fi
}

enable_theme() {
	if command -v uci >/dev/null 2>&1; then
		uci set luci.main.mediaurlbase='/luci-static/proton2025'
		uci commit luci
	fi

	/etc/init.d/uhttpd restart 2>/dev/null || true
	/etc/init.d/rpcd restart 2>/dev/null || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
}

install_download_helper() {
	cat > /usr/bin/proton2025-download <<'EOF'
#!/bin/sh
set -u

dest="$1"
url="$2"
ips="${PROTON2025_RELEASE_ASSET_IPS:-185.199.108.133 185.199.109.133 185.199.111.133 185.199.110.133}"

try_download() {
	try_url="$1"
	try_dest="$2"
	resolve_ip="${3:-}"

	rm -f "$try_dest"

	if command -v curl >/dev/null 2>&1; then
		if [ -n "$resolve_ip" ]; then
			curl -fsSL --connect-timeout 10 -m 120 \
				--resolve "release-assets.githubusercontent.com:443:${resolve_ip}" \
				-o "$try_dest" "$try_url"
		else
			curl -fsSL --connect-timeout 10 -m 120 -o "$try_dest" "$try_url"
		fi
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$try_dest" --timeout=30 "$try_url"
	else
		return 1
	fi

	[ -s "$try_dest" ]
}

try_download "$url" "$dest" && exit 0

case "$url" in
	*github.com*/releases/download/*)
		if command -v curl >/dev/null 2>&1; then
			for ip in $ips; do
				try_download "$url" "$dest" "$ip" && exit 0
			done
		fi
		;;
esac

exit 1
EOF
	chmod 0755 /usr/bin/proton2025-download
}

patch_theme_updater() {
	settings_file="/usr/share/rpcd/ucode/luci.proton-settings"

	[ -f "$settings_file" ] || return 0
	install_download_helper

	if grep -q "proton2025-release-assets-fallback" "$settings_file"; then
		return 0
	fi

	tmp_file="${settings_file}.tmp.$$"
	awk '
		/const downloadResult = runCommand\("rm -f / {
			print "        /* proton2025-release-assets-fallback */";
			print "        const downloadResult = runCommand(\"proton2025-download \" + packagePath + \" \" + assetUrl + \" >/tmp/proton2025-download.log 2>&1 && echo ok || echo fail\");";
			next;
		}
		{ print }
	' "$settings_file" > "$tmp_file" && mv "$tmp_file" "$settings_file"
	rm -f "$tmp_file"
	/etc/init.d/rpcd restart 2>/dev/null || true
}

need_root
need_openwrt

echo "== Proton2025: поиск последнего релиза =="
download "$API_URL" "$TMP_DIR/release.json"

tag="$(json_value tag_name)"
if [ -z "$tag" ]; then
	echo "Не удалось определить последнюю версию Proton2025." >&2
	exit 1
fi

if command -v apk >/dev/null 2>&1; then
	url="$(asset_url '\.apk$')"
elif command -v opkg >/dev/null 2>&1; then
	url="$(asset_url '_all\.ipk$')"
else
	echo "Не найден пакетный менеджер: нужен apk или opkg." >&2
	exit 1
fi

if [ -z "$url" ]; then
	echo "В релизе ${tag} не найден подходящий пакет для этого роутера." >&2
	exit 1
fi

package_file="${TMP_DIR}/$(basename "$url")"

echo "Версия: ${tag}"
echo "Пакет: $(basename "$package_file")"
download "$url" "$package_file"

echo "== Установка пакета =="
install_package "$package_file"

echo "== Включение темы =="
enable_theme
patch_theme_updater

echo
echo "Готово. Тема Proton2025 установлена и включена."
echo "Если браузер показывает старую тему, сделайте жесткое обновление страницы."
