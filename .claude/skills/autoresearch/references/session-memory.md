# Session Memory Protocol

Persist strategic context across sessions. Git history preserves WHAT happened; session memory preserves WHY and WHAT'S NEXT.

## State File Schema

Create `autoresearch-state.md` alongside the results TSV in the working directory. Target size: ~4K tokens.

```markdown
# Autoresearch State
<!-- Session: {N} | Updated: {ISO-8601 timestamp} | Commit: {short-hash} -->

## Current Best
- Metric: {value} (baseline: {baseline_value})
- Commit: {short-hash}
- Key changes: [list of changes that got here]

## Active Hypothesis
- Testing: "{description of current hypothesis}"
- Confidence: {High/Medium/Low}
- Remaining variants: {count}

## Plateau Status
- Current tier: {EXPLOIT/REFINE/PIVOT}
- Window: {last N results summary}
- Category distribution: {breakdown}

## Key Learnings (max 15)
- {Learning} (session {N})
- {Learning} (session {N})
...

## Dead Ends (max 10)
- {What was tried}: {why it failed} (session {N})
...

## Untried Directions
- {Direction not yet attempted}
- {Direction not yet attempted}
...

## Loop Config (for resumption after compact)
- Goal: {exact goal text}
- Scope: {file globs}
- Verify: {exact verify command}
- Guard: {exact guard command or "none"}
- Direction: {higher_is_better or lower_is_better}
- Mode: {unbounded or "bounded N"}
- Current iteration: {N}
- Compact count: {how many times compacted so far}
```

**The Loop Config section is MANDATORY.** Without it, the agent cannot resume the loop after `/compact` — it loses the verify command, scope, and goal. This section must be written on every state file update, not just before compaction.

### Field Guidelines

| Field | What to Write | What NOT to Write |
|-------|---------------|-------------------|
| Current Best | Metric value, commit hash, high-level change list | Full diffs, line-by-line changes |
| Active Hypothesis | The current theory being tested, confidence level | Implementation details |
| Key Learnings | Surprising findings, non-obvious patterns | Obvious facts derivable from code |
| Dead Ends | Failed approaches WITH reasons | Every single discard |
| Untried Directions | Promising ideas not yet explored | Vague "try harder" suggestions |

### What to Persist vs Derive

| Persist in State File | Derive from Git/TSV |
|---|---|
| Strategic context (why this direction) | Exact iteration counts |
| Curated learnings (surprises only) | Full experiment list |
| Active hypothesis + confidence | Commit hashes, diffs |
| Dead ends with reasons | Metric values |
| Untried directions queue | Keep/discard counts |
| Plateau status and tier | Category statistics |

## Session Start Protocol

Integrates into Phase 0 (Precondition Checks) and Phase 1 (Review).

### At Phase 0 (after git checks):

```
1. Check for autoresearch-state.md in working directory
2. If found:
   a. Read the file
   b. Extract: session count, current best metric, active hypothesis, plateau status
   c. Increment session count
   d. Print resumption summary:
      === Resuming Autoresearch (Session {N+1}) ===
      Previous best: {metric} (commit {hash})
      Active hypothesis: {description}
      Plateau status: {tier}
      Dead ends to avoid: {count}
      Untried directions available: {count}
3. If not found:
   a. This is Session 1 — proceed normally
   b. State file will be created at first checkpoint
```

### At Phase 1 (Review) — Drift Detection:

```
4. Cross-reference state file with actual git history:
   - Does the "current best" commit still exist? (git log --oneline | grep {hash})
   - Has someone made changes outside autoresearch since last session?
   - Does the results TSV match the state file's claims?
5. If drift detected:
   - Log: "DRIFT: state file says best={X} but current metric={Y}"
   - Re-run baseline verification to get true current state
   - Update state file with corrected values
6. Load Dead Ends list → avoid re-trying these approaches
7. Load Untried Directions → prioritize these in Phase 2
```

## Session End / Checkpoint Protocol

Four triggers cause a state file write:

### Trigger 1: Every 10 Iterations (Periodic Checkpoint)

```
IF iteration_count % 10 == 0:
    write_state_file()
```

### Trigger 2: Entering PIVOT Mode (Strategic Inflection)

```
IF plateau_status == CONFIRMED_PLATEAU:
    write_state_file()  # Capture state before radical change
```

### Trigger 3: Bounded Loop Completion

```
IF current_iteration == max_iterations:
    write_state_file()  # Final state for next session
```

