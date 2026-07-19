---
name: rtm-manager
description: Inspect and verify Requirements Traceability Matrix (RTM) alignment in docs/RTM.md before writing core code.
---

# RTM Manager Skill

This skill checks requirement traceability compliance against `docs/RTM.md`.

## Usage Instructions

Run the RTM alignment checker script:

```bash
python3 .agents/skills/rtm-manager/scripts/check_rtm_alignment.py
```

### Purpose
- Lists all registered `REQ-FUNC-xxx` and `REQ-NFR-xxx` items.
- Verifies requirement ID formatting and test mapping.
- Ensures new features are properly logged before implementation.
