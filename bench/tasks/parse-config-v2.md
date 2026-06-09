# parse-config-v2: tight per-function CC refactor

## Goal
Refactor `workspace/example-v2/config.py::parse_config_v2` (current CC=47, rank F) so that **every function in the module has cyclomatic complexity ≤ 4**, including any helper functions you extract. All 53 tests must keep passing.

This is harder than `example-task` (which had a permissive single-function target) — the constraint applies to the entire module, so naive "extract one big helper" tactics will fail.

## Scope
- `workspace/example-v2/config.py`
- `workspace/example-v2/tests/test_config.py` (READ ONLY — do not modify)

## Metric
Maximum cyclomatic complexity across **all** functions in `config.py`. Lower is better. Target: ≤ 4.

## Verify
```bash
python -m pytest workspace/example-v2/tests/test_config.py -q && \
python -c "from radon.complexity import cc_visit; import pathlib; \
  src=pathlib.Path('workspace/example-v2/config.py').read_text(); \
  print(max(b.complexity for b in cc_visit(src)))"
```

The verify command's last line is the metric (max CC across all functions).

## Guard
```bash
python -m pytest workspace/example-v2/tests/test_config.py -q
```
All 53 tests must pass at every iteration.

## Budget
- Iterations: 15
- Wall-clock: 45 min

## Specialist chain
researcher → planner → coder → reviewer

## Notes for the coder
- Pre-existing `helpers` pattern from gen-0001 won't be enough — that file's `_parse_port` ended at CC=7 even after split. Sub-extraction is required.
- Decision-table / dispatch-dict approaches eliminate branches: build a map of `(predicate, transform)` pairs and apply.
- Validator chains (`Pipeline` of single-purpose functions) collapse nested if/elif into linear composition.
- Regex pre-compilation outside functions keeps function bodies branch-free.
- A function that just calls 6 helpers in sequence has CC=1; that's the target shape for `parse_config_v2`.

## Baseline (informational)
- Before any edits: `parse_config_v2` CC = **47** (radon rank F)
- After gen-0001 example-task: `parse_config` CC = 1 (split into 7 helpers ranging CC 3-7) — proves the "split-by-section" pattern but is NOT tight enough for this task's per-function ≤ 4 rule.
