#!/bin/sh
# Shared by RouterDesk and moz9/proton2025-theme-installer. Never upgrade the
# system to satisfy a theme: only add the reviewed, absent uhttpd ubus module.
DEP_ROOT=''
dep_fail() { printf 'Proton: %s\n' "$*" >&2; return 1; }
dep_version() {
 if [ "$PM" = opkg ]; then
  opkg status "$1" | awk -v p="$1" '/^Package: / {ok=($2==p)} /^Version: / {v=$2} /^Status: / {if(ok && $NF=="installed") {n++; value=v}} END {if(n==1) print value; else exit 1}'
 else
  apk list --installed "$1" | awk -v p="$1-" 'index($1,p)==1 && $NF=="[installed]" {n++; v=substr($1,length(p)+1)} END {if(n==1) print v; else exit 1}'
 fi
}
dep_field() {
 awk -v field="$2: " 'index($0,field)==1 {n++; value=substr($0,length(field)+1)} END {if(n!=1 || value=="") exit 1; print value}' "$1"
}
dep_download() {
 curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 90 --max-filesize 16777216 -o "$2" "$1"
}
dep_ipk_member() {
 dep_member=$(tar -tzf "$1" | awk -v p="$2" '$0==p || $0=="./"p {n++; v=$0} END {if(n!=1) exit 1; print v}') || return 1
 tar -xzOf "$1" "$dep_member" > "$3"
}
dep_ipk_control() {
 dep_ipk_member "$1" control.tar.gz dependency-control.tar.gz || return 1
 dep_ipk_member dependency-control.tar.gz control "$2"
}
dep_check_requires() {
 dep_requires=$(dep_field "$1" Depends) || return 1
 printf '%s\n' "$dep_requires" | tr ',' '\n' | while IFS= read -r dep_name; do
  dep_name=$(printf '%s' "$dep_name" | sed 's/^ *//;s/ *$//')
  case "$dep_name" in ''|*[!a-z0-9+.-]*) dep_fail "Неподдерживаемая зависимость: $dep_name"; exit 1;; esac
  if [ "${2:-installed}" = theme ] && [ "$dep_name" = uhttpd-mod-ubus ]; then continue; fi
  dep_version "$dep_name" >/dev/null || { dep_fail "Нужен пакет $dep_name; автоматическое изменение системных библиотек запрещено."; exit 1; }
 done
}
dep_check_payload() {
 # Reject links/devices as well as traversal. Only these two reviewed files
 # belong to this module; maintainer scripts are never executed.
 dep_ipk_member dependency.ipk data.tar.gz dependency-data.tar.gz || return 1
 tar -tvzf dependency-data.tar.gz > dependency-listing || return 1
 awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' dependency-listing || return 1
 tar -tzf dependency-data.tar.gz | sed 's|^\./||' > dependency-paths
 dep_count=0
 while IFS= read -r dep_path; do
  case "$dep_path" in ''|./|usr/|usr/lib/|etc/|etc/uci-defaults/) continue;;
   usr/lib/uhttpd_ubus.so) dep_count=$((dep_count+1));;
   etc/uci-defaults/00_uhttpd_ubus) :;;
   *) dep_fail "Неподдерживаемый файл модуля: $dep_path"; return 1;;
  esac
 done < dependency-paths
 [ "$dep_count" = 1 ]
}
dep_stage() (
 set -eu
 umask 077
 [ ! -e dependency-plan ] || { dep_fail 'План зависимостей уже существует.'; exit 1; }
 case "$PM" in opkg|apk) :;; *) exit 1;; esac
 if [ "$PM" = opkg ]; then
  dep_ipk_control old-package.ipk old-theme-control
  [ "$(dep_field old-theme-control Package)" = luci-theme-proton2025 ]
  dep_check_requires old-theme-control
  dep_ipk_control new-package.ipk theme-control
  [ "$(dep_field theme-control Package)" = luci-theme-proton2025 ]
  dep_check_requires theme-control theme
  dep_requires=$(dep_field theme-control Depends)
  case ",$dep_requires," in *uhttpd-mod-ubus*) :;; *) printf 'none\n' > dependency-plan; exit 0;; esac
 fi
 [ -f "$DEP_ROOT/etc/config/uhttpd" ] && [ ! -L "$DEP_ROOT/etc/config/uhttpd" ] || { dep_fail 'Нет обычного файла настроек uhttpd.'; exit 1; }
 dep_prefix=$(uci -q get uhttpd.main.ubus_prefix || true)
 case "$dep_prefix" in ''|/ubus) :;; *) dep_fail "Нестандартный ubus_prefix=$dep_prefix: автоматическая замена запрещена."; exit 1;; esac
 mkdir uhttpd-staging uci-staging
 cp -p "$DEP_ROOT/etc/config/uhttpd" uhttpd.before
 cp -p uhttpd.before uhttpd-staging/uhttpd
 if [ -z "$dep_prefix" ]; then
  uci -c "$PWD/uhttpd-staging" -t "$PWD/uci-staging" set uhttpd.main.ubus_prefix=/ubus
  uci -c "$PWD/uhttpd-staging" -t "$PWD/uci-staging" commit uhttpd
 fi
 cp -p uhttpd-staging/uhttpd uhttpd.expected
 if dep_version uhttpd-mod-ubus >/dev/null; then printf 'keep\n' > dependency-plan; exit 0; fi
 for dep_path in /usr/lib/uhttpd_ubus.so /etc/uci-defaults/00_uhttpd_ubus; do
  [ ! -e "$DEP_ROOT$dep_path" ] && [ ! -L "$DEP_ROOT$dep_path" ] || { dep_fail "Файл $dep_path уже существует без установленного пакета."; exit 1; }
 done
 dep_uv=$(dep_version uhttpd) || { dep_fail 'Версия uhttpd не подтверждена.'; exit 1; }
 case "$dep_uv" in ''|*[!a-zA-Z0-9_.+~:-]*) exit 1;; esac
 if [ "$PM" = opkg ]; then
  dep_release=$(sed -n "s/^DISTRIB_RELEASE='\([0-9.]*\)'$/\1/p" "$DEP_ROOT/etc/openwrt_release")
  dep_arch=$(sed -n "s/^DISTRIB_ARCH='\([a-zA-Z0-9_-]*\)'$/\1/p" "$DEP_ROOT/etc/openwrt_release")
  printf '%s\n' "$dep_release" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
  [ -n "$dep_arch" ]
  dep_feed="https://downloads.openwrt.org/releases/$dep_release/packages/$dep_arch/base"
  dep_download "$dep_feed/Packages" dependency-Packages
  dep_download "$dep_feed/Packages.sig" dependency-Packages.sig
  usign -V -P "$DEP_ROOT/etc/opkg/keys" -m dependency-Packages -x dependency-Packages.sig || { dep_fail 'Подпись официального индекса не подтверждена.'; exit 1; }
  awk 'BEGIN {RS=""} /^Package: uhttpd-mod-ubus\n/ {n++; value=$0} END {if(n!=1) exit 1; print value}' dependency-Packages > dependency-record
  dep_dv=$(dep_field dependency-record Version)
  [ "$dep_dv" = "$dep_uv" ] || { dep_fail "Модуль $dep_dv не совпадает с uhttpd $dep_uv. Веб-сервер автоматически не обновлялся."; exit 1; }
  [ "$(dep_field dependency-record Architecture)" = "$dep_arch" ]
  dep_check_requires dependency-record
  dep_filename=$(dep_field dependency-record Filename)
  case "$dep_filename" in ''|*[!a-zA-Z0-9_.+~:-]*|.*) exit 1;; esac
  dep_sha=$(dep_field dependency-record SHA256sum)
  [ "${#dep_sha}" = 64 ]; case "$dep_sha" in *[!a-f0-9]*) exit 1;; esac
  dep_download "$dep_feed/$dep_filename" dependency.ipk
  [ "$(sha256sum dependency.ipk | cut -d ' ' -f1)" = "$dep_sha" ]
  [ "$(wc -c < dependency.ipk)" -le 1048576 ]
  dep_ipk_control dependency.ipk dependency-control
  [ "$(dep_field dependency-control Package)" = uhttpd-mod-ubus ]
  [ "$(dep_field dependency-control Version)" = "$dep_uv" ]
  [ "$(dep_field dependency-control Architecture)" = "$dep_arch" ]
  dep_check_requires dependency-control
  dep_check_payload
 else
  apk add --simulate --no-scripts --no-commit-hooks --no-network --no-cache --allow-untrusted "$PWD/old-package.apk" > dependency-old-solver.log 2>&1
  awk '/^\([0-9]+\/[0-9]+\)/ {if($3!="luci-theme-proton2025") bad=1} END {exit bad}' dependency-old-solver.log
  mkdir dependency-fetch
  # apk fetch verifies repository signatures; do not allow untrusted or recurse.
  apk fetch --no-cache --output "$PWD/dependency-fetch" "uhttpd-mod-ubus=$dep_uv"
  set -- dependency-fetch/*.apk
  [ "$#" = 1 ] && [ -f "$1" ] && [ ! -L "$1" ]
  mv "$1" dependency.apk
  [ "$(wc -c < dependency.apk)" -le 1048576 ]
  apk add --simulate --no-scripts --no-commit-hooks --no-network --no-cache "$PWD/dependency.apk" "uhttpd-mod-ubus=$dep_uv" > dependency-solver.log 2>&1
  awk '/^\([0-9]+\/[0-9]+\)/ {n++; if($2!="Installing" || $3!="uhttpd-mod-ubus") bad=1} END {exit bad || n!=1}' dependency-solver.log
  dep_sha=$(sha256sum dependency.apk | cut -d ' ' -f1)
 fi
 printf 'add\n%s\n%s\n' "$dep_uv" "$dep_sha" > dependency-plan
 printf 'Proton: подготовлен совместимый uhttpd-mod-ubus %s; системные пакеты не меняются.\n' "$dep_uv"
)
if [ "${1:-}" = stage ]; then dep_stage; fi
