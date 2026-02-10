#!/usr/bin/env python3
"""Compute doc/test coverage and update README badges."""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "src"
README_PATH = ROOT / "README.md"

DOC_DECL_RE = re.compile(r"^\s*pub\s+(const|fn|var|usingnamespace|extern|export)\b")
PUB_FN_RE = re.compile(r"^\s*pub\s+fn\s+(\w+)")
COVERS_RE = re.compile(r"//\s*covers:\s*(.+)")


def read_lines(path: pathlib.Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines()


def doc_coverage(src_dir: pathlib.Path) -> tuple[int, int, list[str]]:
    total = 0
    documented = 0
    missing: list[str] = []
    for path in sorted(src_dir.glob("*.zig")):
        lines = read_lines(path)
        for idx, line in enumerate(lines):
            if not DOC_DECL_RE.match(line):
                continue
            total += 1
            j = idx - 1
            while j >= 0 and lines[j].strip() == "":
                j -= 1
            if j >= 0 and (lines[j].lstrip().startswith("///") or lines[j].lstrip().startswith("//!")):
                documented += 1
                continue
            missing.append(f"{path.name}:{idx + 1}:{line.strip()}")
    return documented, total, missing


def public_functions(src_dir: pathlib.Path, exclude: set[str]) -> list[str]:
    funcs: list[str] = []
    for path in sorted(src_dir.glob("*.zig")):
        if path.stem in exclude:
            continue
        lines = read_lines(path)
        for line in lines:
            match = PUB_FN_RE.match(line)
            if match:
                funcs.append(f"{path.stem}.{match.group(1)}")
    return funcs


def coverage_tags(src_dir: pathlib.Path) -> set[str]:
    tags: set[str] = set()
    for path in sorted(src_dir.glob("*.zig")):
        for line in read_lines(path):
            match = COVERS_RE.search(line)
            if not match:
                continue
            raw = match.group(1)
            for token in re.split(r"[\s,]+", raw.strip()):
                if token:
                    tags.add(token)
    return tags


def percent(part: int, total: int) -> int:
    if total == 0:
        return 100
    return int(round((part / total) * 100))


def badge_url(label: str, pct: int) -> str:
    if pct >= 100:
        color = "brightgreen"
    elif pct >= 90:
        color = "green"
    elif pct >= 80:
        color = "yellowgreen"
    elif pct >= 60:
        color = "orange"
    else:
        color = "red"
    label_enc = urllib.parse.quote(label)
    msg_enc = urllib.parse.quote(f"{pct}%")
    return f"https://img.shields.io/badge/{label_enc}-{msg_enc}-{color}"


def update_readme(doc_pct: int, test_pct: int) -> bool:
    if not README_PATH.exists():
        return False
    start = "<!-- coverage-badges:start -->"
    end = "<!-- coverage-badges:end -->"
    doc_badge = f"![Doc Coverage]({badge_url('doc coverage', doc_pct)})"
    test_badge = f"![Test Coverage]({badge_url('test coverage', test_pct)})"
    block = f"{start}\n{doc_badge}\n{test_badge}\n{end}"

    text = README_PATH.read_text(encoding="utf-8")
    if start in text and end in text:
        pattern = re.compile(rf"{re.escape(start)}.*?{re.escape(end)}", re.DOTALL)
        new_text = pattern.sub(block, text)
    else:
        lines = text.splitlines()
        inserted = False
        for idx, line in enumerate(lines):
            if line.startswith("#"):
                lines.insert(idx + 1, block)
                inserted = True
                break
        if not inserted:
            lines.insert(0, block)
        new_text = "\n".join(lines) + "\n"

    if new_text != text:
        README_PATH.write_text(new_text, encoding="utf-8")
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute doc/test coverage and update README badges.")
    parser.add_argument("--no-update-readme", action="store_true", help="Do not update README badges")
    parser.add_argument("--require-100", action="store_true", help="Exit non-zero unless coverage is 100%")
    args = parser.parse_args()

    documented, total_docs, missing_docs = doc_coverage(SRC_DIR)
    doc_pct = percent(documented, total_docs)

    funcs = public_functions(SRC_DIR, exclude={"main", "tests"})
    tags = coverage_tags(SRC_DIR)
    covered = [fn for fn in funcs if fn in tags]
    missing = sorted(set(funcs) - tags)
    test_pct = percent(len(covered), len(funcs))

    print(f"Doc coverage: {doc_pct}% ({documented}/{total_docs})")
    print(f"Test coverage: {test_pct}% ({len(covered)}/{len(funcs)})")

    if missing_docs:
        print("Missing docs:")
        for item in missing_docs:
            print(f"  - {item}")

    unknown_tags = sorted(tag for tag in tags if tag not in funcs)
    if unknown_tags:
        print("Unknown coverage tags:")
        for tag in unknown_tags:
            print(f"  - {tag}")

    if missing:
        print("Missing test coverage:")
        for fn in missing:
            print(f"  - {fn}")

    if not args.no_update_readme:
        changed = update_readme(doc_pct, test_pct)
        if changed:
            print("README badges updated.")

    if args.require_100:
        if doc_pct < 100 or test_pct < 100 or missing_docs or missing:
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
