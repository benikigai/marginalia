"""Marginalia — on-device voice agent server.

FastAPI server wrapping Cactus + Gemma 4 E2B for the Even Realities G2.
Accepts PCM audio, returns 3 tactical response options with optional tool calls.
"""
import json
import logging
import os
import struct
import sys
import time
from contextlib import asynccontextmanager

import asyncio
from pathlib import Path
from typing import AsyncGenerator

import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

# ---------------------------------------------------------------------------
# Cactus SDK import
# ---------------------------------------------------------------------------
from cactus import (
    cactus_complete,
    cactus_destroy,
    cactus_init,
    cactus_reset,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("marginalia")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
MODEL_PATH = os.environ.get(
    "MARGINALIA_MODEL_PATH",
    "/opt/homebrew/Cellar/cactus/1.14_1/libexec/weights/gemma-4-e2b-it",
)
DUMMY_MODE = os.environ.get("MARGINALIA_DUMMY", "0") == "1"
PORT = int(os.environ.get("MARGINALIA_PORT", "8080"))

# ---------------------------------------------------------------------------
# System prompt (loads scenario context from context.md if present)
# ---------------------------------------------------------------------------
_CONTEXT_PATH = os.path.join(os.path.dirname(__file__), "context.md")
_SCENARIO_CONTEXT = ""
if os.path.exists(_CONTEXT_PATH):
    with open(_CONTEXT_PATH) as f:
        _SCENARIO_CONTEXT = f.read().strip()

SYSTEM_PROMPT = f"""\
You are Marginalia, a private real-time commentary layer for high-stakes \
conversations. You listen to what the other person just said and produce \
exactly 3 tactical response options for the wearer.

Rules:
- Return ONLY valid JSON, no markdown, no explanation.
- The JSON schema is: {{"options": [<option>, <option>, <option>]}}
- Each option has: "label" (short, ≤40 chars), "action" (tool name or null), "args" (object or null)
- Available tools: createCalendarHold(title, startDate, endDate)
- First option should be the most direct/affirmative response.
- Second option should be an alternative or counter.
- Third option should be a deferral or conservative choice.
- Be context-aware: consider workplace dynamics, urgency, and stakes.

{_SCENARIO_CONTEXT}
"""

# ---------------------------------------------------------------------------
# Dummy response for failsafe mode
# ---------------------------------------------------------------------------
DUMMY_RESPONSE = {
    "options": [
        {
            "label": "Approve \u2014 block Mar 10-14",
            "action": "createCalendarHold",
            "args": {"title": "PTO - Direct Report", "startDate": "2026-03-10", "endDate": "2026-03-14"},
        },
        {
            "label": "Counter \u2014 ask about workload",
            "action": None,
            "args": None,
        },
        {
            "label": "Defer \u2014 send calendar hold",
            "action": "createCalendarHold",
            "args": {"title": "Follow-up: PTO Discussion", "startDate": "2026-03-10", "endDate": "2026-03-10"},
        },
    ]
}

# ---------------------------------------------------------------------------
# Tool execution (mock for hackathon)
# ---------------------------------------------------------------------------
CALENDAR_EVENTS: list[dict] = []


def execute_tool(tool_name: str, args: dict) -> dict:
    if tool_name == "createCalendarHold":
        event = {
            "id": len(CALENDAR_EVENTS) + 1,
            "title": args.get("title", "Untitled"),
            "startDate": args.get("startDate"),
            "endDate": args.get("endDate"),
            "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        CALENDAR_EVENTS.append(event)
        log.info(f"Calendar event created: {event}")
        return {"status": "created", "event": event}
    return {"status": "error", "message": f"Unknown tool: {tool_name}"}


# ---------------------------------------------------------------------------
# Model handle (global, set during lifespan)
# ---------------------------------------------------------------------------
_model = None


def _warm_model():
    """Pre-warm the model with a dummy completion to fill caches."""
    global _model
    log.info(f"Loading Gemma 4 E2B from {MODEL_PATH}...")
    t0 = time.time()
    _model = cactus_init(MODEL_PATH, None, False)
    log.info(f"Model loaded in {time.time() - t0:.1f}s")

    # Warm inference pass
    log.info("Warming inference cache...")
    t0 = time.time()
    warm_messages = json.dumps([
        {"role": "system", "content": "Return: {\"options\":[]}"},
        {"role": "user", "content": "Hello"},
    ])
    try:
        cactus_complete(_model, warm_messages, None, None, None)
    except Exception as e:
        log.warning(f"Warm pass raised (non-fatal): {e}")
    log.info(f"Warm pass done in {time.time() - t0:.1f}s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not DUMMY_MODE:
        _warm_model()
    else:
        log.info("DUMMY_MODE enabled — skipping model load")
    yield
    if _model:
        cactus_destroy(_model)


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(title="Marginalia", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve static files (calendar projection page)
_static_dir = Path(__file__).parent / "static"
if _static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(_static_dir)), name="static")

# ---------------------------------------------------------------------------
# SSE — Server-Sent Events for calendar projection
# ---------------------------------------------------------------------------
_sse_subscribers: set[asyncio.Queue] = set()


async def _broadcast_sse(event: dict):
    """Push an event to all connected SSE subscribers."""
    for q in _sse_subscribers.copy():
        try:
            q.put_nowait(event)
        except asyncio.QueueFull:
            _sse_subscribers.discard(q)


async def _sse_generator() -> AsyncGenerator[str, None]:
    """Yields SSE messages to a single client."""
    queue: asyncio.Queue = asyncio.Queue(maxsize=50)
    _sse_subscribers.add(queue)
    try:
        while True:
            event = await queue.get()
            yield f"data: {json.dumps(event)}\n\n"
    except asyncio.CancelledError:
        pass
    finally:
        _sse_subscribers.discard(queue)


def pcm_s16le_to_bytes(data: bytes) -> bytes:
    """Convert S16LE PCM (from G2 mic) to the byte format Cactus expects.

    Cactus cactus_complete accepts pcm_data as raw uint8 bytes.
    The G2 sends 16kHz mono S16LE. We pass it through as-is since
    Cactus/Gemma 4 E2B handles the audio encoding internally.
    """
    return data


def parse_cactus_response(raw: str) -> str:
    """Unwrap the Cactus SDK response envelope to get the model's text output."""
    try:
        envelope = json.loads(raw)
        if isinstance(envelope, dict) and "response" in envelope:
            return envelope["response"]
    except (json.JSONDecodeError, TypeError):
        pass
    return raw


def parse_options_json(raw: str) -> dict:
    """Extract the options JSON from model output, handling potential wrapping."""
    # First unwrap Cactus envelope
    raw = parse_cactus_response(raw)
    raw = raw.strip()

    # Strip markdown code fences if present
    if raw.startswith("```"):
        lines = raw.split("\n")
        lines = [l for l in lines if not l.strip().startswith("```")]
        raw = "\n".join(lines).strip()

    # Find JSON object
    start = raw.find("{")
    end = raw.rfind("}") + 1
    if start == -1 or end == 0:
        raise ValueError(f"No JSON object found in model output: {raw[:200]}")

    parsed = json.loads(raw[start:end])
    if "options" not in parsed:
        raise ValueError(f"Missing 'options' key in response: {list(parsed.keys())}")
    if len(parsed["options"]) != 3:
        log.warning(f"Expected 3 options, got {len(parsed['options'])}")
    return parsed


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model_loaded": _model is not None,
        "dummy_mode": DUMMY_MODE,
        "calendar_events": len(CALENDAR_EVENTS),
    }


@app.get("/events")
async def get_events():
    """Return all calendar events (for the projection display)."""
    return {"events": CALENDAR_EVENTS}


@app.get("/events-stream")
async def events_stream():
    """SSE endpoint for real-time calendar updates."""
    return StreamingResponse(
        _sse_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
    )


@app.post("/inference")
async def inference(audio: UploadFile = File(...)):
    """Accept PCM audio, return 3 tactical options."""
    t0 = time.time()

    if DUMMY_MODE:
        log.info("DUMMY_MODE: returning hardcoded response")
        return JSONResponse(content=DUMMY_RESPONSE)

    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    # Read audio bytes
    audio_bytes = await audio.read()
    log.info(f"Received {len(audio_bytes)} bytes of audio")

    if len(audio_bytes) < 100:
        raise HTTPException(status_code=400, detail="Audio too short")

    # Build messages
    messages = json.dumps([
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": "Listen to this audio and provide 3 tactical response options."},
    ])

    # Tools definition for Gemma 4 function calling
    tools = json.dumps([
        {
            "name": "createCalendarHold",
            "description": "Create a calendar hold/event for scheduling",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Event title"},
                    "startDate": {"type": "string", "description": "Start date (YYYY-MM-DD)"},
                    "endDate": {"type": "string", "description": "End date (YYYY-MM-DD)"},
                },
                "required": ["title", "startDate", "endDate"],
            },
        }
    ])

    # Convert audio if needed
    pcm_data = pcm_s16le_to_bytes(audio_bytes)

    # Run inference with increased token limit
    options = json.dumps({"max_tokens": 512})
    try:
        cactus_reset(_model)
        raw = cactus_complete(_model, messages, options, tools, None, pcm_data=pcm_data)
        elapsed = time.time() - t0
        log.info(f"Inference completed in {elapsed:.2f}s")
        log.info(f"Raw response: {raw[:500]}")
    except Exception as e:
        log.error(f"Inference failed: {e}")
        raise HTTPException(status_code=500, detail=f"Inference failed: {e}")

    # Parse response
    try:
        result = parse_options_json(raw)
    except (json.JSONDecodeError, ValueError) as e:
        log.error(f"Failed to parse model output: {e}")
        log.error(f"Raw output: {raw}")
        # Fall back to dummy response on parse failure
        log.warning("Falling back to dummy response")
        result = DUMMY_RESPONSE

    return JSONResponse(content={**result, "inference_time_ms": int((time.time() - t0) * 1000)})


