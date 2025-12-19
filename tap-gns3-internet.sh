#!/bin/bash
set -e

# --- CONFIGURATION ---
TAP_IFACE="tap-gns3-0"
GATEWAY_IP="172.16.8.1/24"
# ---------------------

# --- NETWORK DETECTION ---

detect_wan_candidates() {
  candidates=()
  # 1. Check default route interface
  default_if=$(ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
  if [ -n "$default_if" ]; then
    candidates+=("$default_if")
  fi
  # 2. Check all UP interfaces (excluding loopback and our own TAP)
  while read -r ifname state; do
    [ "$ifname" = "lo" ] && continue
    [ "$ifname" = "$TAP_IFACE" ] && continue
    # Avoid duplicates
    if ! printf '%s\n' "${candidates[@]}" | grep -q "^$ifname"; then
      candidates+=("$ifname")
    fi
  done < <(ip -o link show up | awk -F': ' '{print $2, $3}')
  echo "${candidates[@]}"
}

choose_wan_iface() {
  if [ -n "$WAN_IFACE" ] && ip link show "$WAN_IFACE" >/dev/null 2>&1; then
    echo "$WAN_IFACE"
    return
  fi
  mapfile -t cand_arr < <(detect_wan_candidates)
  
  # Filter empty entries
  tmp=()
  for c in "${cand_arr[@]}"; do [ -n "$c" ] && tmp+=("$c"); done
  cand_arr=("${tmp[@]}")

  if [ ${#cand_arr[@]} -eq 0 ]; then
    echo "ERROR: No WAN candidates found. Define WAN_IFACE manually." >&2
    exit 1
  elif [ ${#cand_arr[@]} -eq 1 ]; then
    echo "${cand_arr[0]%% *}"
    return
  fi

  echo "Available WAN interfaces:"
  for i in "${!cand_arr[@]}"; do
    echo "  $((i + 1))) ${cand_arr[i]}"
  done

  while true; do
    read -rp "Select WAN interface number: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#cand_arr[@]} ]; then
      chosen="${cand_arr[$((sel - 1))]}"
      echo "${chosen%% *}"
      return
    fi
    if ip link show "$sel" >/dev/null 2>&1; then
      echo "$sel"
      return
    fi
    echo "Invalid selection."
  done
}

# --- MAIN FUNCTIONS ---

function start_bridge() {
  echo "🔵 Starting GNS3 Internet Bridge..."

  WAN_IFACE=$(choose_wan_iface)
  echo "   -> Using WAN interface: $WAN_IFACE"

  # 1. Create TAP Interface
  if ! ip link show "$TAP_IFACE" >/dev/null 2>&1; then
    sudo ip tuntap add dev "$TAP_IFACE" mode tap user "$(whoami)"
    echo "   -> Created $TAP_IFACE"
  fi

  # 2. Configure IP
  sudo ip addr flush dev "$TAP_IFACE"
  sudo ip addr add "$GATEWAY_IP" dev "$TAP_IFACE"
  sudo ip link set "$TAP_IFACE" up
  echo "   -> Assigned IP $GATEWAY_IP"

  # 3. Prevent duplicates: clean old rules first
  sudo iptables -t nat -D POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || true
  sudo iptables -D FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || true
  sudo iptables -D FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  sudo iptables -t mangle -D POSTROUTING -o "$TAP_IFACE" -j TTL --ttl-set 64 2>/dev/null || true

  # 4. Apply Rules
  echo "   -> Applying NAT, Forwarding, and TTL rules..."
  
  # NAT
  if ! sudo iptables -t nat -C POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
  fi

  # Forwarding
  if ! sudo iptables -C FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null; then
    sudo iptables -A FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT
  fi
  if ! sudo iptables -C FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    sudo iptables -A FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi

  # TTL Fix (Critical for nested virtualization/MikroTik)
  if ! sudo iptables -t mangle -C POSTROUTING -o "$TAP_IFACE" -j TTL --ttl-set 64 2>/dev/null; then
    sudo iptables -t mangle -A POSTROUTING -o "$TAP_IFACE" -j TTL --ttl-set 64
    echo "   -> Applied TTL Fix"
  fi

  # 5. Enable IP Forwarding
  if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]; then
    echo "   -> Enabling ip_forward"
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
  fi

  echo "✅ Bridge Started."
}

function stop_bridge() {
  echo "🔴 Stopping GNS3 Bridge..."

  # Infer WAN interface from Filter table (Forward chain) instead of NAT table
  # Look for the rule: -A FORWARD -i tap-gns3-0 -o <WAN_IFACE> ...
  if [ -z "$WAN_IFACE" ]; then
    inferred=$(sudo iptables -S FORWARD | grep "\-i $TAP_IFACE" | awk '/-o/ {for(i=1;i<=NF;i++) if($i=="-o") print $(i+1)}' | head -n1)
    if [ -n "$inferred" ]; then
        WAN_IFACE="$inferred"
        echo "   -> Detected active WAN interface: $WAN_IFACE"
    fi
  fi

  # 1. Remove rules
  if [ -n "$WAN_IFACE" ]; then
    sudo iptables -t nat -D POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  else
    echo "   -> WAN interface not found in rules, attempting generic cleanup..."
    sudo iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true
  fi

  # Cleanup TTL Fix
  sudo iptables -t mangle -D POSTROUTING -o "$TAP_IFACE" -j TTL --ttl-set 64 2>/dev/null || true
  echo "   -> Firewall rules removed."

  # 2. Delete TAP interface
  if ip link show "$TAP_IFACE" >/dev/null 2>&1; then
    sudo ip link delete "$TAP_IFACE"
    echo "   -> Deleted $TAP_IFACE"
  fi

  echo "✅ Bridge Stopped."
}

# --- CONTROLLER ---
case "$1" in
  start)   start_bridge ;;
  stop)    stop_bridge ;;
  restart) stop_bridge; start_bridge ;;
  *)       echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
