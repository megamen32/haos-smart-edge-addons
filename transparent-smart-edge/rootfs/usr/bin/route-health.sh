#!/usr/bin/env bash
# route-health.sh — automatic best-route selection and self-healing for the
# ai-route selector. Every round it probes each regional lane through the
# add-on's own LAN HTTP proxy inbounds (a real end-to-end request to the AI
# endpoint), scores lanes by latency (EWMA) and error streaks, and switches
# the selector via the local clash API when:
#   * the currently selected lane starts erroring (heal), or
#   * another proven lane is >=30% faster for two consecutive rounds.
# The same controller also verifies native Telegram and steers its selector.
# Upstream failure never restarts the healthy DNS/TLS stack.

set -uo pipefail

OPTIONS_PATH="${OPTIONS_PATH:-/data/options.json}"
# shellcheck source=/dev/null
source /usr/lib/transparent-smart-edge-options.sh 2>/dev/null || true
if ! declare -F option >/dev/null 2>&1; then
    option() { printf '%s' "$2"; }
fi

CLASH_API="${ROUTE_HEALTH_CLASH_API:-http://127.0.0.1:9095}"
SELECTOR="${ROUTE_HEALTH_SELECTOR:-ai-route}"
STATE_PATH="${ROUTE_HEALTH_STATE:-/data/route-health-state.json}"
INTERVAL="${ROUTE_HEALTH_INTERVAL:-45}"
PROBE_URL="${ROUTE_HEALTH_PROBE_URL:-https://discord.com/api/v10/gateway}"
CURL="${CURL_BIN:-curl}"
ALL_FAIL_ROUNDS_TO_RESTART="${ROUTE_HEALTH_ALL_FAIL_ROUNDS:-3}"
SWITCH_RATIO_NUM="${ROUTE_HEALTH_SWITCH_RATIO_NUM:-7}"
SWITCH_RATIO_DEN="${ROUTE_HEALTH_SWITCH_RATIO_DEN:-10}"
ONCE="${ROUTE_HEALTH_ONCE:-false}"
TELEGRAM_PROBE="${ROUTE_HEALTH_TELEGRAM_PROBE:-/usr/bin/route-probe}"
TELEGRAM_ENABLED="${ROUTE_HEALTH_TELEGRAM_ENABLED:-$(option telegram_tproxy_enabled false)}"
TELEGRAM_STATE="${ROUTE_HEALTH_TELEGRAM_STATE:-/data/telegram-route-health-state.json}"
AI_ENABLED="${ROUTE_HEALTH_AI_ENABLED:-$(option ai_route_enabled true)}"
PROBE_KIND=ai
STICKY=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENAI_POLICY="${OPENAI_US_POLICY_PATH:-$SCRIPT_DIR/../../etc/transparent-smart-edge/openai-us-policy.json}"
OPENAI_CONFIG="${ROUTE_HEALTH_OPENAI_CONFIG:-/data/singbox-runtime.json}"
OPENAI_STATE="${ROUTE_HEALTH_OPENAI_STATE:-/data/openai-route-health-state.json}"


lanes_default="$(option lan_fi_proxy_outbound_tag fi-helsinki):$(option lan_fi_proxy_port 3126) $(option lan_de_proxy_outbound_tag de-regional):$(option lan_de_proxy_port 3128)"
LANES="${ROUTE_HEALTH_LANES:-$lanes_default}"

log() { printf 'route-health: %s\n' "$*"; }

state_read() {
    if [[ -s "$STATE_PATH" ]] && jq -e 'type == "object"' "$STATE_PATH" >/dev/null 2>&1; then
        cat "$STATE_PATH"
    else
        printf '{}'
    fi
}

state_write() {
    jq '.' <<<"$1" >/dev/null 2>&1 || return 0
    printf '%s' "$1" >"${STATE_PATH}.tmp" && mv -f "${STATE_PATH}.tmp" "$STATE_PATH"
}

lane_field() { # state tag field
    jq -r --arg t "$2" --arg f "$3" '(.lanes[$t][$f] // 0)' <<<"$1" 2>/dev/null
}

