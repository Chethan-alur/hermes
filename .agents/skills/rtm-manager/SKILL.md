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

### Options
- List registered requirements:
  ```bash
  python3 .agents/skills/rtm-manager/scripts/check_rtm_alignment.py
  ```
- Automatically assign & register a new requirement:
  ```bash
  python3 .agents/skills/rtm-manager/scripts/check_rtm_alignment.py --add "Support Whisper.cpp engine" --type FUNC --subsystem "android/speech"
  ```

