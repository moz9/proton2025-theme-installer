#!/bin/sh
set -eu

# Bootstrap only: use RouterDesk for transactional upgrades.
REPO=ChesterGoodiny/luci-theme-proton2025
fail() { echo "$*" >&2; return 1; }

validate_version() {
	case "${PROTON2025_VERSION:-}" in
		*[!v0-9.]*) fail 'Некорректный PROTON2025_VERSION.'; return 1 ;;
	esac
	printf '%s\n' "${PROTON2025_VERSION:-}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || {
		fail 'Задайте PROTON2025_VERSION в формате v1.4.4.'; return 1
	}
}

download() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 -m 120 \
			-H 'User-Agent: openwrt-proton2025-installer' -o "$2" "$1"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		fail 'Нужен curl, uclient-fetch или wget.'
	fi
	[ -s "$2" ]
}

json_get() {
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$1" -e "@$2"
	else
		jq -r "$2 // empty" "$1"
	fi
}

select_asset() {
	metadata="$1"
	expected="$2"
	[ "$(json_get "$metadata" .tag_name)" = "$PROTON2025_VERSION" ] || return 1
	index=0
	matches=0
	while name="$(json_get "$metadata" ".assets[$index].name")" && [ -n "$name" ]; do
		if [ "$name" = "$expected" ]; then
			matches=$((matches + 1))
			asset_url="$(json_get "$metadata" ".assets[$index].browser_download_url")" || return 1
			asset_digest="$(json_get "$metadata" ".assets[$index].digest")" || return 1
		fi
		index=$((index + 1))
	done
	[ "$matches" = 1 ] || return 1
	[ "$asset_url" = "https://github.com/$REPO/releases/download/$PROTON2025_VERSION/$expected" ] || return 1
	printf '%s\n%s\n' "$asset_url" "$asset_digest"
}

verify_digest() {
	case "$2" in sha256:*) expected_hash="${2#sha256:}" ;; *) fail 'Нет SHA-256 digest.'; return 1 ;; esac
	[ "${#expected_hash}" = 64 ] || { fail 'Некорректный SHA-256 digest.'; return 1; }
	case "$expected_hash" in *[!0-9a-f]*) fail 'Некорректный SHA-256 digest.'; return 1 ;; esac
	actual_hash="$(sha256sum "$1")" || return 1
	[ "${actual_hash%% *}" = "$expected_hash" ] || { fail 'SHA-256 пакета не совпадает.'; return 1; }
}

cleanup() {
	status=$?
	trap - EXIT
	if [ "${restore_luci:-0}" = 1 ]; then
		cp -p "$TMP_DIR/luci.before" /etc/config/luci || {
			echo "Не удалось восстановить LuCI config; резервная копия: $TMP_DIR/luci.before" >&2
			exit 1
		}
	fi
	rm -rf "$TMP_DIR"
	exit "$status"
}

main() {
	validate_version
	[ "$(id -u)" = 0 ] || { fail 'Запустите от root на OpenWrt.'; return 1; }
	[ -f /etc/openwrt_release ] || { fail 'Нет /etc/openwrt_release.'; return 1; }
	command -v sha256sum >/dev/null 2>&1 || { fail 'Нужен sha256sum.'; return 1; }
	if ! command -v jsonfilter >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
		fail 'Нужен jsonfilter или jq для строгого разбора GitHub API.'; return 1
	fi
	command -v uci >/dev/null 2>&1 || { fail 'Нужен uci.'; return 1; }
	pending="$(uci changes)" || { fail 'Не удалось проверить изменения UCI.'; return 1; }
	[ -z "$pending" ] || { fail 'Есть несохранённые изменения UCI; сначала примените или отмените их.'; return 1; }
	case "${PROTON2025_ACTIVATE:-0}" in 0|1) ;; *) fail 'PROTON2025_ACTIVATE должен быть 0 или 1.'; return 1 ;; esac
	version="${PROTON2025_VERSION#v}"
	if command -v apk >/dev/null 2>&1; then
		manager=apk
		if apk info -e luci-theme-proton2025 >/dev/null 2>&1; then
			fail 'Тема уже установлена. Для безопасного обновления используйте RouterDesk.'; return 1
		fi
		asset="luci-theme-proton2025-${version}-r1.apk"
	elif command -v opkg >/dev/null 2>&1; then
		manager=opkg
		if opkg status luci-theme-proton2025 | grep -q '^Status: .* installed$'; then
			fail 'Тема уже установлена. Для безопасного обновления используйте RouterDesk.'; return 1
		fi
		asset="luci-theme-proton2025_${version}_all.ipk"
	else
		fail 'Нужен apk или opkg.'; return 1
	fi
	for path in /www/luci-static/proton2025 /usr/share/rpcd/ucode/luci.proton-*; do
		if [ -e "$path" ] || [ -L "$path" ]; then
			fail 'Обнаружены существующие файлы темы. Используйте RouterDesk.'; return 1
		fi
	done
	TMP_DIR="$(mktemp -d /tmp/proton2025.XXXXXX)"
	restore_luci=0
	trap cleanup EXIT
	trap 'exit 1' INT TERM
	download "https://api.github.com/repos/$REPO/releases/tags/$PROTON2025_VERSION" "$TMP_DIR/release.json"
	selection="$(select_asset "$TMP_DIR/release.json" "$asset")" || { fail 'Релиз или точный asset не прошёл проверку.'; return 1; }
	url="$(printf '%s\n' "$selection" | sed -n '1p')"
	digest="$(printf '%s\n' "$selection" | sed -n '2p')"
	download "$url" "$TMP_DIR/$asset"
	verify_digest "$TMP_DIR/$asset" "$digest"
	[ -f /etc/config/luci ] || { fail 'Нет /etc/config/luci; bootstrap отменён.'; return 1; }
	cp -p /etc/config/luci "$TMP_DIR/luci.before"
	restore_luci=1
	echo "Установка $PROTON2025_VERSION ($asset)."
	if [ "$manager" = apk ]; then
		apk add --allow-untrusted "$TMP_DIR/$asset"
	else
		opkg install "$TMP_DIR/$asset"
	fi
	cp -p "$TMP_DIR/luci.before" /etc/config/luci
	if [ "${PROTON2025_ACTIVATE:-0}" = 1 ]; then
		uci set luci.main.mediaurlbase='/luci-static/proton2025'
		uci commit luci
	fi
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd restart
	restore_luci=0
	echo 'Пакет установлен. Этот bootstrap не обеспечивает автоматический откат.'
}

if [ "${PROTON2025_LIBRARY_ONLY:-0}" != 1 ]; then
	main "$@"
fi
