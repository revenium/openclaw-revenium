
## Pre-existing test_report_argv.sh failure

**Found during:** Plan 02 execution
**Scope:** Out-of-scope (pre-existing before Plan 02 changes)
**Issue:** `test_report_argv.sh` fails with "--task-type count (6) != meter completion count (7)" — there are 7 completions across Sessions A-D but only 6 get `--task-type` (Session A comp-A-002 may have an offset or session-parsing issue). This failure existed at commit ddd6428 before any Plan 02 changes.
**Status:** Deferred — not caused by Plan 02; no impact on job lifecycle feature.
