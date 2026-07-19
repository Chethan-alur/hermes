#!/usr/bin/env python3
"""
RTM Alignment & Requirement Trigger Tool for Project Hermes
Parses docs/RTM.md, lists registered requirements, and assists in creating new requirement entries.
"""

import argparse
import re
import sys
from pathlib import Path


def parse_rtm(rtm_file: Path):
    if not rtm_file.exists():
        print(f"❌ RTM file not found at {rtm_file}")
        return False, []

    with open(rtm_file, "r", encoding="utf-8") as f:
        content = f.read()

    req_pattern = re.compile(r"\*\*(REQ-(?:FUNC|NFR)-\d{3})\*\*")
    found_reqs = req_pattern.findall(content)

    print(f"📋 Found {len(found_reqs)} requirements registered in {rtm_file.name}:")
    for req in sorted(set(found_reqs)):
        print(f"  - {req}")

    return True, found_reqs


def get_next_req_id(found_reqs: list, req_type: str) -> str:
    prefix = f"REQ-{req_type.upper()}-"
    numbers = []
    for r in found_reqs:
        if r.startswith(prefix):
            try:
                num = int(r.replace(prefix, ""))
                numbers.append(num)
            except ValueError:
                pass
    next_num = (max(numbers) + 1) if numbers else 1
    return f"{prefix}{next_num:03d}"


def add_requirement(rtm_file: Path, desc: str, req_type: str, subsystem: str, test_id: str):
    _, found_reqs = parse_rtm(rtm_file)
    new_id = get_next_req_id(found_reqs, req_type)
    
    row = f"| **{new_id}** | {desc} | `{subsystem}` | N/A | `{test_id}` | Defined |\n"
    
    with open(rtm_file, "r", encoding="utf-8") as f:
        content = f.read()

    # Append to table
    if "## 2. Functional Requirements Traceability" in content and req_type.upper() == "FUNC":
        target_section = "## 2. Functional Requirements Traceability"
    else:
        target_section = "## 3. Non-Functional Requirements Traceability"

    if target_section in content:
        parts = content.split(target_section, 1)
        # Find end of table (next empty line or section)
        lines = parts[1].split("\n")
        insert_idx = len(lines)
        for idx, line in enumerate(lines[2:], start=2):
            if line.strip() == "" or line.startswith("---") or line.startswith("##"):
                insert_idx = idx
                break
        lines.insert(insert_idx, row.strip())
        new_content = parts[0] + target_section + "\n".join(lines)
        
        with open(rtm_file, "w", encoding="utf-8") as f:
            f.write(new_content)
        print(f"\n✅ Created new requirement: **{new_id}** -> '{desc}' in {rtm_file.name}")
        return new_id
    else:
        print("❌ Target section not found in RTM.")
        return None


def main():
    parser = argparse.ArgumentParser(description="Hermes RTM Manager")
    parser.add_argument("--add", type=str, help="Description of new requirement to trigger")
    parser.add_argument("--type", choices=["FUNC", "NFR"], default="FUNC", help="Requirement type (FUNC or NFR)")
    parser.add_argument("--subsystem", default="android/speech", help="Target subsystem")
    parser.add_argument("--test-id", default="UT-NEW-001", help="Target unit test ID")

    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[4]
    rtm_file = repo_root / "docs" / "RTM.md"

    if args.add:
        add_requirement(rtm_file, args.add, args.type, args.subsystem, args.test_id)
    else:
        success, _ = parse_rtm(rtm_file)
        sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
