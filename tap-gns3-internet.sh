#!/bin/bash

# --- CONFIGURACIÓN ---
# Tu interfaz con internet (Wi-Fi)
WAN_IFACE="wlan0"

# Nombre de la interfaz virtual para GNS3
TAP_IFACE="tap-gns3-internet"

# La IP que tendrá tu host en esa red (Gateway para Mikrotik)
GATEWAY_IP="192.168.123.1/24"
# ---------------------

function start_bridge() {
  echo "🔵 Iniciando Puente GNS3 Internet..."

  # 1. Crear la interfaz TAP si no existe
  if ! ip link show $TAP_IFACE >/dev/null 2>&1; then
    sudo ip tuntap add dev $TAP_IFACE mode tap user $(whoami)
    echo "   -> Interfaz $TAP_IFACE creada."
  fi

  # 2. Asignar IP y levantar
  sudo ip addr flush dev $TAP_IFACE
  sudo ip addr add $GATEWAY_IP dev $TAP_IFACE
  sudo ip link set $TAP_IFACE up
  echo "   -> IP $GATEWAY_IP asignada."

  # 3. Reglas de IPTables (NAT)
  # Limpiamos reglas previas para evitar duplicados
  sudo iptables -t nat -D POSTROUTING -o $WAN_IFACE -j MASQUERADE 2>/dev/null
  sudo iptables -D FORWARD -i $TAP_IFACE -o $WAN_IFACE -j ACCEPT 2>/dev/null
  sudo iptables -D FORWARD -i $WAN_IFACE -o $TAP_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

  # Agregamos las reglas
  sudo iptables -t nat -A POSTROUTING -o $WAN_IFACE -j MASQUERADE
  sudo iptables -A FORWARD -i $TAP_IFACE -o $WAN_IFACE -j ACCEPT
  sudo iptables -A FORWARD -i $WAN_IFACE -o $TAP_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT

  echo "✅ Conexión establecida. Configura tu Mikrotik con Gateway: ${GATEWAY_IP%/*}"
}

function stop_bridge() {
  echo "🔴 Deteniendo Puente GNS3..."

  # 1. Borrar reglas de IPTables
  sudo iptables -t nat -D POSTROUTING -o $WAN_IFACE -j MASQUERADE 2>/dev/null
  sudo iptables -D FORWARD -i $TAP_IFACE -o $WAN_IFACE -j ACCEPT 2>/dev/null
  sudo iptables -D FORWARD -i $WAN_IFACE -o $TAP_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  echo "   -> Reglas NAT eliminadas."

  # 2. Destruir interfaz TAP
  if ip link show $TAP_IFACE >/dev/null 2>&1; then
    sudo ip link delete $TAP_IFACE
    echo "   -> Interfaz $TAP_IFACE eliminada."
  fi

  echo "✅ Puente detenido."
}

# Lógica del comando
case "$1" in
start)
  start_bridge
  ;;
stop)
  stop_bridge
  ;;
restart)
  stop_bridge
  start_bridge
  ;;
*)
  echo "Uso: $0 {start|stop|restart}"
  exit 1
  ;;
esac