@app.post("/tool-call")
async def tool_call(tool_name: str = Form(...), args: str = Form(...)):
    """Execute a tool call (mock for hackathon)."""
    try:
        parsed_args = json.loads(args)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON in args")

    log.info(f"Tool call: {tool_name}({parsed_args})")
    result = execute_tool(tool_name, parsed_args)
    return JSONResponse(content=result)


@app.post("/tool-call-json")
async def tool_call_json(body: dict):
    """Execute a tool call via JSON body (alternative to form-encoded)."""
    tool_name = body.get("tool_name") or body.get("action") or body.get("tool")
    args = body.get("args", {})
    if not tool_name:
        raise HTTPException(status_code=400, detail="Missing tool_name/action/tool")
    log.info(f"Tool call (JSON): {tool_name}({args})")
    result = execute_tool(tool_name, args)
    # Broadcast to SSE subscribers for calendar projection
    await _broadcast_sse({"type": "tool_executed", "tool": tool_name, "result": result})
    return JSONResponse(content=result)


@app.post("/inference-text")
async def inference_text(request: Request):
    """Accept text input (bypass audio), return 3 tactical options.

    Used by the MacBook mic fallback script when Whisper transcribes locally,
    or for direct text testing.
    """
    t0 = time.time()
    body = await request.json()
    text = body.get("text", "")
    if not text:
        raise HTTPException(status_code=400, detail="Missing 'text' field")

    log.info(f"Text inference: \"{text[:100]}\"")

    if DUMMY_MODE:
        log.info("DUMMY_MODE: returning hardcoded response")
        return JSONResponse(content=DUMMY_RESPONSE)

    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    messages = json.dumps([
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"The other person just said: \"{text}\"\n\nProvide 3 tactical response options."},
    ])

    tools = json.dumps([
        {
            "name": "createCalendarHold",
            "description": "Create a calendar hold/event for scheduling",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Event title"},
                    "startDate": {"type": "string", "description": "Start date (YYYY-MM-DD)"},
                    "endDate": {"type": "string", "description": "End date (YYYY-MM-DD)"},
                },
                "required": ["title", "startDate", "endDate"],
            },
        }
    ])

    options = json.dumps({"max_tokens": 512})
    try:
        cactus_reset(_model)
        raw = cactus_complete(_model, messages, options, tools, None)
        elapsed = time.time() - t0
        log.info(f"Text inference completed in {elapsed:.2f}s")
        log.info(f"Raw response: {raw[:500]}")
    except Exception as e:
        log.error(f"Text inference failed: {e}")
        raise HTTPException(status_code=500, detail=f"Inference failed: {e}")

    try:
        result = parse_options_json(raw)
    except (json.JSONDecodeError, ValueError) as e:
        log.error(f"Failed to parse model output: {e}")
        log.warning("Falling back to dummy response")
        result = DUMMY_RESPONSE

    return JSONResponse(content={**result, "inference_time_ms": int((time.time() - t0) * 1000)})


