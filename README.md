# 🎙️ Project Hermes

> **Local-first, low-latency speech-to-text bridge between Android and Windows using on-device AI.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python: 3.10+](https://img.shields.io/badge/Python-3.10%2B-green.svg)](https://www.python.org/)
[![Android: SDK 34+](https://img.shields.io/badge/Android-SDK%2034%2B-brightgreen.svg)](https://developer.android.com/)
[![Protocol: Contract--First](https://img.shields.io/badge/Protocol-JSON%20v1.0-orange.svg)](protocol/README.md)

---

## 📌 1. Overview (What is Project Hermes?)

**Project Hermes** turns your Android phone (such as a Pixel 8 powered by Google's Tensor G3 NPU) into a high-speed, local dictation hardware microphone for your Windows PC.

When you hold a hotkey on Windows (default: **`Right Ctrl`**), your phone transcribes your voice on-device using local AI and streams the text over USB directly into whatever desktop app you are using—whether it's VS Code, Notepad, Microsoft Word, or a web browser.

```text
                  🎙️ USER (Holds Right Ctrl)
                             │
                             ▼
                 🖥️ Windows Companion App
                             │
              🔌 USB Tethering / Wi-Fi / Mobile (TCP:9999)
                             │
                 📱 Android Companion App
                             │
             🧠 Local On-Device AI (Tensor G3 NPU)
                             │
                             ▼
         ✨ Real-Time Text Typed Into Active Application
```

### 🌟 Why Hermes?
* **100% Offline & Private**: Zero data sent to the cloud. Works in air-gapped environments. (One optional, off-by-default exception: cloud polishing of final transcripts via your own Gemini API key, REQ-FUNC-019.)
* **Zero Subscriptions**: Free and open-source forever.
* **Ultra-Low Latency**: End-to-end delay **< 500 ms** from speech stop to text appearance.
* **Extensible Architecture**: Modular speech engines (SpeechRecognizer, Whisper.cpp, Gemini Nano), pluggable transcript polishers (`TranscriptPolisher`: on-device Gemini Nano, cloud Gemini API, future vendors), and formatting pipelines (Code Mode, Markdown Mode).

---

## 🛠️ 2. Prerequisites & Installation

### Hardware Requirements
* **Android Device**: Android 14 (SDK 34) or higher (Google Pixel 8/8 Pro recommended for Tensor G3 NPU hardware acceleration).
* **Windows PC**: Windows 10 or 11.
* **Cable**: Standard USB-C to USB-A/C data cable.

### Software Prerequisites
1. **Python 3.10+** (on Windows host PC).
2. **Android Platform Tools (ADB)** installed and added to System PATH — needed only to *install/update* the APK from source, not for runtime.
3. **Android Studio** (if building the Android app from source).
4. **USB Debugging** — required *only while installing the APK* (*Settings -> Developer Options -> USB Debugging*). Runtime communication uses **USB tethering** instead of ADB, so developer options can stay **off** during normal use (useful when banking or other apps refuse to run with developer options enabled).

> **Transports:** The Android app lets you choose which transport(s) to serve on — **Wi-Fi**, **Mobile data**, and **USB tethering** — from switches in the app. It listens only while a selected transport is actually available, which also minimises battery. USB uses USB tethering (a `usb0` network interface), not ADB.

---

## 🏗️ 3. Building & Environment Setup (Go Taskfile)

This project uses [`Taskfile.yml`](file:///home/calur/github/hermes/Taskfile.yml) for automated environment configuration and build orchestration (linking `/home/calur/android-dev` SDK & JDK 17).

### Quick Commands (`task`)
```bash
# 1. Setup local environment and link Android SDK:
task setup

# 2. Build Android companion app APK:
task android:build

# 3. Install APK onto connected Android device (USB debugging on, temporarily):
task android:install

# 4. (Legacy/optional) ADB port forward — only if using ADB instead of USB tethering:
task adb:forward

# 5. Run test suite:
task test
```

### Manual Build Steps
1. Open [`android/`](file:///home/calur/github/hermes/android) in Android Studio.
2. Ensure `local.properties` specifies `sdk.dir=/home/calur/android-dev/sdk`.
3. Assemble the debug APK:
   ```bash
   cd android && ./gradlew assembleDebug
   ```

### 3.2 Setting Up the Windows Companion App
1. Navigate to the [`windows/`](file:///home/calur/github/hermes/windows) directory.
2. Install required dependencies:
   ```bash
   pip install -r requirements.txt
   ```

---

## 🚀 4. Deploying & Running Hermes

### Step 1: Install the Android App
Install the compiled APK onto your phone (enable USB debugging temporarily for this step only):
```bash
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```
Launch the **Hermes** app on your phone and grant microphone permissions. You may now disable
developer options again — runtime does not need ADB.

### Step 2: Establish the transport link
Pick one of the transports enabled in the app's **Transports** switches:

* **USB (no ADB):** On the phone, enable **USB tethering** (*Settings → Network & internet →
  Hotspot & tethering → USB tethering*). The app's status card shows the phone's serving address
  (e.g. `USB  192.168.42.129:9999`).
* **Wi-Fi / Mobile data (via WireGuard):** Bring up your WireGuard tunnel; the app shows its
  WireGuard address.

Then point the client at that address by setting `host` (and `port`) in
[`windows/hermes.config.json`](file:///home/calur/github/hermes/windows/hermes.config.json):
```json
{ "mode": "Toggle", "host": "192.168.42.129", "port": 9999, "hotkeys": [163] }
```
Both the Python daemon and the PowerShell hotkey client read this file. (You can also override with
the `HERMES_HOST` / `HERMES_PORT` environment variables.)

> *Legacy ADB path (optional):* if you prefer ADB, keep `host` at `127.0.0.1` and run
> `adb forward tcp:9999 tcp:9999` (or `task adb:forward`). This requires USB debugging to stay on.

### Step 3: Launch the Windows Companion Daemon
Run the main Windows client:
```bash
python3 windows/main.py
```

### Step 4: Dictate!
1. Focus your cursor inside any text editor (e.g. VS Code, Notepad).
2. **Press and hold `Right Ctrl`** key.
3. Speak into your phone.
4. **Release `Right Ctrl`**—your dictated text will immediately appear at your cursor position!

---

## 🧪 5. Unit Testing & Contract Validation

Hermes uses a **Contract-First Specification** approach. All messages between Windows and Android are validated against versioned JSON Schemas in [`protocol/schemas/v1/`](file:///home/calur/github/hermes/protocol/README.md).

### Run the Unified Test Suite
Run all contract schema checks and unit tests in one command:
```bash
python3 .agents/skills/test-runner/scripts/run_tests.py
```

### Validate Protocol JSON Schemas
Validate mock message payload fixtures against protocol schemas:
```bash
python3 .agents/skills/protocol-validator/scripts/validate_protocol.py --all
```

### Check Requirement Traceability (RTM)
Verify that all system requirements are mapped to test suites:
```bash
python3 .agents/skills/rtm-manager/scripts/check_rtm_alignment.py
```

---

## 🤖 6. AI Coding Agent Workflow Guidelines

If you are an **AI Coding Agent** (or a developer pairing with an AI agent), this repository strictly enforces **Spec-Driven & Contract-First Engineering** defined in [`AGENTS.md`](file:///home/calur/github/hermes/AGENTS.md).

### 🛑 The 10 AI Governance Commandments
1. **No Requirement, No Code**: Every code change must trace back to a Requirement ID in [`docs/RTM.md`](file:///home/calur/github/hermes/docs/RTM.md).
2. **Skill Usage**: Check for and use workspace skills in `.agents/skills/` for tasks.
3. **RTM Alignment**: Evaluate new requirements against [`docs/RTM.md`](file:///home/calur/github/hermes/docs/RTM.md) before writing code.
4. **Design Impact Check**: Assess changes against [`docs/HLD.md`](file:///home/calur/github/hermes/docs/HLD.md) and [`docs/architecture.drawio`](file:///home/calur/github/hermes/docs/architecture.drawio).
5. **Contract & Test First**: Update RTM $\rightarrow$ HLD $\rightarrow$ JSON Schemas $\rightarrow$ Unit Tests *before* writing core code.
6. **Protocol Fixtures**: Update mock JSON payloads in `tests/fixtures/protocol/v1/` when contracts change.
7. **Layman's Implementation Plan**: Always present a plain-language plan covering proposed changes and unit tests before modifying code.
8. **Living Task Checklist**: Maintain a `task.md` document tracking progress (`[ ]`, `[/]`, `[x]`).
9. **Empirical Verification Gate**: Run `python3 .agents/skills/test-runner/scripts/run_tests.py` and confirm 0 failures before declaring success.
10. **Log Inspection**: Inspect full tracebacks and log output before attempting code fixes.

### Available Agent Skills (`.agents/skills/`)
* 🛠️ `protocol-validator`: Validates JSON payloads against schemas.
* 📋 `rtm-manager`: Inspects requirement traceability alignment.
* 🧪 `test-runner`: Runs unified test suites & verifies empirical pass gates.
* 🔌 `adb-tunnel-manager`: (Legacy/optional) Manages ADB port forwarding rules — superseded by USB tethering for runtime.

---

## 📚 7. Project Documentation Index

* 📄 **High-Level Design (HLD)**: [`docs/HLD.md`](file:///home/calur/github/hermes/docs/HLD.md)
* 📋 **Requirements Traceability Matrix (RTM)**: [`docs/RTM.md`](file:///home/calur/github/hermes/docs/RTM.md)
* 📐 **Editable Architectural Diagram (draw.io)**: [`docs/architecture.drawio`](file:///home/calur/github/hermes/docs/architecture.drawio)
* 📑 **Protocol Specification**: [`protocol/README.md`](file:///home/calur/github/hermes/protocol/README.md)
* 🤖 **AI Agent Directives**: [`AGENTS.md`](file:///home/calur/github/hermes/AGENTS.md)

---

## 📄 License

Project Hermes is licensed under the [MIT License](LICENSE).
