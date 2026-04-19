# Marginalia — G2 Hardware Integration Test

Run these steps IN ORDER. Each step is independently testable.
If a step fails, follow the "FAIL" instruction before proceeding.

## Pre-requisites
- [ ] iPhone Personal Hotspot ON, cellular OFF
- [ ] MacBook joined to iPhone hotspot
- [ ] Run `./scripts/setup-hotspot.sh` to get the MacBook IP
- [ ] Server running: `cd server && .venv/bin/python -m uvicorn server.app:app --host 0.0.0.0 --port 8080`
- [ ] Glasses Vite dev running: `cd glasses && npx vite --host 0.0.0.0 --port 5173`

## Step 1: Network Connectivity
**Test:** From iPhone Safari, load `http://<MACBOOK_IP>:8080/health`
- [ ] PASS: JSON response with `"status": "ok"`
- FAIL: Check hotspot connection, firewall, IP address

**Test:** From iPhone Safari, load `http://<MACBOOK_IP>:5173`
- [ ] PASS: "Marginalia — Waiting for Even App Bridge" page loads
- FAIL: Check Vite is running with `--host 0.0.0.0`

## Step 2: G2 Pairing
- [ ] G2 paired to iPhone via Even Realities app
- [ ] G2 connected (check Even app shows connected status)
- FAIL: Re-pair. Put glasses in case, take out, re-open Even app.

## Step 3: Load Glasses App in Even WebView
**Test:** In Even Realities app, scan QR or enter URL:
`http://<MACBOOK_IP>:5173/?server=<MACBOOK_IP>:8080`
- [ ] PASS: `waitForEvenAppBridge()` resolves (check Vite console log)
- FAIL: Try generating QR with `cd glasses && npx evenhub qr --http --port 5173`

## Step 4: Static Text Display
**Test:** After bridge connects, G2 lens should show:
```
MARGINALIA

Listening...
```
- [ ] PASS: Text visible on G2 lens
- FAIL: Check `createStartUpPageContainer` result in console. Try `rebuildPageContainer`.

## Step 5: Audio Capture
**Test:** After "Listening..." appears, speak clearly for 3 seconds.
Check Vite console for: `[Marginalia] Audio buffer complete: XXXX bytes`
- [ ] PASS: Audio frames arriving, buffer fills after 3s
- FAIL → **PIVOT TO MACBOOK MIC:**
  1. Kill the Vite dev server
  2. Use `python scripts/mic-fallback.py --server <MACBOOK_IP>:8080 --loop`
  3. G2 becomes display-only — manually trigger text updates
  4. For demo: speak into MacBook mic, server returns options,
     use a helper script to push options to G2 display

## Step 6: Inference Response
**Test:** After audio buffer sends, G2 lens should show:
```
MARGINALIA

Processing...
```
Then within 4-5 seconds, 3 options appear:
```
◉ Approve — block Mar 10-14
○ Counter — ask about workload
○ Defer — send calendar hold
```
- [ ] PASS: Options appear on G2 lens
- FAIL: Check server logs for inference errors.
  If inference too slow (>10s), enable dummy mode: `MARGINALIA_DUMMY=1`

## Step 7: Ring Selection
**Test:** Rotate R1 ring clockwise/counter-clockwise.
The ◉ glyph should move between options.
- [ ] PASS: Selection moves on ring rotation
- FAIL: Ring rotation maps to SCROLL events. Check `onEvenHubEvent` logs.
  Fallback: use temple swipe (same scroll events).

## Step 8: Tool Call Execution
**Test:** With an option selected, press R1 ring (click).
G2 should show: `✓ Done — {option label}`
MacBook calendar page should show new event.
- [ ] PASS: Tool call executes, calendar updates, G2 shows confirmation
- FAIL: Check `/tool-call-json` endpoint in server logs.

## Step 9: Reset Cycle
**Test:** After "Done" message, wait 2 seconds.
G2 should return to "Listening..." state.
- [ ] PASS: App cycles back to listening
- FAIL: Check `resetToListening()` in main.ts

## Step 10: End-to-End Demo Run
Run the full demo script (scripts/demo-script.md):
1. Volunteer says the line
2. G2 shows 3 options within 5 seconds
3. Tap ring to select option 1
4. Calendar page shows event
5. G2 shows "Done"
- [ ] PASS: Full cycle works. YOU ARE READY.
- FAIL: Use dummy mode for live demo. Set `MARGINALIA_DUMMY=1`.

## Glyph Fallbacks
If ◉ (U+25C9) doesn't render on G2, change in `glasses/src/main.ts`:
```
const GLYPH_SELECTED = '●'  // U+25CF — confirmed in G2 firmware
```
If ✓ (U+2713) doesn't render:
```
const GLYPH_DONE = 'OK'
```

## Network Verification (Airplane Mode Demo)
- [ ] MacBook WiFi OFF (only connected to iPhone hotspot)
- [ ] iPhone cellular OFF
- [ ] Little Snitch or `nettop -d -P -J bytes_in,bytes_out` shows 0 internet bytes
- [ ] All traffic is 172.20.10.x ↔ 172.20.10.x (hotspot LAN only)
