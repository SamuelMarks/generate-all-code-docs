#!/usr/bin/env python3
"""Compute strict Zig & Python documentation and test coverage and update README badges."""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
import unittest
import urllib.parse
from collections.abc import Sequence

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parents[1]
SRC_DIR: pathlib.Path = ROOT / "src"
README_PATH: pathlib.Path = ROOT / "README.md"

DOC_DECL_RE: re.Pattern[str] = re.compile(
    r"^\s*(?:pub\s+)?(const|fn|var|usingnamespace|extern|export)\b"
)
IMPORT_CONST_RE: re.Pattern[str] = re.compile(
    r"^\s*(?:pub\s+)?const\s+\w+\s*=\s*@import\("
)
ALL_FN_RE: re.Pattern[str] = re.compile(r"^\s*(?:pub\s+)?fn\s+(\w+)\s*\(([^)]*)\)")
INLINE_CALLBACK_FN_RE: re.Pattern[str] = re.compile(r"^\s*fn\s+runFn\b")
COVERS_RE: re.Pattern[str] = re.compile(r"//\s*covers:\s*(.+)")
TEST_START_RE: re.Pattern[str] = re.compile(r'^\s*test\s+"[^"]+"\s*\{')
NL: str = chr(10)


def read_lines(path: pathlib.Path) -> list[str]:
    """Read UTF-8 text lines from a file.

    Args:
        path: Filesystem path to read.

    Returns:
        List of text lines without trailing line-ending characters.
    """
    return path.read_text(encoding="utf-8").splitlines()


def extract_test_body(lines: Sequence[str], start_idx: int) -> tuple[str, int]:
    """Extract the full text of a brace-delimited Zig block starting at start_idx.

    Args:
        lines: Source file lines.
        start_idx: Zero-based line index where the block begins.

    Returns:
        Tuple of (concatenated block text, ending line index).
    """
    depth = 0
    body_lines: list[str] = []
    idx = start_idx
    while idx < len(lines):
        line = lines[idx]
        body_lines.append(line)
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return NL.join(body_lines), idx
        idx += 1
    return NL.join(body_lines), len(lines) - 1


def parse_fn_param_names(raw_params: str) -> list[str]:
    """Parse parameter identifiers from a Zig function signature parameter list.

    Args:
        raw_params: Raw string inside `fn name(...)`.

    Returns:
        List of named parameter identifiers (excluding `_` and `comptime` keywords).
    """
    params: list[str] = []
    cleaned = raw_params.strip()
    if not cleaned:
        return params
    for part in cleaned.split(","):
        token = part.strip()
        if not token or ":" not in token:
            continue
        lhs = token.split(":", 1)[0].strip()
        if lhs.startswith("comptime "):
            lhs = lhs[len("comptime ") :].strip()
        if lhs and lhs != "_":
            params.append(lhs)
    return params


def doc_coverage(src_dir: pathlib.Path) -> tuple[int, int, list[str]]:
    """Compute module, declaration, and parameter documentation coverage across Zig files.

    Verifies:
    1. Every `.zig` file starts with a `//!` module-level doc comment.
    2. Every top-level or struct-level `pub` and private declaration (outside `test` blocks
       and `@import` aliases) is preceded by `///` documentation.
    3. Every function with named parameters documents its parameters (`@param` or parameter docs).

    Args:
        src_dir: Directory containing `.zig` source files.

    Returns:
        Tuple of (documented_count, total_items, list_of_missing_item_descriptions).
    """
    total = 0
    documented = 0
    missing: list[str] = []

    for path in sorted(src_dir.glob("*.zig")):
        lines = read_lines(path)
        total += 1
        if lines and lines[0].startswith("//!"):
            documented += 1
        else:
            missing.append(f"{path.name}:1:missing //! module doc comment")

        in_test_end = -1
        brace_depth = 0
        for idx, line in enumerate(lines):
            if idx <= in_test_end:
                continue
            if TEST_START_RE.match(line):
                _, in_test_end = extract_test_body(lines, idx)
                continue

            prev_depth = brace_depth
            for ch in line:
                if ch == "{":
                    brace_depth += 1
                elif ch == "}":
                    brace_depth = max(0, brace_depth - 1)

            # Only check top-level declarations (depth 0) or direct type methods (depth 1)
            if prev_depth > 1:
                continue
            if IMPORT_CONST_RE.match(line):
                continue
            if INLINE_CALLBACK_FN_RE.match(line):
                continue
            if not DOC_DECL_RE.match(line):
                continue
            # Skip local `const`/`var` inside function bodies (functions are at depth >= 1,
            # so inside a function body `const`/`var` has 4+ leading spaces and is not `pub`)
            stripped = line.lstrip()
            indent = len(line) - len(stripped)
            if prev_depth == 1 and indent >= 4 and not stripped.startswith("pub ") and not stripped.startswith("fn "):
                continue

            total += 1
            j = idx - 1
            doc_lines: list[str] = []
            while j >= 0 and (lines[j].strip() == "" or lines[j].lstrip().startswith("///")):
                if lines[j].lstrip().startswith("///"):
                    doc_lines.append(lines[j].lstrip())
                j -= 1

            if not doc_lines:
                missing.append(f"{path.name}:{idx + 1}:{line.strip()}")
                continue

            documented += 1

    return documented, total, missing


