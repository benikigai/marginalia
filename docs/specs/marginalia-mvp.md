# Spec: Marginalia Hackathon MVP
**Date:** 2026-04-18
**Status:** Approved
**Approved option:** Option C — Parallel Sprint
**Complexity:** High (hackathon, 14 hours remaining)

## Context

Marginalia is an on-device voice agent for Even Realities G2 smart glasses. The hackathon MVP must demonstrate: G2 mic captures audio → Gemma 4 on Cactus generates 3 tactical response options → G2 lens displays them flicker-free → R1 ring tap executes a function call (mock calendar event). Everything runs on MacBook + iPhone hotspot in airplane mode.

Two terminals run in parallel:
- **Terminal 1 (this spec):** Glasses app, fallbacks, calendar projection, landing page, demo hardening
- **Terminal 2 (independent):** Inference pipeline (2-step Parakeet STT → Gemma 4 text, or NPU fix), server API

## API Contract (shared between terminals)

```
POST /inference
  Request:  {"audio": "<base64 PCM 16kHz S16LE mono>", "sampleRate": 16000, "channels": 1, "bitsPerSample": 16}
  Response: {"options": [
    {"label": "Approve — block Mar 10-14", "action": "createCalendarHold", "args": {"title": "...", "startDate": "...", "endDate": "..."}},
    {"label": "Counter — ask about workload", "action": null, "args": null},
    {"label": "Defer — send calendar hold", "action": "createCalendarHold", "args": {...}}
  ]}

POST /inference-text
  Request:  {"text": "I've been feeling burned out. I think I need to take next week off."}
  Response: same as /inference (fallback endpoint for MacBook mic → Whisper → text)

POST /tool-call
  Request:  {"tool": "createCalendarHold", "args": {"title": "...", "startDate": "...", "endDate": "..."}}
  Response: {"status": "ok", "result": {"event": "PTO Hold", "dates": "Mar 10-14"}}
  Side effect: broadcasts to SSE /events stream

GET /health
  Response: {"status": "ok", "model": "gemma-4-e2b", "dummy": false}

GET /events
  SSE stream — pushes {"type": "tool_executed", "tool": "...", "result": {...}} when /tool-call fires
```

## Decisions

1. **G2 audio is primary, MacBook mic is fallback.** Build both paths; switch at demo time based on what works.
2. **2-step inference pipeline** (Parakeet STT → Gemma 4 text) unless other terminal fixes NPU audio path.
3. **TextContainer only** on G2 — zero flicker via textContainerUpgrade. No ListContainer.
4. **usemarginalia.com** — single-page site deployed to Cloudflare Pages showing product vision + 8 verticals.
5. **Calendar projection** — standalone HTML page served by FastAPI, receives events via SSE, runs on MacBook localhost.

## Tasks

### Task 1: MacBook Mic Fallback Script
**Objective:** Create a Python script that records audio from MacBook mic, sends to /inference, and prints options. This is the demo safety net if G2 audio relay fails.
**Complexity:** Simple
**Dependencies:** None
**Files to change:**
  - scripts/mic-fallback.py (new)
  - server/requirements.txt (add sounddevice)
**Acceptance criteria:**
  - Script records 3s of audio from MacBook default mic
  - Sends base64 PCM to POST /inference
  - Prints 3 options to stdout
  - Works with MARGINALIA_DUMMY=1 server
**Test plan:**
  - Unit: Run script against dummy server, verify 3 options returned
  - Smoke: Server /health endpoint still works
**Rollback plan:** Delete scripts/mic-fallback.py
**Blast radius:** None — standalone script
**Research needed:** No (sounddevice pattern confirmed)

### Task 2: Calendar Projection Page
**Objective:** Build a MacBook-side HTML page that shows a calendar grid. When /tool-call fires createCalendarHold, the event appears on the calendar in real-time via SSE. This is projected during the demo.
**Complexity:** Moderate
**Dependencies:** None (server SSE endpoint built by other terminal, but we can add it ourselves if needed)
**Files to change:**
  - server/static/calendar.html (new)
  - server/app.py (add SSE /events endpoint + serve static files)
**Acceptance criteria:**
  - Page shows a weekly calendar grid for current week
  - When /tool-call fires, event block appears with animation
  - Works at localhost:8080/calendar — no internet needed
  - Clean, dark-themed UI that looks good on projector
**Test plan:**
  - Unit: Open /calendar in browser, POST to /tool-call via curl, verify event appears
  - Smoke: /inference and /tool-call still work
**Rollback plan:** Remove static/calendar.html and SSE code
**Blast radius:** Adds SSE broadcast to /tool-call — must not slow down the response
**Research needed:** No (SSE pattern confirmed)

### Task 3: Landing Page — usemarginalia.com
**Objective:** Build a single-page static site showing Marginalia's vision: tagline, product screenshot/mockup, 8 vertical products (Counsel, Clinical, Floor, Diligence, etc.), and contact. Deploy to Cloudflare Pages.
**Complexity:** Moderate
**Dependencies:** None
**Files to change:**
  - site/index.html (new)
  - site/style.css (new)
**Acceptance criteria:**
  - Hero: "Marginalia" + tagline "The private commentary on every conversation that can't leave the room"
  - Section: 8 verticals with icons/names (Counsel, Clinical, Floor, Diligence, Counselor, Defense, Executive, Press)
  - Section: "How it works" — 3-step visual (Listen → Analyze → Act)
  - Footer: usemarginalia.com, contact email, "Built at YC Gemma 4 Hackathon"
  - Dark theme, minimal, loads without any external dependencies
  - Fine-tuning/training data narrative for each vertical