probe_lane() { # port -> "ok <seconds>" | "err"
    local out code trace country=unknown seconds
    if [[ "$PROBE_KIND" == openai ]]; then
        # Probe the same exact private per-exit inbound for country and service.
        # No auth, conversations, cookies, retries or direct-route fallback.
        trace="$("$CURL" -fsS --noproxy '' --max-filesize 8192 -m 6 \
          -x "http://127.0.0.1:$1" "$OPENAI_COUNTRY_URL" 2>/dev/null)" || trace=""
        # Unknown geography cannot qualify for US priority; a working tunnel
        # may still be used as a fallback when no verified US exit is healthy.
        country="$(printf '%s\n' "$trace" | tr -d '\r' | awk -F= '$1=="loc" {count++; if (NF==2 && length($2)==2 && $2 ~ /^[A-Z][A-Z]$/ && $2!="XX" && $2!="ZZ") loc=$2} END {print (count==1 && loc!="") ? loc : "unknown"}')"
    fi
    if [[ "$PROBE_KIND" == telegram ]]; then
        "$TELEGRAM_PROBE" -proxy "127.0.0.1:$1" -timeout 3s 2>/dev/null || printf 'err'
        return
    fi
    out="$("$CURL" -s -o /dev/null -w '%{http_code} %{time_total}' --noproxy '' -x "http://127.0.0.1:$1" -m 6 "$PROBE_URL" 2>/dev/null)" || { printf 'err'; return; }
    code="${out%% *}"
    seconds="${out##* }"
    if [[ "$code" =~ ^2[0-9][0-9]$ && "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [[ "$PROBE_KIND" == openai ]]; then printf 'ok %s %s' "$seconds" "$country";
        else printf 'ok %s' "$seconds"; fi
    else printf 'err'; fi
}

clash_get_now() {
    "$CURL" -s -m 3 "$CLASH_API/proxies/$SELECTOR" 2>/dev/null | jq -r '.now // empty' 2>/dev/null
}

clash_select() { # tag
    "$CURL" -fsS -m 3 -X PUT -H 'Content-Type: application/json' \
        -d "{\"name\":\"$1\"}" "$CLASH_API/proxies/$SELECTOR" >/dev/null 2>&1
}

pid_of_singbox() {
    if [[ -n "${SINGBOX_PID:-}" ]] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
        printf '%s' "$SINGBOX_PID"
        return
    fi
    pgrep -o -x sing-box 2>/dev/null | head -1 || true
}

wait_for_clash() {
    local i
    for i in $(seq 1 30); do
        [[ -n "$(clash_get_now)" ]] && return 0
        sleep 1
    done
    return 1
}

score_of() { # ewma_ms err_streak -> score
    awk -v e="$1" -v s="$2" 'BEGIN { pen = (s > 0) ? 3 : 1; printf "%.0f", e * pen }'
}

round() {
    local state chosen all_fail line="" best_tag="" best_score=0 best_priority=2 any_ok=false
    local spec tag port res ms ewma errs oks score country priority seconds
    state="$(state_read)"
    chosen="$(jq -r '.chosen // empty' <<<"$state" 2>/dev/null)"
    all_fail="$(jq -r '.all_fail_rounds // 0' <<<"$state" 2>/dev/null)"

    for spec in $LANES; do
        tag="${spec%%:*}"
        port="${spec##*:}"
        res="$(probe_lane "$port")"
        country=unknown; priority=1
        ewma="$(lane_field "$state" "$tag" ewma_ms)"; ewma="${ewma%%.*}"
        [[ "$ewma" =~ ^[0-9]+$ ]] || ewma=0
        errs="$(lane_field "$state" "$tag" err_streak)"
        [[ "$errs" =~ ^[0-9]+$ ]] || errs=0
        oks="$(lane_field "$state" "$tag" ok_streak)"
        [[ "$oks" =~ ^[0-9]+$ ]] || oks=0
        if [[ "$res" == ok* ]]; then
            seconds="${res#ok }"
            if [[ "$PROBE_KIND" == openai ]]; then
                country="${seconds##* }"; seconds="${seconds% *}"
                [[ "$country" == US ]] && priority=0
            fi
            ms="$(awk -v t="$seconds" 'BEGIN { printf "%.0f", t * 1000 }')"
            if (( ewma == 0 )); then ewma=$ms; else ewma=$(( (7 * ewma + 3 * ms) / 10 )); fi
            oks=$((oks + 1)); errs=0
            any_ok=true
        else
            errs=$((errs + 1)); oks=0
            if (( ewma > 0 )); then ewma=$(( ewma * 3 )); else ewma=10000; fi
            (( ewma > 30000 )) && ewma=30000
            ms=0
        fi
        state="$(jq --arg t "$tag" --argjson e "$ewma" --argjson r "$errs" --argjson o "$oks" \
            --arg country "$country" '.lanes[$t] = {ewma_ms:$e, err_streak:$r, ok_streak:$o, country:$country}' <<<"$state")"
        line+="${tag}=${ms}ms/$([[ "$res" == ok* ]] && printf 'ok' || printf "err${errs}") "
        score="$(score_of "$ewma" "$errs")"
        if [[ "$res" == ok* ]]; then
            # Geographic preference is lexicographic, not a latency penalty:
            # any healthy US exit outranks every non-US/unknown exit.
            if [[ -z "$best_tag" ]] || (( priority < best_priority )) ||
               { (( priority == best_priority )) && (( score < best_score )); }; then
                best_tag="$tag"; best_score=$score; best_priority=$priority
            fi
        fi
    done

    if [[ "$any_ok" != true ]]; then
        all_fail=$((all_fail + 1))
        state="$(jq --argjson a "$all_fail" '.all_fail_rounds = $a' <<<"$state")"
        if [[ "$PROBE_KIND" == openai ]]; then
            state="$(jq '.available = false | .selection_verified = false | .country = "unknown" | .fallback = null' <<<"$state")"
            if [[ "$(clash_get_now)" == openai-us-blocked ]] || \
               { clash_select openai-us-blocked && [[ "$(clash_get_now)" == openai-us-blocked ]]; }; then
                state="$(jq '.chosen = "openai-us-blocked" | .selection_verified = true' <<<"$state")"
            fi
            log "OpenAI: no healthy proxy exit in any configured region; local reject (no direct fallback)"
        fi
        state_write "$state"
        log "round: $line| ALL LANES FAILING (${all_fail}/${ALL_FAIL_ROUNDS_TO_RESTART})"
        log "${SELECTOR}: upstreams unavailable; preserving the local stack and existing streams"
        return 0
    fi
    state="$(jq '.all_fail_rounds = 0' <<<"$state")"
    if [[ "$PROBE_KIND" == openai ]]; then
        state="$(jq '.available = true | .preference = "US-first" | .selection_verified = false' <<<"$state")"
    fi

    local now cur_tag cur_ewma cur_errs cur_oks cur_score best_oks action cur_country cur_priority
    now="$(clash_get_now)"
    [[ -n "$now" ]] || now="$chosen"
    cur_tag="$now"
    cur_ewma="$(lane_field "$state" "$cur_tag" ewma_ms)"; cur_ewma="${cur_ewma%%.*}"
    cur_errs="$(lane_field "$state" "$cur_tag" err_streak)"
    cur_oks="$(lane_field "$state" "$cur_tag" ok_streak)"
    cur_score="$(score_of "${cur_ewma:-0}" "${cur_errs:-0}")"
    best_oks="$(lane_field "$state" "$best_tag" ok_streak)"
    cur_country="$(lane_field "$state" "$cur_tag" country)"; cur_priority=1
    if [[ "$PROBE_KIND" == openai ]]; then
        [[ "$cur_country" == US ]] && cur_priority=0
        [[ " $LANES " == *" $cur_tag:"* ]] || cur_oks=0
    fi

    action="keep"
    if [[ -z "$cur_tag" || "${cur_oks:-0}" -eq 0 ]]; then
        action="switch"
    elif [[ "$PROBE_KIND" == openai ]] && (( best_priority < cur_priority )); then
        # Return from FI/DE/another fallback as soon as a US exit proves
        # healthy, even if its RTT is higher. Hysteresis applies within a tier.
        action="switch"
    elif [[ "$STICKY" != true && "$best_tag" != "$cur_tag" ]] && (( best_oks >= 2 )); then
        if (( cur_score == 0 )) || (( SWITCH_RATIO_DEN * best_score <= SWITCH_RATIO_NUM * cur_score )); then
            action="switch"
        fi
    fi

    if [[ "$action" == switch && -n "$best_tag" && "$best_tag" != "$cur_tag" ]]; then
        if clash_select "$best_tag" && { [[ "$PROBE_KIND" != openai ]] || [[ "$(clash_get_now)" == "$best_tag" ]]; }; then
            state="$(jq --arg c "$best_tag" '.chosen = $c' <<<"$state")"
            log "SWITCH ${SELECTOR} -> ${best_tag} (from ${cur_tag:-none}, score ${cur_score}ms -> ${best_score}ms) | $line"
        else
            log "switch to ${best_tag} via clash API failed; keeping ${cur_tag:-none}"
        fi
    else
        log "round: $line| chosen=${cur_tag:-none} best=${best_tag}(${best_score}ms) -> keep"
    fi
    if [[ "$PROBE_KIND" == openai ]]; then
        local verified_now
        verified_now="$(clash_get_now)"
        if [[ "$(lane_field "$state" "$verified_now" ok_streak)" =~ ^[1-9][0-9]*$ ]] && \
           [[ " $LANES " == *" $verified_now:"* ]]; then
            state="$(jq --arg c "$verified_now" '.chosen = $c | .selection_verified = true
              | .country = .lanes[$c].country | .fallback = (.country != "US")' <<<"$state")"
        fi
    fi
    state_write "$state"
}

openai_round() {
    local SELECTOR=openai-us-route STATE_PATH="$OPENAI_STATE" PROBE_KIND=openai STICKY=false
    local LANES PROBE_URL OPENAI_COUNTRY_URL
    [[ -s "$OPENAI_CONFIG" ]] || return 0
    # Read only nonsecret tags/ports. Probes bypass the selector itself.
    LANES="$(jq -er '
      . as $r
      | [.outbounds[]? | select(.tag == "openai-us-route" and .type == "selector")] as $groups
      | if ($groups | length) == 0 then "" else
        if ($groups | length) != 1 then error("duplicate OpenAI selector") else . end
        | [$groups[0].outbounds[] | select(. != "openai-us-blocked")] as $wanted
        | [.inbounds[]? | select((.tag | test("^openai-us-probe-[0-9]+$")) and .listen == "127.0.0.1")
          | . as $i
          | [$r.route.rules[]? | select(.inbound == [$i.tag]) | .outbound] as $route
          | if ($route | length) == 1 and ($route[0] | test("^[A-Za-z0-9_.-]+$"))
              and ($wanted | index($route[0])) != null
              and ([$r.outbounds[]? | select(.tag == $route[0])
                | select(.type as $kind | ["vless","vmess","trojan","shadowsocks","hysteria2","tuic","wireguard"] | index($kind) != null)] | length) == 1
              and ($i.listen_port | type) == "number"
              and $i.listen_port > 18100 and $i.listen_port < 65536
            then {tag:$route[0],port:$i.listen_port}
            else error("unverified OpenAI health inbound") end] as $pairs
        | if ($pairs | length) != ($wanted | length) or ($pairs | length) == 0
            or ($pairs | map(.tag) | unique | length) != ($wanted | length)
            or ($pairs | map(.port) | unique | length) != ($wanted | length)
          then error("incomplete OpenAI health topology")
          else [$pairs[] | .tag + ":" + (.port | tostring)] | join(" ") end
        end' "$OPENAI_CONFIG" 2>/dev/null)" || {
          clash_select openai-us-blocked || true
          log 'OpenAI health topology invalid; refusing an unverified exit'
          return 1
        }
    [[ -n "$LANES" ]] || return 0
    PROBE_URL="$(jq -er '.probeUrl' "$OPENAI_POLICY" 2>/dev/null)" || return 1
    OPENAI_COUNTRY_URL="$(jq -er '.countryProbeUrl' "$OPENAI_POLICY" 2>/dev/null)" || return 1
    [[ "$PROBE_URL" == https://chatgpt.com/robots.txt && "$OPENAI_COUNTRY_URL" == https://www.cloudflare.com/cdn-cgi/trace ]] || {
        clash_select openai-us-blocked || true
        log 'OpenAI health URL policy invalid; no arbitrary probes'
        return 1
    }
    round
}

telegram_round() {
    local SELECTOR=telegram-route STATE_PATH="$TELEGRAM_STATE" PROBE_KIND=telegram STICKY=true
    if [[ ! -x "$TELEGRAM_PROBE" ]]; then
        log "native Telegram probe unavailable; selection is not verified"
        return 1
    fi
    round
}

main() {
    log "started: lanes=[${LANES// /, }] probe=${PROBE_URL} every ${INTERVAL}s"
    if ! wait_for_clash; then
        log "clash API not reachable at ${CLASH_API}; selector control unavailable this start"
    fi
    local state saved
    state="$(state_read)"
    saved="$(jq -r '.chosen // empty' <<<"$state" 2>/dev/null)"
    if [[ -n "$saved" && "$saved" != "$(clash_get_now)" ]]; then
        clash_select "$saved" && log "restored saved selection: ${saved}"
    fi
    while true; do
        if [[ "$AI_ENABLED" == true ]]; then round; fi
        openai_round
        if [[ "$TELEGRAM_ENABLED" == true ]]; then telegram_round; fi
        [[ "$ONCE" == true ]] && break
        sleep "$INTERVAL"
    done
}

main "$@"
