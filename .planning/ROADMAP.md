# Roadmap: HAOS Smart Edge

## Overview
Repair one existing route-health controller and prove automatic home failover.

## Phases
- [ ] **Phase 1: Automatic route recovery** - Extend existing controller, deliver and prove consumer recovery.

## Phase Details
### Phase 1: Automatic route recovery
**Goal**: Home AI and Telegram automatically retain a usable route.
**Depends on**: Nothing
**Requirements**: HEAL-01, HEAL-02, HEAL-03
**Success Criteria**:
  1. One live controller uses native Telegram probes and AI HTTPS probes.
  2. Controlled route failure causes automatic selection and successful home traffic.
  3. Existing healthy streams remain connected; DNS and phone gateway are preserved.
**Plans**: 1 plan
- [ ] 01-PLAN.md — Extend and deliver existing route-health, then run controlled live failover.

## Progress
| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. Automatic route recovery | 0/1 | In progress | - |
