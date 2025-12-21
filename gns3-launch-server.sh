#!/bin/bash

# Configuration
BRIDGE_SCRIPT="/usr/lib/python3.13/site-packages/gns3server/compute/docker/tap-gns3-internet.sh"
GNS3_EXECUTABLE="gns3server" # Use "gns3" if launching the GUI

# Pre-validate sudo to prevent password prompt overlapping with logs
sudo -v

# Keep sudo alive in background (optional, useful for long sessions)
while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" || exit
done 2>/dev/null &

# Cleanup function
function cleanup() {
  echo -e "\n🛑 Shutting down GNS3 environment..."
  # Suppress output to keep shutdown clean, unless there's an error
  sudo "$BRIDGE_SCRIPT" stop >/dev/null
  exit
}

# Trap signals (Ctrl+C, Termination)
trap cleanup SIGINT SIGTERM

echo "🚀 Setting up GNS3 network environment..."

# 1. Check & Start Podman Socket (Rootless)
systemctl --user is-active --quiet podman.socket
if [ $? -ne 0 ]; then
  echo "   -> Starting podman.socket..."
  if ! systemctl --user start podman.socket; then
    echo "❌ Failed to start podman.socket. Is podman installed?"
    exit 1
  fi
  echo "   -> podman.socket is active."
fi

# 2. Start Network Bridge (NAT + TTL/Checksum Fix)
if ! sudo "$BRIDGE_SCRIPT" start; then
  echo "❌ Failed to start network bridge. Aborting."
  exit 1
fi

echo "✅ Network ready. Launching GNS3..."
echo "-----------------------------------------------------"
# Small pause to ensure stdout flushes before GNS3 logs start
sleep 1

# 3. Start GNS3 in background
"$GNS3_EXECUTABLE" &
PID_GNS3=$!

# Wait for GNS3 process to finish
wait $PID_GNS3

# Final cleanup
cleanup
