I actually think this project is **much more interesting than simply cloning WhisperFlow**.

Given your background (Python, networking, Kubernetes, distributed systems, AI), I'd design this as an **open, extensible voice platform**, not just a dictation app. The initial release can be a WhisperFlow replacement, but the architecture should allow future additions like AI rewriting, voice commands, and LLM integration.

Below is the design document I'd hand to Codex (or any coding agent) to build the project.

---

# Project: Project Hermes

**Tagline**

> Local-first, low-latency speech-to-text bridge between Android and Windows using on-device AI.

---

# Goals

## Functional

* Use Pixel 8 on-device speech recognition.
* No cloud dependency.
* No subscriptions.
* Windows global Push-to-Talk.
* Inject text into any Windows application.
* Support partial recognition.
* Support final recognition.
* USB communication.
* Future support for Bluetooth/wireless microphone.

---

## Non-functional

* End-to-end latency < 500 ms
* No Internet required
* CPU usage on Windows < 2%
* Idle battery drain on phone < 2%/hour
* Modular architecture
* Testable components
* Extensible protocol

---

# High-Level Architecture

```text
                         USER

                          │
                  Hold Right Ctrl
                          │
                          ▼
                Windows Companion App
                          │
          Global Hotkey Detection Service
                          │
                          ▼
              USB Transport Layer
                          │
════════════════ USB ════════════════
                          │
              Android Transport Layer
                          │
                          ▼
              Speech Recognition Engine
                          │
              Android SpeechRecognizer
                          │
               Tensor G3 On-device AI
                          │
             Partial / Final Recognition
                          │
                          ▼
              Windows Text Injection
                          │
                          ▼
            Active Windows Application
```

---

# Repository Structure

```text
project-hermes/

    docs/

    protocol/

    android/

    windows/

    shared/

    tools/

    tests/

    examples/
```

---

# Components

## Android

Language

> Kotlin

Minimum SDK

> Android 14

Modules

```text
android/

    app/

    speech/

    transport/

    settings/

    diagnostics/
```

---

## Windows

Language

> Python initially

Later

> Rust

Python is perfectly adequate for the prototype and lets you iterate quickly.

Modules

```text
windows/

    hotkeys/

    websocket/

    injector/

    overlay/

    logging/
```

---

# Android Modules

## Speech Engine

Responsibilities

* initialize SpeechRecognizer
* configure language
* receive partial text
* receive final text
* handle errors
* restart recognizer

Interface

```python
class SpeechEngine:

    start()

    stop()

    shutdown()
```

Events

```text
SpeechStarted

SpeechStopped

PartialText

FinalText

Error
```

---

## Transport Layer

Initially

USB TCP

Future

* WiFi
* BLE
* QUIC

Interface

```python
send(event)

receive(command)
```

---

## Controller

State machine

```text
Idle

↓

Listening

↓

Recognizing

↓

Finished

↓

Idle
```

---

# Windows Components

## Global Hotkey

Registers

```text
Right Ctrl
```

or configurable

Events

```text
KeyDown

KeyUp
```

Produces

```json
{
  "command":"start_listening"
}

{
  "command":"stop_listening"
}
```

---

## Transport

USB socket

Handles

* reconnect
* heartbeat
* version negotiation

---

## Text Injector

Abstract interface

```python
inject(text)
```

Implementations

```text
SendInput

Clipboard

UI Automation
```

---

## Overlay

Tiny transparent window

States

```text
Listening

Processing

Disconnected

Error
```

---

# Protocol

JSON

Example

Start

```json
{
  "type":"command",
  "command":"start_listening"
}
```

Stop

```json
{
  "type":"command",
  "command":"stop_listening"
}
```

Partial

```json
{
  "type":"partial",
  "text":"create a pyt"
}
```

Final

```json
{
  "type":"final",
  "text":"Create a Python class."
}
```

Error

```json
{
  "type":"error",
  "message":"Speech timeout"
}
```

Heartbeat

```json
{
  "type":"heartbeat"
}
```

---

# State Diagram

```text
                DISCONNECTED
                      │
                USB Connected
                      │
                      ▼
                   READY
                      │
           Right Ctrl Down
                      │
                      ▼
                 LISTENING
                      │
          Partial Recognition
                      │
                      ▼
                RECOGNIZING
                      │
            Right Ctrl Up
                      │
                      ▼
               FINALIZING
                      │
             Final Recognition
                      │
                      ▼
                   READY
```

---

# Push-To-Talk Flow

```text
Right Ctrl Down

↓

Windows

↓

START_LISTENING

↓

Pixel

↓

SpeechRecognizer.start()

↓

Partial

↓

Partial

↓

Partial

↓

Right Ctrl Up

↓

SpeechRecognizer.stop()

↓

Final Text

↓

Windows

↓

Inject Text

↓

Done
```

---

# Future Speech Engines

The application should never depend directly on Android SpeechRecognizer.

Instead

```text
SpeechEngine

    AndroidSpeechRecognizer

    Whisper.cpp

    Gemini Nano

    Cloud STT
```

Each implements

```python
start()

stop()

shutdown()
```

---

# Future Output Pipelines

Instead of

```text
Speech

↓

Inject
```

Design

```text
Speech

↓

Pipeline

↓

Formatter

↓

Commands

↓

Injection
```

Examples

Programming Mode

```text
"new line"

↓

"\n"
```

Email Mode

```text
dear john

↓

Dear John,
```

Markdown Mode

```text
bullet

↓

-
```

---

# Milestones

## M1

Android

* SpeechRecognizer
* Console logging

---

## M2

USB communication

Android

↔

Windows

---

## M3

Push-to-talk

Windows

↓

Android

---

## M4

Partial recognition

---

## M5

Text injection

Notepad

VS Code

Word

Browser

---

## M6

Overlay

---

## M7

Settings

---

## M8

Packaging

Installer

APK

---

# Testing Strategy

### Unit

* Protocol serialization
* State machine
* Hotkey handling

### Integration

* USB reconnect
* Recognition timeout
* Long dictation
* Suspend/resume

### Performance

Measure:

* Recognition latency
* Transport latency
* Injection latency
* CPU
* Memory
* Battery

---

# Stretch Goals

* Voice commands ("open terminal", "run tests")
* Application-aware formatting (VS Code vs Outlook vs Teams)
* Local LLM post-processing (grammar, punctuation, code formatting)
* Plugin architecture for custom command handlers
* Multiple language profiles
* Wake-word support (optional)
* Cross-platform support (Linux/macOS companion)

## One architectural recommendation

Because you mentioned using **Codex-like coding agents**, I'd make this a **contract-first project**.

Build in this order:

1. **Define the protocol** (`protocol/`) as JSON schemas with versioning.
2. Generate protocol models for both Kotlin and Python from those schemas.
3. Build Android and Windows independently against the shared contract.
4. Add integration tests that replay recorded protocol messages.

This allows coding agents to work on the Android app, Windows app, and protocol in parallel with minimal merge conflicts. It also makes it straightforward to swap the Windows client for macOS/Linux or the Android client for another mobile platform in the future, because every component communicates through a stable, versioned interface rather than implementation-specific APIs.
