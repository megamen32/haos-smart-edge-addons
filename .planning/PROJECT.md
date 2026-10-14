# HAOS Smart Edge

## What This Is
Existing HAOS Store app serving home SmartDNS, transparent TLS, regional proxies and Telegram TPROXY. This delivery repairs the home network through one existing route-health controller.

## Core Value
Home traffic automatically uses a confirmed working non-Russian route without manual switching or interrupted healthy streams.

## Requirements
### Validated
- Existing Store app 0.1.23 owns LAN DNS/TLS/TPROXY and the AI selector.
### Active
- [ ] One route-health controller verifies AI and native Telegram, switches failed routes automatically, and preserves working connections.
- [ ] Controlled live failover proves the real home consumer recovers.
### Out of Scope
- New schedulers, phone gateway changes, foreign workloads, and purchasing VPS capacity.

## Context
October14: US transport degraded, AI selector already uses Finland; native Telegram is hard-pinned to failed us-reality. Native home probes0/8; DE proxy8/8. Daily S21 cellular measurement is owned by vpn-panel and must remain measurement only.

## Constraints
- Preserve protected runtime transport credentials and current DNS/recovery topology.
- Publish from canonical main; no new worktree or competing route controller.
- Reuse bundled sing-box1.13.14 and existing45-second controller loop.

## Key Decisions
| Decision | Rationale | Outcome |
|---|---|---|
| Extend existing route-health | User explicitly requested one autoheal | Pending |
| Native req_pq_multi/resPQ as Telegram proof | TCP/web success misses native failures | Verified schema and official Android source |

---
*Last updated: 2026-10-14 after direct user correction*