**Test plan:**
  - Unit: Open index.html in browser, verify renders correctly
  - Smoke: No external requests (check Network tab)
**Rollback plan:** Delete site/ directory
**Blast radius:** None — standalone static files
**Research needed:** No

### Task 4: Server-Side Hardening (SSE + static serving + /inference-text)
**Objective:** Add SSE events endpoint, static file serving for calendar page, and /inference-text fallback endpoint to the FastAPI server. This is the glue between the calendar projection and the MacBook mic fallback.
**Complexity:** Moderate
**Dependencies:** Task 2 (calendar page exists to serve)
**Files to change:**
  - server/app.py (add endpoints + static mount)
**Acceptance criteria:**
  - GET /events returns SSE stream
  - POST /tool-call broadcasts to SSE subscribers
  - POST /inference-text accepts {"text": "..."} and returns 3 options (bypasses audio)
  - Static files served from /static/ path
  - All existing endpoints still work
**Test plan:**
  - Unit: curl /inference-text with text, verify 3 options
  - Unit: Open /events in browser, POST /tool-call, verify SSE message
  - Smoke: /inference and /health still work
**Rollback plan:** Revert app.py changes
**Blast radius:** Modifies server code — must not break /inference
**Research needed:** No

### Task 5: Demo Context File
**Objective:** Create the scenario context file that primes Gemma 4 for the specific demo scenario (executive 1:1, direct report requests time off).
**Complexity:** Simple
**Dependencies:** None
**Files to change:**
  - server/context.md (new)
  - server/app.py (load context into system prompt)
**Acceptance criteria:**
  - Context includes: role (manager), scenario (direct report burnout/time-off request), guidance (consider workload, approve if sustainable, counter if not, defer to HR if needed)
  - System prompt incorporates context so model generates contextually sharp options
  - Volunteer line embedded: "I've been feeling burned out. I think I need to take next week off."
**Test plan:**
  - Unit: Run /inference-text with the volunteer line, verify options match scenario
  - Smoke: /inference still works with audio
**Rollback plan:** Remove context.md, revert system prompt
**Blast radius:** Changes model output quality — test carefully
**Research needed:** No

### Task 6: Glasses App — MacBook IP Configuration + Hotspot Setup Script
**Objective:** Make the MacBook IP configurable (not hardcoded) and create a setup script that detects the hotspot IP and updates the glasses app config.
**Complexity:** Simple
**Dependencies:** None
**Files to change:**
  - glasses/src/main.ts (read IP from config or URL param)
  - scripts/setup-hotspot.sh (new)
**Acceptance criteria:**
  - Glasses app reads MACBOOK_IP from URL query param: ?server=172.20.10.2:8080
  - Setup script detects MacBook's IP on the hotspot interface, prints the URL to load
  - Script generates QR code for the URL (via evenhub CLI)
**Test plan:**
  - Unit: Load glasses app with ?server=localhost:8080, verify it connects
  - Smoke: App still works without query param (uses default)
**Rollback plan:** Revert main.ts, delete setup script
**Blast radius:** None
**Research needed:** No

### Task 7: G2 Hardware Integration Test Checklist
**Objective:** Create a step-by-step test script for Phase 4 hardware integration. Each step is independently testable so we know exactly where a failure occurs.
**Complexity:** Simple
**Dependencies:** Tasks 1, 4, 6
**Files to change:**
  - scripts/integration-test.md (new)
**Acceptance criteria:**
  - Step-by-step checklist: (a) static text on G2, (b) audio capture, (c) audio POST, (d) options display, (e) ring selection, (f) tool-call execution
  - Each step has a "pass" and "fail → do this" instruction
  - Includes the MacBook mic pivot instruction if G2 audio fails
**Test plan:**
  - N/A — this is a test plan itself
**Rollback plan:** N/A
**Blast radius:** None
**Research needed:** No

### Task 8: Demo Rehearsal Script + Volunteer Briefing
**Objective:** Write the exact 5-minute demo script (what Ben says, what volunteer says, what the audience sees) and the volunteer briefing card.
**Complexity:** Simple
**Dependencies:** Tasks 2, 5
**Files to change:**
  - scripts/demo-script.md (new)
  - scripts/volunteer-briefing.md (new)
**Acceptance criteria:**
  - Demo script with timestamps: Act 1 (60s frame), Act 2 (2m45s live demo), Act 3 (75s company)
  - Volunteer briefing: exact line, pace, tone, one-take instructions
  - Fallback instructions if volunteer unavailable (pre-recorded audio via MacBook speakers)
  - usemarginalia.com referenced in Act 1 opening and Act 3 close
**Test plan:**
  - Read aloud, time it — should land 4:30-4:45
**Rollback plan:** N/A
**Blast radius:** None
**Research needed:** No

## Risks

1. **G2 BLE audio relay** — highest risk. Mitigation: MacBook mic fallback (Task 1), integration test checklist (Task 7).
2. **Inference latency >4s** — 2-step pipeline may hit 5-6s. Mitigation: dummy_mode as ultimate failsafe, context priming (Task 5) to get sharper responses.
3. **Two-terminal merge conflict** — both terminals modify server/app.py. Mitigation: API contract defined above, this terminal's changes are additive (SSE, /inference-text, static serving).
4. **Glyph rendering** — ◉ and ✓ may not render on G2 hardware. Mitigation: ● and "Done" as instant fallbacks in code.
5. **Cloudflare Pages deployment** — may need DNS propagation time. Mitigation: deploy early, or just show the page from localhost during demo.

## Research Notes
N/A — all research done inline via subagents (sounddevice, SSE patterns confirmed).
