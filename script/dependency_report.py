#!/usr/bin/env python3
"""Render the lookup log of pinned Renovate 44.143.0 without exposing raw config."""

import argparse
import html
import json
from pathlib import Path


def collect(log):
    packages = None
    warnings = 0
    for line in log.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        if isinstance(record.get("level"), int) and record["level"] >= 40:
            warnings += 1
        if record.get("msg") == "packageFiles with updates":
            packages = record.get("config")
    if not isinstance(packages, dict) or not packages:
        raise ValueError("Renovate did not produce a dependency lookup result.")
    rows = []
    for manager, files in packages.items():
        for package in files:
            for dep in package.get("deps", []):
                if manager == "dockerfile" and dep.get("depType") == "install":
                    continue  # This task checks base images, not apt packages.
                row = {
                    "manager": manager,
                    "file": package.get("packageFile", "unknown"),
                    "dependency": dep.get("depName", "unknown"),
                    "constraint": dep.get("currentValue", "unknown"),
                    "current": dep.get("lockedVersion") or dep.get("currentVersion")
                    or dep.get("currentValue") or dep.get("currentDigest") or "unknown",
                    "updates": [],
                    "problem": dep.get("skipReason") or
                    ("lookup-warning" if dep.get("warnings") else ""),
                }
                for update in dep.get("updates", []):
                    row["updates"].append({
                        "type": update.get("updateType", "unknown"),
                        "version": update.get("newVersion") or update.get("newValue")
                        or update.get("newDigest") or "unknown",
                        "reference": update.get("newDigest") or update.get("newValue") or "",
                    })
                rows.append(row)
    if not rows:
        raise ValueError("No dependencies were extracted for the selected scope.")
    return {"dependencies": rows, "warning_count": warnings}


def cell(value):
    return html.escape(str(value)).replace("|", "&#124;").replace("\n", " ").replace("\r", " ")


def render(data, scope, revision, failed=False):
    incomplete = failed or data.get("error") or data.get("warning_count", 0) or any(
        row["problem"] for row in data.get("dependencies", [])
    )
    lines = ["# Dependency check", "", f"Scope: {cell(scope)}. Revision: {cell(revision)}.", "",
             "Status: **incomplete**." if incomplete else "Status: **lookup completed**.", "",
             "Read-only lookup. No files, branches, pull requests or container tags were changed.",
             "Candidates require review and relevant validation before adoption. This is not a vulnerability scan.", ""]
    if data.get("error"):
        lines += [data["error"], ""]
    rows = data.get("dependencies", [])
    for title, major in [("Major update candidates", True), ("Other update candidates", False)]:
        lines += [f"## {title}", ""]
        updates = [(row, update) for row in rows for update in row["updates"]
                   if (update["type"] == "major") == major]
        if not updates:
            lines += ["No candidates in the available lookup results.", ""]
            continue
        lines += ["| Dependency | File | Current | Candidate | Type | Target reference |",
                  "| --- | --- | --- | --- | --- | --- |"]
        for row, update in updates:
            values = [row["dependency"], row["file"], row["current"], update["version"],
                      update["type"], update["reference"]]
            lines.append("| " + " | ".join(cell(v) for v in values) + " |")
        lines.append("")
    lines += ["## Examined dependency inventory", "",
              "Constraints remain in force. No candidate does not prove compatibility, security or global freshness.", "",
              "| Manager | File | Dependency | Current | Constraint/reference | Lookup issue |",
              "| --- | --- | --- | --- | --- | --- |"]
    for row in rows:
        lines.append("| " + " | ".join(cell(row[key]) for key in
                     ["manager", "file", "dependency", "current", "constraint", "problem"]) + " |")
    lines += ["", f"Renovate warning/error log records: {data.get('warning_count', 0)}.",
              "Raw configuration and logs are not included in the downloadable report.", ""]
    return "\n".join(lines), bool(incomplete)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--scan-failed", action="store_true")
    args = parser.parse_args()
    try:
        data = collect(args.log.read_text() if args.log.exists() else "")
    except ValueError as error:
        data = {"error": str(error), "dependencies": [], "warning_count": 0}
    report, incomplete = render(data, args.scope, args.revision, args.scan_failed)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "dependency-report.md").write_text(report)
    (args.output / "dependency-report.json").write_text(json.dumps(data, indent=2) + "\n")
    return 1 if incomplete else 0


if __name__ == "__main__":
    raise SystemExit(main())
