# Changelog

## 0.1.26

- Add the `smartdns_sync_url` option (default
  `http://192.168.2.100:30130/api/internal/smart-dns/clients`): the add-on
  keeps its own `.sync` block instead of dropping it, so the edge pulls the
  canonical client policy from the VPN Panel control plane on its own.
- Adopt the SmartDNS P0 fixes from the VPN Panel source of truth: the edge
  API fails closed when no token is configured, and the DoT client identity
  accepts only the base name or a known `<client_id>.<base>` suffix.
- Build and publish this image from THIS repository
  (`.github/workflows/build-haos-addon.yaml`); the add-on build no longer
  depends on a private pipeline.

## 0.1.25

- Add the `world` LAN proxy lane on port `3125` through the new options
  `lan_world_proxy_enabled`, `lan_world_proxy_port`, and
  `lan_world_proxy_outbound_tag` (default outbound tag `world-auto`).
- Move the `fi` LAN proxy lane from port `3129` to `3126`, so the lane map
  is world `3125`, fi `3126`, us `3127`, de `3128`, ru `3130`.
- The sing-box internal listener stays on `23128`; the image stays untagged
  and is published by the VPN Panel repository workflow.
- The default `telegram_outbound_tag` is now `us-reality`, matching the value
  the production deployment sets; `telegram-auto` stays available as the
  health-selected group for the Telegram lane itself.

## 0.1.24

- One existing route-health controller verifies Discord HTTPS and native Telegram resPQ, and selects working routes automatically.
- Preserve established connections across selector changes; upstream-only outages no longer restart the healthy local stack.
- Keep native Telegram on its healthy route until a real probe fails, with bounded two-DC checks.

## 0.1.22

- Add the `ai-route` selector (fi-helsinki, de-regional, us-regional) with an
  AI domain rule so transparent DLP traffic to OpenAI/Anthropic stops landing
  on randomly picked slow US exits.
- Add `route-health.sh`: per-lane end-to-end probes scored by EWMA latency
  and error streaks, automatic selector healing, switching after a sustained
  30% improvement, and a sing-box restart when every lane fails repeatedly.
- Build sing-box with `with_clash_api`; controller bound to `127.0.0.1:9095`
  inside the add-on only.
- New option `ai_route_enabled` (default true).
- Align default `singbox_outbound_tag`/`telegram_outbound_tag` with the
  deployed `world-auto`/`telegram-auto` values.

## 0.1.9

- Add a Telegram TPROXY policy watchdog that re-applies the idempotent nft
  table and marked route when they disappear after a boot-time interface race
  or an external flush; the 2026-09-06 lane incident showed the one-shot
  boot apply leaves every health check green while the lane is dead.

## 0.1.0

- Initial standalone Home Assistant repository release.
- Bundle SmartDNS, transparent TLS edge, and sing-box `1.13.14`.
- Publish a pre-built `aarch64` image to GitHub Container Registry.
# 0.1.6

- Restore automatic DE/US transport selection with complete `urltest` groups.
- Route the Telegram TPROXY inbound through the independent US transport group.

