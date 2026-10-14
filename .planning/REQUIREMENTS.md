# Requirements: HAOS Smart Edge

**Defined:** 2026-10-14
**Core Value:** Automatic usable home routes without manual switching.

## v1 Requirements
### Automatic recovery
- [ ] **HEAL-01**: One existing controller manages AI and native Telegram selection using real consumer probes.
- [ ] **HEAL-02**: Healthy streams survive route selection changes; upstream-only failure never restarts the healthy stack.
- [ ] **HEAL-03**: A controlled failure automatically selects another proven route and real home traffic succeeds.

## v2 Requirements
None requested.

## Out of Scope
| Feature | Reason |
|---|---|
| Competing scheduler or controller | User explicitly requested one healer |
| Foreign workload shutdown or VPS purchase | No ownership or purchase authority |

## Traceability
| Requirement | Phase | Status |
|---|---|---|
| HEAL-01 | Phase 1 | Pending |
| HEAL-02 | Phase 1 | Pending |
| HEAL-03 | Phase 1 | Pending |
