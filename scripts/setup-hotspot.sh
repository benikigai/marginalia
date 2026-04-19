#!/usr/bin/env bash
# Detect MacBook's IP on the iPhone hotspot bridge interface and print the URLs.
# Usage: ./scripts/setup-hotspot.sh

set -euo pipefail

# iPhone hotspot typically creates bridge100 or en* interface with 172.20.10.x
HOTSPOT_IP=$(ifconfig | grep -A2 'bridge100\|en0' | grep 'inet ' | grep '172.20.10' | awk '{print $2}' | head -1)

if [ -z "$HOTSPOT_IP" ]; then
  # Fallback: try any 172.20.10.x address
  HOTSPOT_IP=$(ifconfig | grep 'inet 172.20.10' | awk '{print $2}' | head -1)
fi

if [ -z "$HOTSPOT_IP" ]; then
  echo "ERROR: No hotspot IP found. Is iPhone Personal Hotspot on?"
  echo "Trying all local IPs:"
  ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print "  " $2}'
  exit 1
fi

echo "============================================"
echo "  Marginalia — Hotspot Setup"
echo "============================================"
echo ""
echo "  MacBook IP: ${HOTSPOT_IP}"
echo ""
echo "  Server:     http://${HOTSPOT_IP}:8080"
echo "  Health:     http://${HOTSPOT_IP}:8080/health"
echo "  Calendar:   http://${HOTSPOT_IP}:8080/static/calendar.html"
echo ""
echo "  Glasses app (Vite dev):"
echo "    http://${HOTSPOT_IP}:5173/?server=${HOTSPOT_IP}:8080"
echo ""
echo "  To generate QR for Even Realities app:"
echo "    cd glasses && npx evenhub qr --http --port 5173"
echo ""
echo "============================================"
