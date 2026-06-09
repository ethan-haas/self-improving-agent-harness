# Novelty Generation Protocol

Enforce diversity in hypothesis generation. Prevents tunnel vision, encourages creative exploration, and provides structured techniques for breaking out of local optima.

## Enhanced Phase 2 — Hypothesis Generation Before Code

Replace the simple priority list with a structured two-step process.

### Phase 2A: Generate Candidate Strategies

Before writing any code, propose 3-5 qualitatively different strategies. Each strategy MUST specify:

1. **What changes** — concrete description of the modification
2. **Why it might improve the metric** — causal reasoning, not hope
3. **How it differs from last 3 accepted changes** — explicit novelty justification

Self-evaluate each strategy on three dimensions (1-5 scale):

| Dimension | 1 (Low) | 5 (High) |
|-----------|---------|----------|
| **Expected Impact** | Marginal improvement | Transformative change |
| **Novelty** | Variant of recent work | Completely new approach |
| **Risk** | Safe, predictable | Could fail spectacularly |

**Selection rule:** Pick the strategy with the highest combined score (Impact + Novelty + Risk). In case of tie, prefer higher Novelty.

### Phase 2B: Diversity Check

Before executing the selected strategy, check it against the last 3 accepted changes:

```
FOR each of last 3 accepted changes:
    IF selected strategy modifies the same file AND uses the same technique:
        REJECT — select next-highest strategy
    IF selected strategy is a parameter variant of a previously discarded approach:
        REJECT — select next-highest strategy

IF all strategies rejected:
    Trigger cross-domain analogical prompt (see below)
```

## Creativity Constitution

7 rules that govern experiment diversity. The agent MUST follow these throughout the loop.

### Rule 1: 1-in-5 Rule

At least 1 in every 5 experiments must be **fundamentally new** — different file, different technique, different direction from anything in the last 5 iterations.

```
IF last 5 experiments all touch the same file or use the same technique:
    NEXT experiment MUST be category "explore" or "pivot"
```

### Rule 2: No-Repeat Rule

Each change must be **qualitatively different** from the last 3 accepted changes. "Qualitatively different" means at least one of:
- Different file(s) modified
- Different technique applied
- Different aspect of the problem addressed

### Rule 3: Similarity Rejection

Reject hypotheses that are variants of **previously discarded** approaches. If the same technique was tried and discarded (even with different parameters), do not retry it unless:
- At least 10 iterations have passed since the discard
- The context has fundamentally changed (new approach succeeded in between)

### Rule 4: Radical Quota

After every 10 iterations, at least 1 experiment must be **high-risk** (self-rated Risk 4-5). This prevents the agent from settling into a comfortable but unproductive groove.

```
IF iterations_since_last_radical >= 10:
    NEXT experiment MUST have Risk >= 4
    Tag as category "pivot" or "explore"
```

### Rule 5: Cross-Domain Trigger

3 consecutive failures (discards or crashes) trigger the **cross-domain analogical prompting** protocol (see below).

### Rule 6: Pivot Escalation

5 consecutive discards trigger **adversarial negative mining** for the next 2 experiments (see below).

### Rule 7: Anti-Tunnel-Vision

No more than 3 consecutive experiments may modify the **same file**. After 3 consecutive edits to one file, the next experiment MUST target a different file.

```
IF last 3 experiments all modified file X:
    NEXT experiment MUST NOT modify file X
    (Other files in scope are fair game)
```

## Cross-Domain Analogical Prompting Protocol

Triggered by: Rule 5 (3 consecutive failures) or PIVOT mode.

### Step 1: Identify Bottleneck

State the current obstacle in ONE sentence:
```
"The metric is stuck at X because [specific bottleneck]."
```

### Step 2: Recall Analogous Problems

Think of 3 analogous problems from **different domains** — biology, physics, economics, manufacturing, military strategy, architecture, medicine, ecology, music, sports:

```
Domain: [domain name]
Analogous challenge: [similar problem in that domain]
Solution used: [how they solved it]
```