@app.post("/inference-json")
async def inference_json(request: Request):
    """Accept audio as base64 JSON (from glasses app), return 3 options.

    Expected body: {"audio": "<base64 PCM>", "sampleRate": 16000, ...}
    """
    t0 = time.time()
    body = await request.json()
    audio_b64 = body.get("audio", "")
    if not audio_b64:
        raise HTTPException(status_code=400, detail="Missing 'audio' field")

    import base64
    audio_bytes = base64.b64decode(audio_b64)
    log.info(f"Received {len(audio_bytes)} bytes of base64-decoded audio")

    if DUMMY_MODE:
        log.info("DUMMY_MODE: returning hardcoded response")
        return JSONResponse(content=DUMMY_RESPONSE)

    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    if len(audio_bytes) < 100:
        raise HTTPException(status_code=400, detail="Audio too short")

    messages = json.dumps([
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": "Listen to this audio and provide 3 tactical response options."},
    ])

    tools = json.dumps([
        {
            "name": "createCalendarHold",
            "description": "Create a calendar hold/event for scheduling",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Event title"},
                    "startDate": {"type": "string", "description": "Start date (YYYY-MM-DD)"},
                    "endDate": {"type": "string", "description": "End date (YYYY-MM-DD)"},
                },
                "required": ["title", "startDate", "endDate"],
            },
        }
    ])

    pcm_data = pcm_s16le_to_bytes(audio_bytes)
    options = json.dumps({"max_tokens": 512})
    try:
        cactus_reset(_model)
        raw = cactus_complete(_model, messages, options, tools, None, pcm_data=pcm_data)
        elapsed = time.time() - t0
        log.info(f"Audio inference completed in {elapsed:.2f}s")
    except Exception as e:
        log.error(f"Audio inference failed: {e}")
        raise HTTPException(status_code=500, detail=f"Inference failed: {e}")

    try:
        result = parse_options_json(raw)
    except (json.JSONDecodeError, ValueError) as e:
        log.error(f"Failed to parse model output: {e}")
        log.warning("Falling back to dummy response")
        result = DUMMY_RESPONSE

    return JSONResponse(content={**result, "inference_time_ms": int((time.time() - t0) * 1000)})


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
