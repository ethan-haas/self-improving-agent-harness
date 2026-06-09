# count-inversions-perf: O(n^2) -> O(n log n) speedup

## Goal
Rewrite `workspace/example-perf/count_inversions.py::count_inversions` to drop the bench's median ms/op by **at least 10x**. Baseline ~280 ms; target ≤ 30 ms. All 14 tests must keep passing.

## Scope
- `workspace/example-perf/count_inversions.py`
- `workspace/example-perf/tests/test_count_inversions.py` (READ ONLY)
- `workspace/example-perf/bench.py` (READ ONLY -- measurement is the contract)

## Metric
Median ms/op printed by `bench.py`. Lower is better. Target ≤ 30.

## Verify
```bash
python -m pytest workspace/example-perf/tests/test_count_inversions.py -q && \
python workspace/example-perf/bench.py
```

## Guard
```bash
python -m pytest workspace/example-perf/tests/test_count_inversions.py -q
```
14 tests must pass at every iteration.

## Budget
- Iterations: 8
- Wall-clock: 30 min

## Specialist chain
researcher → planner → coder → reviewer

## Hint
Classic inversion counting reduces to a modified merge sort with O(n log n) work. The hard part is the contract — `count_inversions` returns an int, takes a list, must handle empty/single/duplicate/negative/sorted/reverse cases identically. The bench input is `[random.randint(-10000, 10000) for _ in range(4000)]` with seed 42. 4000^2 / 2 = 8M comparisons baseline; merge sort does ~50K comparisons.

## Anti-pattern
Do NOT cache the bench's specific seeded array's answer and short-circuit. That's reward hacking and will trip the post-tool detector.

## Baseline (informational)
- Bench p50: ~280 ms (3-run median)
- All 14 tests pass at HEAD