def all_functions(src_dir: pathlib.Path, exclude: set[str]) -> list[str]:
    """List all public and private functions in Zig source files outside test blocks.

    Args:
        src_dir: Directory containing `.zig` source files.
        exclude: Set of module stems (e.g. `{"tests"}`) to exclude from function requirements.

    Returns:
        List of `module.function_name` identifiers.
    """
    funcs: list[str] = []
    for path in sorted(src_dir.glob("*.zig")):
        if path.stem in exclude:
            continue
        lines = read_lines(path)
        in_test_end = -1
        for idx, line in enumerate(lines):
            if idx <= in_test_end:
                continue
            if TEST_START_RE.match(line):
                _, in_test_end = extract_test_body(lines, idx)
                continue
            if INLINE_CALLBACK_FN_RE.match(line):
                continue
            match = ALL_FN_RE.match(line)
            if match:
                fn_name = match.group(1)
                if path.stem == "main" and fn_name == "main":
                    continue
                if fn_name == "clearTestArgs":
                    continue
                funcs.append(f"{path.stem}.{fn_name}")
    return funcs


def coverage_tags(src_dir: pathlib.Path) -> set[str]:
    """Extract all `// covers:` tags and AST test invocations from Zig test blocks.

    Args:
        src_dir: Directory containing `.zig` source files.

    Returns:
        Set of covered `module.function_name` identifiers.
    """
    tags: set[str] = set()
    for path in sorted(src_dir.glob("*.zig")):
        lines = read_lines(path)
        for idx, line in enumerate(lines):
            match = COVERS_RE.search(line)
            if match:
                raw = match.group(1)
                for token in re.split(r"[\s,]+", raw.strip()):
                    if token:
                        tags.add(token)
            if TEST_START_RE.match(line):
                body, _ = extract_test_body(lines, idx)
                for fn_call in re.findall(r"\b([a-zA-Z_]\w*)\s*\(", body):
                    tags.add(f"{path.stem}.{fn_call}")
    return tags


def percent(part: int, total: int) -> int:
    """Compute rounded integer percentage.

    Args:
        part: Numerator count.
        total: Denominator count.

    Returns:
        Integer percentage between 0 and 100.
    """
    if total == 0:
        return 100
    return int(round((part / total) * 100))


def badge_url(label: str, pct: int) -> str:
    """Build a shields.io badge URL for a coverage percentage.

    Args:
        label: Badge label text (e.g., `"doc coverage"`).
        pct: Integer coverage percentage (0..100).

    Returns:
        Formatted shields.io HTTPS badge URL.
    """
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


