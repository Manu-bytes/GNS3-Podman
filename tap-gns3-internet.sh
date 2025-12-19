#!/bin/bash

set -e

# --- CONFIGURACIÓN ---
# Nombre de la interfaz virtual para GNS3
TAP_IFACE="tap-gns3-0"
# La IP que tendrá tu host en esa red (Gateway para Mikrotik)
GATEWAY_IP="172.16.8.1/24"
# ---------------------

# Detecta interfaces "salida a Internet" heurística:
# - interfaces UP y con ruta por defecto asociada
detect_wan_candidates() {
  candidates=()

  # Si hay una ruta por defecto, tomar la interfaz asociada
  default_if=$(ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
  if [ -n "$default_if" ]; then
    candidates+=("$default_if (ruta por defecto)")
  fi

  # Añadir interfaces UP y con dirección IPv4 (excluye loopback)
  while read -r ifname state; do
    [ "$ifname" = "lo" ] && continue
    # evitar duplicados si ya está en candidates
    if ! printf '%s\n' "${candidates[@]}" | grep -q "^$ifname"; then
      candidates+=("$ifname")
    fi
  done < <(ip -o link show up | awk -F': ' '{print $2, $3}')

  # Expandir a sólo nombres sin etiquetas si hay paréntesis
  # Devolver array
  echo "${candidates[@]}"
}

choose_wan_iface() {
  # Si WAN_IFACE está exportada en entorno o variable ya definida y existe, usarla
  if [ -n "$WAN_IFACE" ] && ip link show "$WAN_IFACE" >/dev/null 2>&1; then
    echo "$WAN_IFACE"
    return
  fi

  mapfile -t cand_arr < <(detect_wan_candidates)
  # eliminar elementos vacíos
  tmp=()
  for c in "${cand_arr[@]}"; do [ -n "$c" ] && tmp+=("$c"); done
  cand_arr=("${tmp[@]}")

  if [ ${#cand_arr[@]} -eq 0 ]; then
    echo "ERROR: No se detectaron interfaces candidatas. Define WAN_IFACE en el script." >&2
    exit 1
  elif [ ${#cand_arr[@]} -eq 1 ]; then
    # extraer nombre antes de espacios/parentesis
    echo "${cand_arr[0]%% *}"
    return
  fi

  echo "Se detectaron las siguientes interfaces candidatas para salir a Internet:"
  for i in "${!cand_arr[@]}"; do
    idx=$((i+1))
    name="${cand_arr[i]}"
    echo "  $idx) $name"
  done

  while true; do
    read -rp "Selecciona el número de la interfaz a usar como WAN (o escribe el nombre): " sel
    # si es número válido
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#cand_arr[@]} ]; then
      chosen="${cand_arr[$((sel-1))]}"
      echo "${chosen%% *}"
      return
    fi
    # si corresponde a un nombre
    if ip link show "$sel" >/dev/null 2>&1; then
      echo "$sel"
      return
    fi
    echo "Selección inválida. Intenta de nuevo."
  done
}

function start_bridge() {
  echo "🔵 Iniciando Puente GNS3 Internet..."

  WAN_IFACE=$(choose_wan_iface)
  echo "   -> Usando interfaz WAN: $WAN_IFACE"

  # 1. Crear la interfaz TAP si no existe
  if ! ip link show "$TAP_IFACE" >/dev/null 2>&1; then
    sudo ip tuntap add dev "$TAP_IFACE" mode tap user "$(whoami)"
    echo "   -> Interfaz $TAP_IFACE creada."
  fi

  # 2. Asignar IP y levantar
  sudo ip addr flush dev "$TAP_IFACE"
  sudo ip addr add "$GATEWAY_IP" dev "$TAP_IFACE"
  sudo ip link set "$TAP_IFACE" up
  echo "   -> IP $GATEWAY_IP asignada."

  # 3. Reglas de IPTables (NAT)
  # Limpiamos reglas previas para evitar duplicados (ignorar errores)
  sudo iptables -t nat -D POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || true
  sudo iptables -D FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || true
  sudo iptables -D FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

  # Agregamos las reglas (evitar duplicados comprobando antes)
  if ! sudo iptables -t nat -C POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
  fi
  if ! sudo iptables -C FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null; then
    sudo iptables -A FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT
  fi
  if ! sudo iptables -C FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    sudo iptables -A FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi

  # Habilitar forwarding en runtime si no está
  if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]; then
    echo "   -> Habilitando ip_forward temporalmente"
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
  fi

  echo "✅ Conexión establecida. Configura tu Mikrotik con Gateway: ${GATEWAY_IP%/*}"
}

function stop_bridge() {
  echo "🔴 Deteniendo Puente GNS3..."

  # Detectar WAN interface de las reglas (intentar usar variable WAN_IFACE si existe)
  if [ -z "$WAN_IFACE" ]; then
    # buscar reglas que mencionen tap iface para inferir WAN
    inferred=$(sudo iptables -t nat -S | grep -m1 "$TAP_IFACE" -B1 | awk '/-o/ {for(i=1;i<=NF;i++) if($i=="-o") print $(i+1)}' | head -n1)
    [ -n "$inferred" ] && WAN_IFACE="$inferred"
  fi

  # 1. Borrar reglas de IPTables (ignorar errores)
  if [ -n "$WAN_IFACE" ]; then
    sudo iptables -t nat -D POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i "$TAP_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$WAN_IFACE" -o "$TAP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    echo "   -> Reglas NAT eliminadas para $WAN_IFACE."
  else
    echo "   -> No se pudo inferir WAN_IFACE; se intentarán borrados globales."
    sudo iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true
  fi

  # 2. Destruir interfaz TAP
  if ip link show "$TAP_IFACE" >/dev/null 2>&1; then
    sudo ip link delete "$TAP_IFACE"
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
