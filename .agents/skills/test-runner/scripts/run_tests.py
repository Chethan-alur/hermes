#!/usr/bin/env python3
"""
Unified Test Runner for Project Hermes
Enforces Empirical Verification Gate for AI Coding Agents.
"""

import argparse
import subprocess
import sys
from pathlib import Path


def run_protocol_tests(repo_root: Path) -> bool:
    validator_script = repo_root / ".agents" / "skills" / "protocol-validator" / "scripts" / "validate_protocol.py"
    if not validator_script.exists():
        print(f"❌ Protocol validator script missing: {validator_script}")
        return False
    
    print("\n🧪 [SUITE 1/2] Running Protocol Contract Validation...")
    res = subprocess.run([sys.executable, str(validator_script), "--all"])
    return res.returncode == 0


def run_unit_tests(repo_root: Path) -> bool:
    print("\n🧪 [SUITE 2/2] Running Unit & Integration Test Suites...")
    pytest_path = repo_root / "tests"
    if not pytest_path.exists() or not any(pytest_path.rglob("*.py")):
        print("ℹ️ No python unit test files in tests/ directory yet. Contract verification passed.")
        return True
    
    # Try pytest first, fall back to built-in unittest module
    res = subprocess.run([sys.executable, "-m", "pytest", str(pytest_path)], capture_output=True, text=True)
    if res.returncode == 0:
        print(res.stdout)
        return True
    elif "No module named pytest" in res.stderr:
        print("ℹ️ pytest module not found, falling back to python unittest runner...")
        res_unit = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"], capture_output=True, text=True)
        print(res_unit.stdout)
        if res_unit.returncode != 0:
            print(res_unit.stderr)
        return res_unit.returncode == 0
    else:
        print(res.stdout)
        print(res.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(description="Hermes Test Runner")
    parser.add_argument("--suite", choices=["protocol", "unit", "all"], default="all", help="Test suite to run")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[4]
    
    success = True
    if args.suite in ["protocol", "all"]:
        success = run_protocol_tests(repo_root) and success

    if args.suite in ["unit", "all"]:
        success = run_unit_tests(repo_root) and success

    print("\n" + "=" * 60)
    if success:
        print("✅ [EMPIRICAL VERIFICATION GATE: PASSED] All test suites completed with 0 failures.")
        sys.exit(0)
    else:
        print("❌ [EMPIRICAL VERIFICATION GATE: FAILED] Test failures detected. Inspect logs above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
