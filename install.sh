#!/bin/env bash

# --- Configuration ---
# Detect the first site-packages directory found for gns3server
PYTHON_SITE_PACKAGES=$(python3 -c "import site; print([p for p in site.getsitepackages() if 'site-packages' in p][0])")
TARGET_DIR="$PYTHON_SITE_PACKAGES/gns3server/compute/docker"
BIN_LINK="/usr/local/bin/gns3-launch"
CURRENT_USER=$(whoami)
USER_UID=$(id -u)
DOCKER_LINK_EXISTS=0

echo "🔍 Verifying container engine status..."

# V.1. Detect if the 'docker' command is actually Podman or the real Docker
if command -v docker >/dev/null 2>&1; then
  REAL_DOCKER_PATH=$(readlink -f $(which docker))
  if [[ "$REAL_DOCKER_PATH" != *"podman"* ]]; then
    echo "❌ CRITICAL: Real Docker binary detected at $REAL_DOCKER_PATH"
    echo "   This project is incompatible with the standard Docker engine."
    echo "   Please uninstall Docker (docker-ce, docker.io) before proceeding."
    exit 1
  else
    echo "✅ 'docker' command is already a symlink to Podman. Good."
    DOCKER_LINK_EXISTS=1
  fi
fi

# V.2. Check if the Docker Daemon binary exists anywhere (even if not in PATH)
if [ -f "/usr/bin/dockerd" ] || [ -f "/usr/local/bin/dockerd" ]; then
  echo "⚠️  WARNING: Docker Daemon (dockerd) found on system."
  echo "   Running both engines can cause socket conflicts."
  exit 1
fi

# V.3. Final check: Does Podman exist?
if ! command -v podman >/dev/null 2>&1; then
  echo "❌ ERROR: Podman not found. Please install Podman first."
  exit 1
fi

echo "🚀 Starting GNS3 Rootless Podman Patch Installation"

# 1. System Prerequisites
echo "🛠️  Configuring System Prerequisites..."

# Symlink docker -> podman
if [ $DOCKER_LINK_EXISTS -eq 0 ]; then
  echo "🔗 Creating docker alias for podman..."
  sudo ln -s /usr/bin/podman /usr/local/bin/docker
else
  echo "✅ Skipping docker alias creation (already exists)."
fi

# Configure systemd-tmpfiles for the socket
TMPFILES_CONF="/etc/tmpfiles.d/containers.conf"
if [ ! -f "$TMPFILES_CONF" ]; then
  echo "⚙️  Configuring Podman socket symlink via tmpfiles.d..."
  sudo bash -c "cat <<EOF > $TMPFILES_CONF
d /run/containers 0755 root root
d /run/containers/storage 0700 $CURRENT_USER $CURRENT_USER
L /run/docker.sock - - - - /run/user/$USER_UID/podman/podman.sock
EOF"
  sudo systemd-tmpfiles --create $TMPFILES_CONF
else
  echo "✅ $TMPFILES_CONF already exists. Skipping creation."
fi

# ubridge capabilities
CURRENT_CAPS=$(getcap /usr/bin/ubridge)
if [[ $CURRENT_CAPS == *"cap_net_admin"* ]] && [[ $CURRENT_CAPS == *"cap_net_raw"* ]]; then
  echo "✅ ubridge already has the necessary capabilities."
else
  echo "🔒 Setting capabilities for ubridge..."
  sudo setcap cap_net_admin,cap_net_raw+ep /usr/bin/ubridge
fi

# 2. Compilation
echo "🛠  Compiling C++ Proxy and C Agent..."
g++ -O3 -pthread -o gns3-net-proxy gns3-net-proxy.cpp
gcc -O2 -static -o gns3-net-agent gns3-net-agent.c

if [ $? -ne 0 ]; then
  echo "❌ Compilation failed. Please check if g++ and gcc are installed."
  exit 1
fi

# 3. Preparation
if [ ! -d "$TARGET_DIR" ]; then
  echo "❌ GNS3 Server directory not found at $TARGET_DIR"
  exit 1
fi

# 4. Deployment
echo "📦 Copying files to $TARGET_DIR..."
sudo cp gns3-net-proxy gns3-net-agent gns3-launch-server.sh tap-gns3-internet.sh docker_vm.py "$TARGET_DIR/"
rm -f gns3-net-proxy gns3-net-agent

echo "🔐 Setting executable permissions..."
sudo chmod +x "$TARGET_DIR/gns3-net-proxy"
sudo chmod +x "$TARGET_DIR/gns3-launch-server.sh"
sudo chmod +x "$TARGET_DIR/tap-gns3-internet.sh"
sudo chown root:root "$TARGET_DIR/docker_vm.py"

# 5. Symbolic Link
echo "🔗 Creating symbolic link at $BIN_LINK..."
if [ -L "$BIN_LINK" ]; then
  sudo rm "$BIN_LINK"
fi
sudo ln -s "$TARGET_DIR/gns3-launch-server.sh" "$BIN_LINK"

echo "✅ Installation complete!"
echo "💡 You can now run the server using: gns3-launch"
