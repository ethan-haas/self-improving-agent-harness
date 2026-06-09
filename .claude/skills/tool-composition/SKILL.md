---
name: tool-composition
description: Archives winning MCP tool chains. When a coder discovers a sequence of MCP calls that solves a recurring task type (e.g., Context7 → WebFetch → Edit), this skill records the recipe so future runs can replay it directly. Invoked by archivist after task completion.
version: 0.1.0
---

# Tool Composition

Records recipes — sequences of MCP tool calls that have been verified to solve a task class.

## When to record

A composition is worth recording only if ALL three hold:

1. The sequence ran end-to-end without revision (no backtracking)
2. The final task passed all 7 verifier tiers
3. The sequence was non-trivial (≥3 distinct tools) OR uses a novel tool combination

## Recipe schema

```yaml
# .claude/skills/tool-composition/recipes/<recipe-slug>.yaml
name: <kebab-case>
description: <one line — when to use this recipe>
task_class: <descriptor: "API integration | data migration | doc search | ...">
tools:
  - tool: <tool-name>
    purpose: <one line>
  - tool: <tool-name>
    purpose: <one line>
preconditions:
  - <one line each>
postconditions:
  - <one line each>
provenance: archive/gen-NNNN/agent-MMMM
```

## Workflow

1. Archivist receives signal from coder via `workspace/<task>/composition-hint.md`
2. Read the task's autoresearch results.tsv → confirm criteria above
3. Extract the tool sequence from `logs/agent.jsonl` (tool_name field)
4. Generate the recipe YAML
5. Stage as scaffold-edit proposal — recipe lives under `.claude/skills/tool-composition/recipes/`

## Replay

When a new task arrives, the orchestrator scans `task_class` fields and surfaces matching recipes to the planner. The planner can either:
- Use the recipe as-is (replay mode)
- Use it as a starting hypothesis (adapt mode)
- Ignore it if the task differs materially

## Pruning

Recipes with 0 invocations in 60 days are deprecated (same as voyager-skill-discover deprecation pass). Recipes that have been superseded (a newer recipe with higher success rate covers the same task class) are tombstoned.

## Reference

Anthropic AAR pattern (2025): forum-shared tool compositions across parallel agents lifted PGR by ~5pp vs isolated agents. The recipe-archive approach here is the asynchronous, single-machine version.
