#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$repo_dir/.test-tmp/route-health"
daemon="$repo_dir/transparent-smart-edge/rootfs/usr/bin/route-health.sh"

rm -rf "$work_dir"
mkdir -p "$work_dir"
trap 'rm -rf "$work_dir"' EXIT INT TERM

cat >"$work_dir/curl" <<'SH'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >>"$CURL_LOG"
if [[ "$args" == *"-X PUT"* && "$args" == *"/proxies/ai-route"* ]]; then
    printf 'PUT\n' >>"$CURL_LOG_ACTIONS"
    exit 0
fi
if [[ "$args" == *"/proxies/ai-route"* ]]; then
    cat "$CLASH_NOW_FILE"
    exit 0
fi
port="$(printf '%s\n' "$args" | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 | cut -d: -f2)"
cat "$PROBE_DIR/$port"
SH
chmod 0700 "$work_dir/curl"

cat >"$work_dir/options.json" <<'JSON'
{
  "lan_fi_proxy_port": 3129,
  "lan_de_proxy_port": 3128,
  "lan_us_proxy_port": 3127,
  "lan_fi_proxy_outbound_tag": "fi-helsinki",
  "lan_de_proxy_outbound_tag": "de-regional",
  "lan_us_proxy_outbound_tag": "us-regional"
}
JSON

run_scenario() {
    local name="$1" clash_now="$2" probes="$3" init_state="$4" want_chosen="$5" want_put="$6" want_log="$7"
    local d="$work_dir/$name"
    mkdir -p "$d/probes"
    printf '%s' "$clash_now" >"$d/clash-now"
    cp "$work_dir/options.json" "$d/options.json"
    local port
    for port in 3127 3128 3129; do printf '401 0.500\n' >"$d/probes/$port"; done
    local spec
    for spec in $probes; do printf '%s\n' "${spec#*:}" | tr ',' ' ' >"$d/probes/${spec%%:*}"; done
    printf '%s' "$init_state" >"$d/state.json"
    : >"$d/curl.log"
    : >"$d/actions"

    OPTIONS_PATH="$d/options.json" \
    ROUTE_HEALTH_ONCE=true \
    ROUTE_HEALTH_STATE="$d/state.json" \
    ROUTE_HEALTH_CLASH_API="http://127.0.0.1:9095" \
    CURL_LOG="$d/curl.log" CURL_LOG_ACTIONS="$d/actions" \
    CLASH_NOW_FILE="$d/clash-now" PROBE_DIR="$d/probes" \
    CURL_BIN="$work_dir/curl" \
        bash "$daemon" >"$d/out.log" 2>&1 || { printf '[%s] daemon failed\n' "$name"; cat "$d/out.log"; exit 1; }

    if [[ "$want_put" == yes ]]; then
        [[ -s "$d/actions" ]] || { printf '[%s] expected selector PUT, none recorded\n' "$name"; cat "$d/out.log"; exit 1; }
    else
        [[ ! -s "$d/actions" ]] || { printf '[%s] unexpected selector PUT\n' "$name"; cat "$d/out.log"; exit 1; }
    fi
    if [[ -n "$want_chosen" ]]; then
        local got
        got="$(jq -r '.chosen // empty' "$d/state.json")"
        [[ "$got" == "$want_chosen" ]] || { printf '[%s] chosen=%s want=%s\n' "$name" "$got" "$want_chosen"; cat "$d/out.log"; exit 1; }
    fi
    if [[ -n "$want_log" ]]; then
        grep -qF "$want_log" "$d/out.log" || { printf '[%s] log missing: %s\n' "$name" "$want_log"; cat "$d/out.log"; exit 1; }
    fi
    printf 'scenario %s: PASS\n' "$name"
}

HEALTHY='{"lanes":{"fi-helsinki":{"ewma_ms":200,"err_streak":0,"ok_streak":3},"de-regional":{"ewma_ms":500,"err_streak":0,"ok_streak":3},"us-regional":{"ewma_ms":900,"err_streak":0,"ok_streak":3}},"chosen":"fi-helsinki","all_fail_rounds":0}'

run_scenario keep-healthy '{"now":"fi-helsinki"}' \
  '3129:401,0.200 3128:401,0.500 3127:401,0.900' \
  "$HEALTHY" fi-helsinki no ''

run_scenario heal-current-broken '{"now":"fi-helsinki"}' \
  '3129:000,0.001 3128:401,0.300 3127:401,0.800' \
  "$HEALTHY" de-regional yes 'SWITCH ai-route -> de-regional'

RECOVERED='{"lanes":{"fi-helsinki":{"ewma_ms":200,"err_streak":0,"ok_streak":3},"de-regional":{"ewma_ms":250,"err_streak":0,"ok_streak":0},"us-regional":{"ewma_ms":900,"err_streak":0,"ok_streak":3}},"chosen":"fi-helsinki","all_fail_rounds":0}'
run_scenario hysteresis-first-round '{"now":"fi-helsinki"}' \
  '3129:401,0.600 3128:401,0.100 3127:401,0.800' \
  "$RECOVERED" fi-helsinki no ''

SUSTAINED='{"lanes":{"fi-helsinki":{"ewma_ms":320,"err_streak":0,"ok_streak":3},"de-regional":{"ewma_ms":205,"err_streak":0,"ok_streak":2},"us-regional":{"ewma_ms":900,"err_streak":0,"ok_streak":3}},"chosen":"fi-helsinki","all_fail_rounds":0}'
run_scenario switch-when-sustained '{"now":"fi-helsinki"}' \
  '3129:401,0.600 3128:401,0.100 3127:401,0.800' \
  "$SUSTAINED" de-regional yes 'SWITCH ai-route -> de-regional'

run_scenario all-fail '{"now":"fi-helsinki"}' \
  '3129:000,0.001 3128:000,0.001 3127:000,0.001' \
  '{"lanes":{"fi-helsinki":{"ewma_ms":200,"err_streak":0,"ok_streak":1},"de-regional":{"ewma_ms":500,"err_streak":0,"ok_streak":1},"us-regional":{"ewma_ms":900,"err_streak":0,"ok_streak":1}},"chosen":"fi-helsinki","all_fail_rounds":2}' \
  '' no 'ALL LANES FAILING (3/3)'

printf '%s\n' 'route-health auto-selection contract: PASS'
