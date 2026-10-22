#!/bin/sh
# Local two-phase transaction. Upstream package identity, dependency
# and manifest validation is the desktop caller's responsibility. No downloads.
set -eu
umask 077
ROOT=''
JOB_BASE=/root/routerdesk
TIMEOUT=180
PACKAGE=luci-theme-proton2025
GLOBAL_LOCK=$ROOT/tmp/routerdesk-operation.lock
job=$(pwd -P)
fail() { printf '%s\n' "Proton transaction: $*" >&2; exit 1; }
pid_token() {
 [ -r "/proc/$1/stat" ] || return 1
 token_value=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}')
 case "$token_value" in ''|*[!0-9]*) return 1;; esac
 printf '%s\n' "$token_value"
}
process_matches() {
 case "$1:$2" in *[!0-9:]*|:*|*:) return 1;; esac
 kill -0 "$1" 2>/dev/null && [ "$(pid_token "$1" 2>/dev/null || true)" = "$2" ]
}
process_tree() (
 tree_pid=$1; tree_token=$2; tree_output=$3
 process_matches "$tree_pid" "$tree_token" || exit 0
 printf '%s %s\n' "$tree_pid" "$tree_token" >> "$tree_output"
 for tree_stat in /proc/[0-9]*/stat; do
  [ -r "$tree_stat" ] || continue
  tree_parent=$(sed 's/^.*) //' "$tree_stat" 2>/dev/null | awk '{print $2}')
  [ "$tree_parent" = "$tree_pid" ] || continue
  tree_child=${tree_stat#/proc/}; tree_child=${tree_child%/stat}
  tree_child_token=$(pid_token "$tree_child" 2>/dev/null || true)
  [ -z "$tree_child_token" ] || process_tree "$tree_child" "$tree_child_token" "$tree_output"
 done
)
bounded() (
 bound_seconds=$1; shift
 case "$bound_seconds" in ''|*[!0-9]*) exit 1;; esac
 [ "$bound_seconds" -gt 0 ] && pid_token "$$" >/dev/null || exit 1
 "$@" &
 bound_pid=$!
 bound_token=$(pid_token "$bound_pid" 2>/dev/null || true)
 # Very short commands may finish before /proc is inspected. wait retains their
 # exact result and there is no live process to time out in that case.
 if [ -z "$bound_token" ]; then
  if wait "$bound_pid"; then exit 0; else exit "$?"; fi
 fi
 bound_prefix="$job/bounded.$bound_pid"
 rm -f "$bound_prefix.expired" "$bound_prefix.pids"
 (
  trap '' HUP
  sleep "$bound_seconds"
  process_matches "$bound_pid" "$bound_token" || exit 0
  printf 'expired\n' > "$bound_prefix.expired"
  # Capture children before TERM, so adoption by init cannot hide a child that
  # ignores TERM. All subsequent signals require the original starttime token.
  : > "$bound_prefix.pids"
  process_tree "$bound_pid" "$bound_token" "$bound_prefix.pids"
  while read -r signal_pid signal_token; do
   process_matches "$signal_pid" "$signal_token" && kill -TERM "$signal_pid" 2>/dev/null || true
  done < "$bound_prefix.pids"
  sleep 5
  while read -r signal_pid signal_token; do
   process_matches "$signal_pid" "$signal_token" && kill -KILL "$signal_pid" 2>/dev/null || true
  done < "$bound_prefix.pids"
 ) </dev/null >/dev/null 2>&1 &
 bound_timer=$!
 bound_timer_token=$(pid_token "$bound_timer" 2>/dev/null || true)
 bound_result=0
 wait "$bound_pid" || bound_result=$?
 if [ -f "$bound_prefix.expired" ]; then
  wait "$bound_timer" || true
  bound_result=124
 else
  process_matches "$bound_timer" "$bound_timer_token" && kill -TERM "$bound_timer" 2>/dev/null || true
  wait "$bound_timer" 2>/dev/null || true
 fi
 rm -f "$bound_prefix.expired" "$bound_prefix.pids"
 exit "$bound_result"
)
dir_meta() {
 if dir_result=$(command stat -c '%a %u' "$1" 2>/dev/null); then printf '%s\n' "$dir_result"; return; fi
 if dir_result=$(busybox stat -c '%a %u' "$1" 2>/dev/null); then printf '%s\n' "$dir_result"; return; fi
 command -v ucode >/dev/null 2>&1 || return 1
 bounded 5 ucode -l fs -e '
  let s=fs.lstat(ARGV[0]);
  if (!s || type(s.mode)!="int" || type(s.uid)!="int") exit(1);
  printf("%o %d\n",s.mode & 4095,s.uid);
 ' "$1"
}
case "$job" in "$JOB_BASE"/*) ;; *) fail 'invalid private transaction directory';; esac
job_id=${job#"$JOB_BASE"/}
case "$job_id" in ''|*[!a-f0-9]* ) fail 'invalid transaction id';; esac
[ "${#job_id}" -ge 12 ] || fail 'transaction id too short'
for dir in "$JOB_BASE" "$job"; do
 [ ! -L "$dir" ] && [ -d "$dir" ] || fail 'symlink transaction directory'
 dir_metadata=$(dir_meta "$dir") || fail 'safe directory metadata provider unavailable'
 [ "${dir_metadata% *}" = 700 ] || fail 'transaction directory must be private (0700)'
 [ "${dir_metadata#* }" = "$(id -u)" ] || fail 'transaction directory owner mismatch'
done
safe_path() {
 case "$1" in /*) ;; *) return 1;; esac
 case "$1" in *'/../'*|*'/./'*|*'//'*|*/..|*/.|*[!a-zA-Z0-9_./+-]*) return 1;; esac
 cursor=$ROOT
 rest=${1#/}
 while [ -n "$rest" ]; do
  component=${rest%%/*}; cursor=$cursor/$component
  [ ! -L "$cursor" ] || return 1
  if [ "$rest" = "$component" ]; then break; fi
  rest=${rest#*/}
 done
}
theme_path() {
 case "$1" in
  # These three exact legacy compatibility files are carried in the upstream
  # APK payload. They are not /lib/apk/db and never authorize another package.
  /lib/apk/packages/luci-theme-proton2025.conffiles|/lib/apk/packages/luci-theme-proton2025.conffiles_static|/lib/apk/packages/luci-theme-proton2025.list) [ "$PM" = apk ]; return;;
  # Upstream 1.4.4 local-package RPC. Keep this exact: other RPC services must
  # not become writable merely because a future package lists them.
  /usr/share/rpcd/ucode/luci.proton-packages) return 0;;
  /usr/share/licenses/luci-theme-proton2025/*|/usr/share/luci/menu.d/luci-theme-proton2025.json|/usr/share/rpcd/acl.d/luci-theme-proton2025.json|/usr/share/rpcd/ucode/luci.proton-search-cache|/usr/share/rpcd/ucode/luci.proton-system|/usr/share/rpcd/ucode/luci.proton-temp|/www/luci-static/resources/menu-dropdowns.js|/www/luci-static/resources/menu-proton2025.core.js|/www/luci-static/resources/menu-proton2025.js|/www/luci-static/resources/menu-search-index.js|/www/luci-static/resources/menu-theme-settings.js|/www/luci-static/resources/router-proton2025.js|/www/luci-static/resources/view/status/proton-temperature.js) return 0;;
  /www/luci-static/proton2025|/www/luci-static/proton2025/*|/usr/lib/lua/luci/view/themes/proton2025|/usr/lib/lua/luci/view/themes/proton2025/*|/usr/share/ucode/luci/template/themes/proton2025|/usr/share/ucode/luci/template/themes/proton2025/*|/usr/share/luci/themes/proton2025.json|/usr/share/rpcd/ucode/luci.proton-settings|/usr/bin/proton2025-download|/usr/bin/proton-update|/etc/config/proton2025|/etc/uci-defaults/*proton*) return 0;;
  *) return 1;;
 esac
}
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
dependency_mode() { if regular dependency-plan; then sed -n '1p' dependency-plan; else printf none; fi; }
dependency_check() {
 case "$(dependency_mode)" in
  none) return 0;;
  keep|add) regular dependencies.sh && regular uhttpd.before && regular uhttpd.expected || return 1;;
  *) return 1;;
 esac
 safe_path /etc/config/uhttpd && regular "$ROOT/etc/config/uhttpd" || return 1
 cmp -s uhttpd.before "$ROOT/etc/config/uhttpd" || return 1
 if [ "$(dependency_mode)" = add ]; then
  . ./dependencies.sh
  dep_version uhttpd-mod-ubus >/dev/null 2>&1 && return 1
  for dep_path in /usr/lib/uhttpd_ubus.so /etc/uci-defaults/00_uhttpd_ubus; do
   safe_path "$dep_path" && [ ! -e "$ROOT$dep_path" ] || return 1
  done
  check_hash "dependency.$ext" "$(sed -n '3p' dependency-plan)" || return 1
 fi
}
dependency_remove() {
 [ "$(dependency_mode)" = add ] || return 0
 . ./dependencies.sh
 if [ "$PM" = opkg ]; then
  dep_installed=$(opkg status uhttpd-mod-ubus | awk '/^Version: / {print $2}')
 else dep_installed=$(dep_version uhttpd-mod-ubus 2>/dev/null || true); fi
 if [ -n "$dep_installed" ]; then
  [ "$dep_installed" = "$(sed -n '2p' dependency-plan)" ] || return 1
  if [ "$PM" = opkg ]; then bounded 30 opkg --offline-root / remove uhttpd-mod-ubus || return 1
  else
   bounded 20 apk del --simulate --no-scripts --no-commit-hooks --no-network --no-cache uhttpd-mod-ubus > dependency-remove-solver.log 2>&1 || return 1
   awk '/^\([0-9]+\/[0-9]+\)/ {n++; if($3!="uhttpd-mod-ubus")bad=1} END {exit bad || n!=1}' dependency-remove-solver.log || return 1
   bounded 30 apk del --no-scripts --no-commit-hooks --no-network --no-cache uhttpd-mod-ubus || return 1
  fi
 fi
 dep_version uhttpd-mod-ubus >/dev/null 2>&1 && return 1
 for dep_path in /usr/lib/uhttpd_ubus.so /etc/uci-defaults/00_uhttpd_ubus; do
  safe_path "$dep_path" || return 1
  if [ -e "$ROOT$dep_path" ]; then regular "$ROOT$dep_path" && rm -f "$ROOT$dep_path" || return 1; fi
 done
}
dependency_refresh() {
 [ "$(dependency_mode)" != none ] || return 0
 if [ -x "$ROOT/etc/init.d/uhttpd" ]; then bounded 10 "$ROOT/etc/init.d/uhttpd" restart; fi
}
hash() { sha256sum "$1" | awk '{print $1}'; }
check_hash() { regular "$1" && [ "$(hash "$1")" = "$2" ]; }
state() { if regular state; then cat state; else printf absent; fi; }
set_state() { printf '%s\n' "$1" > state.new; mv state.new state; }
lock() {
 attempts=0
 until mkdir decision.lock 2>/dev/null; do
  attempts=$((attempts + 1)); [ "$attempts" -lt 30 ] || return 1; sleep 1
 done
}
unlock() { rmdir decision.lock; }
global_acquire() {
 safe_path /tmp/routerdesk-operation.lock || return 1
 mkdir "$GLOBAL_LOCK" 2>/dev/null || return 1
 printf '%s' "$job_id" > "$GLOBAL_LOCK/owner"
}
global_release() {
 if [ ! -L "$GLOBAL_LOCK" ] && regular "$GLOBAL_LOCK/owner" && [ "$(cat "$GLOBAL_LOCK/owner")" = "$job_id" ]; then
  rm -f "$GLOBAL_LOCK/owner"; rmdir "$GLOBAL_LOCK"
 fi
}
version() {
 if [ "$PM" = opkg ]; then
  opkg status "$PACKAGE" | awk '/^Version: / {print $2}'
 else
  # APK 3 info -v prints description/URL/size, not the installed version.
  # list --installed uses NAME-VERSION as its first field. Require one exact
  # package prefix and the installed marker; never accept a description row.
  apk list --installed "$PACKAGE" | awk -v package="$PACKAGE" '
   index($1,package "-")==1 && $NF=="[installed]" {
    value=substr($1,length(package)+2);
    if (value ~ /^[0-9][a-zA-Z0-9_.+~:-]*$/) {version=value; count++}
   }
   END {if (count==1) print version; else exit 1}'
 fi
}
installed_paths() {
 if [ "$PM" = opkg ]; then
  opkg files "$PACKAGE" | sed -n '/^\//p'
 else
  apk info -L "$PACKAGE" | awk '$0 ~ "^[a-zA-Z0-9_][-a-zA-Z0-9_./+]*$" {print "/"$0}'
 fi
}
no_pending() {
 pending=$(uci changes) || return 1
 [ -z "$pending" ]
}
read_metadata() {
 regular metadata && regular integrity.sha256 || fail 'missing prepared metadata'
 sha256sum -c integrity.sha256 >/dev/null 2>&1 || fail 'prepared backup/manifest integrity mismatch'
 PM=$(sed -n '1p' metadata); OLD_VERSION=$(sed -n '2p' metadata); NEW_VERSION=$(sed -n '3p' metadata)
 OLD_SHA256=$(sed -n '4p' metadata); NEW_SHA256=$(sed -n '5p' metadata)
 case "$PM" in opkg) ext=ipk;; apk) ext=apk;; *) fail 'invalid stored package manager';; esac
 check_hash "old-package.$ext" "$OLD_SHA256" || fail 'old package changed'
 case "${1:-}" in rollback) ;; *) check_hash "new-package.$ext" "$NEW_SHA256" || fail 'new package changed';; esac
}
apk_manifest() {
 [ "$PM" = apk ] || fail 'missing verified new payload manifest'
 [ ! -e payload-manifest ] || fail 'unexpected APK extraction directory'
 mkdir payload-manifest
 apk extract --allow-untrusted --destination "$job/payload-manifest" "$job/new-package.apk" > manifest-extract.log 2>&1 || fail 'APK extract unsupported or failed'
 [ -z "$(find payload-manifest -type l -print)" ] || fail 'APK symlink payload refused'
 find payload-manifest -type f -print | sed 's|^payload-manifest| |' | sed 's|^ /|/|' | sort -u > new-paths.txt
}
check_paths() {
 while IFS= read -r path; do
  safe_path "$path" && theme_path "$path" || fail "unsafe or non-theme path: $path"
  if [ -e "$ROOT$path" ] && [ ! -d "$ROOT$path" ]; then
   grep -Fxq "$path" current-paths.txt || fail "unknown existing file ownership: $path"
  fi
 done < new-paths.txt
 while IFS= read -r path; do
  safe_path "$path" || fail "unsafe installed theme path: $path"
  # Package inventories include common ancestor directories. These are not
  # payload files to back up or remove, but their symlink safety still matters.
  [ ! -d "$ROOT$path" ] || continue
  theme_path "$path" || fail "non-theme installed file: $path"
 done < current-paths.txt
}
capture() {
 : > backup-paths.txt; : > preserve-paths.txt; : > missing-preserve.txt
 for path in /etc/config/luci /etc/config/proton2025 /usr/bin/proton2025-download /usr/bin/proton-update; do
  safe_path "$path" || fail "unsafe custom/config path: $path"
  if [ -e "$ROOT$path" ]; then
   [ -f "$ROOT$path" ] || fail "non-regular custom/config path: $path"
   printf '%s\n' "${path#/}" >> backup-paths.txt
   case "$path" in
    /etc/config/*) printf '%s\n' "${path#/}" >> preserve-paths.txt;;
    *) grep -Fxq "$path" new-paths.txt || printf '%s\n' "${path#/}" >> preserve-paths.txt;;
   esac
  else printf '%s\n' "${path#/}" >> missing-preserve.txt; fi
 done
 [ -f "$ROOT/etc/config/luci" ] || fail 'missing LuCI configuration'
 while IFS= read -r path; do
  if [ -f "$ROOT$path" ]; then printf '%s\n' "${path#/}" >> backup-paths.txt
  elif [ -e "$ROOT$path" ] && [ ! -d "$ROOT$path" ]; then fail "non-regular installed path: $path"; fi
 done < current-paths.txt
 if [ "$(dependency_mode)" != none ]; then printf 'etc/config/uhttpd\n' >> backup-paths.txt; fi
 cat preserve-paths.txt >> backup-paths.txt
 sort -u backup-paths.txt > backup-paths.sorted; mv backup-paths.sorted backup-paths.txt
 : > new-only.txt
 while IFS= read -r path; do
  [ -e "$ROOT$path" ] || printf '%s\n' "${path#/}" >> new-only.txt
 done < new-paths.txt
 root_dir=${ROOT:-/}
 tar -cf backup.tar -C "$root_dir" -T "$job/backup-paths.txt"
 tar -cf preserve.tar -C "$root_dir" -T "$job/preserve-paths.txt"
 (cd "$root_dir"; while IFS= read -r path; do sha256sum "$path"; done < "$job/backup-paths.txt") > baseline.sha256
 (cd "$root_dir"; while IFS= read -r path; do sha256sum "$path"; done < "$job/preserve-paths.txt") > preserve.sha256
}
restore_preserved() {
 root_dir=${ROOT:-/}
 while IFS= read -r path; do safe_path "/$path" || return 1; done < preserve-paths.txt
 tar -xf preserve.tar -C "$root_dir" || return 1
 while IFS= read -r path; do
  safe_path "/$path" || return 1
  # Do not remove a new package-owned helper: only restore existing preferences.
  case "$path" in etc/config/*) [ ! -e "$ROOT/$path" ] || rm -f "$ROOT/$path";; esac
 done < missing-preserve.txt
 (cd "$root_dir" && sha256sum -c "$job/preserve.sha256" >/dev/null 2>&1)
}
refresh_luci() {
 # Cache invalidation is restricted to known regular LuCI cache files.
 for path in /tmp/luci-indexcache /tmp/luci-modulecache; do
  [ ! -f "$ROOT$path" ] || { safe_path "$path" && rm -f "$ROOT$path"; }
 done
 if [ -x "$ROOT/etc/init.d/rpcd" ]; then
  bounded 10 "$ROOT/etc/init.d/rpcd" restart >/dev/null 2>&1 || return 1
 fi
}
install_package() (
 direction=$1
 if [ "$direction" = old ]; then package_file="$job/old-package.$ext"; target=$OLD_VERSION
 else package_file="$job/new-package.$ext"; target=$NEW_VERSION; fi
 if [ "$PM" = opkg ]; then
  # Official opkg suppresses maintainer scripts in offline-root mode. Root /
  # still uses the live package database, without restoring a global DB snapshot.
  if [ "$direction" = old ]; then bounded 45 opkg --offline-root / --nodeps --force-downgrade --force-reinstall install "$package_file"
  elif [ "$(dependency_mode)" = add ]; then exec opkg --offline-root / --nodeps install "$job/dependency.ipk" "$package_file"
  else exec opkg --offline-root / --nodeps install "$package_file"; fi
 else
  if [ "$direction" = old ]; then
   apk_scope old || exit 1
   bounded 45 apk add --no-scripts --no-commit-hooks --no-network --no-cache --allow-untrusted "$package_file" "$PACKAGE=$target"
  elif [ "$(dependency_mode)" = add ]; then exec apk add --no-scripts --no-commit-hooks --no-network --no-cache --allow-untrusted "$job/dependency.apk" "uhttpd-mod-ubus=$(sed -n '2p' dependency-plan)" "$package_file" "$PACKAGE=$target"
  else exec apk add --no-scripts --no-commit-hooks --no-network --no-cache --allow-untrusted "$package_file" "$PACKAGE=$target"; fi
 fi
)
apk_scope() {
 [ "$PM" = apk ] || return 0
 if [ "$1" = old ]; then scope_file="$job/old-package.apk"; scope_version=$OLD_VERSION
 else scope_file="$job/new-package.apk"; scope_version=$NEW_VERSION; fi
 scope_direction=$1
 if [ "$1" = new ] && [ "$(dependency_mode)" = add ]; then set -- "$job/dependency.apk" "uhttpd-mod-ubus=$(sed -n '2p' dependency-plan)"; else set --; fi
 bounded 20 apk add --simulate --no-scripts --no-commit-hooks --no-network --no-cache --allow-untrusted "$scope_file" "$PACKAGE=$scope_version" "$@" > "solver-$scope_direction.log" 2>&1 || return 1
 awk -v package="$PACKAGE" -v added="$#" '/^\([0-9]+\/[0-9]+\)/ {count++; if ($3 != package && !(added==2 && $2=="Installing" && $3=="uhttpd-mod-ubus")) bad=1} END {exit bad || count==0 || count>(added==2?2:1)}' "solver-$scope_direction.log"
}
stop_installer() {
 if regular installer.pid; then
  pid=$(sed -n '1p' installer.pid); token=$(sed -n '2p' installer.pid)
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  if kill -0 "$pid" 2>/dev/null; then
   [ -n "$token" ] && [ "$(pid_token "$pid")" = "$token" ] || return 1
   # Scripts are disabled, so the package-manager process has no script tree.
   kill -TERM "$pid" 2>/dev/null || true
   attempts=0
   while kill -0 "$pid" 2>/dev/null && [ "$(pid_token "$pid" 2>/dev/null || true)" = "$token" ]; do
    attempts=$((attempts+1)); [ "$attempts" -lt 5 ] || break; sleep 1
   done
   if kill -0 "$pid" 2>/dev/null && [ "$(pid_token "$pid" 2>/dev/null || true)" = "$token" ]; then
    kill -KILL "$pid" 2>/dev/null || true; sleep 1
   fi
   # A zombie is finished and cannot race the restore.
   if [ -r "/proc/$pid/stat" ] && [ "$(pid_token "$pid" 2>/dev/null || true)" = "$token" ]; then
    [ "$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $1}')" = Z ] || return 1
   fi
  fi
 fi
}
rollback_locked() {
 case "$(state)" in confirmed|rolled_back) return 0;; prepared) set_state rolled_back; return 0;; applying|awaiting_confirmation|rolling_back|rollback_failed) ;; *) return 1;; esac
 set_state rolling_back
 if ! stop_installer; then set_state rollback_failed; return 1; fi
 # The watchdog may have armed minutes earlier: validate recovery inputs again
 # immediately before any package-manager or archive restoration operation.
 if ! sha256sum -c integrity.sha256 >/dev/null 2>&1; then set_state rollback_failed; return 1; fi
 package_failed=0
 if check_hash "old-package.$ext" "$OLD_SHA256"; then
  install_package old > rollback-package.log 2>&1 || package_failed=1
 else
  printf 'Old package SHA256 changed; package-manager rollback refused.\n' > rollback-package.log
  package_failed=1
 fi
 root_dir=${ROOT:-/}
 while IFS= read -r path; do
  safe_path "/$path" || { set_state rollback_failed; return 1; }
  [ ! -f "$ROOT/$path" ] || rm -f "$ROOT/$path"
 done < new-only.txt
 while IFS= read -r path; do safe_path "/$path" || { set_state rollback_failed; return 1; }; done < backup-paths.txt
 if ! tar -xf backup.tar -C "$root_dir" || ! restore_preserved ||
  ! (cd "$root_dir" && sha256sum -c "$job/baseline.sha256" >/dev/null 2>&1) ||
  [ "$package_failed" != 0 ] || [ "$(version)" != "$OLD_VERSION" ] || ! dependency_remove || ! dependency_refresh || ! refresh_luci; then
  set_state rollback_failed; return 1
 fi
 set_state rolled_back
}
rollback() {
 lock || fail 'transaction decision busy'
 result=0; rollback_locked || result=1
 # Failed recovery remains an unresolved operation. Keep this job's global
 # lock so another RouterDesk mutation cannot race manual recovery.
 if [ "$result" = 0 ]; then global_release || result=1; fi
 unlock; return "$result"
}
check_space() {
 # Keep the conservative install/rollback reserve. Only retry measurements, never
 # a package operation: flash writeback can change the immediate free estimate.
 space_phase=$1
 space_packages_raw=$(du -k "old-package.$ext" "new-package.$ext") || fail 'cannot measure disk reserve: package sizes'
 space_packages=$(printf '%s\n' "$space_packages_raw" | awk '$1 !~ /^[0-9]+$/ {bad=1} {sum+=$1; count++} END {if (bad || count!=2 || sum<=0) exit 1; printf "%.0f",sum}') || fail 'cannot measure disk reserve: invalid package sizes'
 space_theme=0
 if [ "$space_phase" = prepare ]; then
  while IFS= read -r space_path; do
   if [ -f "$ROOT$space_path" ]; then
    space_file_raw=$(du -k "$ROOT$space_path") || fail 'cannot measure disk reserve: installed file size'
    space_file=$(printf '%s\n' "$space_file_raw" | awk 'NF && $1 ~ /^[0-9]+$/ {n++; size=$1} END {if(n!=1) exit 1; print size}') || fail 'cannot measure disk reserve: invalid installed file size'
    space_theme=$((space_theme+space_file))
   fi
  done < current-paths.txt
 fi
 # Once capture has completed, the archives already consume disk space. Do not
 # count the same theme backup twice in the prepared/apply check.
 space_needed=$((space_packages*6+8192+space_theme))
 if [ "$(dependency_mode)" = add ]; then
  space_dep=$(wc -c < "dependency.$ext") || fail 'cannot measure dependency size'
  case "$space_dep" in ''|*[!0-9]*) fail 'invalid dependency size';; esac
  space_needed=$((space_needed+(space_dep/1024+1)*8+1024))
 fi
 space_attempt=1
 while :; do
  space_df=$(df -Pk "$job") || fail 'cannot measure disk reserve: df failed'
  space_available=$(printf '%s\n' "$space_df" | awk 'END {if(NF!=6 || $4 !~ /^[0-9]+$/) exit 1; print $4}') || fail 'cannot measure disk reserve: invalid df result'
  space_shortfall=$((space_needed-space_available)); [ "$space_shortfall" -ge 0 ] || space_shortfall=0
  space_report="PROTON_SPACE phase=$space_phase attempt=$space_attempt available_kib=$space_available required_kib=$space_needed shortfall_kib=$space_shortfall package_kib=$space_packages theme_backup_kib=$space_theme fixed_reserve_kib=8192"
  printf '%s\n' "$space_report"
  printf '%s\n' "$space_report" >> space-check.log
  [ "$space_available" -lt "$space_needed" ] || return 0
  [ "$space_attempt" -lt 3 ] || fail "Недостаточно места для обновления и отката Proton: свободно $space_available КиБ, требуется $space_needed КиБ, не хватает $space_shortfall КиБ (этап $space_phase; 3 замера). Установка не начата."
  sleep 2
  space_attempt=$((space_attempt+1))
 done
}
case "${1:-}" in
 prepare)
  [ "$(state)" = absent ] || fail 'already prepared'
  [ ! -e "$GLOBAL_LOCK" ] && [ ! -L "$GLOBAL_LOCK" ] || fail 'another RouterDesk operation is active'
  pid_token "$$" >/dev/null || fail 'safe process starttime metadata unavailable'
  case "${PM:-}" in opkg) ext=ipk;; apk) ext=apk;; *) fail 'unsupported package manager';; esac
  for value in "${OLD_VERSION:-}" "${NEW_VERSION:-}"; do
   case "$value" in ''|*[!a-zA-Z0-9_.+~:-]*) fail 'invalid package version';; esac
  done
  for value in "${OLD_SHA256:-}" "${NEW_SHA256:-}"; do
   [ "${#value}" = 64 ] || fail 'missing SHA256'
   case "$value" in *[!a-f0-9]*) fail 'invalid SHA256';; esac
  done
  [ "$(version)" = "$OLD_VERSION" ] || fail 'installed version mismatch or absent theme'
  no_pending || fail 'uncommitted UCI changes'
  check_hash "old-package.$ext" "$OLD_SHA256" || fail 'old package hash mismatch'
  check_hash "new-package.$ext" "$NEW_SHA256" || fail 'new package hash mismatch'
  if [ ! -e new-paths.txt ]; then apk_manifest; fi
  regular new-paths.txt && [ -s new-paths.txt ] || fail 'missing verified new payload manifest'
  installed_paths | sort -u > current-paths.txt
  [ -s current-paths.txt ] || fail 'installed ownership list unavailable'
  check_paths
  dependency_check || fail 'dependency plan changed or is incomplete'
  check_space prepare
  capture
  check_space prepared
  printf '%s\n' "$PM" "$OLD_VERSION" "$NEW_VERSION" "$OLD_SHA256" "$NEW_SHA256" > metadata
  sha256sum metadata new-paths.txt current-paths.txt backup-paths.txt preserve-paths.txt missing-preserve.txt new-only.txt backup.tar preserve.tar baseline.sha256 preserve.sha256 > integrity.sha256
  if [ "$(dependency_mode)" != none ]; then
   sha256sum dependencies.sh dependency-plan uhttpd.before uhttpd.expected >> integrity.sha256
   [ "$(dependency_mode)" != add ] || sha256sum "dependency.$ext" >> integrity.sha256
  fi
  set_state prepared
  printf 'prepared\n';;
 apply)
  read_metadata
  no_pending || fail 'uncommitted UCI changes'
  [ "$(version)" = "$OLD_VERSION" ] || fail 'installed version changed'
  check_paths
  dependency_check || fail 'dependency or web-server settings changed after preparation'
  root_dir=${ROOT:-/}
  (cd "$root_dir" && sha256sum -c "$job/baseline.sha256" >/dev/null 2>&1) || fail 'installed files changed after preparation'
  apk_scope new || fail 'APK solver changes more than the theme or cannot prove scope'
  check_space apply
  lock || fail 'decision busy'
  [ "$(state)" = prepared ] || { unlock; fail 'not prepared'; }
  global_acquire || { unlock; fail 'another RouterDesk operation is active'; }
  set_state applying; unlock
  trap 'trap - EXIT HUP INT TERM; rollback || true' EXIT HUP INT TERM
  printf '%s\n' "$(($(date +%s) + TIMEOUT))" > deadline
  rm -f watchdog.ready
  (trap '' HUP; exec sh "$job/transaction.sh" watchdog) > watchdog.log 2>&1 < /dev/null &
  watchdog=$!
  printf '%s\n' "$watchdog" > watchdog.pid
  attempts=0
  while [ ! -f watchdog.ready ] && kill -0 "$watchdog" 2>/dev/null && [ "$attempts" -lt 5 ]; do
   attempts=$((attempts+1)); sleep 1
  done
  if ! regular watchdog.ready || [ "$(cat watchdog.ready)" != "$watchdog" ] || ! kill -0 "$watchdog" 2>/dev/null; then
   kill -TERM "$watchdog" 2>/dev/null || true
   lock || fail 'decision busy after watchdog failure'
   [ "$(state)" != applying ] || set_state prepared
   global_release; unlock
   trap - EXIT HUP INT TERM
   fail 'independent rollback watchdog did not arm; no installation started'
  fi
  lock || fail 'decision busy before installation'
  [ "$(state)" = applying ] || { unlock; fail 'watchdog already resolved transaction'; }
  install_package new > apply-package.log 2>&1 &
  installer=$!
  printf '%s\n%s\n' "$installer" "$(pid_token "$installer" 2>/dev/null || true)" > installer.pid
  unlock
  wait "$installer" || fail 'package installation failed; rollback requested'
  lock || fail 'decision busy after installation'
  [ "$(state)" = applying ] || { unlock; fail 'watchdog already resolved transaction'; }
  if [ "$(dependency_mode)" != none ]; then
   . ./dependencies.sh
   if ! dep_version uhttpd-mod-ubus >/dev/null; then unlock; fail 'ubus module not installed; rollback requested'; fi
   if [ "$(dependency_mode)" = add ] && [ "$(dep_version uhttpd-mod-ubus)" != "$(sed -n '2p' dependency-plan)" ]; then unlock; fail 'ubus module version mismatch'; fi
   if ! cp -p uhttpd.expected "$ROOT/etc/config/uhttpd" || ! dependency_refresh; then unlock; fail 'web-server verification failed; rollback requested'; fi
  fi
  if [ "$(version)" != "$NEW_VERSION" ] || ! restore_preserved || ! refresh_luci; then
   unlock; fail 'local verification failed; rollback requested'
  fi
  set_state awaiting_confirmation; unlock
  trap - EXIT HUP INT TERM
  printf 'awaiting_confirmation\n';;
 confirm)
  read_metadata; lock || fail 'decision busy'
  if [ "$(dependency_mode)" != none ] && ! cmp -s uhttpd.expected "$ROOT/etc/config/uhttpd"; then unlock; fail 'web-server settings changed'; fi
  if [ "$(state)" != awaiting_confirmation ] || [ "$(version)" != "$NEW_VERSION" ] || ! no_pending ||
   ! (cd "${ROOT:-/}" && sha256sum -c "$job/preserve.sha256" >/dev/null 2>&1); then
   unlock; fail 'confirmation preconditions failed'
  fi
  set_state confirmed; global_release; unlock; printf 'confirmed\n';;
 rollback) read_metadata rollback; rollback; state;;
 status) state; printf '\n';;
 watchdog)
  read_metadata rollback
  regular deadline || fail 'missing rollback deadline'
  due=$(cat deadline)
  case "$due" in ''|*[!0-9]*) fail 'invalid rollback deadline';; esac
  printf '%s\n' "$$" > watchdog.ready
  delay=$((due - $(date +%s)))
  [ "$delay" -le 0 ] || sleep "$delay"
  rollback;;
 *) fail 'expected prepare/apply/confirm/rollback/status';;
esac
