# Changelog

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

