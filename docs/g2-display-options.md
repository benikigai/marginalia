# G2 Display: Two Paths to Try

## Context
- Even App must be disconnected for Marginalia to connect via BLE
- Raw BLE from iOS hits "no write characteristics" on some attempts
- We need text on the G2 lens for the demo, 2 hours left

---

## OPTION 2: Notification Protocol (0x4B) from iOS App

**Architecture:** Same as current — iPhone connects to G2 directly via BLE.
But instead of the 0x4E EvenAI text command, use the 0x4B notification command
which is a simpler rendering path on the glasses firmware.

**Why it might work when 0x4E doesn't:** The 0x4B notification display is a
lower-level feature that doesn't require the full EvenAI session state machine.
It's how the Even App shows phone notifications on the lens.

**Packet format (from EvenDemoApp proto.dart):**
```
[0x4B] [msgId] [maxSeq] [seq] [...JSON payload bytes]
```

JSON payload:
```json
{"ncs_notification": {"title": "Marginalia", "body": "Your LLM response text here"}}
```

Max 176 bytes per chunk. Send to L first (wait for ack 0xC9), then R.

**Implementation in G2BluetoothManager.swift:**
```swift
func sendNotification(title: String, body: String) {
    let json = "{\"ncs_notification\":{\"title\":\"\(title)\",\"body\":\"\(body)\"}}"
    let data = Array(json.utf8)
    let chunkSize = 176
    let totalChunks = max(1, (data.count + chunkSize - 1) / chunkSize)
    let msgId = UInt8(textSeq & 0xFF)
    textSeq &+= 1
    
    for seq in 0..<totalChunks {
        let start = seq * chunkSize
        let end = min(start + chunkSize, data.count)
        let chunk = Array(data[start..<end])
        
        var packet = Data()
        packet.append(0x4B)
        packet.append(msgId)
        packet.append(UInt8(totalChunks))
        packet.append(UInt8(seq))
        packet.append(contentsOf: chunk)
        
        writeToLeft(packet)
        writeToRight(packet)
    }
    lensText = body
}
```

**Changes needed:**
1. Add `sendNotification()` to G2BluetoothManager.swift
2. In ContentView, when LLM responds, call `g2.sendNotification()` instead of `g2.sendText()`
3. Test if the notification renders on the lens

**Risk:** Medium. Same BLE connection — if write characteristics aren't found, this won't help either. But if the UART fix (already pushed) works and connection reaches "Ready", this is an alternative render path.

**Time:** 15-20 min to implement + test.

---

## OPTION 3: Python BLE Bridge from MacBook (RECOMMENDED)

**Architecture:**
```
iPhone (Marginalia)                    MacBook
┌──────────────┐     HTTP POST      ┌──────────────┐     BLE      ┌─────┐
│ Gemma LLM    │ ──────────────���───>│ Python bridge │ ──────────> │ G2  │
│ Mic → STT    │  /display-text     │ (bleak)       │  0x4E UART  │     │
│ Wake word    │                    │ port 9091     │             └─────┘
└──────────────┘                    └──────────────┘
```

**Why this is better:**
1. Mac BLE stack (bleak) is battle-tested and different from iOS CoreBluetooth
2. i-soxi/even-g2-protocol already has working Python code
3. Separates concerns: phone owns inference, Mac owns display
4. No "write characteristics" issue — bleak discovers services differently
5. Can test the Python script independently first

**Implementation plan:**

### Step 1: Clone and test the existing Python tool
```bash
cd ~/marginalia
git clone https://github.com/i-soxi/even-g2-protocol.git g2-python
cd g2-python
pip install bleak
python teleprompter.py "Hello from Marginalia"
```

If that works, G2 shows text. Done — we know BLE from Mac works.

### Step 2: Build a simple HTTP bridge server
File: `marginalia/g2-bridge/bridge.py`

