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
