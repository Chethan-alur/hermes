# AGENTS.md: AI Coding Agent Governance & Workflow Directives

> **Mandatory Guidelines & Execution Rules for AI Coding Agents Operating on Project Hermes.**

---

## Core Philosophy: Spec-Driven & Contract-First Engineering

All AI agents working on this codebase must strictly adhere to a **Specification-Driven, Contract-First, and Test-Driven Workflow**. Code must never be produced opportunistically or without formal requirement tracing.

---

## 🛑 The 10 Commandments for AI Coding Agents

### Rule 1: No Requirement, No Code
* **Directive**: Never write, refactor, or delete core application code without an assigned Requirement ID (`REQ-FUNC-xxx` or `REQ-NFR-xxx`).
* **Enforcement**: If a requested feature or bug fix lacks a requirement ID, create a new requirement entry in [`docs/RTM.md`](file:///home/calur/github/hermes/docs/RTM.md) first.

### Rule 2: Skill-Based Execution
* **Directive**: Always check for and utilize available skills (e.g., in `.agents/skills/` or customization roots) before attempting complex codebase manipulations or setup operations.
* **Enforcement**: Rely on standardized tools, scripts, and pre-defined skill procedures for repetitive operations.

### Rule 3: Requirements Traceability Impact Analysis (RTM Alignment)
* **Directive**: Before touching any code, cross-reference the new requirement against the existing Requirements Traceability Matrix ([`docs/RTM.md`](file:///home/calur/github/hermes/docs/RTM.md)).
* **Enforcement**: 
  - Check if the requirement overlaps with, conflicts with, or modifies existing requirements (`REQ-FUNC-001` through `REQ-NFR-006`).
  - Document affected subsystems, schemas, and test suites in `docs/RTM.md`.

### Rule 4: Design Impact Analysis
* **Directive**: Evaluate whether the requirement requires structural or design alterations against available architecture documentation:
  - High-Level Design: [`docs/HLD.md`](file:///home/calur/github/hermes/docs/HLD.md)
  - Architectural Diagram: [`docs/architecture.drawio`](file:///home/calur/github/hermes/docs/architecture.drawio)
* **Enforcement**: If system components, data flows, or state machine transitions change, update the design docs *before* coding.

### Rule 5: Contract & Test-First (Design -> Contract -> Test -> Code)
* **Directive**: Update all design documents, JSON protocol contracts ([`protocol/schemas/v1/`](file:///home/calur/github/hermes/protocol/README.md)), and unit test definitions **BEFORE** writing any core application code.
* **Execution Order**:
  1. Update `docs/RTM.md` (Assign REQ ID and mapping).
  2. Update `docs/HLD.md` & `docs/architecture.drawio` (Adjust design & state diagrams).
  3. Update/Create JSON Schemas in `protocol/schemas/` (Define message contracts).
  4. Write/Update Unit Test Cases & Protocol Fixtures in `tests/fixtures/protocol/` (Write failing tests against the new contract).
  5. Write Core Application Code (Implement feature until unit tests pass).

### Rule 6: Layman's Terms Implementation Plan
* **Directive**: Before executing any code changes, present a clear, human-readable implementation plan to the user.
* **Plan Requirements**:
  - Explain the purpose of the change in simple, layman's terms.
  - Detail exact files to be added, modified, or deleted.
  - Explicitly outline unit test additions and verification steps.
  - Wait for explicit user confirmation/approval before proceeding to core code implementation.

### Rule 7: Contract Mocking & Protocol Fixtures
* **Directive**: Store sample protocol payload fixtures in `tests/fixtures/protocol/`.
* **Enforcement**: When schema changes occur, validate JSON fixtures against schema validators (`jsonschema` / `kotlinx.serialization`) to ensure zero contract drift or breakage before implementing core handlers.

### Rule 8: Living Task Checklist (`task.md`)
* **Directive**: Once an implementation plan is approved, maintain a living checklist artifact/file (`task.md`) with explicit items marked as `[ ]` (uncompleted), `[/]` (in-progress), and `[x]` (completed).
* **Enforcement**: Update `task.md` continuously during execution to prevent context drift.

### Rule 9: Empirical Verification Gate (No Assumptions)
* **Directive**: NEVER declare a task, requirement, or bug fix completed until you have executed automated build/test commands and confirmed clean execution.
* **Enforcement**: Run pytest / gradle test commands and display empirical terminal test pass verification.

### Rule 10: Diagnostic Log Inspection Before Fixing
* **Directive**: If a test or build fails, NEVER form a diagnosis or edit code blindly without inspecting the full error log and traceback.
* **Enforcement**: Base all code edits strictly on verified empirical log evidence.

---

## 🔄 Standard Feature Change Workflow Checklist for AI Agents

```text
[ ] 1. Identify or Create Requirement ID in docs/RTM.md
[ ] 2. Check RTM Alignment & Impact on existing requirements
[ ] 3. Analyze HLD & Architectural Diagram impact (docs/HLD.md)
[ ] 4. Update JSON Protocol Contracts (protocol/schemas/)
[ ] 5. Update/Create Protocol Test Fixtures in tests/fixtures/protocol/
[ ] 6. Write / Update Unit Test Cases (TDD Red Phase)
[ ] 7. Present Layman's Implementation Plan for User Approval
[ ] 8. Maintain Living Checklist (task.md) during execution
[ ] 9. Implement Core Application Code (TDD Green Phase)
[ ] 10. Run Automated Test Suite & Verify 100% Pass Rate (Empirical Gate)
```
