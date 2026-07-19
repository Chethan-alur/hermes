---
name: test-runner
description: Automated test execution suite for Project Hermes (Protocol schema validation, Python tests, Kotlin/Android tests).
---

# Test Runner Skill

This skill executes automated unit and contract tests across Project Hermes and enforces the Empirical Verification Gate.

## Usage Instructions

Run the unified test runner:

```bash
python3 .agents/skills/test-runner/scripts/run_tests.py
```

### Options
- Run protocol validation tests:
  ```bash
  python3 .agents/skills/test-runner/scripts/run_tests.py --suite protocol
  ```
- Run unit test suites:
  ```bash
  python3 .agents/skills/test-runner/scripts/run_tests.py --suite unit
  ```
