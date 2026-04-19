# Hackathon Submission --- Marginalia

**Use these for whatever submission form Cactus/YC provides. Copy-paste the relevant sections.**

---

## Project Name

Marginalia

## One-Line Description

On-device voice intelligence for smart glasses --- listens to conversations, runs Gemma 4 locally on iPhone, and surfaces tactical response options on the lens. Zero cloud.

## Website

http://usemarginalia.com

## GitHub

https://github.com/benikigai/marginalia

## Team

Ben Shyong (solo) --- Staff TPM, Meta Reality Labs (AR/VR Hardware). Previously 6 years at Apple.

## What does it do? (Short)

Marginalia is a real-time AI commentary layer for high-stakes conversations. It captures audio through Even Realities G2 smart glasses, runs Gemma 4 E2B on-device via Cactus Compute on an iPhone in airplane mode, and displays three tactical response options on the lens. Tap the R1 ring to execute a function call (calendar hold, follow-up, escalation). No data ever leaves the device.

## What does it do? (Long)

Marginalia solves a problem that cloud AI structurally cannot: providing real-time intelligence during conversations where the data legally cannot leave the room.

Attorney-client privilege, HIPAA, material non-public information in M&A, classified defense environments, factory floor IP at Apple and Foxconn --- these are high-stakes conversations where professionals make decisions worth millions, and where sending audio to a cloud API is either illegal, unethical, or both.

Marginalia runs entirely on-device. The Even Realities G2 smart glasses capture conversation audio through their built-in microphone. The audio streams via Bluetooth to an iPhone running Cactus Compute with Gemma 4 E2B (2.3B effective parameters, INT4 quantized). The model reasons over the audio --- not just transcribing, but understanding tone, intent, and context --- and generates exactly three tactical response options with optional function calls.

The options appear on the G2's micro-LED lens display. The wearer scrolls with the R1 ring, taps to select, and the function executes. In the demo scenario, a direct report says "I've been feeling burned out. I need next week off," and within seconds the manager sees: Approve (block calendar), Counter (ask about workload), Defer (send calendar hold).

The entire pipeline runs in airplane mode. We verified zero bytes leave the device.

## How does it use Cactus?

Cactus Compute v1.14 is the inference engine. We use the Cactus Swift SDK (cactusInit, cactusComplete, cactusTranscribe, cactusReset) to load and run two models on-device:

1. **NVIDIA Parakeet TDT 0.6B** for speech-to-text (4.65% WER, NPU-accelerated)
2. **Gemma 4 E2B** for tactical response generation with native function calling

Both models are loaded at app startup via cactusInit and kept warm in memory (~2 GB combined). The inference pipeline uses cactusTranscribe for STT and cactusComplete with tools_json for the LLM pass. Responses include function calls (createCalendarHold) that the app executes locally.

We also use Cactus's INT4 quantization and zero-copy memory mapping to fit both models in iPhone RAM, and the Apple Neural Engine integration for prefill acceleration.

## How does it use Gemma 4?

Gemma 4 E2B is the reasoning engine. We use three of its capabilities:

1. **Audio understanding** --- the 300M-parameter conformer encoder processes raw PCM audio directly, picking up tone and hesitation that transcription loses
2. **Function calling** --- native tool use generates structured JSON with tool invocations (createCalendarHold with title, startDate, endDate)
3. **Contextual reasoning** --- a system prompt with scenario context (role, relationship, organizational dynamics) produces options that are contextually sharp, not generic

The model generates exactly 3 options per utterance, each with a short label and an optional function call. This constrained output format keeps lens display clean (5 lines max on G2's 576x288 display) and latency low (<5s end-to-end).

## Technical Architecture

```
G2 Glasses (mic + lens + R1 ring)
    | BLE (CoreBluetooth, Nordic UART)
    v
iPhone 17 Pro Max (airplane mode)
    |-- EvenDemoApp (Flutter): BLE connection, audio capture, lens display
    |-- Marginalia App (SwiftUI): Cactus inference server on localhost:8080
    |     |-- Parakeet TDT 0.6B (STT)
    |     |-- Gemma 4 E2B (LLM + function calling)
    |     |-- HTTP API: /inference-text, /tool-call-json, /health
    |-- Communication: localhost HTTP (loopback, zero network)
```

MacBook serves only as a projector via AirPlay screen mirroring. No computation on the MacBook.

## What makes this novel?

1. **First on-device voice agent for smart glasses.** Other hackathon entries use cloud APIs or run on laptops. Marginalia runs on a phone in airplane mode with the output on glasses you're wearing.

2. **Constrained output for a constrained display.** Instead of generating free-form text, the model produces exactly 3 actionable options with function calls --- designed for a 576x288 pixel lens display that the wearer glances at, not reads.

3. **The privacy story is the product story.** This isn't a privacy feature bolted onto a cloud product. The on-device architecture IS the product --- because the target customers (attorneys, physicians, bankers, defense) literally cannot use cloud AI by law.

## What would you build next?

1. **Vertical fine-tunes.** Generic Gemma 4 generates reasonable options, but a model fine-tuned on 50,000 hours of de-identified deposition transcripts would generate options that reference specific legal standards. Each vertical (law, medicine, M&A, manufacturing) gets its own fine-tune trained on privileged domain data under BAA.

2. **On-device continual learning.** The model adapts to the wearer's style, vocabulary, and decision patterns over months --- and that personalization never leaves the device. Six months of adaptation is six months of switching cost.

3. **Multi-turn conversation tracking.** Current MVP processes single utterances. Next: maintain conversation context across the full meeting, tracking key decisions, commitments, and unresolved issues.

4. **Hardware-agnostic distribution.** G2 today, Mentra Live next quarter, Ray-Ban Meta after that. The product is the intelligence layer, not the glasses.

## Demo Video URL

*(Add YouTube unlisted URL after recording)*

## Anything else?

Built solo in 22 hours. Two apps running on one iPhone communicating via localhost. The glasses connect directly via CoreBluetooth --- no intermediary app, no WebView, no cloud relay. The entire inference pipeline (audio capture, speech recognition, contextual reasoning, function calling, lens display) runs without a single byte leaving the device.

The company is not a smart glasses company. It's an on-device vertical intelligence platform. The glasses are the current interface. The verticals --- law, medicine, M&A, manufacturing, defense --- are the business. Each one is a fine-tuned model trained on privileged data that cloud LLMs will never have access to.
