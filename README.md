# Marginalia

**The private commentary on every conversation that can't leave the room.**

[usemarginalia.com](http://usemarginalia.com) | Built at the [YC Gemma 4 Voice Agents Hackathon](https://lu.ma/gemma4-voice), April 18-19 2026

---

*marginalia* (n.) --- Latin, from *marginalis*. The handwritten notes, comments, and annotations inscribed in the margins of a text. For centuries, the most important thinking happened not in the main body, but at the edge --- private observations meant only for the reader's eyes.

Cloud AI writes in the main text. Marginalia writes in the margin.

---

## What It Does

Marginalia is an on-device voice agent for smart glasses. It listens to a conversation through the Even Realities G2's microphone, runs Gemma 4 locally on your iPhone via Cactus Compute, and surfaces three tactical response options on the lens --- all without any data leaving the device.

Tap the R1 ring to execute: calendar holds, follow-ups, escalations. The other person never knows.

### Demo Scenario

An executive 1:1. Your direct report says:

> *"I've been feeling burned out. I think I need to take next week off."*

Within seconds, three options appear on your lens:

```
◉ Approve --- block Apr 21-25
○ Counter --- ask about workload
○ Defer --- send calendar hold
```

Tap the ring. Calendar event created. Conversation continues naturally.

## Architecture

Everything runs on one iPhone in airplane mode. Zero cloud. Zero network traffic.

```
┌────────────┐                    ┌───────────────────────────────────────┐
│  G2        │       BLE          │  iPhone 17 Pro Max                    │
│  Glasses   │◄──────────────────►│                                       │
│            │                    │  EvenDemoApp (Flutter)                │
│  ● Mic     │──PCM audio────────►│    └── CoreBluetooth direct to G2     │
│  ● Lens    │◄──text─────────────│    └── iOS Speech Recognition         │
│  ● R1 Ring │──tap event────────►│    └── HTTP to localhost:8080         │
│            │                    │        ↓                               │
└────────────┘                    │  Marginalia App (SwiftUI)             │
                                  │    ├── HTTP Server (:8080)            │
                                  │    ├── Cactus Parakeet STT            │
                                  │    └── Cactus Gemma 4 E2B             │
                                  │        (2.3B params, INT4, ~2GB RAM)  │
                                  └───────────────────────────────────────┘
```

**Two apps on one iPhone, communicating via localhost:**

1. **Marginalia App** (SwiftUI) --- Cactus inference engine + HTTP server on port 8080. Loads Gemma 4 E2B and Parakeet TDT models. Accepts text via `/inference-text`, returns 3 tactical options as JSON with optional function calls.

2. **Modified EvenDemoApp** (Flutter) --- Connects to G2 glasses via CoreBluetooth (BLE). Captures audio from G2 mic, runs iOS speech recognition, sends transcribed text to localhost:8080, and pushes the formatted response to the G2 lens display via BLE protocol command 0x4E.

### Fallback: MacBook BLE Bridge

If the Flutter app can't connect to G2 directly, a Python bridge on the MacBook relays display commands:

```
iPhone (inference) ──HTTP──► MacBook (Flask :9090) ──BLE (bleak)──► G2
```

## Tech Stack

| Component | Technology | Role |
|-----------|-----------|------|
| **LLM** | [Gemma 4 E2B](https://ai.google.dev/gemma) (Google DeepMind) | 2.3B effective params, native audio + function calling. Apache 2.0. |
| **Inference** | [Cactus Compute](https://cactuscompute.com) v1.14 (YC S25) | C++ engine, INT4 quantization, Apple Neural Engine, zero-copy memory mapping |
| **STT** | NVIDIA Parakeet TDT 0.6B | 4.65% WER, NPU-accelerated, sub-second transcription |
| **Glasses** | [Even Realities G2](https://evenrealities.com) + R1 Ring | 576x288 px micro-LED, BLE mic (16kHz PCM), ring for selection |
| **BLE Protocol** | CoreBluetooth + Nordic UART (6E400001) | Direct iPhone-to-glasses, dual-arm protocol (L then R) |
| **iOS App** | SwiftUI + Cactus Swift SDK | Model loading, HTTP server, inference pipeline |
| **Glasses App** | Flutter + [EvenDemoApp](https://github.com/even-realities/EvenDemoApp) | BLE connection, audio capture, lens text display |
| **Landing Page** | Static HTML/CSS on GitHub Pages | [usemarginalia.com](http://usemarginalia.com) |

## Performance

| Metric | Value |
|--------|-------|
| End-to-end latency (audio in → options on lens) | <5 seconds |
| Model RAM (both models loaded) | ~2 GB |
| Decode speed (Cactus + Apple Neural Engine) | 48 tok/s |
| Data sent to cloud | 0 bytes |
| Model weights on disk | ~7 GB (Gemma 6.3GB + Parakeet 750MB) |

## Repository Structure

```
marginalia/
├── ios/                          # SwiftUI Marginalia app (Cactus inference + HTTP server)
│   ├── Marginalia/
│   │   ├── MarginaliaApp.swift   # App entry, model loading
│   │   ├── InferenceEngine.swift # Cactus STT + LLM pipeline
│   │   ├── LocalServer.swift     # NWListener HTTP server on :8080
│   │   ├── ContentView.swift     # iPhone UI (dashboard + chat)
│   │   ├── ModelDownloader.swift  # In-app HuggingFace weight downloader
│   │   ├── WebApp/               # Built glasses web app (Even SDK version)
│   │   └── Cactus/               # Swift FFI wrapper + modulemap
│   └── cactus.xcframework/       # Pre-built Cactus iOS framework (arm64)
│
├── even-demo-app/                # Modified Flutter EvenDemoApp (G2 BLE + Marginalia)
│   └── lib/services/
│       ├── api_services_marginalia.dart  # Calls localhost:8080/inference-text
│       ├── evenai.dart                   # Modified: Marginalia replaces DeepSeek
│       └── ...                           # Original BLE protocol, text display, audio
│
├── glasses/                      # Vite + TypeScript web app (Even Hub SDK version)
│   └── src/main.ts               # State machine: LISTEN → PROCESS → OPTIONS → DONE
│
├── server/                       # FastAPI server (MacBook fallback)
│   ├── app.py                    # /inference, /inference-text, /tool-call, SSE
│   ├── context.md                # Demo scenario context for system prompt
│   └── static/calendar.html      # Calendar projection page (SSE-driven)
│
├── site/                         # usemarginalia.com landing page
│   ├── index.html                # Product story, architecture, 8 verticals
│   └── style.css
│
├── scripts/
│   ├── demo-script.md            # Timed 5-minute demo (Act 1/2/3)
│   ├── volunteer-briefing.md     # Exact line for volunteer
│   ├── integration-test.md       # Step-by-step G2 hardware test
│   ├── mic-fallback.py           # MacBook mic → inference fallback
│   └── setup-hotspot.sh          # Auto-detect hotspot IP
│
└── docs/specs/                   # Spec artifacts
    ├── marginalia-mvp.md         # Full spec with API contract
    └── marginalia-mvp-yolo.md    # Execution checklist
```

## API

The Marginalia server exposes these endpoints on `localhost:8080`:

```
POST /inference-text
  Body: {"text": "I need to take next week off"}
  Response: {
    "options": [
      {"label": "Approve — block Apr 21-25", "action": "createCalendarHold", "args": {...}},
      {"label": "Counter — ask about workload", "action": null, "args": null},
      {"label": "Defer — send calendar hold", "action": "createCalendarHold", "args": {...}}
    ]
  }

POST /inference
  Body: raw PCM audio (16kHz S16LE mono)
  Response: same as above

POST /tool-call-json
  Body: {"action": "createCalendarHold", "args": {"title": "PTO", "startDate": "2026-04-21", "endDate": "2026-04-25"}}
  Response: {"status": "created", "event": {...}}

GET /health
GET /events          # Calendar events list
GET /events-stream   # SSE for real-time calendar updates
```

## Running Locally

### iOS App (inference engine)

```bash
open ios/Marginalia.xcodeproj
# Set signing team, build to iPhone (Cmd+R)
# Transfer weights via Finder → iPhone → Marginalia → weights/
# Or use in-app downloader (pulls from HuggingFace)
```

### Flutter App (G2 glasses connection)

```bash
cd even-demo-app
flutter pub get
flutter run    # targets connected iPhone
```

### MacBook Server (fallback)

```bash
cd server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
MARGINALIA_DUMMY=1 python -m uvicorn server.app:app --host 0.0.0.0 --port 8080
```

### MacBook BLE Bridge (fallback)

```bash
cd marginalia-bridge
pip install flask bleak
python app.py              # with G2 glasses
python app.py --no-glasses # dry run
```

## The Company

Marginalia is not a smart glasses company. It's an on-device vertical intelligence platform where every high-stakes profession runs a fine-tuned model trained on their domain's privileged data.

| Vertical | Product | Why Cloud AI Can't Serve It |
|----------|---------|---------------------------|
| **Law** | Marginalia Counsel | Attorney-client privilege --- cloud AI is a potential privilege waiver |
| **Medicine** | Marginalia Clinical | HIPAA prohibits cloud AI with patient audio |
| **M&A** | Marginalia Diligence | Material non-public information --- securities violation |
| **Manufacturing** | Marginalia Floor | Manufacturing IP (Apple, defense, pharma) can't leave the site |
| **Therapy** | Marginalia Counselor | Therapy is the most sacred trust relationship |
| **Defense** | Marginalia Defense | Classified environments --- federal mandate (EO 14110) |
| **Executive** | Marginalia Executive | HR investigations must stay private |
| **Journalism** | Marginalia Press | Source confidentiality is professional ethics |

**Wedge vertical:** Manufacturing (Marginalia Floor). Founder has 6 years at Apple inside Foxconn --- Day One distribution that no competitor can replicate.

**Roadmap:** Manufacturing pilots 2026, law firms 2027, health systems 2028, platform maturity 2030.

## Founder

**Ben Shyong** --- Staff TPM, Meta Reality Labs (AR/VR Hardware). Previously 6 years at Apple / Foxconn. Leaving Meta August 15, 2026 to build Marginalia full-time.

benjamin.shyong@gmail.com

## License

Apache 2.0
