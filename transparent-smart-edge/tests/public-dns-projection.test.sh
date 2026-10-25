#!/usr/bin/env bash

# The public DNS profile of the add-on is optional. While it is off, the
# runtime config must stay exactly as it was before: the DoH listener on the
# loopback with the LAN profile and no public listener at all.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fixture="$workdir/config.json"
cat >"$fixture" <<'JSON'
{
  "edgeProfiles": {
    "public": {"enabled": true, "ipv4": "185.240.120.152", "ttl": 60},
    "local": {"enabled": true, "ipv4": "203.0.113.1", "ttl": 60}
  },
  "udpListen": {"host": "192.168.2.100", "port": 53, "profile": "local"},
  "dohListen": {"host": "127.0.0.1", "port": 8053, "profile": "public"},
  "dotListen": {"host": "127.0.0.1", "port": 8853, "profile": "public"},
  "publicDnsListen": {"host": "192.168.2.100", "port": 5354, "profile": "public"},
  "tls": {"certFile": "/old/cert.pem", "keyFile": "/old/key.pem"},
  "sync": {"url": "http://old"}
}
JSON

# The projection is the jq program of run.sh. It is extracted from the script
# so the test proves the shipped behavior and not a copy of it.
extract_filter() {
  sed -n "/^ *'\.udpListen/,/ttl: 60}'/p" "$root/rootfs/usr/bin/run.sh" \
    | sed "1s/^ *'//" \
    | tr -d '\\' \
    | sed -e 's/[[:space:]]*$//' -e '$ s/.$//'
}

filter="$(extract_filter)"
[[ -n "$filter" ]] || { echo "the projection of run.sh was not found" >&2; exit 1; }

project() {
  local enabled="$1" cert="$2" key="$3"
  jq -r \
    --arg dns_host "0.0.0.0" \
    --argjson dns_port 53 \
    --argjson doh_port 18053 \
    --arg edge_ipv4 "203.0.113.1" \
    --argjson proxy_port 23128 \
    --arg sync_url "http://192.168.2.100:30130/api/internal/smart-dns/clients" \
    --arg public_enabled "$enabled" \
    --argjson public_doh_port 18054 \
    --argjson public_dot_port 18853 \
    --argjson public_plain_port 5354 \
    --arg public_cert "$cert" \
    --arg public_key "$key" \
    "$filter" "$fixture"
}

off="$(project false "" "")"
[[ "$(jq -r '.dohListen.host' <<<"$off")" == "127.0.0.1" ]]
[[ "$(jq -r '.dohListen.port' <<<"$off")" == "18053" ]]
[[ "$(jq -r '.dohListen.profile' <<<"$off")" == "local" ]]
[[ "$(jq -r '.dotListen' <<<"$off")" == "null" ]]
[[ "$(jq -r '.publicDnsListen' <<<"$off")" == "null" ]]
[[ "$(jq -r '.tls' <<<"$off")" == "null" ]]
[[ "$(jq -r '.udpListen.profile' <<<"$off")" == "local" ]]

on="$(project true /data/certs/dns.pem /data/certs/dns.key)"
[[ "$(jq -r '.dohListen.host' <<<"$on")" == "0.0.0.0" ]]
[[ "$(jq -r '.dohListen.port' <<<"$on")" == "18054" ]]
[[ "$(jq -r '.dohListen.profile' <<<"$on")" == "public" ]]
[[ "$(jq -r '.dotListen.port' <<<"$on")" == "18853" ]]
[[ "$(jq -r '.dotListen.profile' <<<"$on")" == "public" ]]
[[ "$(jq -r '.publicDnsListen.port' <<<"$on")" == "5354" ]]
[[ "$(jq -r '.publicDnsListen.profile' <<<"$on")" == "public" ]]
[[ "$(jq -r '.tls.certFile' <<<"$on")" == "/data/certs/dns.pem" ]]
[[ "$(jq -r '.dohTls' <<<"$on")" == "true" ]]
[[ "$(jq -r '.proxyProtocol' <<<"$on")" == "true" ]]
[[ "$(jq -r '.udpListen.profile' <<<"$on")" == "local" ]]
[[ "$(jq -r '.edgeProfiles.public.ipv4' <<<"$on")" == "185.240.120.152" ]]
[[ "$(jq -r '.edgeProfiles.local.ipv4' <<<"$on")" == "203.0.113.1" ]]
[[ "$(jq -r '.sync.url' <<<"$on")" == "http://192.168.2.100:30130/api/internal/smart-dns/clients" ]]

printf "public DNS projection: ok\n"
