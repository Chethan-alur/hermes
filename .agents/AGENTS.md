# Workspace Rules: Project Hermes Agent Governance

- **No Requirement, No Code**: Every code change must trace back to a `REQ-FUNC` or `REQ-NFR` item in [`docs/RTM.md`](file:///home/calur/github/hermes/docs/RTM.md).
- **Skill Usage**: Check for and use workspace skills whenever available for task execution.
- **RTM Alignment**: Evaluate new requirements against [`docs/RTM.md`](file:///home/calur/github/hermes/docs/RTM.md) to detect conflicts or overlaps.
- **Design Impact Check**: Assess changes against [`docs/HLD.md`](file:///home/calur/github/hermes/docs/HLD.md) and [`docs/architecture.drawio`](file:///home/calur/github/hermes/docs/architecture.drawio).
- **Contract & Test First**: Update RTM, HLD, JSON Schemas in [`protocol/schemas/`](file:///home/calur/github/hermes/protocol/README.md), and unit tests *before* writing core code.
- **Protocol Fixtures**: Maintain sample JSON payload fixtures in `tests/fixtures/protocol/` and validate schemas against fixtures before coding.
- **Layman's Implementation Plan**: Always present a plain-language plan covering proposed changes and unit tests before modifying implementation files.
- **Living Checklist**: Maintain a `task.md` document tracking progress (`[ ]`, `[/]`, `[x]`).
- **Empirical Verification Gate**: Run automated test suites (`pytest`, `./gradlew test`) and confirm 0 failures before declaring success.
- **Log Inspection**: Inspect full tracebacks and log output before attempting test failure diagnoses or code edits.
