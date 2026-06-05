---
phase: quick-260605-enh
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - scripts/setup-guardrails.sh
  - tests/test_setup_guardrails_argv.sh
  - README.md
autonomous: true
requirements:
  - QUICK-260605-enh
must_haves:
  truths:
    - "Re-running setup-guardrails against a tenant that already has a same-scope budget rule does NOT create a second rule — the existing rule is adopted (RULE_ID set to the existing id)."
    - "When >1 same-scope rule already exists, setup warns, lists the duplicate ids with the exact delete commands, adopts the first, and skips creation (never auto-deletes)."
    - "Created rule names include a deployment-disambiguating label token (REVENIUM_BUDGET_LABEL or short hostname) so fresh-VM installs against the same tenant produce distinguishable names."
    - "All new list/dedup/patch logic is fail-open: a failed or non-JSON list response falls back to the current create-as-today behavior and never aborts setup."
    - "The shadow-mode read-back assertion and all existing input validation remain unchanged and effective."
  artifacts:
    - path: "scripts/setup-guardrails.sh"
      provides: "find_existing_rules finder + adopt/warn/create dedup branch in create_rule + label-bearing rule name at both call sites + REVENIUM_BUDGET_LABEL doc in usage()"
      contains: "find_existing_rules"
    - path: "tests/test_setup_guardrails_argv.sh"
      provides: "Suite C: list-before-create ordering, single-match adopt (no create), multi-match warn+skip, name-includes-label assertions"
      contains: "STUB_REVENIUM_BUDGET_RULES_JSON"
    - path: "README.md"
      provides: "Idempotency + REVENIUM_BUDGET_LABEL note; per-deployment budgets called out as deferred future capability"
      contains: "REVENIUM_BUDGET_LABEL"
  key_links:
    - from: "create_rule()"
      to: "find_existing_rules()"
      via: "pre-create call that sets RULE_ID and short-circuits creation on match"
      pattern: "find_existing_rules"
    - from: "find_existing_rules()"
      to: "revenium guardrails budget-rules list --output json"
      via: "list call parsed by python3 env-heredoc, fail-open on non-JSON"
      pattern: "budget-rules list"
---

<objective>
Make `scripts/setup-guardrails.sh` budget-rule creation idempotent and give rules
unique, deployment-disambiguating names so re-runs and fresh-VM installs against
the same Revenium tenant stop creating scope-identical duplicate cost-control rules.

Scope is **Option A — idempotent dedup + unique names** for the single shared
tenant budget. Per-deployment filter scoping (distinct budgets per deployment) is
explicitly OUT OF SCOPE and deferred to a future capability. Do NOT modify
report.sh or the agent-id construction.

Purpose: Confirmed root cause (live tenant, NOT a Revenium bug) — `create_rule()`
always creates `"OpenClaw ${period_title} Budget"` with filter
`AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}` and never checks for an existing rule,
so re-runs / fresh VMs silently create scope-identical duplicates that both meter
the same transaction set.

Output: a finder helper, an adopt/warn/create dedup branch inside `create_rule()`,
label-bearing rule names at both call sites, extended argv tests, and a short docs note.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md

# The file to change. Focus areas:
#   - create_rule() ~lines 268-380 (insert finder call + dedup branch before the create)
#   - run_default rule_name ~line 487
#   - run_interactive rule_name ~line 668
#   - usage() heredoc ~lines 37-67 (document REVENIUM_BUDGET_LABEL)
# Existing env-passing python3 heredoc patterns to MIRROR (bash 3.2 safe):
#   - read_config_field ~line 138, compute_warn_threshold ~line 225
#   - interactive rules-display parser ~lines 521-546 (uses r['id'], name, windowType, hardLimit)
# Existing helpers from common.sh already in scope: info/warn/error, REVENIUM_AGENT_PREFIX.
@scripts/setup-guardrails.sh

