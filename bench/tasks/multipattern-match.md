# multipattern-match: multi-pattern substring search sub-second

## Goal
Beat baseline `str.find` loop on 5MB text + 5000 patterns. Baseline ~13s. Target <=2.0s (Aho-Corasick or equivalent). Stretch <=0.1s (C extension).

## Scope
- `workspace/multipattern-match/solver.py`  (MUTABLE — only find_all function)
- `workspace/multipattern-match/check.py`  (READ ONLY — frozen verifier, oracle-gaming trip)
- `workspace/multipattern-match/corpus.py`  (READ ONLY — frozen deterministic corpus generator)
- `workspace/multipattern-match/tests/test_correctness.py`  (READ ONLY — 8 sanity tests)
- `workspace/multipattern-match/README.md`  (READ ONLY)

## Metric
Wall-clock seconds for find_all on 5MB text + 5000 patterns. Parsed from last line `METRIC=<seconds>` of check.py. Target <=2.0.

## Verify
```bash
cd workspace/multipattern-match && python -m pytest tests/ -q && python check.py
```

## Guard
```bash
cd workspace/multipattern-match && python -m pytest tests/ -q
```
8 sanity tests must pass each iteration. Ground-truth `total=258249` and `pattern_hash=12e4e7cd5f1d800e` enforced.

## Budget per /orchestrate call
- Iterations per gen: 10
- Generations per call: 15
- Wall-clock per gen: 60 min

## Specialist chain
researcher → planner → coder → reviewer → archivist

## Plateau ladder (planner hint)

| Mode | Direction | Expected |
|---|---|---|
| EXPLOIT | First-char hash bucket — skip patterns whose first char isn't present at scan position | ~5-8s |
| EXPLOIT | Group patterns by first 2 chars, jump-table dispatch | ~3-5s |
| REFINE | Pure-Python Aho-Corasick automaton (goto + failure links) | ~1-2s |
| REFINE | Aho-Corasick + bytes ops (encode text/patterns once, operate on bytes) | ~0.5s |
| PIVOT | Commentz-Walter (BM-style suffix-shift on Aho-Corasick) | ~0.3s |
| META | C extension via ctypes; PRE-BUILT .dll/.so, committed via `--binary --full-index` | ~0.05s |

If gens 1-3 plateau at >5s with simple optimizations, planner should commit to building Aho-Corasick. If gens 6+ plateau at ~0.5s on pure Python, signal `agenta/sentinels/multipattern-match-no-direction.md` to escalate to meta-improver for C-extension scaffolding.

## Heartbeat protocol (NEW — mandatory per coder.md)

Coder MUST write `agenta/sentinels/multipattern-match-heartbeat.json` each autoresearch iter:
```json
{
  "task": "multipattern-match",
  "iter": <int>,
  "ts": "<ISO>",
  "last_metric": <float>,
  "best_metric": <float>,
  "last_action": "<short>",
  "elapsed_s": <float>
}
```
Host watchdog fires `multipattern-match-stuck.md` if no update >15min. Long-running but progressing tasks remain safe.

## Anti-patterns (auto-quarantine)

- Hardcoding `return 258249` → reviewer rejects + post-tool hack-detector trips
- Modifying check.py/corpus.py/tests/* → oracle gaming REJECT
- Using third-party deps (pyahocorasick, regex.compile, ahocorasick) — out of scope; reviewer REJECT (must be in-tree)
- Compile-on-import C extension (gen-0001 prime-sieve trap) → replay-drift; reviewer REJECT
- Caching `find_all` result to disk → cold-run timed, subsequent runs are reproducibility failures
- Pre-computing for THIS corpus only and hardcoding lookup → reward hacking; reviewer pattern-checks

## Replay-drift hardening

Per gen-0001 prime-sieve incident: do NOT compile DLLs inside solver.py's import path. Pre-build any C extension, commit binary via `git diff --binary --full-index`, load via ctypes at module init. Otherwise cold-sandbox replay shows compile-time inside timer = drift CRITICAL → quarantine.

## Baseline (informational)

- `python check.py` at HEAD: PASS total=258249, time ~12.913s
- Baseline commit: `2ca4ef27636ce1a4160eef04bebcd47c89a142e4`
- 8 sanity tests pass

## Nested-repo notes

Inner repo at `workspace/multipattern-match/`. Manifest MUST set `repo_root: workspace/multipattern-match`. Host runs `git -C workspace/multipattern-match worktree add --detach <baseline>`. Tier 5/6 skipped (external-repo). Tier 0 (review-gate), 1-4, 7 still apply.

## Why this task tests the reorganized pipeline

| Infra component | Exercised by |
|---|---|
| `agenta/tasks/` location | task lives here, all spec paths use it |
| `agenta/infra/staged/` | coder stages diff here |
| `agenta/sentinels/` | heartbeat + status + stuck files land here |
| `agenta/infra/lessons-inbox/` | archivist writes here, host polls every 30s |
| Junctions backward-compat | old archive manifests with workspace/... refs still resolve |
| Review-gate (tier 0) | reviewer must APPROVE before host promotes |
| Replay-Archive new parser | METRIC=<x> line correctly extracted (no false positives) |
| Heartbeat watchdog | hang detection live during multi-gen coder runs |
| Memory-aware planner | reads EXPERIMENTS_TRIED from past iterations + LESSONS_FILTERED |
| Plateau ladder | 6-tier ladder, multiple PIVOT options |
| Meta-improver path | C-extension scaffolding when Python ceiling hit (~0.5s) |
| Continuous outer-loop | multi-gen run until target/plateau/sentinel/cap |
| Lessons compounding | each gen's lesson informs next gen's planner |
