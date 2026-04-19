#!/usr/bin/env python3
"""Marginalia — MacBook mic fallback.

Records audio from the MacBook's default microphone and sends it to the
Marginalia server for inference. Use this if G2 BLE audio relay fails.

Usage:
    python scripts/mic-fallback.py                    # record 3s, send to server
    python scripts/mic-fallback.py --duration 5       # record 5s
    python scripts/mic-fallback.py --server 172.20.10.2:8080
    python scripts/mic-fallback.py --test             # test with dummy server
    python scripts/mic-fallback.py --loop             # continuous mode
"""
import argparse
import base64
import json
import sys
import time

import numpy as np
import sounddevice as sd
import urllib.request


def record_audio(duration: float, sample_rate: int = 16000) -> bytes:
    """Record audio from default mic, return as PCM S16LE bytes."""
    print(f"  Recording {duration}s from MacBook mic...")
    audio = sd.rec(
        int(duration * sample_rate),
        samplerate=sample_rate,
        channels=1,
        dtype="int16",
        blocking=True,
    )
    pcm_bytes = audio.tobytes()
    print(f"  Captured {len(pcm_bytes)} bytes ({len(audio)} samples)")
    return pcm_bytes


def send_inference(server: str, pcm_bytes: bytes) -> dict:
    """Send PCM audio to /inference as base64 JSON."""
    payload = json.dumps({
        "audio": base64.b64encode(pcm_bytes).decode(),
        "sampleRate": 16000,
        "channels": 1,
        "bitsPerSample": 16,
    }).encode()

    req = urllib.request.Request(
        f"http://{server}/inference",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"  ERROR: {e}")
        return {}


def send_text_inference(server: str, text: str) -> dict:
    """Send text to /inference-text (bypass audio entirely)."""
    payload = json.dumps({"text": text}).encode()
    req = urllib.request.Request(
        f"http://{server}/inference-text",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"  ERROR: {e}")
        return {}


def display_options(result: dict):
    """Pretty-print the 3 options."""
    options = result.get("options", [])
    if not options:
        print("  No options returned!")
        return
    print()
    for i, opt in enumerate(options):
        glyph = "\u25c9" if i == 0 else "\u25cb"
        label = opt.get("label", "???")
        action = opt.get("action", "")
        suffix = f"  [{action}]" if action else ""
        print(f"  {glyph} {label}{suffix}")
    print()
    inference_ms = result.get("inference_time_ms")
    if inference_ms:
        print(f"  Inference: {inference_ms}ms")


def main():
    parser = argparse.ArgumentParser(description="Marginalia mic fallback")
    parser.add_argument("--server", default="localhost:8080", help="Server host:port")
    parser.add_argument("--duration", type=float, default=3.0, help="Record duration (seconds)")
    parser.add_argument("--text", type=str, help="Send text instead of recording audio")
    parser.add_argument("--test", action="store_true", help="Quick test with dummy server")
    parser.add_argument("--loop", action="store_true", help="Continuous recording mode")
    args = parser.parse_args()

    print("=" * 50)
    print("  Marginalia — MacBook Mic Fallback")
    print(f"  Server: {args.server}")
    print("=" * 50)

    if args.text:
        print(f"\n  Sending text: \"{args.text}\"")
        result = send_text_inference(args.server, args.text)
        display_options(result)
        return

    if args.test:
        # Quick connectivity test
        try:
            req = urllib.request.Request(f"http://{args.server}/health")
            with urllib.request.urlopen(req, timeout=5) as resp:
                health = json.loads(resp.read())
                print(f"\n  Server health: {health}")
        except Exception as e:
            print(f"\n  Server unreachable: {e}")
            sys.exit(1)

    while True:
        print()
        input("  Press ENTER to start recording (Ctrl+C to quit)...")
        pcm = record_audio(args.duration)
        result = send_inference(args.server, pcm)
        display_options(result)

        if not args.loop:
            break


if __name__ == "__main__":
    main()
