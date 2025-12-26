#!/bin/env bash

# --- Configuration ---
PYTHON_SITE_PACKAGES=$(python3 -c "import site; print([p for p in site.getsitepackages() if 'site-packages' in p][0])")
TARGET_DIR="$PYTHON_SITE_PACKAGES/gns3server/compute/docker"
BIN_LINK="/usr/local/bin/gns3-launch"

# Detect installed GNS3 version to download the correct original file
GNS3_VERSION=$(python3 -c "import gns3server; print(gns3server.__version__)")

echo "🗑️ Starting GNS3 Rootless Podman Patch Uninstallation"
echo "ℹ️ Detected GNS3 Version: $GNS3_VERSION"

# 1. Remove Symbolic Link
if [ -L "$BIN_LINK" ]; then
  echo "🔗 Removing symbolic link $BIN_LINK..."
  sudo rm "$BIN_LINK"
fi

# 2. Restore Original docker_vm.py
echo "🔄 Restoring original docker_vm.py from GNS3 GitHub..."
TEMP_FILE="/tmp/docker_vm_original.py"

# Try to download the version-specific file, fallback to master if not found
URL="https://raw.githubusercontent.com/GNS3/gns3-server/refs/tags/v${GNS3_VERSION}/gns3server/compute/docker/docker_vm.py"

if ! curl -s --head --fail "$URL" >/dev/null; then
  echo "⚠️ Version tag v${GNS3_VERSION} not found, falling back to master branch..."
  URL="https://raw.githubusercontent.com/GNS3/gns3-server/refs/heads/master/gns3server/compute/docker/docker_vm.py"
fi

curl -L -o "$TEMP_FILE" "$URL"

if [ $? -eq 0 ]; then
  sudo mv "$TEMP_FILE" "$TARGET_DIR/docker_vm.py"
  sudo chown root:root "$TARGET_DIR/docker_vm.py"
  echo "✅ Original docker_vm.py restored."
else
  echo "❌ Failed to download original docker_vm.py. Please restore it manually."
fi

# 3. Clean up additional files
echo "🧹 Removing patch files from $TARGET_DIR..."
FILES_TO_REMOVE=(
  "gns3-net-proxy"
  "gns3-net-agent"
  "gns3-launch-server.sh"
  "tap-gns3-internet.sh"
)

for FILE in "${FILES_TO_REMOVE[@]}"; do
  if [ -f "$TARGET_DIR/$FILE" ]; then
    sudo rm "$TARGET_DIR/$FILE"
    echo "  - Removed $FILE"
  fi
done

echo "✨ Uninstallation complete. System restored to standard GNS3 state."
