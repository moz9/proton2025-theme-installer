#!/bin/sh
set -eu

# First install and transactional upgrades of the original upstream theme.
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

load_backend() {
	case "$1" in
		proton-transaction.sh) backend_hash=8319c369bd0f602787a45a99626c6bf8ad92a230b7bee609536d151849d50b3f;;
		proton-dependencies.sh) backend_hash=7352991323cf29c03cba75f5d700b24ff05b76e1ae25d82c6f0e54ad9a2908d7;;
		proton-luci-health.sh) backend_hash=807a8980763643e7e897b0da33e6edc57dbbe59138b6146c76541cfc09bf6b41;;
		*) return 1;;
	esac
	# Local checkout and one-command download use exactly the same reviewed bytes.
	if [ -f "$INSTALLER_DIR/lib/$1" ]; then cp "$INSTALLER_DIR/lib/$1" "$2"
	else download "https://raw.githubusercontent.com/moz9/proton2025-theme-installer/main/lib/$1" "$2"; fi
	verify_digest "$2" "sha256:$backend_hash"
}

update_existing() (
	set -eu
	umask 077
	old_version=$1
	old_logical=$(printf '%s\n' "$old_version" | sed 's/-r[0-9]*$//')
	printf '%s\n' "$old_logical" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { fail 'Неизвестная установленная версия темы.'; exit 1; }
	if [ "$old_logical" = "${PROTON2025_VERSION#v}" ]; then echo "Proton $old_version уже установлен."; exit 0; fi
	# Never turn an update command into an accidental downgrade.
	awk -v a="$old_logical" -v b="${PROTON2025_VERSION#v}" 'BEGIN {split(a,x,"."); split(b,y,"."); for(i=1;i<=3;i++){if(y[i]>x[i])exit 0; if(y[i]<x[i])exit 1} exit 1}' || { fail 'Целевая версия не новее установленной.'; exit 1; }
	for entry in /root/routerdesk /tmp/routerdesk-operation.lock; do [ ! -L "$entry" ] || { fail "Символическая ссылка: $entry"; exit 1; }; done
	[ ! -e /tmp/routerdesk-operation.lock ] || { fail 'Другая операция RouterDesk ещё не завершена.'; exit 1; }
	mkdir -p /root/routerdesk
	job_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	[ "${#job_id}" = 32 ] || exit 1
	job=/root/routerdesk/$job_id
	mkdir "$job"
	cd "$job"
	echo "Копия и журнал обновления: $job (не удалять до проверки)."
	load_backend proton-transaction.sh transaction.sh
	load_backend proton-dependencies.sh dependencies.sh
	load_backend proton-luci-health.sh health.sh
	PM=$manager; export PM
	. ./dependencies.sh
	case "$manager" in opkg) ext=ipk;; apk) ext=apk;; esac
	new_tag=$PROTON2025_VERSION
	for direction in old new; do
		if [ "$direction" = old ]; then PROTON2025_VERSION=v$old_logical; else PROTON2025_VERSION=$new_tag; fi
		if [ "$manager" = opkg ]; then name="luci-theme-proton2025_${PROTON2025_VERSION#v}_all.ipk"
		else
			if [ "$direction" = old ]; then pkg_version=$old_version; else pkg_version="${PROTON2025_VERSION#v}-r1"; fi
			name="luci-theme-proton2025-$pkg_version.apk"
		fi
		download "https://api.github.com/repos/$REPO/releases/tags/$PROTON2025_VERSION" "$direction-release.json"
		selected=$(select_asset "$direction-release.json" "$name") || { fail 'Точный пакет для установки/отката не подтверждён.'; exit 1; }
		url=$(printf '%s\n' "$selected" | sed -n '1p'); digest=$(printf '%s\n' "$selected" | sed -n '2p')
		download "$url" "$direction-package.$ext"
		verify_digest "$direction-package.$ext" "$digest"
		[ "$(wc -c < "$direction-package.$ext")" -le 4194304 ]
		if [ "$direction" = old ]; then OLD_SHA256=${digest#sha256:}; else NEW_SHA256=${digest#sha256:}; fi
	done
	PROTON2025_VERSION=$new_tag
	OLD_VERSION=$old_version; NEW_VERSION=${new_tag#v}
	[ "$manager" != apk ] || NEW_VERSION=$NEW_VERSION-r1
	export OLD_VERSION NEW_VERSION OLD_SHA256 NEW_SHA256
	if [ "$manager" = opkg ]; then
		dep_ipk_member new-package.ipk data.tar.gz theme-data.tar.gz
		tar -tvzf theme-data.tar.gz > theme-listing
		awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' theme-listing || { fail 'Пакет содержит ссылки или специальные файлы.'; exit 1; }
		tar -tzf theme-data.tar.gz > theme-paths
		sed -n '/\/$/!{s|^\./||;s|^|/|;p;}' theme-paths > new-paths.txt
	fi
	sh ./health.sh
	sh ./dependencies.sh stage
	sh ./transaction.sh prepare
	# From here the independent watchdog owns failure recovery, even if SSH dies.
	if ! sh ./transaction.sh apply; then
		sh ./transaction.sh status
		fail "Обновление не подтверждено; журнал и восстановление: $job"; exit 1
	fi
	PROTON_HEALTH_LAYOUT=modern; export PROTON_HEALTH_LAYOUT
	if [ "$(head -n 1 dependency-plan)" != none ]; then PROTON_HEALTH_UBUS=1; export PROTON_HEALTH_UBUS; fi
	if ! sh ./health.sh; then
		sh ./transaction.sh rollback
		fail "LuCI не прошёл проверку; выполнен откат. Копия: $job"; exit 1
	fi
	sh ./transaction.sh confirm
	echo "Proton $NEW_VERSION обновлён; LuCI проверен. Копия: $job"
)

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
			installed=$(apk list --installed luci-theme-proton2025 | awk '$1 ~ /^luci-theme-proton2025-/ && $NF=="[installed]" {n++; sub(/^luci-theme-proton2025-/,"",$1); v=$1} END {if(n!=1)exit 1;print v}') || return 1
			update_existing "$installed"; return
		fi
		asset="luci-theme-proton2025-${version}-r1.apk"
	elif command -v opkg >/dev/null 2>&1; then
		manager=opkg
		if opkg status luci-theme-proton2025 | grep -q '^Status: .* installed$'; then
			installed=$(opkg status luci-theme-proton2025 | awk '/^Version: / {n++; v=$2} END {if(n!=1)exit 1;print v}') || return 1
			update_existing "$installed"; return
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
	INSTALLER_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
	main "$@"
fi
