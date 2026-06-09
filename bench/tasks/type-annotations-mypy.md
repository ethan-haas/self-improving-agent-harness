# type-annotations-mypy: drive mypy --strict errors to zero

## Goal
Add type annotations to `workspace/example-types/strops.py` until `mypy --strict` reports **zero** errors. All 27 tests must keep passing.

Baseline: 11 errors (10 missing function annotations + 1 var-annotated for `h` dict).

## Scope
- `workspace/example-types/strops.py`
- `workspace/example-types/tests/test_strops.py` (READ ONLY)

## Metric
Count of mypy errors reported by `--strict`. Lower is better. Target: 0.

## Verify
```bash
python -m pytest workspace/example-types/tests/test_strops.py -q && \
python -c "import subprocess; r=subprocess.run(['python','-m','mypy','--strict','workspace/example-types/strops.py'], capture_output=True, text=True); print(sum(1 for l in r.stdout.splitlines() if 'error:' in l))"
```

Last stdout line is the metric.

## Guard
```bash
python -m pytest workspace/example-types/tests/test_strops.py -q
```
27 tests must pass at every iteration.

## Budget
- Iterations: 5
- Wall-clock: 20 min

## Specialist chain
coder → reviewer

## Type hints needed
- `normalize`, `tokenize`, `parse_csv_line`, `fold_lines` -> `str` and `list[str]`
- `tokenize(s: str, delim: str | None = None) -> list[str]`
- `build_url(scheme: str, host: str, path: str = "", query: dict[str, str | int] | None = None) -> str`
- `redact_secrets(text: str, patterns: list[str]) -> str` (uses `re` from stdlib)
- `counts_by_first_letter(words: list[str]) -> dict[str, int]` — the `h` dict needs an explicit annotation: `h: dict[str, int] = {}`
- `StringPipeline`:
  - `__init__(self, steps: list[Callable[[str], str]] | None = None) -> None`
  - `.steps: list[Callable[[str], str]]`
  - `.then(self, fn: Callable[[str], str]) -> "StringPipeline"`
  - `.run(self, s: str) -> str`
- Import `from collections.abc import Callable` (or `typing.Callable`)

## Anti-pattern
- Do NOT use `Any` to silence errors. mypy --strict will still pass with `Any`, but it defeats the point of strict mode. The reviewer will flag.
- Do NOT add `# type: ignore`. Same reason.
- Do NOT loosen the test contract.
