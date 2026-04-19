#!/bin/bash
# Copy model weights to iPhone's Marginalia app Documents/weights directory.
# Requires: iPhone connected via USB, Marginalia app installed.
#
# Method 1: Use Xcode's Devices & Simulators window
#   1. Open Xcode → Window → Devices and Simulators
#   2. Select your iPhone → Marginalia app
#   3. Click gear icon → Download Container
#   4. Show Package Contents → AppData/Documents/weights/
#   5. Copy the model directories there
#   6. Replace Container
#
# Method 2: Use ios-deploy or ideviceinstaller (if available)
#
# Method 3: Use Apple Configurator 2
#
# The weights directories to copy:
#   /opt/homebrew/Cellar/cactus/1.14_1/libexec/weights/gemma-4-e2b-it/
#   /opt/homebrew/Cellar/cactus/1.14_1/libexec/weights/parakeet-tdt-0.6b-v3/

set -e

WEIGHTS_SRC="/opt/homebrew/Cellar/cactus/1.14_1/libexec/weights"
STAGING="/tmp/marginalia-weights"

echo "=== Marginalia Weight Transfer ==="
echo ""

# Create staging directory
rm -rf "$STAGING"
mkdir -p "$STAGING"

echo "Copying Gemma 4 E2B weights..."
cp -R "$WEIGHTS_SRC/gemma-4-e2b-it" "$STAGING/"
echo "  $(du -sh "$STAGING/gemma-4-e2b-it" | cut -f1)"

echo "Copying Parakeet TDT weights..."
cp -R "$WEIGHTS_SRC/parakeet-tdt-0.6b-v3" "$STAGING/"
echo "  $(du -sh "$STAGING/parakeet-tdt-0.6b-v3" | cut -f1)"

echo ""
echo "Staged at: $STAGING"
echo "Total: $(du -sh "$STAGING" | cut -f1)"
echo ""
echo "=== Transfer Options ==="
echo ""
echo "Option A — Xcode (recommended):"
echo "  1. Build & run Marginalia on iPhone from Xcode"
echo "  2. Window → Devices and Simulators"
echo "  3. Select iPhone → Marginalia → Download Container"
echo "  4. Right-click .xcappdata → Show Package Contents"
echo "  5. Copy $STAGING/* into AppData/Documents/weights/"
echo "  6. Replace Container"
echo ""
echo "Option B — ifuse (if installed):"
echo "  ifuse --documents com.marginalia.app /tmp/marginalia-mount"
echo "  mkdir -p /tmp/marginalia-mount/weights"
echo "  cp -R $STAGING/* /tmp/marginalia-mount/weights/"
echo "  fusermount -u /tmp/marginalia-mount"
echo ""
echo "Option C — AirDrop the staging directory:"
echo "  open $STAGING"
echo "  Then AirDrop to iPhone and use Files app to move to Marginalia"
