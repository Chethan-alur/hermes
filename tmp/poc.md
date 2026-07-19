This is exactly how I'd approach it. Before investing time in the complete system, we should answer **one question only**:

> **Can a Pixel 8 reliably perform on-device speech recognition while the screen is off and the phone is locked, under the control of a foreground service?**

Everything else in the project depends on this.

---

# Project Hermes - Milestone 0

## Feasibility Spike

**Version:** 0.1

**Target Device:** Google Pixel 8

**Target Android:** Android 15+ (latest available)

**Estimated effort:** 1–2 days

**Purpose**

This milestone is **not** intended to build the final application.

Its sole objective is to validate Android platform capabilities and identify any OS restrictions that would prevent the overall architecture.

---

# Success Criteria

The milestone is considered successful only if all of the following are true.

## Functional

* Foreground service starts successfully.
* Service survives screen-off.
* Service survives device lock.
* Speech recognition can be started repeatedly.
* Partial recognition events are received.
* Final recognition events are received.
* Recognition remains on-device.
* No Internet connection required after language pack installation.

---

## Reliability

The following test sequence succeeds at least **100 consecutive times**.

```
Start Recognition

↓

Speak

↓

Receive partial results

↓

Receive final result

↓

Stop

↓

Repeat
```

No crashes.

No ANRs.

No service termination.

---

## Non-functional

Latency

Target:

* Initial recognition < 500 ms
* Partial updates continuously
* Final text < 1 second after speech ends

Battery

Phone connected via USB.

Battery drain is not considered.

---

# Out of Scope

Do NOT implement:

* Windows application
* USB communication
* WebSockets
* Text injection
* Global hotkeys
* Bluetooth microphone
* AI post-processing
* Voice commands
* Wake word
* Settings UI

The objective is platform validation only.

---

# Architecture

```
                Activity

                    │

             Start Service

                    │

                    ▼

         Foreground Service

                    │

                    ▼

           Speech Controller

                    │

                    ▼

          Android SpeechRecognizer

                    │

                    ▼

         Recognition Event Handler

                    │

                    ▼

      Logcat + On-screen Event Console
```

---

# Components

## MainActivity

Responsibilities

* Request permissions
* Start service
* Stop service
* Display event log
* Display current state

Buttons

```
Start Service

Stop Service

Start Recognition

Stop Recognition

Clear Log
```

---

## Foreground Service

Responsibilities

Remain alive regardless of:

* screen off
* device lock

Notification

```
Hermes

Ready

Listening

Recognizing

Stopped
```

The notification should remain visible.

---

## Speech Controller

Wrapper around SpeechRecognizer.

Must expose:

```kotlin
interface SpeechEngine {

    fun start()

    fun stop()

    fun shutdown()

}
```

Do not couple directly to Activity lifecycle.

---

## Event Model

Internal events only.

```kotlin
sealed class SpeechEvent
```

Implement

```
ListeningStarted

ListeningStopped

ReadyForSpeech

BeginningOfSpeech

EndOfSpeech

PartialResult

FinalResult

Error

Timeout
```

---

## Logger

Every event should be timestamped.

Example

```
12:04:22.123

ListeningStarted

12:04:23.042

ReadyForSpeech

12:04:25.221

Partial

"create a"

12:04:25.401

Partial

"create a python"

12:04:26.512

Final

"Create a Python class."
```

Log should be visible:

* Logcat
* UI console

---

# Permissions

Request only what is required.

Expected:

```
RECORD_AUDIO

FOREGROUND_SERVICE

POST_NOTIFICATIONS
```

Avoid requesting unnecessary permissions.

---

# UI

Keep intentionally simple.

```
----------------------------

Hermes Feasibility Test

Status:

READY

Buttons

[Start Service]

[Stop Service]

[Start Recognition]

[Stop Recognition]

----------------------------

Console

12:10:21

Ready

12:10:25

Listening

...

----------------------------
```

No Material Design polish required.

---

# State Machine

```
Idle

↓

ServiceStarted

↓

Ready

↓

Listening

↓

Recognizing

↓

Finalizing

↓

Ready
```

Errors always return to Ready.

---

# Required Experiments

## Experiment 1

Screen ON

Recognition.

Expected

Works.

---

## Experiment 2

Screen OFF

Recognition.

Expected

Works.

---

## Experiment 3

Phone Locked

Recognition.

Expected

Works.

---

## Experiment 4

Screen OFF

Wait

30 minutes

Recognition.

Expected

Works.

---

## Experiment 5

Repeat

100 cycles.

Expected

No crashes.

---

## Experiment 6

Long speech.

Approximately

2 minutes.

Expected

No truncation.

---

## Experiment 7

Airplane Mode

Expected

Recognition still works.

This validates on-device processing.

---

## Experiment 8

Kill Activity

Keep Service running.

Recognition should still function.

---

# Measurements

Collect

```
Startup latency

Recognition latency

Partial event frequency

Final latency

CPU

Memory

Service lifetime

Errors

Restart count
```

---

# Failure Report

For every failure capture:

```
Android version

Pixel build

Stack trace

Event timeline

Logcat

Recovery behaviour
```

---

# Acceptance Checklist

* Service survives lock screen.
* Service survives screen off.
* SpeechRecognizer usable from foreground service.
* Partial results received.
* Final results received.
* Offline recognition confirmed.
* Activity can be destroyed independently.
* No crashes during 100 iterations.
* No Internet dependency after language packs are installed.

---

# Deliverables

The coding agent should produce:

```
android/

    HermesTest/

README.md

ARCHITECTURE.md

TEST_RESULTS.md
```

`TEST_RESULTS.md` should include:

* Android version and Pixel model tested.
* Results of each experiment (pass/fail).
* Measured latencies.
* Any API limitations encountered (for example, if recognition only works while the screen is on).
* Recommendations for Milestone 1 based on the findings.

---

## Notes for the coding agent

1. Prioritize correctness and observability over UI.
2. Keep components loosely coupled so the `SpeechEngine` can later be replaced by another implementation (e.g., Whisper.cpp or Gemini Nano).
3. Do not hard-code any assumptions about the transport layer or Windows integration.
4. If Android platform restrictions prevent one or more success criteria, document the exact behavior rather than attempting unsupported workarounds.

This milestone is considered successful if it clearly answers whether the Android platform can support the proposed architecture, even if the answer is that certain constraints require changes to the overall design.
