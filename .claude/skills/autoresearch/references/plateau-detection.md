# Plateau Detection Protocol

Detect when iterative improvements stall and escalate systematically. Replaces ad-hoc "5 consecutive discards" with principled exploitation/exploration balance.

## Strategy Categories

Tag every experiment with exactly one category. This enables diversity tracking and targeted escalation.

| Category | Description | Examples |
|----------|-------------|---------|
| `exploit` | Variant of last success | Same approach, different parameters |
| `explore` | Untried approach | New technique, different file |
| `refine` | Smaller variation in current direction | Tweak threshold, adjust config |
| `pivot` | Fundamentally different direction | New algorithm, structural rewrite |
| `combine` | Merge 2+ previous successes | Stack winning changes |
| `simplify` | Remove complexity | Delete code, reduce abstractions |

**Tagging rule:** Choose the category BEFORE making the change (Phase 2). Record it in the results log `strategy_category` column (see `references/results-logging.md`).

## Sliding-Window Plateau Assessment

Run this assessment at the START of every Phase 1 (Review), after reading the results log.

### Step 1: Read the Window

Read the last N results log entries (N depends on sensitivity setting):

| Plateau-Sensitivity | Window Size (N) |
|---------------------|-----------------|
| `aggressive` | 7 |
| `normal` (default) | 10 |
| `patient` | 15 |

### Step 2: Count and Assess

From the window entries:
- Count **keeps** vs **discards** (ignore crashes, no-ops, hook-blocked)
- Note the **delta trend** — are keeps getting smaller over time?
- Note the **category distribution** — how many distinct categories appear?

### Step 3: Determine Improvement Trend

| Condition | Trend |
|-----------|-------|
| 4+ keeps in window, or last 3 deltas increasing | **STRONG** |
| 2-3 keeps in window, deltas stable or mixed | **MODERATE** |
| 0-1 keeps in window, or last 5 deltas all decreasing/zero | **FLAT** |

### Step 4: Determine Category Diversity

| Condition | Diversity |
|-----------|-----------|
| 1-2 distinct categories in window | **NARROW** |
| 3+ distinct categories in window | **BROAD** |

### Step 5: Combine into Plateau Status

| Improvement Trend | Category Diversity | Plateau Status | Meaning |
|-------------------|--------------------|----------------|---------|
| STRONG | any | **NO PLATEAU** | Continue normally |
| MODERATE | BROAD | **EARLY PLATEAU** | Watch closely |
| MODERATE | NARROW | **CATEGORY EXHAUSTION** | Switch category |
| FLAT | any | **CONFIRMED PLATEAU** | Trigger escalation |

## 3-Tier Response: EXPLOIT → REFINE → PIVOT

| Tier | Trigger | Behavior Change |
|------|---------|----------------|
| **EXPLOIT** | No plateau | Continue current category. Exploit variants of last success. Normal operation. |
| **REFINE** | Early plateau / category exhaustion | Switch to a different category. Use UCB1 intuition: prefer categories with highest success rate AND fewest attempts. |
| **PIVOT** | Confirmed plateau (0-1 keeps in window) | Suspend incremental thinking. Run self-reflection audit. Activate novelty search (see `references/novelty-generation.md`). Read all files from scratch. Try untried categories. |

### EXPLOIT Mode (default)

Business as usual. Follow the normal Phase 2 priority order from `references/autonomous-loop-protocol.md`. Tag experiments with the most productive category.

### REFINE Mode

1. Build the category scorecard (see below)
2. Identify which categories have been overused (high attempts, declining success rate)
3. Switch to a different category — prefer the one with the best UCB1 score
4. If a category has never been tried, prioritize it
5. Continue for at least 3 iterations in the new category before reassessing

### PIVOT Mode

1. **Stop and reflect.** Do not immediately try another experiment
2. **Re-read ALL in-scope files** from scratch (not just diffs)
3. **Re-read the original goal** — has the approach drifted from the intent?
4. **Self-reflection audit:** "What assumptions have I been making? Which are untested?"
5. **Activate novelty generation** at maximum stringency (see `references/novelty-generation.md`)
6. **Try untried categories first** — check the scorecard for categories with 0 attempts
7. **Mandatory radical experiment** — the next experiment MUST be category `pivot` or `explore`
8. **If session memory exists**, review `autoresearch-state.md` Dead Ends and Untried Directions

## Category Scorecard

Build this mental scorecard from the FULL results log at the start of each Phase 1. This informs category selection in REFINE and PIVOT modes.

