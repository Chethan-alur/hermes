---
name: adb-tunnel-manager
description: Manage and verify ADB USB TCP port forwarding (adb forward tcp:9999 tcp:9999) between Windows host and Android device.
---

# ADB Tunnel Manager Skill

This skill sets up, verifies, and manages the USB ADB socket tunnel for Project Hermes.

## Usage Instructions

Run the ADB tunnel helper script:

```bash
python3 .agents/skills/adb-tunnel-manager/scripts/manage_adb_forward.py
```

### Options
- Setup port forwarding:
  ```bash
  python3 .agents/skills/adb-tunnel-manager/scripts/manage_adb_forward.py --setup --port 9999
  ```
- Check status of forward channels:
  ```bash
  python3 .agents/skills/adb-tunnel-manager/scripts/manage_adb_forward.py --status
  ```
- Remove port forwarding:
  ```bash
  python3 .agents/skills/adb-tunnel-manager/scripts/manage_adb_forward.py --remove --port 9999
  ```
