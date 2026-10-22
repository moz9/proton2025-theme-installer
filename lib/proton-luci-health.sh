#!/bin/sh
set -eu
command -v curl >/dev/null || exit 81
listen=$(uci -q get uhttpd.main.listen_http | awk '{print $1}')
scheme=http
if [ -z "$listen" ]; then listen=$(uci -q get uhttpd.main.listen_https | awk '{print $1}'); scheme=https; fi
port=${listen##*:}
case "$port" in ''|*[!0-9]*) exit 82;; esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || exit 82
# Self-signed TLS is accepted only on the router's own loopback address.
code=$(curl --noproxy '*' -k -sSL --connect-timeout 3 --max-time 10 --max-filesize 1048576 \
 -D luci-health.headers -w '%{http_code}' "${scheme}://127.0.0.1:${port}/cgi-bin/luci/" -o luci-health.html) || exit 83
[ "$(wc -c < luci-health.html)" -ge 100 ] || exit 83
case "$code" in
 200) grep -qiE 'luci|proton' luci-health.html || exit 83;;
 403)
  # Current LuCI returns 403 for a successfully rendered unauthenticated login.
  # A generic forbidden/error response must never pass this health check.
  tr -d '\r' < luci-health.headers | grep -qi '^x-luci-login-required: yes$' || exit 83
  grep -q 'name="luci_username"' luci-health.html || exit 83
  grep -q 'name="luci_password"' luci-health.html || exit 83;;
 *) exit 83;;
esac
modern=/luci-static/proton2025/css/cascade.css
legacy=/luci-static/proton2025/cascade.css
layout=${PROTON_HEALTH_LAYOUT:-auto}
case "$layout" in auto|modern) :;; *) exit 84;; esac
# 1.3 used /cascade.css, 1.4 uses /css/cascade.css. Check the stylesheet
# actually rendered by Proton, never an arbitrary URL supplied by HTML.
rendered=$(grep -oE 'href="/luci-static/proton2025/(css/)?cascade\.css[^" ]*"' luci-health.html | head -n 1 | sed 's/^href="//; s/"$//; s/?.*$//')
if [ "$layout" = modern ]; then
 [ -z "$rendered" ] || [ "$rendered" = "$modern" ] || exit 84
 css=$modern
else
 case "$rendered" in "$modern"|"$legacy") css=$rendered;; '') css=$modern;; *) exit 84;; esac
fi
code=$(curl --noproxy '*' -k -sS --connect-timeout 3 --max-time 10 --max-filesize 1048576 \
 -w '%{http_code}' "${scheme}://127.0.0.1:${port}${css}" -o theme-health.css) || exit 84
# An installed but inactive legacy theme has no reference in the login page.
# Only an explicit 404 permits the old layout probe, never network/HTTP 5xx.
if [ "$layout" = auto ] && [ -z "$rendered" ] && [ "$code" = 404 ]; then
 code=$(curl --noproxy '*' -k -sS --connect-timeout 3 --max-time 10 --max-filesize 1048576 \
  -w '%{http_code}' "${scheme}://127.0.0.1:${port}${legacy}" -o theme-health.css) || exit 84
fi
[ "$code" = 200 ] || exit 84
[ "$(wc -c < theme-health.css)" -ge 100 ] || exit 84
if [ "${PROTON_HEALTH_UBUS:-0}" = 1 ]; then
 code=$(curl --noproxy '*' -k -sS --connect-timeout 3 --max-time 10 --max-filesize 65536 \
  -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"list","params":["00000000000000000000000000000000"]}' \
  -w '%{http_code}' "${scheme}://127.0.0.1:${port}/ubus" -o ubus-health.json) || exit 85
 [ "$code" = 200 ] || exit 85
 if command -v jsonfilter >/dev/null; then
  [ "$(jsonfilter -i ubus-health.json -e '@.jsonrpc')" = 2.0 ] && [ "$(jsonfilter -i ubus-health.json -e '@.id')" = 1 ] || exit 85
  result=$(jsonfilter -i ubus-health.json -e '@.result' -e '@.error.code') || exit 85
  [ -n "$result" ] || exit 85
 else
  jq -e '.jsonrpc=="2.0" and .id==1 and (has("result") or .error.code==-32002)' ubus-health.json >/dev/null || exit 85
 fi
fi
printf 'PROTON_HEALTH_OK\n'