# Existing argv-capture harness. Stub revenium is INLINE in this test file
# (heredoc at ~lines 60-113), NOT tests/stub-revenium.sh. The inline stub already
# has a `*"budget-rules list"*` branch returning '[]' (~lines 85-88) and an
# update/delete fall-through. Extend the inline stub to honor a fixture env var
# (mirror STUB_REVENIUM_BUDGET_RULES_JSON from tests/stub-revenium.sh ~line 135).
@tests/test_setup_guardrails_argv.sh

# Reference for the fixture-env idiom and budget-rules list JSON shape only.
@tests/stub-revenium.sh
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Add find_existing_rules finder + adopt/warn/create dedup branch in create_rule(), with label-bearing rule names</name>
  <files>scripts/setup-guardrails.sh</files>
  <behavior>
    - find_existing_rules: runs `revenium guardrails budget-rules list --output json`,
      parses with a python3 env-heredoc, returns (stdout) the ids of rules whose SCOPE
      matches the about-to-create rule: identical filter SET (AGENT:STARTS_WITH:<prefix>
      plus any extra_filter, order-insensitive) AND same window-type/period AND same
      group-by. One id per line. Empty output = no match.
    - Fail-open: if the list call exits non-zero OR stdout is not valid JSON, the python
      parse yields empty and the function returns 0 (treated as "none found" → create proceeds).
    - create_rule dedup branch (runs BEFORE the existing create block):
        * exactly one match → set RULE_ID to that id, RULE_EXIT=0, log
          `Reusing existing budget rule <id> (<name>) — skipping duplicate creation`,
          best-effort `budget-rules update <id> --name '<rule_name>'` only when the
          existing display name differs from the desired name (fail-open; never abort),
          then RETURN without creating.
        * more than one match → warn, list each duplicate id, state they all meter the
          same spend, print the exact `revenium guardrails budget-rules delete <id> --yes`
          command for EACH id, adopt the FIRST id (RULE_ID set, RULE_EXIT=0), do NOT
          auto-delete, then RETURN without creating.
        * zero matches → fall through to the existing create-as-today logic unchanged.
    - Rule name carries a deployment label token at BOTH call sites (run_default ~line 487
      and run_interactive ~line 668): `OpenClaw ${period_title} Budget — ${LABEL}` where
      LABEL is `${REVENIUM_BUDGET_LABEL:-<short-hostname>}` and the short hostname is
      sourced portably: `hostname -s` 2>/dev/null, else `uname -n`, else `${HOSTNAME}`,
      else `unknown`. The per-task-type rule name (~line 800) is NOT in scope for the
      label suffix (keep its current form to avoid disturbing Suite A assertions),
      but it MUST still flow through the dedup branch via create_rule.
    - usage() documents REVENIUM_BUDGET_LABEL (operator-overridable name suffix) and a
      one-line note that idempotent adopt prevents duplicate rules on re-run / fresh VM.
  </behavior>
  <action>
    Add `find_existing_rules` as a new helper above `create_rule` (mirror the env-passing
    python3 heredoc pattern of read_config_field / the interactive rules-display parser —
    bash 3.2 safe, no associative arrays, all values passed via env, no herestrings).
    The finder builds the DESIRED filter set in bash (always `AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}`
    plus `${extra_filter}` when non-empty), the desired window-type (period), and the
    desired group-by (group_by_override or AGENT), passes them + the raw list JSON to
    python3 via env, and the python compares each rule's `filters` (array of
    {dimension,operator,value} reduced to a normalized order-insensitive set of
    "DIM:OP:VAL" strings) against the desired set, plus `windowType`/period field and
    `groupBy` field, printing matching ids. Accept the field-name variance noted in the
    confirmed findings (`period` OR `window`/`windowType`) by checking the present key.
    Signature: `find_existing_rules <period> <group_by_arg> [extra_filter]` — reuse the
    same `group_by_arg`/`extra_filter` already computed at the top of create_rule.

    In `create_rule`, immediately after computing `group_by_arg` (and before the
    SHADOW_MODE if/else create block), call the finder, capture its output into a
    newline list, count the ids, and branch adopt / warn+adopt / create per <behavior>.
    Use `info`/`warn` from common.sh. Truncate any rule name echoed into logs to 64 chars
    (reuse the existing log-injection mitigation pattern, e.g. `${name:0:64}`). The
    best-effort name update is `revenium guardrails budget-rules update "${RULE_ID}" --name "${rule_name}" >/dev/null 2>&1 || warn ...`.

    Replace `local rule_name="OpenClaw ${period_title} Budget"` at BOTH the run_default
    and run_interactive call sites with the label-bearing form. Compute the label once
    via a small helper (e.g. `budget_label()` returning `${REVENIUM_BUDGET_LABEL:-$(short_host)}`)
    or inline; keep it bash 3.2 safe. Do NOT touch the per-task-type `task_rule_name`.

    Add a REVENIUM_BUDGET_LABEL block to the usage() heredoc (under DEFAULT FILTER
    SCOPING or a new IDEMPOTENCY section) documenting the override and the adopt behavior.

    Do NOT place fenced code blocks in this action — directive prose only. Preserve the
    shadow-mode read-back assertion (~lines 345-379) and ALL existing input validation.
  </action>
  <verify>
    <automated>bash -n scripts/setup-guardrails.sh && grep -q 'find_existing_rules' scripts/setup-guardrails.sh && grep -q 'REVENIUM_BUDGET_LABEL' scripts/setup-guardrails.sh && grep -c 'OpenClaw ${period_title} Budget' scripts/setup-guardrails.sh | grep -qv '^[3-9]'</automated>
  </verify>
  <done>
    `bash -n` passes; find_existing_rules defined and called from create_rule before the
    create block; both base rule_name strings carry the label suffix; per-task rule_name
    unchanged; REVENIUM_BUDGET_LABEL documented in usage(); shadow-mode read-back and
    validators untouched.
  </done>