```python
#!/usr/bin/env python3
"""HTTP bridge: receives text via POST, pushes to G2 via BLE."""
import asyncio
import json
from aiohttp import web
from bleak import BleakClient, BleakScanner

UART_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
UART_TX      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
UART_RX      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

g2_client = None  # BleakClient, set after connect

async def connect_g2():
    """Scan for G2, connect, init UART."""
    global g2_client
    print("Scanning for G2...")
    devices = await BleakScanner.discover(timeout=10)
    left = right = None
    for d in devices:
        name = d.name or ""
        if "_L_" in name and ("Even" in name or "G2" in name):
            left = d
        if "_R_" in name and ("Even" in name or "G2" in name):
            right = d
    
    # Connect to left arm (primary for text display)
    target = left or right
    if not target:
        print("ERROR: No G2 found")
        return False
    
    print(f"Connecting to {target.name}...")
    g2_client = BleakClient(target.address)
    await g2_client.connect()
    
    # Init command
    await g2_client.write_gatt_char(UART_TX, bytes([0x4D, 0x01]), response=False)
    print(f"Connected to {target.name}")
    
    # Start heartbeat
    asyncio.create_task(heartbeat_loop())
    return True

async def heartbeat_loop():
    """Send heartbeat every 8s to keep connection alive."""
    seq = 0
    while g2_client and g2_client.is_connected:
        data = bytes([0x25, 0x06, 0x00, seq & 0xFF, 0x04, seq & 0xFF])
        try:
            await g2_client.write_gatt_char(UART_TX, data, response=False)
        except:
            pass
        seq += 1
        await asyncio.sleep(8)

async def send_text_to_g2(text: str):
    """Send text to G2 lens using 0x4E teleprompter command."""
    if not g2_client or not g2_client.is_connected:
        return False
    
    text_bytes = text.encode("utf-8")
    chunk_size = 191
    total_chunks = max(1, (len(text_bytes) + chunk_size - 1) // chunk_size)
    sync_seq = 0  # increment if needed
    
    for seq in range(total_chunks):
        start = seq * chunk_size
        end = min(start + chunk_size, len(text_bytes))
        chunk = text_bytes[start:end]
        
        packet = bytes([
            0x4E,           # command
            sync_seq,       # sync sequence
            total_chunks,   # total chunks
            seq,            # current chunk
            0x71,           # newScreen: text show mode
            0x00, 0x00,     # char position
            0x01,           # current page
            0x01,           # total pages
        ]) + chunk
        
        await g2_client.write_gatt_char(UART_TX, packet, response=False)
        await asyncio.sleep(0.05)  # small delay between chunks
    
    return True

# HTTP endpoints
async def handle_display(request):
    data = await request.json()
    text = data.get("text", "")
    if not text:
        return web.json_response({"error": "no text"}, status=400)
    
    ok = await send_text_to_g2(text)
    return web.json_response({"sent": ok, "text": text[:100]})

async def handle_health(request):
    connected = g2_client is not None and g2_client.is_connected
    return web.json_response({"g2_connected": connected})

async def init_app():
    await connect_g2()

app = web.Application()
app.router.add_post("/display-text", handle_display)
app.router.add_get("/health", handle_health)
app.on_startup.append(lambda _: init_app())

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=9091)
```

### Step 3: Wire Marginalia iOS app to POST to bridge
In `InferenceEngine.swift`, after LLM response, POST to the bridge:
```swift
// After setting llmResponse:
if let data = try? JSONSerialization.data(withJSONObject: ["text": response]),
   let url = URL(string: "http://<mbp-ip>:9091/display-text") {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    URLSession.shared.dataTask(with: req).resume()
}
```

### Step 4: Run during demo
```bash
# On MacBook (MBP):
cd ~/marginalia/g2-bridge
python bridge.py
# → "Scanning for G2... Connected to Even G2_XX_L_YYYY"

# On iPhone:
# Marginalia app listens → "Hey Gemma" → LLM response → POST to bridge �� G2 shows text
```

**Risk:** Low. bleak is well-tested. The i-soxi project already proved this works.
**Time:** 30-45 min total (clone, test, build bridge, wire).

---

## RECOMMENDATION

**Try both in parallel:**
- MBP Terminal 1: Test Option 3 first (clone i-soxi, run teleprompter.py, confirm text shows on G2)
- MBP Terminal 2: If raw Python works, build the HTTP bridge
- Mac Mini: Wire the iOS app to POST to the bridge endpoint

If Option 3 works (Python can push text to G2), it's the demo architecture.
If it doesn't, try Option 2 (0x4B notification command) as a last resort.
