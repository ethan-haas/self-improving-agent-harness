# maintainability-radon-mi: lift Maintainability Index to >= 80

## Goal
Refactor `workspace/example-maint/sched.py` so `radon mi` reports MI ≥ **80**. All 12 tests must keep passing.

Baseline: 38.70 (A-rank but low). Symptoms: single-letter names, no docstrings, 1-space indents, deeply nested loops, mystery booleans, no whitespace, no type hints, dead else branches with `pass`.

## Scope
- `workspace/example-maint/sched.py`
- `workspace/example-maint/tests/test_sched.py` (READ ONLY)

This is harder than per-function CC because MI is a composite of:
- **Halstead volume** (token count + uniqueness)
- **Cyclomatic complexity** (branches)
- **Lines of code**
- **Comment ratio**
Improving one without improving others won't move MI much. Have to fix all four.

## Metric
Maintainability Index reported by `radon mi -s`. Higher is better. Target: **≥80**.

## Verify
```bash
python -m pytest workspace/example-maint/tests/test_sched.py -q && \
python -c "import subprocess,re; r=subprocess.run(['radon','mi','workspace/example-maint/sched.py','-s'], capture_output=True, text=True); m=re.search(r'\(([\d.]+)\)', r.stdout); print(int(round(float(m.group(1))))) if m else print(0)"
```

## Guard
```bash
python -m pytest workspace/example-maint/tests/test_sched.py -q
```
12 tests must pass at every iteration.

## Budget
- Iterations: 5
- Wall-clock: 25 min

## Specialist chain
coder → reviewer

## Tactic
- **Rename** `s`/`g`/`h` to `place`/`durations_by_key`/`prune_by_limit`. Test imports refactor-friendly: shim the old names back as aliases at module bottom (`s = place; g = durations_by_key; h = prune_by_limit`) so tests still import.
- **Split** the 30-line `s` body into small helpers: `_merge_intervals`, `_group_by_key`, `_resolve_conflicts`, `_order_output`. Each ≤ CC 4.
- **Docstrings** on every public function (interrogate-style).
- **Type hints** on every signature.
- **Remove dead `else: pass`** branches.
- **PEP-8 indent** (4 spaces, not 1). Radon counts physical lines too — proper formatting helps.
- **Single-letter loop vars** stay (radon doesn't penalize iter vars), but `t/d/p` params should become `tasks/ascending/priorities`.

## Anti-patterns
- Do NOT delete the test-required symbols (`s`, `g`, `h`). Aliases at module bottom preserve import contract.
- Do NOT modify the test file.
- Do NOT add `# noqa: maintainability` markers.

## Hint
After refactor, also run:
```bash
radon raw workspace/example-maint/sched.py   # see LOC + comment breakdown
radon cc workspace/example-maint/sched.py    # per-function CC
```
to verify all the underlying inputs to MI dropped. If MI plateaus < 80, add module-level docstring + comment-to-code-ratio boost.
