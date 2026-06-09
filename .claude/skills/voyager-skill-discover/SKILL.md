---
name: voyager-skill-discover
description: Voyager-style skill library curator. Cosine-similarity 0.85 dedupe of proposed new skills against existing .claude/skills/. Weekly deprecation pass on unused skills. Invoked by archivist after coder discovers a reusable helper, or by meta-improver for "add-skill" mutation.
version: 0.1.0
---

# Voyager Skill Discovery

Maintains the skill library as monotone-accumulating except for explicit deprecation pass.

## Inputs

- `New-Skill-Name:` proposed kebab-case name
- `New-Skill-Description:` one-line description (same form as SKILL frontmatter)
- `New-Skill-Content:` proposed full body

## Workflow

### Path A: New skill proposal (most common)

1. Read all `.claude/skills/*/SKILL.md` description fields
2. Build TF-IDF vectors of (proposed description + first 500 chars of body) vs each existing skill
3. Compute cosine similarity. **If max similarity > 0.85 → REJECT.** Suggest extending the matching skill instead.
4. If similarity ≤ 0.85: stage the new skill as a scaffold-edit proposal (`.claude/skills/<new-name>/SKILL.md` written to `agenta/infra/staged/.../staged-skills/<new-name>/SKILL.md`)
5. Append to `workspace/<task>/voyager-additions.md` so the archivist can record it in LESSONS

### Path B: Weekly deprecation pass

Run by host-scheduled monthly meta-judge audit, NOT by agent on demand.

1. Read invocation count per skill from `logs/tokens.jsonl` (correlate by tool_name)
2. Any skill with 0 invocations in last 30 days → propose deprecation as a scaffold-edit
3. Tombstone (don't delete): move to `archive/skills-deprecated/<name>-YYYYMMDD/`

## Cosine implementation

Coarse TF-IDF over alphanumeric tokens. Description fields are weighted 3× over body content (descriptions are the load-bearing surface area).

```python
# Reference snippet — actual implementation lives in workspace per call
from collections import Counter
import math
def cosine(a: str, b: str) -> float:
    ta, tb = Counter(a.lower().split()), Counter(b.lower().split())
    common = set(ta) & set(tb)
    dot = sum(ta[t] * tb[t] for t in common)
    na = math.sqrt(sum(v*v for v in ta.values()))
    nb = math.sqrt(sum(v*v for v in tb.values()))
    return dot / (na * nb) if na and nb else 0.0
```

## Rules

- **Threshold is sacred:** 0.85 cosine. Don't lower to admit pet skills.
- **Description must be specific:** vague descriptions inflate similarity and starve discovery. Reject submissions where description has <3 distinct content words.
- **No silent edits.** New skills go through scaffold-edit staging like any other DGM proposal — they don't get fast-tracked.
- **Skill library cap:** ≤30 skills. Beyond that, mandatory deprecation pass before adding more.

## Reference

Voyager (Wang et al., 2023): NeurIPS — skill library + iterative refinement + curriculum agent. Adapted here for verbose-prompt agents.
