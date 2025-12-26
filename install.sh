#!/bin/env bash

# --- Configuration ---
# Detect the first site-packages directory found for gns3server
PYTHON_SITE_PACKAGES=$(python3 -c "import site; print([p for p in site.getsitepackages() if 'site-packages' in p][0])")
TARGET_DIR="$PYTHON_SITE_PACKAGES/gns3server/compute/docker"
BIN_LINK="/usr/local/bin/gns3-launch"

echo "🚀 Starting GNS3 Rootless Podman Patch Installation"
echo "📂 Target directory: $TARGET_DIR"

# 1. Compilation
echo "🛠  Compiling C++ Proxy and C Agent..."
g++ -O3 -pthread -o gns3-net-proxy gns3-net-proxy.cpp
gcc -O2 -static -o gns3-net-agent gns3-net-agent.c

if [ $? -ne 0 ]; then
  echo "❌ Compilation failed. Please check if g++ and gcc are installed."
  exit 1
fi

# 2. Preparation
if [ ! -d "$TARGET_DIR" ]; then
  echo "❌ GNS3 Server directory not found at $TARGET_DIR"
  exit 1
fi

# 3. Deployment
echo "📦 Copying files to $TARGET_DIR..."
sudo cp gns3-net-proxy gns3-net-agent gns3-launch-server.sh tap-gns3-internet.sh docker_vm.py "$TARGET_DIR/"
rm -f gns3-net-proxy gns3-net-agent

echo "🔐 Setting executable permissions..."
sudo chmod +x "$TARGET_DIR/gns3-net-proxy"
sudo chmod +x "$TARGET_DIR/gns3-launch-server.sh"
sudo chmod +x "$TARGET_DIR/tap-gns3-internet.sh"
sudo chown root:root "$TARGET_DIR/docker_vm.py"

# 4. Symbolic Link
echo "🔗 Creating symbolic link at $BIN_LINK..."
if [ -L "$BIN_LINK" ]; then
  sudo rm "$BIN_LINK"
fi
sudo ln -s "$TARGET_DIR/gns3-launch-server.sh" "$BIN_LINK"

echo "✅ Installation complete!"
echo "💡 You can now run the server using: export GNS3_USE_PODMAN=1 && gns3-launch"
