#!/usr/bin/env python3
"""Quick test: scan for G2 glasses and try to display text using the G2 native protocol."""
import asyncio
import sys
import time
from bleak import BleakClient, BleakScanner

# G2 custom service UUIDs (NOT Nordic UART!)
CHAR_WRITE  = "00002760-08c2-11e1-9073-0e8ac72e5401"
CHAR_NOTIFY = "00002760-08c2-11e1-9073-0e8ac72e5402"

def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc

def build_packet(seq, svc_hi, svc_lo, payload):
    header = bytes([0xAA, 0x21, seq, len(payload) + 2, 0x01, 0x01, svc_hi, svc_lo])
    full = header + payload
    crc = crc16_ccitt(payload)
    return full + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

def encode_varint(value):
    result = []
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)

async def main():
    text = sys.argv[1] if len(sys.argv) > 1 else "Hello from Marginalia!\nGemma 4 on-device AI"

    print("Scanning for G2 glasses...")
    devices = await BleakScanner.discover(timeout=10.0)

    g2_left = None
    g2_right = None
    for d in devices:
        name = d.name or ""
        if "_L_" in name and ("Even" in name or "G2" in name):
            g2_left = d
            print(f"  Found LEFT: {name}")
        if "_R_" in name and ("Even" in name or "G2" in name):
            g2_right = d
            print(f"  Found RIGHT: {name}")

    target = g2_left or g2_right
    if not target:
        print("No G2 glasses found! Make sure:")
        print("  1. Glasses are powered on")
        print("  2. Even Realities app is force-closed")
        print("  3. Glasses are NOT connected to another device")
        return

    print(f"\nConnecting to {target.name}...")
    async with BleakClient(target) as client:
        print(f"Connected! Services:")
        for svc in client.services:
            print(f"  {svc.uuid}")
            for char in svc.characteristics:
                print(f"    {char.uuid} props={char.properties}")

        # Check if G2 write char exists
        try:
            chars = {c.uuid: c for s in client.services for c in s.characteristics}
            if CHAR_WRITE not in chars:
                print(f"\nERROR: G2 write characteristic {CHAR_WRITE} not found!")
                print("Available characteristics:")
                for uuid, c in chars.items():
                    print(f"  {uuid} props={c.properties}")
                return
        except Exception as e:
            print(f"Error enumerating chars: {e}")

        # Enable notifications
        await client.start_notify(CHAR_NOTIFY, lambda s, d: print(f"  <- notify [{len(d)}b]: {d[:20].hex()}"))

        # 7-packet auth
        print("\nAuthenticating (7-packet sequence)...")
        timestamp = int(time.time())
        ts_varint = encode_varint(timestamp)
        txid = bytes([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])

        auth_packets = [
            # 1: Capability query
            bytes([0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00,
                   0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04]),
            # 2: Capability response
            bytes([0xAA, 0x21, 0x02, 0x0A, 0x01, 0x01, 0x80, 0x20,
                   0x08, 0x05, 0x10, 0x0E, 0x22, 0x02, 0x08, 0x02]),
        ]

        # 3: Time sync
        p3_payload = bytes([0x08, 0x80, 0x01, 0x10, 0x0F, 0x82, 0x08, 0x11, 0x08]) + ts_varint + bytes([0x10]) + txid
        auth_packets.append(bytes([0xAA, 0x21, 0x03, len(p3_payload) + 2, 0x01, 0x01, 0x80, 0x20]) + p3_payload)

        # 4-5: Additional caps
        auth_packets.append(bytes([0xAA, 0x21, 0x04, 0x0C, 0x01, 0x01, 0x80, 0x00,
                                    0x08, 0x04, 0x10, 0x10, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04]))
        auth_packets.append(bytes([0xAA, 0x21, 0x05, 0x0C, 0x01, 0x01, 0x80, 0x00,
                                    0x08, 0x04, 0x10, 0x11, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04]))

        # 6: Final cap
        auth_packets.append(bytes([0xAA, 0x21, 0x06, 0x0A, 0x01, 0x01, 0x80, 0x20,
                                    0x08, 0x05, 0x10, 0x12, 0x22, 0x02, 0x08, 0x01]))

        # 7: Final time sync
        p7_payload = bytes([0x08, 0x80, 0x01, 0x10, 0x13, 0x82, 0x08, 0x11, 0x08]) + ts_varint + bytes([0x10]) + txid
        auth_packets.append(bytes([0xAA, 0x21, 0x07, len(p7_payload) + 2, 0x01, 0x01, 0x80, 0x20]) + p7_payload)

        # Add CRC to each
        for i, pkt in enumerate(auth_packets):
            crc = crc16_ccitt(pkt[8:])
            auth_packets[i] = pkt + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

        for i, pkt in enumerate(auth_packets):
            await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
            print(f"  Auth {i+1}/7 sent")
            await asyncio.sleep(0.1)

        await asyncio.sleep(0.5)
        print("Auth complete!")

        # Display config (service 0x0E-20)
        seq, msg_id = 0x08, 0x14
        config_hex = ("0801121308021090" "4E1D00E094442500" "000000280030001213"
                      "0803100D0F1D0040" "8D44250000000028" "0030001212080410"
                      "001D0000884225" "00000000280030" "001212080510001D"
                      "00009242250000" "A242280030001212" "080610001D0000C6"
                      "42250000C4422800" "30001800")
        config = bytes.fromhex(config_hex)
        disp_payload = bytes([0x08, 0x02, 0x10]) + encode_varint(msg_id) + bytes([0x22, 0x6A]) + config
        disp_pkt = build_packet(seq, 0x0E, 0x20, disp_payload)
        await client.write_gatt_char(CHAR_WRITE, disp_pkt, response=False)
        seq += 1; msg_id += 1
        print("Display config sent")
        await asyncio.sleep(0.3)

        # Teleprompter init (service 0x06-20, type=1)
        display_settings = (
            bytes([0x08, 0x01, 0x10, 0x00, 0x18, 0x00, 0x20, 0x8B, 0x02]) +
            bytes([0x28]) + encode_varint(500) +
            bytes([0x30, 0xE6, 0x01, 0x38, 0x8E, 0x0A, 0x40, 0x05, 0x48, 0x00])
        )
        settings = bytes([0x08, 0x01, 0x12, len(display_settings)]) + display_settings
        init_payload = bytes([0x08, 0x01, 0x10]) + encode_varint(msg_id) + bytes([0x1A, len(settings)]) + settings
        init_pkt = build_packet(seq, 0x06, 0x20, init_payload)
        await client.write_gatt_char(CHAR_WRITE, init_pkt, response=False)
        seq += 1; msg_id += 1
        print("Teleprompter init sent")
        await asyncio.sleep(0.5)

        # Content page (service 0x06-20, type=3)
        text_bytes = ("\n" + text).encode("utf-8")
        inner = bytes([0x08, 0x00, 0x10, 0x0A, 0x1A]) + encode_varint(len(text_bytes)) + text_bytes
        content = bytes([0x2A]) + encode_varint(len(inner)) + inner
        content_payload = bytes([0x08, 0x03, 0x10]) + encode_varint(msg_id) + content
        content_pkt = build_packet(seq, 0x06, 0x20, content_payload)
        await client.write_gatt_char(CHAR_WRITE, content_pkt, response=False)
        seq += 1; msg_id += 1
        print(f"Content sent: {text[:60]}...")
        await asyncio.sleep(0.1)

        # Sync trigger
        sync_payload = bytes([0x08, 0x0E, 0x10]) + encode_varint(msg_id) + bytes([0x6A, 0x00])
        sync_pkt = build_packet(seq, 0x80, 0x00, sync_payload)
        await client.write_gatt_char(CHAR_WRITE, sync_pkt, response=False)
        seq += 1; msg_id += 1
        print("Sync sent")

        print(f"\n✓ Text should be visible on G2 lens now!")
        print("Keeping connection alive for 30s...")

        # Heartbeat loop
        for i in range(4):
            await asyncio.sleep(8)
            hb_payload = bytes([0x08, 0x04, 0x10]) + encode_varint(msg_id) + bytes([0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])
            hb_pkt = build_packet(seq, 0x80, 0x00, hb_payload)
            await client.write_gatt_char(CHAR_WRITE, hb_pkt, response=False)
            seq += 1; msg_id += 1
            print(f"  Heartbeat {i+1}/4")

    print("Done!")

if __name__ == "__main__":
    asyncio.run(main())
