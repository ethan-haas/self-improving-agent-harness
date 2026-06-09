---
name: prebuilt-c-extension
description: Prebuild C extension externally, commit binary blob via git diff --binary, load via ctypes at module init. Avoids replay-drift quarantine on cold sandbox replays. Use when task is CPU-bound and pure-Python ceiling hit.
---

# prebuilt-c-extension

Safely add a C-extension speedup to a solver without tripping the host's
Replay-Archive cold-sandbox drift check. The host re-runs solvers in fresh
Windows Sandbox VMs with NO toolchain; any solver that tries to compile at
import time will fail replay and be quarantined.

## When to invoke

- Pure-Python inner loop saturates the CPU (one hot kernel >70% wall).
- Plateau ladder reached NEXT-RUNG / META tier.
- Expected speedup from C is >=10x (otherwise NumPy/Cython aren't worth it).
- Examples: 2-opt swap loop (tsp-multi), n-body force kernel, prime sieve
  bitset, count-inversions merge step.

## Forbidden patterns (will REJECT at replay)

Quoted from `bench/tasks/tsp-multi.md`:
> "Replay-drift hardening: DO NOT compile C extensions inside solver.py's
> import path. Pre-build any DLL/.so externally, commit binary via git diff
> --binary --full-index, load via ctypes at module init."

Concretely, in `solver.py` or any module it imports:

- NO `subprocess.run(["cl", ...])` / `subprocess.run(["gcc", ...])`
- NO `setuptools.setup(..., ext_modules=...)` build invocations
- NO `cffi.FFI().set_source(...).compile()`
- NO `Cython.Build.cythonize(...)` at runtime
- NO `os.system("make")`, no `pip install` of a source-only package
- NO `Python.h` dependency (CPython API binds to interpreter version;
  ctypes-loadable extern "C" only)

## Required pipeline

### a. Author pure-C source (no Python.h)

`workspace/<task>/ext/<name>.c`:

```c
// no Python.h. extern C, ctypes-loadable.
#include <stddef.h>
#ifdef _WIN32
  #define EXPORT __declspec(dllexport)
#else
  #define EXPORT
#endif

EXPORT double two_opt_delta(const double *xy, const int *tour, int n,
                             int i, int j) {
    // ... pure C, no allocations in hot loop ...
    return 0.0;
}
```

### b. Build externally (NOT in solver import path)

Windows (host runner platform):

```powershell
cl.exe /LD /O2 /Fe:ext/<name>.dll ext/<name>.c
```

Linux/WSL dev fallback:

```bash
gcc -shared -O3 -fPIC -o ext/<name>.so ext/<name>.c
```

Build is a HUMAN/dev step, run once outside the agent loop. Commit the
resulting binary. Do NOT script the build from solver.py.

### c. Commit binary blob via git binary diff

```bash
git add workspace/<task>/ext/<name>.dll
git diff --staged --binary --full-index | head -5
# Should show "GIT binary patch" or "Binary files ... differ" with
# index lines containing full sha for both sides.
git commit -m "ext: prebuilt <name>.dll for ctypes load"
```

The binary travels with the diff applied by the host runner in fresh
sandbox. No build needed at replay time.

### d. Load via ctypes at module init

`solver.py`:

```python
import ctypes, os
_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB_NAME = "<name>.dll" if os.name == "nt" else "<name>.so"
_lib = ctypes.CDLL(os.path.join(_HERE, "ext", _LIB_NAME))

_lib.two_opt_delta.argtypes = [
    ctypes.POINTER(ctypes.c_double),  # xy
    ctypes.POINTER(ctypes.c_int),     # tour
    ctypes.c_int,                     # n
    ctypes.c_int,                     # i
    ctypes.c_int,                     # j
]
_lib.two_opt_delta.restype = ctypes.c_double
```

### e. Call from hot loop

Pass numpy arrays via `arr.ctypes.data_as(ctypes.POINTER(ctypes.c_double))`
or `(ctypes.c_int * n)(*python_list)` for small fixed buffers. Cache the
buffer pointers outside the loop.

## Drift verification (mandatory before staging)

The host runs a Replay-Archive sweep: cold sandbox, fresh checkout, apply
diff, import solver. If `.dll`/`.so` missing OR if any compile is invoked,
REJECTed and quarantined.

Local pre-check:

```bash
# Simulate cold sandbox: nuke __pycache__, import in subprocess with -S
python -S -c "import sys; sys.path.insert(0, 'workspace/<task>'); import solver"
# Must succeed without invoking gcc/cl/setuptools.
python -S -c "import ctypes; ctypes.CDLL('workspace/<task>/ext/<name>.dll')"
# Must load cleanly.
```

If either fails locally, it WILL fail replay. Fix before staging.

## Cross-platform notes

- Host runner is Windows 11 Sandbox -> `.dll` is canonical.
- Build on Windows with MSVC `cl.exe` (Build Tools for VS, free).
- Linux WSL `.so` only valid if dev environment matches host (rare; skip).
- Do NOT ship both `.dll` and `.so` unless solver tries both via
  `if os.name == "nt"` and the host actually runs Linux replays.

## Test checklist before staging

1. `file workspace/<task>/ext/<name>.dll` reports PE32+ (Windows DLL).
2. `git ls-files workspace/<task>/ext/` shows the binary tracked.
3. `git diff HEAD~1 --stat` shows the binary in the commit, size > 0.
4. `python -S -c "..."` cold-import succeeds (see drift verification).
5. Solver metric improved by >=10x on `time python solver.py`.

## Failure modes captured

- gen-0044: meta-improver tried to author this skill but missed
  diff.patch + manifest.json staging files. Skill not produced. Retry =
  gen-0047 (this file).
- Replay-drift quarantine triggers if `import solver` does ANY of: spawn
  process, write to fs, sleep > 100ms, or fails to load DLL. Keep
  module-init under 50ms.
