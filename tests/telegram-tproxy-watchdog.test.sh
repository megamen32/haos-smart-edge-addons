#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$repo_dir/.test-tmp/telegram-tproxy-watchdog"
watchdog="$repo_dir/transparent-smart-edge/rootfs/usr/bin/telegram-tproxy-watchdog.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

setup_stubs() {
    local dir="$1"
    mkdir -p "$dir/bin"
    cat >"$dir/bin/nft" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "list table" ]]; then
    if [[ -f "$(dirname "$0")/../nft-table-present" ]]; then exit 0; fi
    exit 1
fi
exit 0
SH
    cat >"$dir/bin/ip" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "route show table" ]]; then
    if [[ -f "$(dirname "$0")/../route-table-present" ]]; then
        printf 'local default dev lo scope host\n'
    fi
    exit 0
fi
exit 0
SH
    cat >"$dir/policy-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$(dirname "$0")/apply.log"
if [[ -f "$(dirname "$0")/apply-fails" ]]; then exit 77; fi
touch "$(dirname "$0")/../nft-table-present" "$(dirname "$0")/../route-table-present"
exit 0
SH
    chmod 0755 "$dir/bin/nft" "$dir/bin/ip" "$dir/policy-stub.sh"
}

run_once() {
    local dir="$1"; shift
    (cd "$dir" && PATH="$dir/bin:$PATH" POLICY_BIN="$dir/policy-stub.sh" \
        bash "$watchdog" "$@" --once >"$dir/watchdog.out" 2>&1)
}

# Case 1: policy present -> no apply, exit 0.
rm -rf "$work_dir"; mkdir -p "$work_dir"
setup_stubs "$work_dir"
touch "$work_dir/nft-table-present" "$work_dir/route-table-present"
run_once "$work_dir" 12555 || fail "case 1: watchdog exited non-zero on healthy policy"
[[ ! -s "$work_dir/apply.log" ]] || fail "case 1: apply invoked although policy present"

# Case 2: policy missing -> apply invoked once with the port, exit 0.
rm -rf "$work_dir"; mkdir -p "$work_dir"
setup_stubs "$work_dir"
run_once "$work_dir" 12555 || fail "case 2: watchdog exited non-zero on missing policy"
{ [[ "$(wc -l <"$work_dir/apply.log")" -eq 2 ]] \
    && grep -qx "12555" "$work_dir/apply.log" \
    && grep -qxe "--apply" "$work_dir/apply.log"; } \
    || fail "case 2: unexpected apply invocation: $(tr '\n' ' ' <"$work_dir/apply.log")"
grep -q 'policy missing; re-applying' "$work_dir/watchdog.out" \
    || fail "case 2: repair not logged"

# Case 3: apply failing -> logged failure, watchdog still exits 0 in --once.
rm -rf "$work_dir"; mkdir -p "$work_dir"
setup_stubs "$work_dir"
touch "$work_dir/apply-fails"
run_once "$work_dir" 12555 || fail "case 3: watchdog exited non-zero on apply failure"
grep -q 're-apply failed' "$work_dir/watchdog.out" || fail "case 3: apply failure not reported"

rm -rf "$work_dir"
printf 'telegram-tproxy-watchdog tests passed\n'
