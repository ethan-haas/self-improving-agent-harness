# Example Task: Refactor `parse_config` for readability

## Goal
Refactor `workspace/example/config.py::parse_config` to reduce cyclomatic complexity from current (≥12) to ≤6 while preserving behavior.

## Scope
- `workspace/example/config.py`
- `workspace/example/tests/test_config.py` (may be extended, not changed)

## Metric
Cyclomatic complexity of `parse_config` as reported by `radon cc -s workspace/example/config.py | grep parse_config | awk '{print $NF}'`. Lower is better.

## Verify
```bash
pytest workspace/example/tests/test_config.py -q && radon cc -s workspace/example/config.py | grep parse_config | awk '{print $NF}'
```

## Guard
```bash
pytest workspace/example/tests/test_config.py -q
```

## Budget
- Iterations: 10
- Wall-clock: 30 min

## Specialist chain
researcher → planner → coder → tester → reviewer
