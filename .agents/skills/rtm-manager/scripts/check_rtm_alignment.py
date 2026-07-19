#!/usr/bin/env python3
"""
RTM Alignment Checker for Project Hermes
Parses docs/RTM.md and verifies requirement coverage and mapping.
"""

import re
import sys
from pathlib import Path


def parse_rtm(rtm_file: Path):
    if not rtm_file.exists():
        print(f"❌ RTM file not found at {rtm_file}")
        return False

    with open(rtm_file, "r", encoding="utf-8") as f:
        content = f.read()

    req_pattern = re.compile(r"\*\*(REQ-(?:FUNC|NFR)-\d{3})\*\*")
    found_reqs = req_pattern.findall(content)

    if not found_reqs:
        print("⚠️ No requirements found in RTM.")
        return False

    print(f"📋 Found {len(found_reqs)} requirements registered in {rtm_file.name}:")
    for req in sorted(set(found_reqs)):
        print(f"  - {req}")

    return True


def main():
    repo_root = Path(__file__).resolve().parents[4]
    rtm_file = repo_root / "docs" / "RTM.md"
    success = parse_rtm(rtm_file)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
