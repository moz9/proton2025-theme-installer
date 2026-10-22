#!/bin/sh
# End-to-end standalone update with real archives/transaction, fake network/PM.
set -eu
base=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
original_path=$PATH
for mode in success health_failure; do
 root=$work/$mode; jobbase=$root/root/routerdesk
 mkdir -p "$root/bin" "$root/etc/config" "$root/www/luci-static/proton2025" "$root/tmp" "$root/payload/www/luci-static/proton2025" "$root/control" "$root/archive" "$jobbase"
 chmod 700 "$jobbase"
 printf old > "$root/www/luci-static/proton2025/theme.css"
 printf 'config core main\n option mediaurlbase /luci-static/proton2025\n' > "$root/etc/config/luci"
 printf settings > "$root/etc/config/proton2025"
 printf 'config uhttpd main\n option ubus_prefix /ubus\n' > "$root/etc/config/uhttpd"
 printf 1.4.2 > "$root/version"
 printf new > "$root/payload/www/luci-static/proton2025/theme.css"
 printf 'Package: luci-theme-proton2025\nVersion: 1.4.4\nDepends: libc, luci-base, uhttpd-mod-ubus\n' > "$root/control/control"
 tar -czf "$root/archive/data.tar.gz" -C "$root/payload" .
 tar -czf "$root/archive/control.tar.gz" -C "$root/control" .
 tar -czf "$root/package.ipk" -C "$root/archive" control.tar.gz data.tar.gz
 cat > "$root/bin/opkg" <<'EOF'
#!/bin/sh
set -eu
while [ "${1#--}" != "$1" ]; do case "$1" in --offline-root) shift 2;; *) shift;; esac; done
case "$1" in
 status)
  if [ "$2" = luci-theme-proton2025 ]; then v=$(cat "$TEST_ROOT/version"); else v=1.0-r1; fi
  printf 'Package: %s\nVersion: %s\nStatus: install user installed\n' "$2" "$v";;
 files) printf '/www/luci-static/proton2025/theme.css\n';;
 install)
  case "$*" in *old-package*) printf 1.4.2 > "$TEST_ROOT/version"; printf old > "$TEST_ROOT/www/luci-static/proton2025/theme.css";;
   *) printf 1.4.4 > "$TEST_ROOT/version"; printf new > "$TEST_ROOT/www/luci-static/proton2025/theme.css";; esac;;
 *) exit 1;;
esac
EOF
 cat > "$root/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in changes) exit 0;; *ubus_prefix*) echo /ubus;; *) exit 1;; esac
EOF
 chmod +x "$root/bin/"*
 sed -e "s|/root/routerdesk|$jobbase|g" -e "s|/tmp/routerdesk-operation.lock|$root/tmp/routerdesk-operation.lock|g" "$base/install-proton2025-theme.sh" > "$root/installer.sh"
 sed -e "s|^ROOT=''|ROOT='$root'|" -e "s|^JOB_BASE=/root/routerdesk|JOB_BASE='$jobbase'|" -e 's/^TIMEOUT=180/TIMEOUT=8/' "$base/lib/proton-transaction.sh" > "$root/transaction.sh"
 sed "s|^DEP_ROOT=''|DEP_ROOT='$root'|" "$base/lib/proton-dependencies.sh" > "$root/dependencies.sh"
 export TEST_ROOT=$root TEST_MODE=$mode PATH="$root/bin:$original_path" INSTALLER_DIR=$base
 if sh -s > "$root/log" 2>&1 <<'RUN'
  PROTON2025_LIBRARY_ONLY=1 . "$TEST_ROOT/installer.sh"
  load_backend() {
   case "$1" in proton-transaction.sh) cp "$TEST_ROOT/transaction.sh" "$2";; proton-dependencies.sh) cp "$TEST_ROOT/dependencies.sh" "$2";;
    proton-luci-health.sh) printf '#!/bin/sh\n[ "$TEST_MODE" != health_failure ] || [ "$(cat "$TEST_ROOT/version")" = 1.4.2 ]\n' > "$2";; esac
  }
  download() { case "$1" in *.ipk) cp "$TEST_ROOT/package.ipk" "$2";; *) printf metadata > "$2";; esac; }
  select_asset() { printf 'https://fixture.invalid/package.ipk\nsha256:%s\n' "$(sha256sum "$TEST_ROOT/package.ipk" | cut -d ' ' -f1)"; }
  export manager=opkg PROTON2025_VERSION=v1.4.4
  update_existing 1.4.2
RUN
 then rc=0; else rc=$?; fi
 set -- "$jobbase/"*/state
 [ "$#" = 1 ] && [ -f "$1" ] || { cat "$root/log"; exit 1; }
 case "$mode" in
  success) [ "$rc" = 0 ] && [ "$(cat "$1")" = confirmed ] && [ "$(cat "$root/version")" = 1.4.4 ] || { cat "$root/log"; exit 1; };;
  health_failure) [ "$rc" != 0 ] && [ "$(cat "$1")" = rolled_back ] && [ "$(cat "$root/version")" = 1.4.2 ] || { cat "$root/log"; exit 1; };;
 esac
 [ ! -e "$root/tmp/routerdesk-operation.lock" ]
 echo "PASS standalone upgrade: $mode"
 # Let the independent watchdog finish against its preserved terminal state.
 sleep 9
done
