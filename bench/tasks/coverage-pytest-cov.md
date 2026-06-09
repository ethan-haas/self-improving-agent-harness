# coverage-pytest-cov: drive validators.py line coverage to 100%

## Goal
Add tests to `workspace/example-cov/tests/test_validators.py` until `pytest --cov` reports **100%** line coverage on `workspace/example-cov/validators.py`. All existing tests must keep passing.

Baseline: 49% (31 of 61 lines uncovered).

## Scope
- `workspace/example-cov/tests/test_validators.py` (extend with new tests)
- `workspace/example-cov/validators.py` (READ ONLY)

This task is different from the others: the agent WRITES tests, doesn't refactor source.

## Metric
Line coverage % on `validators.py`. Higher is better. Target: **100**.

## Verify
```bash
python -m pytest workspace/example-cov/tests/test_validators.py -q && \
python -c "import subprocess,re; r=subprocess.run(['python','-m','pytest','workspace/example-cov/tests/test_validators.py','--cov=workspace/example-cov/validators','--cov-report=term','-q'],capture_output=True,text=True); m=re.search(r'validators\.py\s+\d+\s+\d+\s+(\d+)%',r.stdout); print(int(m.group(1)) if m else 0)"
```

## Guard
```bash
python -m pytest workspace/example-cov/tests/test_validators.py -q
```
All tests must pass at every iteration.

## Budget
- Iterations: 5
- Wall-clock: 20 min

## Specialist chain
coder → reviewer

## Uncovered lines (from baseline run)
`14, 17, 19, 21, 24, 26, 33, 36, 38-40, 45-52, 58, 60, 62, 64-65, 70-77`

Branches to cover (group your new tests by function):

**validate_email** — missing branches:
- non-string input (line 14)
- empty after strip (line 17)
- >254 chars (line 19)
- bad format regex miss (line 21)
- local-part leading/trailing dot (line 24)
- double-dot in local or domain (line 26)

**parse_phone** — missing branches:
- non-string input (line 33)
- no digits (line 36)
- starts-with-+ valid range (38-40)
- US 11-digit starting with 1 (line 45-52 mostly)
- US bad length
- GB country valid + bad
- unsupported country

**format_currency** — missing branches:
- bool rejection (line 58)
- non-number rejection (line 60)
- NaN check (line 62)
- negative amount (lines 64-65)
- EUR / GBP / JPY paths (lines 70-77)
- unsupported currency

## Anti-patterns (reviewer enforces)
- **No empty assertions** (`assert True` or no `assert` at all). Every new test must check something specific.
- **No mocking validators internals.** Test the public surface.
- Do NOT modify validators.py — out of scope. If a branch seems untestable, that's a finding for a future refactor task, not this one.
- Do NOT use `# pragma: no cover` markers.

## Hint
Aim for one test per branch. ~25 new tests should hit 100%. Use `pytest.mark.parametrize` for cleaner grouping.