### Step 3: Frame Adaptations

For each analogy, frame it as a concrete adaptation:

```
"In [domain], [analogous challenge] was solved by [technique].
Applied here: [specific adaptation to current codebase/metric]."
```

### Step 4: Generate and Select

Generate 3 hypotheses from the analogies. Self-evaluate on Impact/Novelty/Risk. Select the best one.

### Example

```
Bottleneck: "Test coverage stuck at 88% — all obvious test paths covered."

Analogy 1 (Biology — immune system):
"The immune system finds pathogens by generating random antibodies, not by
searching systematically. Applied here: use mutation testing to randomly
perturb code and find which mutations survive — those reveal weak tests."

Analogy 2 (Manufacturing — quality control):
"Manufacturing uses destructive testing on samples to find failure modes.
Applied here: deliberately inject known bugs and verify tests catch them.
Tests that miss injected bugs are coverage gaps."

Analogy 3 (Military — red teaming):
"Military uses adversarial teams to find defensive weaknesses.
Applied here: write adversarial inputs designed to break validators,
then add tests for each broken case."

Selected: Analogy 1 — mutation testing (Impact: 4, Novelty: 5, Risk: 3 = 12)
```

## Adversarial Negative Mining Protocol

Triggered by: Rule 6 (5 consecutive discards) or PIVOT mode.

### Step 1: Identify Overused Patterns

List the 3 most common change types attempted in recent iterations:

```
1. [Most common change type] — attempted N times
2. [Second most common] — attempted N times
3. [Third most common] — attempted N times
```

### Step 2: Explicitly Forbid

For the next 2 experiments, these change types are **FORBIDDEN**:

```
FORBIDDEN for next 2 experiments:
- [Change type 1]
- [Change type 2]
- [Change type 3]
```

### Step 3: Generate Under Constraint

Generate hypotheses that work WITHIN the constraint. The constraint forces creative thinking — you MUST find approaches that don't rely on the overused patterns.

### Example

```
Overused patterns:
1. "Add unit tests for uncovered functions" — attempted 8 times
2. "Increase branch coverage in conditionals" — attempted 5 times
3. "Add edge case tests for validators" — attempted 4 times

FORBIDDEN: unit tests for functions, branch coverage, validator edge cases

Forced alternatives:
- Integration test for the full request pipeline (different test type)
- Property-based test generation for data models (different technique)
- Error path coverage for async operations (different aspect)
```

## Integration with PIVOT Mode

When plateau detection (`references/plateau-detection.md`) triggers PIVOT mode, novelty generation activates at **maximum stringency**:

| Normal Mode | PIVOT Mode |
|-------------|------------|
| 1-in-5 radical quota | 1-in-3 radical quota |
| Cross-domain on 3 failures | Mandatory cross-domain prompting |
| Adversarial mining on 5 discards | Mandatory adversarial mining |
| Phase 2A generates 3-5 strategies | Phase 2A generates 5+ strategies |
| Select highest combined score | Select highest Novelty score (Impact as tiebreaker) |

### PIVOT Mode Activation Checklist

When entering PIVOT:

```
1. Run adversarial negative mining (forbid top 3 overused patterns)
2. Run cross-domain analogical prompting (3 domain analogies)
3. Generate 5+ strategies from analogies + constrained thinking
4. Score all strategies — select by highest NOVELTY (not combined)
5. Tag experiment as category "pivot" or "explore"
6. Write checkpoint to autoresearch-state.md (see references/session-memory.md)
```

## Integration Points

- **Phase 2 (Ideate):** Replace simple priority list with Phase 2A/2B when plateau status is not NO PLATEAU
- **Phase 7 (Log):** Strategy scores (Impact/Novelty/Risk) inform future hypothesis generation
- **Creativity Constitution:** Rules 1-7 apply at ALL times, not just during plateau
- **Plateau Detection:** PIVOT mode triggers maximum-stringency novelty generation
- **Session Memory:** Untried Directions in state file feed into Phase 2A candidate generation
