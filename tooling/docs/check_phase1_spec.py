#!/usr/bin/env python3
"""Phase 1 spec consistency gate (T24).

Fails when the frozen spec, traceability, checklist and completion matrix drift
apart. It is intentionally dependency-free and read-only; it never fixes files.

Checks:
  1. capability-spec.md AC ids == traceability.md AC rows (ids and count).
  2. D2-03-AC4 (v1.1 request headers) is present in both.
  3. completion-matrix.md lists every AC and every one of the 44 checklist steps.
  4. test-plan.md still documents the L4-Real / L4-Process evidence tiers.
  5. No `L4→T22` placeholder is left in traceability once COMPLETION_FINAL=1.

Run: python3 tooling/docs/check_phase1_spec.py [--repo PATH]
Exit: 0 ok, 1 drift, 2 usage.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

AC = re.compile(r"^\s*-\s+\*\*((?:D\d-\d+|PERSIST-01)-AC\d+)\*\*", re.M)
AC_ROW = re.compile(r"^\|\s*((?:D\d-\d+|PERSIST-01)-AC\d+)\s*\|", re.M)
STEP_ROW = re.compile(r"^\|\s*([A-G]\d{1,2})\s*\|", re.M)
CHECK_STEP = re.compile(r"^-\s+\[\s\]\s+\*\*([A-G]\d{1,2})\b", re.M)


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"check_phase1_spec: cannot read {path}: {error}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    specs = repo / "docs" / "specs" / "phase1"

    spec = read(specs / "capability-spec.md")
    trace = read(specs / "traceability.md")
    matrix = read(specs / "completion-matrix.md")
    checklist = read(specs / "acceptance-checklist.md")
    test_plan = read(specs / "test-plan.md")

    spec_ids = AC.findall(spec)
    row_ids = AC_ROW.findall(trace)
    problems: list[str] = []

    if len(spec_ids) != len(set(spec_ids)):
        problems.append("capability-spec has duplicate AC ids")
    if len(row_ids) != len(set(row_ids)):
        problems.append("traceability has duplicate AC rows")
    if set(spec_ids) != set(row_ids):
        missing = sorted(set(spec_ids) - set(row_ids))
        extra = sorted(set(row_ids) - set(spec_ids))
        problems.append(f"spec/traceability AC sets differ: missing={missing} extra={extra}")
    if "D2-03-AC4" not in spec_ids:
        problems.append("D2-03-AC4 missing from capability-spec (v1.1 request headers)")

    matrix_ids = set(AC_ROW.findall(matrix))
    if set(spec_ids) != matrix_ids:
        problems.append(
            "completion-matrix AC set differs: "
            f"missing={sorted(set(spec_ids) - matrix_ids)} extra={sorted(matrix_ids - set(spec_ids))}"
        )

    check_steps = set(CHECK_STEP.findall(checklist))
    matrix_steps = set(STEP_ROW.findall(matrix))
    if len(check_steps) != 44:
        problems.append(f"acceptance-checklist should have 44 steps, found {len(check_steps)}")
    if check_steps != matrix_steps:
        problems.append(
            "completion-matrix step set differs: "
            f"missing={sorted(check_steps - matrix_steps)} extra={sorted(matrix_steps - check_steps)}"
        )

    for tier in ("L4-Real", "L4-Process"):
        if tier not in test_plan:
            problems.append(f"test-plan.md does not define {tier}")

    if os.environ.get("COMPLETION_FINAL") == "1" and "L4→T22" in trace:
        problems.append("traceability still contains L4→T22 placeholders (COMPLETION_FINAL=1)")

    if problems:
        print("Phase 1 spec check: FAIL")
        for problem in problems:
            print(f" - {problem}")
        return 1
    print(
        "Phase 1 spec check: OK "
        f"({len(spec_ids)} AC, {len(check_steps)} checklist steps, matrix aligned)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
