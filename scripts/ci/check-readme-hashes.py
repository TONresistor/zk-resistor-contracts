#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
README = ROOT / "README.md"
ARTIFACTS = {
    "Factory": ROOT / "build" / "Factory.json",
    "Pool": ROOT / "build" / "Pool.json",
    "TonPool": ROOT / "build" / "TonPool.json",
}


def error(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)


readme = README.read_text()
failed = False

for name, artifact_path in ARTIFACTS.items():
    if not artifact_path.exists():
        error(f"Missing build artifact: {artifact_path.relative_to(ROOT)}")
        failed = True
        continue

    actual = json.loads(artifact_path.read_text())["hash"].lower()
    match = re.search(rf"\| {re.escape(name)} \| `([0-9a-fA-F]+)` \|", readme)
    if not match:
        error(f"README.md is missing the {name} code hash row")
        failed = True
        continue

    documented = match.group(1).lower()
    if documented != actual:
        error(
            f"{name} hash drift: README has {documented}, "
            f"but build/{name}.json has {actual}"
        )
        failed = True
    else:
        print(f"{name} hash OK: {actual}")

if failed:
    sys.exit(1)

print("README build hashes match Acton artifacts.")
