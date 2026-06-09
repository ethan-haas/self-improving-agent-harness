# dead-code-vulture: drive vulture findings to zero

## Goal
Remove dead code from `workspace/example-dead/calc.py` so `vulture --min-confidence 60` reports **zero** findings. All 14 tests must keep passing.

Baseline: 15 findings (4 unused imports, 5 unused functions/methods, 1 unreachable block, 1 unused class, 2 unused attrs/vars, etc.).

## Scope
- `workspace/example-dead/calc.py`
- `workspace/example-dead/tests/test_calc.py` (READ ONLY)

## Metric
Count of vulture findings (lines matching `:line: <category>` pattern). Lower is better. Target: 0.

## Verify
```bash
python -m pytest workspace/example-dead/tests/test_calc.py -q && \
python -c "import subprocess; r=subprocess.run(['python','-m','vulture','workspace/example-dead/calc.py','--min-confidence','60'], capture_output=True, text=True); print(len([l for l in r.stdout.splitlines() if ':' in l]))"
```

Last line of stdout is the metric (integer count). Vulture's non-zero exit code is normal — the Python wrapper above swallows it; pytest's exit code is what matters for verify_exit_code.

## Guard
```bash
python -m pytest workspace/example-dead/tests/test_calc.py -q
```
14 tests must pass at every iteration.

## Budget
- Iterations: 5
- Wall-clock: 15 min

## Specialist chain
coder → reviewer (research/plan unnecessary -- vulture output is the plan)

## Anti-patterns
- Do NOT comment-out the dead code (vulture still flags noqa-style comments in some patterns; just delete it).
- Do NOT add `# noqa` or `# vulture: ignore` markers. The metric MUST drop because the code is gone, not because warnings are suppressed.
- Do NOT delete tests to "make vulture cleaner" -- guard pytest is non-negotiable.

## Hint
The dead items are: unused imports (json, os, dataclass, Any), unused functions (fibonacci, gcd, is_prime, _early_return_dead, factorial), unused class (Calculator) and its members, unused constants (UNUSED_PI, UNUSED_E), unreachable code after a return statement. `math` import is only needed if `factorial` stays — but `factorial` is itself dead, so `math` goes too. Cascade: removing dead callers may un-need their imports.
