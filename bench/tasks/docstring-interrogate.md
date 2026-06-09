# docstring-interrogate: drive docstring coverage to 100%

## Goal
Add docstrings to every public + private function, method, and class in `workspace/example-docs/graph.py` until `interrogate` reports **100%** coverage. All 16 tests must keep passing.

Baseline: 0/14 (0%). Items missing: module-level docstring, `Graph` class, all 6 Graph methods, 5 module-level functions, 1 nested `_dfs` inside `has_cycle`.

## Scope
- `workspace/example-docs/graph.py`
- `workspace/example-docs/tests/test_graph.py` (READ ONLY)

## Metric
`interrogate` coverage percentage (integer). Higher is better. Target: **100**.

## Verify
```bash
python -m pytest workspace/example-docs/tests/test_graph.py -q && \
python -c "import subprocess,re; r=subprocess.run(['python','-m','interrogate','workspace/example-docs/graph.py'], capture_output=True, text=True); m=re.search(r'actual:\s*([\d.]+)%', r.stdout); print(int(round(float(m.group(1))))) if m else print(0)"
```

## Guard
```bash
python -m pytest workspace/example-docs/tests/test_graph.py -q
```
16 tests must pass at every iteration.

## Budget
- Iterations: 3
- Wall-clock: 15 min

## Specialist chain
coder → reviewer

## Style rules
- One-line summary on the first line, ending in a period.
- Optional second paragraph for params/returns if non-obvious from signature.
- No need for full reST/Google/Numpy block-format -- interrogate only counts presence, not format.
- Module-level docstring goes at the very top, BEFORE `from __future__ import annotations`.

## Anti-patterns
- Do NOT add empty `"""..."""` placeholder docstrings. interrogate may count them but reviewer will flag as noise; static-critic style-2 (readability) won't, but style-4 (devils-advocate) might. Write one-line specifics.
- Do NOT modify the test file (out of scope).
- Do NOT use `# noqa` or `# interrogate: ignore`.

## Hint
14 items total: 1 module + 1 class + 6 methods (`__init__`, `add_node`, `add_edge`, `neighbors`, `nodes`, `edges`) + 5 module functions (`bfs`, `dfs`, `shortest_path`, `connected_components`, `has_cycle`) + 1 nested function (`_dfs` inside `has_cycle`). All 14 need a docstring to reach 100%.