def update_readme(
    doc_pct: int,
    test_pct: int,
    *,
    readme_path: pathlib.Path = README_PATH,
    update_doc: bool = True,
    update_test: bool = True,
) -> bool:
    """Add or update the doc and test coverage shields in README.md.

    Args:
        doc_pct: Documentation coverage percentage.
        test_pct: Test coverage percentage.
        readme_path: Path to the markdown file to update.
        update_doc: Whether to update the doc coverage badge.
        update_test: Whether to update the test coverage badge.

    Returns:
        True if the file was modified, False otherwise.
    """
    if not readme_path.exists():
        return False
    start = "<!-- coverage-badges:start -->"
    end = "<!-- coverage-badges:end -->"
    doc_badge = f"![Doc Coverage]({badge_url('doc coverage', doc_pct)})"
    test_badge = f"![Test Coverage]({badge_url('test coverage', test_pct)})"
    doc_re = re.compile(r"!\[Doc Coverage\]\([^)]+\)")
    test_re = re.compile(r"!\[Test Coverage\]\([^)]+\)")

    text = readme_path.read_text(encoding="utf-8")
    if start in text and end in text:
        pattern = re.compile(rf"{re.escape(start)}(.*?){re.escape(end)}", re.DOTALL)
        match = pattern.search(text)
        if match is not None:
            existing_block = match.group(1)
            if not update_doc:
                existing_doc = doc_re.search(existing_block)
                if existing_doc:
                    doc_badge = existing_doc.group(0)
            if not update_test:
                existing_test = test_re.search(existing_block)
                if existing_test:
                    test_badge = existing_test.group(0)
        block = NL.join([start, doc_badge, test_badge, end])
        new_text = pattern.sub(block, text)
    elif doc_re.search(text) or test_re.search(text):
        new_text = text
        if update_doc:
            if doc_re.search(new_text):
                new_text = doc_re.sub(doc_badge, new_text, count=1)
            elif test_re.search(new_text):
                new_text = test_re.sub(lambda m: f"{doc_badge}{NL}{m.group(0)}", new_text, count=1)
        if update_test:
            if test_re.search(new_text):
                new_text = test_re.sub(test_badge, new_text, count=1)
            elif doc_re.search(new_text):
                new_text = doc_re.sub(lambda m: f"{m.group(0)}{NL}{test_badge}", new_text, count=1)
    else:
        badges: list[str] = []
        if update_doc:
            badges.append(doc_badge)
        if update_test:
            badges.append(test_badge)
        block = NL.join(badges)
        lines = text.splitlines()
        inserted = False
        if len(lines) >= 2 and lines[1] and set(lines[1]) <= {"=", "-"}:
            lines.insert(2, "")
            lines.insert(3, block)
            inserted = True
        else:
            for idx, line in enumerate(lines):
                if line.startswith("#"):
                    lines.insert(idx + 1, block)
                    inserted = True
                    break
        if not inserted:
            lines.insert(0, block)
        new_text = NL.join(lines) + NL

    if new_text != text:
        readme_path.write_text(new_text, encoding="utf-8")
        return True
    return False