</task>

<task type="auto">
  <name>Task 2: Extend argv tests (Suite C) for list-before-create, single-match adopt, multi-match warn+skip, and label-in-name; keep Suites A/B green</name>
  <files>tests/test_setup_guardrails_argv.sh</files>
  <action>
    Teach the INLINE stub revenium (heredoc ~lines 60-113) to honor a fixture env var for
    the list response: change the `*"budget-rules list"*` branch (~lines 85-88) to print
    `${STUB_REVENIUM_BUDGET_RULES_JSON:-[]}` (mirror the idiom in tests/stub-revenium.sh
    ~line 135) instead of the hardcoded `[]`. Leave the `create`, `get`, `delete`, and
    `--help` branches unchanged. Add capture of `budget-rules update` so its argv can be
    asserted: add an `*"budget-rules update"*` case ABOVE the `*"budget-rules create"*`
    case that appends `UPDATE` + its args to INVOCATION_FILE (or a second capture file)
    and exits 0 — do NOT let update fall through to the create capture.

    Add a record of call ORDER so list-before-create is assertable: in the inline stub,
    append a single ordered tag (e.g. `LIST` / `CREATE` / `UPDATE`) to a new
    ORDER_FILE env path for the list/create/update branches. Wire ORDER_FILE into
    run_interactive() (mirror INVOCATION_FILE export at ~lines 194-197) and reset it in
    run_interactive() alongside INVOCATION_FILE (~line 191).

    Add Suite C (after Suite B) using run_interactive with the existing 4-line MONTHLY
    stdin (no per-task picker; pass help_has_task_type=""):
      - C1 ordering: with STUB_REVENIUM_BUDGET_RULES_JSON='[]', assert the ORDER_FILE
        shows a LIST tag appearing before the first CREATE tag.
      - C2 single-match adopt: set STUB_REVENIUM_BUDGET_RULES_JSON to a one-element array
        whose filters/windowType/groupBy MATCH the base rule
        (filters:[{dimension:"AGENT",operator:"STARTS_WITH",value:"openclaw-"}],
         windowType:"MONTHLY", groupBy:"AGENT", id:"existing-1", name:"old name").
        Assert count_invocations (create) == 0 AND config.json ruleIds == ["existing-1"].
        Assert an UPDATE invocation carrying `--name` was captured (name differed).
      - C3 multi-match warn+skip: set the fixture to TWO matching rules
        (ids existing-1, existing-2). Capture combined stdout+stderr; assert create
        invocations == 0, the output warns about duplicates, and contains both
        `budget-rules delete existing-1` and `budget-rules delete existing-2`. Assert
        config.json ruleIds == ["existing-1"] (first adopted).
      - C4 label in name: with the '[]' fixture, run setup with
        REVENIUM_BUDGET_LABEL=myhost in the env, assert invocation 1 args contain
        `myhost` (the create --name carries the label token). Extend run_interactive (or
        add a run_interactive_env variant) so REVENIUM_BUDGET_LABEL can be exported.
    Use the existing count_invocations / get_invocation / assert_contains / assert_not_contains
    helpers; add small python3 readers for config.json ruleIds equality and for ORDER_FILE
    ordering. Keep Suite A and Suite B and ALL their assertions exactly as-is.
  </action>
  <verify>
    <automated>bash tests/test_setup_guardrails_argv.sh</automated>
  </verify>
  <done>
    Test script exits 0 with "All tests passed." Suites A and B unchanged and green;
    Suite C adds C1 (list-before-create order), C2 (single-match adopt: zero create,
    update --name, ruleIds=["existing-1"]), C3 (multi-match warn+skip: zero create,
    both delete commands printed, ruleIds=["existing-1"]), C4 (label token in create name).
  </done>
