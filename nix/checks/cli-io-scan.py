"""Find I/O in the CLI's product code.

Everything that spawns a process, touches the filesystem, opens a socket or
reads the environment belongs in cli/src/io. The rest of the tree stays
testable without a cluster, a daemon or a home directory.

Test modules are exempt: a test may reach for a real temp directory. Finding
them is the whole difficulty. The previous extractor was
`awk '/^#\\[cfg\\(test\\)\\]/ { exit }'`, which stopped at the first match and
treated the attribute on any item as the start of tests, so a conditional
`#[cfg(test)] use std::io::Read;` on line 2 of host/services.rs exempted all
422 lines of it. This walks the file instead: `#[cfg(test)]` begins a test
region only when it sits on a module, and the region ends at that module's
closing brace.
"""

import re
import sys
from pathlib import Path

PATTERNS = [
    (r"std::process::Command", "spawns a process"),
    (r"use std::process::\{?Command", "spawns a process"),
    (r"std::process::exit", "exits without unwinding, so Drop never runs"),
    (r"std::fs::[A-Za-z_]+\s*\(", "touches the filesystem"),
    (r"use std::fs;", "touches the filesystem"),
    (r"use std::fs::[a-z_]", "touches the filesystem"),
    (r"std::env::var\s*\(", "reads the environment"),
    (r"tempfile::", "creates files outside the io seam"),
    (r"std::net::", "opens a socket"),
    (r"reqwest::(Client::|get\s*\()", "makes an HTTP request"),
    (r"which::which", "searches PATH"),
]

MOD_START = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")
CFG_TEST = re.compile(r"^\s*#\[cfg\(test\)\]\s*$")
ATTRIBUTE = re.compile(r"^\s*#\[")


def strip_literals(line: str) -> str:
    """Blank out anything a brace could hide in, so counting braces is safe."""
    line = re.sub(r'r#*"(?:[^"]|"(?!#))*"#*', '""', line)
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(?:\\.|[^'\\])'", "''", line)
    return line.split("//")[0]


def test_line_numbers(lines: list[str]) -> set[int]:
    """1-indexed lines that belong to a test module."""
    test_lines: set[int] = set()
    i = 0
    while i < len(lines):
        if not CFG_TEST.match(lines[i]):
            i += 1
            continue

        j = i + 1
        while j < len(lines) and (not lines[j].strip() or ATTRIBUTE.match(lines[j])):
            j += 1

        if j >= len(lines) or not MOD_START.match(lines[j]):
            i += 1
            continue

        depth = 0
        k = j
        while k < len(lines):
            stripped = strip_literals(lines[k])
            depth += stripped.count("{") - stripped.count("}")
            test_lines.add(k + 1)
            if depth <= 0 and k > j - 1 and "{" in strip_literals(lines[j]):
                break
            k += 1
        for n in range(i + 1, j + 2):
            test_lines.add(n)
        i = k + 1
    return test_lines


def scan(root: Path) -> list[tuple[str, str, str]]:
    """(key, why, source line) for every finding, keyed path:line."""
    findings = []
    for path in sorted(root.rglob("*.rs")):
        if "/io/" in str(path):
            continue
        lines = path.read_text().splitlines()
        exempt = test_line_numbers(lines)
        rel = path.relative_to(root)
        for n, line in enumerate(lines, start=1):
            if n in exempt:
                continue
            code = strip_literals(line)
            for pattern, why in PATTERNS:
                if re.search(pattern, code):
                    findings.append((f"{rel}:{n}", why, line.strip()))
                    break
    return findings


def main() -> int:
    root = Path(sys.argv[1])
    baseline_path = sys.argv[2] if len(sys.argv) > 2 else None

    baseline = set()
    if baseline_path and Path(baseline_path).is_file():
        baseline = {
            l.strip()
            for l in Path(baseline_path).read_text().splitlines()
            if l.strip() and not l.startswith("#")
        }

    findings = scan(root)
    keys = {key for key, _, _ in findings}

    new = sorted(k for k in keys if k not in baseline)
    stale = sorted(b for b in baseline if b not in keys)

    if new:
        print("the CLI does I/O outside cli/src/io:", file=sys.stderr)
        for key, why, line in findings:
            if key in new:
                print(f"  {key}: {why}", file=sys.stderr)
                print(f"      {line}", file=sys.stderr)
        print("", file=sys.stderr)
        print("io/ owns every one of these, so the rest of the tree stays", file=sys.stderr)
        print("testable without a cluster, a daemon or a home directory.", file=sys.stderr)
        print("Add or reuse an adapter there and call it by name.", file=sys.stderr)

    if stale:
        print("", file=sys.stderr)
        print("these baseline entries no longer fire, so the baseline is stale:", file=sys.stderr)
        for s in stale:
            print(f"  {s}", file=sys.stderr)
        print("", file=sys.stderr)
        print("Delete them. A baseline that outlives its debt stops being a", file=sys.stderr)
        print("ratchet and starts being an excuse list.", file=sys.stderr)

    return 1 if (new or stale) else 0


if __name__ == "__main__":
    sys.exit(main())
