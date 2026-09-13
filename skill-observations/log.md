# Skill Observation Log

Observations captured during task-oriented work.

**Status key:** OPEN = not yet actioned | ACTIONED (YYYY-MM-DD) = skill
updated/created | DECLINED (YYYY-MM-DD) = user decided not to pursue —
resolved statuses always carry their resolution date

---

## 2026-09-08

### Observation 1: Preserve environment-specific skills

**Status:** OPEN
**Date:** 2026-09-08
**Session context:** Creating project skills shared by ZCode and Claude Code.
**Skill:** All skills
**Type:** open-source
**Phase/Area:** Compatibility and fallback design

**Issue:** A skill can depend on tools unique to one agent environment. Rewriting or deleting it because the current environment cannot execute those tools removes valid capability from other agents.

**Suggested improvement:** Every cross-agent skill set should preserve environment-specific skills, declare tool dependencies explicitly, and provide a documented fallback without claiming unavailable execution.

**Principle:** Tool incompatibility should be represented as capability metadata and a fallback path, never as a reason to erase another environment's working instructions.

## 2026-09-11

### Observation 2: Repository migration must include deployment ownership

**Status:** OPEN
**Date:** 2026-09-11
**Session context:** Moving a project after its source-hosting account was suspended.
**Skill:** New skill candidate: repository-host migration
**Type:** open-source
**Phase/Area:** Disaster recovery and CI/CD migration

**Issue:** Copying Git refs to a replacement host restores source control but not the production path. Branch protection, required checks, secrets, deployment serialization, edge-function settings, and a second backup remain separate failure points.

**Suggested improvement:** Define a migration workflow that inventories repository history, local dirty state, CI checks, production triggers, provider-specific secrets, protected branches, and rollback before declaring the move complete.

**Principle:** A source-host migration is complete only when both code custody and deployment authority have moved and been independently verified.

### Observation 3: Deployment scripts need failure-path tests

**Status:** OPEN
**Date:** 2026-09-11
**Session context:** Hardening a new CI/CD path before its first production run.
**Skill:** New skill candidate: repository-host migration
**Type:** open-source
**Phase/Area:** Deployment verification

**Issue:** Shell deployment scripts can continue after a failed command or turn an unreadable remote state into an empty state, causing false success or unsafe replay even when their happy path looks correct.

**Suggested improvement:** Require mocked failure-path tests for every remote-state read and deployment command, asserting a nonzero exit, an explicit failure marker, no later mutation, and no success marker.

**Principle:** A deployment tool is not locally verified until its critical failure paths prove fail-closed behavior, not merely valid syntax or a successful happy path.