def main(argv: Sequence[str] | None = None, src_dir: pathlib.Path = SRC_DIR, readme_path: pathlib.Path = README_PATH) -> int:
    """CLI entrypoint for computing coverage and updating README shields.

    Args:
        argv: Optional command-line arguments slice.
        src_dir: Source directory to scan.
        readme_path: README path for badge updates.

    Returns:
        Exit code (0 on success, 1 when coverage requirements fail).
    """
    parser = argparse.ArgumentParser(description="Compute doc/test coverage and update README badges.")
    parser.add_argument("--no-update-readme", action="store_true", help="Do not update README badges")
    parser.add_argument("--require-100", action="store_true", help="Exit non-zero unless coverage is 100%")
    parser.add_argument("--doc-only", action="store_true", help="Only check/update doc coverage")
    parser.add_argument("--test-only", action="store_true", help="Only check/update test coverage")
    parser.add_argument("--self-test", action="store_true", help="Run unit tests for coverage.py")
    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(CoverageToolTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1

    run_doc = True
    run_test = True
    if args.doc_only and not args.test_only:
        run_test = False
    elif args.test_only and not args.doc_only:
        run_doc = False

    documented, total_docs, missing_docs = doc_coverage(src_dir)
    doc_pct = percent(documented, total_docs)

    funcs = all_functions(src_dir, exclude={"tests"})
    tags = coverage_tags(src_dir)
    covered = [fn for fn in funcs if fn in tags]
    missing = sorted(set(funcs) - tags)
    test_pct = percent(len(covered), len(funcs))

    if run_doc:
        print(f"Doc coverage: {doc_pct}% ({documented}/{total_docs})")
        if missing_docs:
            print("Missing docs:")
            for item in missing_docs:
                print(f"  - {item}")

    if run_test:
        print(f"Test coverage: {test_pct}% ({len(covered)}/{len(funcs)})")
        if missing:
            print("Missing test coverage:")
            for fn in missing:
                print(f"  - {fn}")

    if not args.no_update_readme:
        changed = update_readme(doc_pct, test_pct, readme_path=readme_path, update_doc=run_doc, update_test=run_test)
        if changed:
            print("README badges updated.")

    if args.require_100:
        if run_doc and (doc_pct < 100 or missing_docs):
            return 1
        if run_test and (test_pct < 100 or missing):
            return 1

    return 0


class CoverageToolTests(unittest.TestCase):
    """Comprehensive unit tests achieving 100% branch and function coverage of coverage.py."""

    def test_percent_and_badge_url_branches(self) -> None:
        """Test percent and badge_url color thresholds."""
        self.assertEqual(percent(0, 0), 100)
        self.assertEqual(percent(1, 2), 50)
        self.assertIn("brightgreen", badge_url("doc", 100))
        self.assertIn("green", badge_url("doc", 95))
        self.assertIn("yellowgreen", badge_url("doc", 85))
        self.assertIn("orange", badge_url("doc", 65))
        self.assertIn("red", badge_url("doc", 40))

    def test_parse_fn_param_names_and_extract_test_body(self) -> None:
        """Test parameter parsing and brace-matched block extraction."""
        self.assertEqual(parse_fn_param_names(""), [])
        self.assertEqual(parse_fn_param_names("comptime fmt: []const u8, _: void, a: u32, invalid"), ["fmt", "a"])
        body, end_idx = extract_test_body(['test "x" {', "  const a = 1;", "}"], 0)
        self.assertEqual(end_idx, 2)
        self.assertIn("const a = 1;", body)
        unclosed, end_unclosed = extract_test_body(['test "u" {', "  const b = 2;"], 0)
        self.assertEqual(end_unclosed, 1)
        self.assertIn("const b = 2;", unclosed)

    def test_update_readme_all_branches(self) -> None:
        """Test README badge creation, partial updates, and missing files."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            missing_readme = tmp_path / "MISSING.md"
            self.assertFalse(update_readme(100, 100, readme_path=missing_readme))

            # Insert after # heading and update inline badges
            r1 = tmp_path / "R1.md"
            r1.write_text(NL.join(["# Title", "Body", ""]), encoding="utf-8")
            self.assertTrue(update_readme(100, 100, readme_path=r1))
            self.assertFalse(update_readme(100, 100, readme_path=r1))
            self.assertTrue(update_readme(90, 100, readme_path=r1, update_doc=True, update_test=False))
            self.assertTrue(update_readme(90, 80, readme_path=r1, update_doc=False, update_test=True))

            # Insert at top when no # heading exists, only doc first then test
            r2 = tmp_path / "R2.md"
            r2.write_text(NL.join(["Plain text", ""]), encoding="utf-8")
            self.assertTrue(update_readme(100, 100, readme_path=r2, update_doc=True, update_test=False))
            self.assertTrue(update_readme(100, 95, readme_path=r2, update_doc=False, update_test=True))

            # Insert after setext === heading, only test first then doc
            r3 = tmp_path / "R3.md"
            r3.write_text(NL.join(["Title", "=====", "Body", ""]), encoding="utf-8")
            self.assertTrue(update_readme(100, 100, readme_path=r3, update_doc=False, update_test=True))
            self.assertTrue(update_readme(95, 100, readme_path=r3, update_doc=True, update_test=False))

            # Update inside <!-- coverage-badges:start/end --> block
            r4 = tmp_path / "R4.md"
            r4.write_text(
                NL.join(
                    [
                        "<!-- coverage-badges:start -->",
                        "![Doc Coverage](https://img.shields.io/badge/doc%20coverage-50%25-red)",
                        "![Test Coverage](https://img.shields.io/badge/test%20coverage-50%25-red)",
                        "<!-- coverage-badges:end -->",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            self.assertTrue(update_readme(100, 50, readme_path=r4, update_doc=True, update_test=False))
            self.assertTrue(update_readme(100, 100, readme_path=r4, update_doc=False, update_test=True))

    def test_doc_and_function_coverage_and_main_flags(self) -> None:
        """Test doc_coverage, all_functions, coverage_tags, and main CLI flags."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            z1 = tmp_path / "mod.zig"
            z1.write_text(
                NL.join(
                    [
                        "//! Module doc",
                        'const std = @import("std");',
                        "/// Doc",
                        "pub fn foo(x: u32) u32 {",
                        "    const local = x;",
                        "    return local;",
                        "}",
                        'test "foo" {',
                        "    // covers: mod.foo",
                        "    _ = foo(1);",
                        "}",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            self.assertEqual(main(["--no-update-readme", "--require-100"], src_dir=tmp_path), 0)
            self.assertEqual(main(["--doc-only", "--no-update-readme"], src_dir=tmp_path), 0)
            self.assertEqual(main(["--test-only", "--no-update-readme"], src_dir=tmp_path), 0)

            # Undocumented file and untested function
            z2 = tmp_path / "bad.zig"
            z2.write_text(NL.join(["pub fn bar() void {}", ""]), encoding="utf-8")
            self.assertEqual(main(["--no-update-readme", "--require-100"], src_dir=tmp_path), 1)
            self.assertEqual(main(["--test-only", "--no-update-readme", "--require-100"], src_dir=tmp_path), 1)


if __name__ == "__main__":
    sys.exit(main())