</task>

<task type="auto">
  <name>Task 3: Document idempotency + REVENIUM_BUDGET_LABEL in README; note per-deployment budgets as deferred</name>
  <files>README.md</files>
  <action>
    Add a short note in the Setup / guardrails area (around the setup flow ~lines 170-180
    and/or the cleanup troubleshooting ~lines 274-306) covering: (1) setup is idempotent —
    re-running, or installing on a fresh VM pointed at the same Revenium tenant, adopts an
    existing same-scope budget rule instead of creating a duplicate; if pre-existing
    duplicates are detected it warns and prints the exact `revenium guardrails budget-rules
    delete <id> --yes` commands rather than auto-deleting (a shared tenant may host other
    hosts' rules); (2) `REVENIUM_BUDGET_LABEL` env var overrides the deployment label suffix
    in rule names (default: short hostname) so multiple deployments produce
    human-distinguishable names; (3) a one-line forward-looking note that independent
    per-deployment budgets (distinct filter-scoped budgets per deployment, not a single
    shared tenant budget) are a separate future capability, currently out of scope.
    Keep it concise (a short paragraph or a few bullets). Match the existing README voice.
  </action>
  <verify>
    <automated>grep -q 'REVENIUM_BUDGET_LABEL' README.md && grep -qi 'idempotent\|adopt' README.md</automated>
  </verify>
  <done>
    README mentions REVENIUM_BUDGET_LABEL, the idempotent adopt-on-rerun behavior, the
    no-auto-delete duplicate warning, and that per-deployment budgets are a deferred
    future capability.
  </done>
</task>

</tasks>

<verification>
- `bash -n scripts/setup-guardrails.sh` passes (bash 3.2 safe; no associative arrays / herestrings introduced).
- `bash tests/test_setup_guardrails_argv.sh` exits 0 — Suites A, B (unchanged) and new Suite C all green.
- Manual read: find_existing_rules is called inside create_rule BEFORE the create block; fail-open on non-JSON list; shadow-mode read-back assertion and input validators untouched.
- README documents idempotency + REVENIUM_BUDGET_LABEL and flags per-deployment budgets as deferred.
</verification>

<success_criteria>
- Re-run / fresh-VM install against a tenant with one same-scope rule adopts it (no second rule created).
- >1 same-scope rule → warn + delete-command list + adopt-first + skip create (no auto-delete).
- Created base rule names include REVENIUM_BUDGET_LABEL (or short hostname).
- All list/dedup/patch logic is fail-open; existing shadow-mode assertion + validation preserved.
- Change is contained to scripts/setup-guardrails.sh + tests + README. report.sh and agent-id construction untouched.
</success_criteria>

<output>
Create `.planning/quick/260605-enh-idempotent-uniquely-named-revenium-budge/260605-enh-SUMMARY.md` when done
</output>