### Trigger 4: Auto-compact Recovery

Claude Code automatically compacts conversation history when context fills. When this happens, the state file ensures strategic context survives compression:

```
AFTER AUTO-COMPACT:
    If autoresearch-state.md exists:
        Read it to recover goal, scope, verify command, active hypothesis, dead ends
    If autoresearch-results.tsv exists:
        Read tail -20 to recover recent experiment history
    Continue loop from Phase 1 — do NOT stop or restart setup
```

The state file MUST always include the Loop Config section (Goal, Scope, Verify, Guard, Direction, Mode, iteration count) so the agent can resume seamlessly after any context compression.

### State File Write Procedure

```
1. Gather current state:
   - Read current best metric and commit from results log
   - Read active hypothesis from Phase 2 context
   - Run plateau assessment for current status
   - Compile key learnings from this session's results
   - Update dead ends with this session's confirmed failures
   - Generate untried directions from category scorecard gaps

2. Write autoresearch-state.md:
   - Update session count
   - Update timestamp to now
   - Update all sections
   - Trim Key Learnings to max 15 (drop oldest, keep most impactful)
   - Trim Dead Ends to max 10 (drop oldest, keep most relevant)

3. Do NOT commit the state file to git
   - Add to .gitignore alongside autoresearch-results.tsv
   - State file is local working state, not experiment history
```

## State File Management

### .gitignore Entry

Add during Phase 0 setup (alongside results TSV):

```bash
echo "autoresearch-state.md" >> .gitignore
```

### Size Control

The state file should stay under ~4K tokens to avoid context bloat when loaded:

- Key Learnings: max 15 entries, one line each
- Dead Ends: max 10 entries, one line each
- Untried Directions: max 10 entries, one line each
- Trim oldest entries when limits are reached
- Prefer impactful/surprising learnings over routine observations

### Staleness

State files become stale when:
- The codebase has been significantly modified outside autoresearch
- More than 7 days have passed since the last update
- The results TSV has been deleted or reset

When staleness is detected, log a warning and re-derive what you can from git history and the results TSV. Update the state file with corrected values.

## Example: Multi-Session Flow

### Session 1 (iterations 1-25)

```
# No state file exists — Session 1
# Agent creates baseline, runs 25 iterations
# At iteration 10: checkpoint written
# At iteration 20: checkpoint written
# At iteration 25 (bounded): final state written

# autoresearch-state.md after Session 1:
## Current Best
- Metric: 88.3% (baseline: 72.0%)
- Commit: d4e5f6g
- Key changes: auth middleware tests, error handling tests, boundary validators

## Active Hypothesis
- Testing: "Property-based testing for input validators"
- Confidence: Medium
- Remaining variants: 3

## Key Learnings (5 entries)
- Auth middleware edge cases consistently improve coverage (session 1)
- Error handling tests in API routes are high-value targets (session 1)
- Refactoring test helpers tends to break existing tests — avoid (session 1)
- Boundary value tests have diminishing returns after 3 iterations (session 1)
- Coverage gains slow dramatically above 85% — need new approach (session 1)

## Dead Ends (3 entries)
- Integration tests with external DB: connection fails in CI environment (session 1)
- Mocking entire request pipeline: too brittle, breaks on any route change (session 1)
- Inlining hot-path functions: breaks guard tests every time (session 1)

## Untried Directions
- Mutation testing to find weak test assertions
- Property-based testing for data validators
- Coverage of async error paths and promise rejections
- Snapshot testing for complex response objects
```

### Session 2 (iterations 26-50)

```
# Agent finds autoresearch-state.md — Session 2
=== Resuming Autoresearch (Session 2) ===
Previous best: 88.3% (commit d4e5f6g)
Active hypothesis: "Property-based testing for input validators"
Plateau status: REFINE
Dead ends to avoid: 3
Untried directions available: 4

# Agent avoids dead ends, starts with untried directions
# Picks up property-based testing hypothesis from Session 1
# Reaches 92.1% by iteration 50
```

## Integration Points

- **Phase 0:** Check for state file, load if exists, print resumption summary
- **Phase 1:** Cross-reference state with git/TSV, detect drift, load dead ends and untried directions
- **Phase 2:** Use untried directions to inform hypothesis selection
- **Plateau Detection:** PIVOT mode triggers checkpoint write
- **Bounded Loop End:** Final checkpoint write
- **Every 10 iterations:** Periodic checkpoint write