```
Category     | Attempts | Keeps | Success Rate | Last Tried
-------------|----------|-------|--------------|------------
exploit      | 8        | 3     | 37.5%        | iteration 32
explore      | 4        | 2     | 50.0%        | iteration 28
refine       | 12       | 2     | 16.7%        | iteration 41
pivot        | 2        | 1     | 50.0%        | iteration 15
combine      | 3        | 2     | 66.7%        | iteration 38
simplify     | 1        | 0     | 0.0%         | iteration 10
```

**UCB1 intuition for category selection:**

Pick the category with the best combination of:
1. **Highest success rate** — categories that have worked before
2. **Fewest attempts** — categories that haven't been explored enough

When tied, prefer the category that was tried least recently. If a category has never been tried, it gets highest priority in REFINE/PIVOT modes.

## Configuration

Set plateau sensitivity in the inline config:

```
/autoresearch
Goal: Improve test coverage to 95%
Scope: src/**/*.ts
Verify: npx jest --coverage 2>&1 | grep 'All files' | awk '{print $4}'
Plateau-Sensitivity: normal     # default — 10-experiment window
```

| Setting | Window | Triggers | Use When |
|---------|--------|----------|----------|
| `aggressive` | 7 experiments | Faster escalation | Known difficult problem, want early pivots |
| `normal` | 10 experiments | Balanced | Most tasks (default) |
| `patient` | 15 experiments | More conservative | Easy gains expected, don't want premature pivots |

## Worked Example

Showing EXPLOIT → REFINE → PIVOT → back to EXPLOIT across a 33-iteration session.

### Iterations 1-15: EXPLOIT Mode

```
Iter | Category  | Status  | Delta  | Plateau Status
1    | exploit   | keep    | +2.1   | NO PLATEAU
2    | exploit   | keep    | +1.8   | NO PLATEAU
3    | exploit   | keep    | +1.2   | NO PLATEAU
4    | exploit   | discard | -0.3   | NO PLATEAU
5    | exploit   | keep    | +0.9   | NO PLATEAU
6    | refine    | keep    | +0.5   | NO PLATEAU
7    | exploit   | discard | -0.1   | NO PLATEAU
8    | exploit   | keep    | +0.4   | NO PLATEAU
9    | exploit   | discard | -0.2   | NO PLATEAU
10   | exploit   | discard | -0.1   | NO PLATEAU
...
15   | exploit   | discard | -0.1   | EARLY PLATEAU (MODERATE + NARROW)
```

**Window at iteration 15:** 2 keeps in last 10, almost all `exploit` category → MODERATE + NARROW → EARLY PLATEAU. Agent shifts to REFINE.

### Iterations 16-22: REFINE Mode

```
16   | explore   | keep    | +0.7   | EARLY PLATEAU → trying new category
17   | combine   | keep    | +1.1   | improving — watching
18   | explore   | discard | -0.2   | still exploring
19   | simplify  | keep    | +0.3   | NO PLATEAU (3 keeps in window, BROAD categories)
20   | combine   | discard | -0.1   | NO PLATEAU
21   | exploit   | keep    | +0.2   | NO PLATEAU → back to EXPLOIT
22   | exploit   | discard | -0.1   | NO PLATEAU
```

**Agent switched to `explore` and `combine`, found new gains. Back to EXPLOIT once plateau cleared.**

### Iterations 23-28: Plateau Returns

```
23   | exploit   | discard | -0.1   |
24   | refine    | discard | 0.0    |
25   | exploit   | discard | -0.2   |
26   | explore   | discard | -0.1   |
27   | combine   | discard | 0.0    |
28   | refine    | discard | -0.1   | CONFIRMED PLATEAU (0 keeps in 6, FLAT)
```

**0 keeps in last 6 iterations despite BROAD categories → CONFIRMED PLATEAU. Agent enters PIVOT.**

### Iterations 29-33: PIVOT Mode

```
29   | pivot     | discard | -0.5   | PIVOT — radical restructure attempt
30   | pivot     | keep    | +2.3   | PIVOT — fundamentally new approach works!
31   | exploit   | keep    | +1.1   | Exploiting the new direction
32   | exploit   | keep    | +0.8   | NO PLATEAU — gains resumed
33   | refine    | keep    | +0.4   | NO PLATEAU — steady improvement
```

**PIVOT forced a radical rethink. New approach unlocked a fresh improvement trajectory. Agent returned to EXPLOIT on the new direction.**

## Integration Points

- **Phase 1 (Review):** Run plateau assessment after reading results log
- **Phase 2 (Ideate):** Use plateau status to select tier (EXPLOIT/REFINE/PIVOT)
- **Phase 7 (Log):** Record `strategy_category` in TSV
- **When Stuck:** PIVOT mode subsumes the "When Stuck" protocol with more structure
- **Session Memory:** PIVOT mode triggers a checkpoint write to `autoresearch-state.md`
- **Novelty Generation:** PIVOT mode activates maximum-stringency novelty generation
