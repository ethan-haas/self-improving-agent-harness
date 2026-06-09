"""bench/run.py — host runner invokes this to compute the composite bench metric.

Subscription mode: this script must NOT call any LLM API. It's pure mechanical scoring
over bench/tasks/* outcomes recorded by the agent's workspace/.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def score_task(task_path: Path, workspace_root: Path) -> float:
    """Return [0, 1] score for a single bench task."""
    task_id = task_path.stem
    outcome = workspace_root / "outcomes" / f"{task_id}.json"
    if not outcome.exists():
        return 0.0
    try:
        data = json.loads(outcome.read_text(encoding="utf-8"))
    except Exception:
        return 0.0
    if data.get("status") == "passed":
        return float(data.get("score", 1.0))
    return 0.0


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    tasks_dir = root / "bench" / "tasks"
    workspace = root / "workspace"

    tasks = list(tasks_dir.glob("*.md"))
    if not tasks:
        print("0.0")
        return 0

    total = sum(score_task(t, workspace) for t in tasks)
    print(f"{total / len(tasks):.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
