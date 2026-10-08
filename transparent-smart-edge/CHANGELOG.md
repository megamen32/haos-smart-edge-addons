# Changelog

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

