#!/usr/bin/env bash
# ==============================================================================
# Proxmox VE Helper-Script: AceStream Scraper + Acexy + Cloudflare WARP (LXC)
# Basado en el estilo de community-scripts/ProxmoxVE
# Uso en el nodo Proxmox:
#   bash install-acestream-lxc.sh
# ==============================================================================

set -uo pipefail

# Asegurar variable TERM para whiptail/clear
export TERM="${TERM:-xterm}"

# --- Colores y formato ---
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"

header_info() {
  clear 2>/dev/null || true
  cat <<"EOF"
    ___            _____ __                            _____                                 
   /   | _________ / ___// /_________  ____ _____ ___  / ___/______________ _____  ___  _____
  / /| |/ ___/ _ \\__ \/ __/ ___/ _ \/ __ `/ __ `__ \ \__ \/ ___/ ___/ __ `/ __ \/ _ \/ ___/
 / ___ / /__/  __/__/ / /_/ /  /  __/ /_/ / / / / / /___/ / /__/ /  / /_/ / /_/ /  __/ /    
/_/  |_\___/\___/____/\__/_/   \___/\__,_/_/ /_/ /_//____/\___/_/   \__,_/ .___/\___/_/     
                                                                        /_/                  
EOF
  echo -e "${BL}==============================================================================${CL}"
  echo -e "          ${GN}Instalador LXC para Proxmox VE (AceStream Scraper + WARP)${CL}"
  echo -e "${BL}==============================================================================${CL}\n"
}

msg_info() {
  echo -ne " ${INFO} ${YW}$1...${CL}"
}

msg_ok() {
  echo -e "${BFR} ${CM} ${GN}$1${CL}"
}

msg_error() {
  echo -e "${BFR} ${CROSS} ${RD}$1${CL}"
}

# --- Comprobaciones previas ---
check_proxmox() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Este script debe ejecutarse como root en el host Proxmox VE."
    exit 1
  fi
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "No se ha detectado Proxmox VE en este sistema."
    exit 1
  fi
}

# --- Obtener valores por defecto del host Proxmox ---
NEXTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "111")
HOST_IP=$(hostname -I | awk '{print $1}')
DEFAULT_SUBNET=$(echo "$HOST_IP" | awk -F. '{print $1"."$2"."$3}')
DEFAULT_GW=$(ip route | awk '/default/ {print $3; exit}')
if [[ -z "$DEFAULT_GW" ]]; then
  DEFAULT_GW="${DEFAULT_SUBNET}.1"
fi

# Valores por defecto del contenedor
CTID="$NEXTID"
HN="acestream"
DISK_SIZE="40"
CORE_COUNT="2"
RAM_SIZE="2048"
SWAP_SIZE="512"
BRG="vmbr0"
NET="dhcp"
GATE=""
APT_DNS="85.208.114.52"
ENABLE_WARP="true"
APPLY_PATCH="true"
TZ_VAL=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo "Europe/Madrid")
if [[ -z "$TZ_VAL" ]]; then
  TZ_VAL="Europe/Madrid"
fi

# Seleccionar storage para rootfs y plantillas
select_storage() {
  local storages
  storages=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  if [[ -z "$storages" ]]; then
    msg_error "No se encontró ningún almacenamiento activo compatible con contenedores (rootdir)."
    exit 1
  fi
  local count
  count=$(echo "$storages" | wc -l | tr -d ' ')
  if [[ "$count" -eq 1 ]]; then
    CONTAINER_STORAGE="$storages"
  else
    local menu_items=()
    while read -r st; do
      [[ -z "$st" ]] && continue
      local avail
      avail=$(pvesm status -storage "$st" 2>/dev/null | awk 'NR>1 {printf "%.1fGB libres", $6/1024/1024}')
      menu_items+=("$st" "$avail")
    done <<<"$storages"
    CONTAINER_STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Almacenamiento del Contenedor" \
      --menu "Selecciona el almacenamiento donde se creará el disco del LXC:" 15 65 5 \
      "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1
  fi

  # Almacenamiento para plantillas (vztmpl)
  TEMPLATE_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' | head -n 1)
  if [[ -z "$TEMPLATE_STORAGE" ]]; then
    TEMPLATE_STORAGE="local"
  fi
}

# Preguntar configuración de red (IP Fija vs DHCP)
ask_network() {
  local net_mode
  net_mode=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Configuración de Red" \
    --menu "¿Cómo quieres configurar la IP del contenedor?" 12 65 2 \
    "static" "IP Fija (Estática) - Recomendado para servidores" \
    "dhcp" "Automática por DHCP" 3>&1 1>&2 2>&3) || exit 1

  if [[ "$net_mode" == "static" ]]; then
    while true; do
      local input_ip
      input_ip=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Dirección IP Fija" \
        --inputbox "Introduce la IP fija para el contenedor (ej. ${DEFAULT_SUBNET}.75/24):" 10 65 "${DEFAULT_SUBNET}.75/24" 3>&1 1>&2 2>&3) || exit 1
      if [[ -n "$input_ip" ]]; then
        # Si el usuario no puso máscara CIDR, añadir /24 automáticamente
        if [[ "$input_ip" != */* ]]; then
          input_ip="${input_ip}/24"
        fi
        NET="$input_ip"
        break
      fi
    done

    local input_gw
    input_gw=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Puerta de Enlace (Gateway)" \
      --inputbox "Introduce la puerta de enlace (Gateway) de tu red:" 10 65 "$DEFAULT_GW" 3>&1 1>&2 2>&3) || exit 1
    GATE="$input_gw"
  else
    NET="dhcp"
    GATE=""
  fi
}

# --- Asistente de Configuración ---
start_wizard() {
  header_info
  select_storage

  local mode
  mode=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Modo de Instalación" \
    --menu "Selecciona el modo de configuración para AceStream Scraper:" 13 75 2 \
    "default" "Valores recomendados (2 CPU, 2GB RAM, ${DISK_SIZE}GB Disco + Red)" \
    "advanced" "Personalizar todos los parámetros (ID, CPU, RAM, Disco, Red, WARP)" \
    3>&1 1>&2 2>&3) || exit 1

  if [[ "$mode" == "default" ]]; then
    ask_network
  else
    CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "ID del Contenedor (VMID)" \
      --inputbox "Introduce el ID para el nuevo contenedor LXC:" 10 60 "$NEXTID" 3>&1 1>&2 2>&3) || exit 1

    HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Nombre de Host (Hostname)" \
      --inputbox "Introduce el hostname del contenedor:" 10 60 "$HN" 3>&1 1>&2 2>&3) || exit 1

    DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Tamaño de Disco" \
      --inputbox "Introduce el tamaño del disco en GB:" 10 60 "$DISK_SIZE" 3>&1 1>&2 2>&3) || exit 1

    CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Núcleos de CPU" \
      --inputbox "Introduce el número de núcleos (vCPU):" 10 60 "$CORE_COUNT" 3>&1 1>&2 2>&3) || exit 1

    RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Memoria RAM" \
      --inputbox "Introduce la memoria RAM en MiB:" 10 60 "$RAM_SIZE" 3>&1 1>&2 2>&3) || exit 1

    SWAP_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Memoria Swap" \
      --inputbox "Introduce la memoria Swap en MiB:" 10 60 "$SWAP_SIZE" 3>&1 1>&2 2>&3) || exit 1

    BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Puente de Red (Bridge)" \
      --inputbox "Introduce el bridge de red de Proxmox:" 10 60 "$BRG" 3>&1 1>&2 2>&3) || exit 1

    ask_network

    APT_DNS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DNS del Contenedor Docker" \
      --inputbox "Introduce el servidor DNS para el contenedor Docker:" 10 60 "$APT_DNS" 3>&1 1>&2 2>&3) || exit 1

    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Cloudflare WARP" \
      --yesno "¿Deseas activar Cloudflare WARP integrado (oculta el tráfico P2P y evita bloqueos de operadoras)?" 10 65; then
      ENABLE_WARP="true"
    else
      ENABLE_WARP="false"
    fi

    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Parche de Reproducción desde Buscador" \
      --yesno "¿Deseas aplicar el parche automático para que los canales del buscador (infohash) reproduzcan sin dar 'failed to load content'?" 10 65; then
      APPLY_PATCH="true"
    else
      APPLY_PATCH="false"
    fi
  fi

  # Confirmación final
  local summary="Se creará el contenedor con la siguiente configuración:\n\n"
  summary+="  • VMID:            ${CTID}\n"
  summary+="  • Hostname:        ${HN}\n"
  summary+="  • Almacenamiento:  ${CONTAINER_STORAGE} (${DISK_SIZE} GB)\n"
  summary+="  • CPU / RAM:       ${CORE_COUNT} vCPU / ${RAM_SIZE} MB RAM\n"
  summary+="  • Red (${BRG}):     ${NET}${GATE:+ (GW: $GATE)}\n"
  summary+="  • Cloudflare WARP: ${ENABLE_WARP}\n"
  summary+="  • Parche Buscador: ${APPLY_PATCH}\n\n"
  summary+="¿Deseas iniciar la instalación ahora?"

  if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "Confirmar Instalación" --yesno "$summary" 18 70; then
    echo -e "${RD}Instalación cancelada por el usuario.${CL}"
    exit 0
  fi
}

# --- Descarga / selección de plantilla Debian 12 ---
prepare_template() {
  msg_info "Comprobando plantilla LXC Debian 12"
  local tmpl
  tmpl=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-12-standard/ {print $1}' | head -n 1)
  if [[ -z "$tmpl" ]]; then
    pveam update >/dev/null 2>&1 || true
    local avail_tmpl
    avail_tmpl=$(pveam available -section system 2>/dev/null | awk '/debian-12-standard/ {print $2}' | head -n 1)
    if [[ -z "$avail_tmpl" ]]; then
      msg_error "No se pudo encontrar la plantilla debian-12-standard en los repositorios."
      exit 1
    fi
    msg_info "Descargando plantilla ${avail_tmpl} en ${TEMPLATE_STORAGE}"
    if ! pveam download "$TEMPLATE_STORAGE" "$avail_tmpl" >/dev/null; then
      msg_error "Error al descargar la plantilla ${avail_tmpl}."
      exit 1
    fi
    tmpl="${TEMPLATE_STORAGE}:vztmpl/${avail_tmpl}"
  fi
  TEMPLATE_PATH="$tmpl"
  msg_ok "Plantilla lista: ${TEMPLATE_PATH}"
}

# --- Creación del contenedor LXC ---
create_lxc() {
  if pct status "$CTID" >/dev/null 2>&1; then
    msg_error "Ya existe un contenedor con el ID ${CTID}."
    exit 1
  fi

  local net_string="name=eth0,bridge=${BRG},ip=${NET},type=veth"
  local ns_args=()
  if [[ -n "$GATE" ]]; then
    net_string="name=eth0,bridge=${BRG},ip=${NET},gw=${GATE},type=veth"
    ns_args=(--nameserver "${GATE} 1.1.1.1")
  fi

  msg_info "Creando contenedor LXC ${CTID} (${HN}) en ${CONTAINER_STORAGE}"
  if ! pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$HN" \
    --cores "$CORE_COUNT" \
    --memory "$RAM_SIZE" \
    --swap "$SWAP_SIZE" \
    --storage "$CONTAINER_STORAGE" \
    --rootfs "${CONTAINER_STORAGE}:${DISK_SIZE}" \
    --net0 "$net_string" \
    "${ns_args[@]}" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1 \
    --timezone "$TZ_VAL" \
    --tags "acestream;iptv;media" >/dev/null; then
    msg_error "Fallo al crear el contenedor LXC ${CTID}."
    exit 1
  fi
  msg_ok "Contenedor LXC ${CTID} creado"

  msg_info "Habilitando passthrough de /dev/net/tun para Cloudflare WARP"
  cat <<'EOF' >> "/etc/pve/lxc/${CTID}.conf"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  msg_ok "Dispositivo /dev/net/tun configurado en /etc/pve/lxc/${CTID}.conf"

  msg_info "Arrancando contenedor LXC ${CTID}"
  if ! pct start "$CTID"; then
    msg_error "No se pudo arrancar el contenedor LXC ${CTID}."
    exit 1
  fi
  sleep 4

  # Esperar a que tenga IP y conectividad
  local retries=15
  while [[ $retries -gt 0 ]]; do
    CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "${CT_IP:-}" ]]; then
      break
    fi
    sleep 2
    retries=$((retries - 1))
  done

  if [[ -z "${CT_IP:-}" ]]; then
    msg_error "El contenedor no obtuvo dirección IP. Revisa la configuración de red."
    exit 1
  fi
  msg_ok "Contenedor arrancado con IP: ${CT_IP}"
}

# --- Instalación de Docker y despliegue de AceStream Scraper ---
deploy_stack() {
  msg_info "Instalando Docker y Docker Compose dentro del LXC ${CTID}"
  if ! pct exec "$CTID" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    APT_OPTS="-o DPkg::Lock::Timeout=180 -o Acquire::Retries=3"

    # Esperar a que terminen los apt/dpkg del primer arranque y a tener DNS/Internet
    for i in $(seq 1 60); do
      if ! fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
         && getent hosts deb.debian.org >/dev/null 2>&1; then
        break
      fi
      sleep 3
    done

    # Índices frescos (con reintentos): evita 404 por una lista de paquetes obsoleta
    ok=0
    for i in 1 2 3; do
      if apt-get $APT_OPTS update; then ok=1; break; fi
      sleep 5
    done
    [ "$ok" = 1 ] || exit 1

    ok=0
    for i in 1 2 3; do
      if apt-get $APT_OPTS install -y -qq --no-install-recommends --fix-missing ca-certificates curl docker.io docker-compose fuse-overlayfs python3 >/dev/null; then
        ok=1; break
      fi
      apt-get $APT_OPTS update >/dev/null 2>&1 || true
      sleep 5
    done
    [ "$ok" = 1 ] || exit 1
  '; then
    msg_error "Error instalando Docker dentro del contenedor (verifica que la IP tenga salida a Internet/DNS)."
    exit 1
  fi
  msg_ok "Docker y dependencias instalados"

  msg_info "Descargando y levantando pipepito/acestream-scraper:latest (puede tardar 1-2 min)"
  if ! pct exec "$CTID" -- bash -c "
    mkdir -p /opt/acestream-scraper
    cat <<'EOF' > /opt/acestream-scraper/docker-compose.yml
version: \"3.8\"
services:
  acestream-scraper:
    image: pipepito/acestream-scraper:latest
    container_name: acestream-scraper
    restart: unless-stopped
    dns:
      - \"${APT_DNS}\"
    ports:
      - \"0.0.0.0:8000:8000\"  # Web interface
      - \"8080:8080\"          # Acexy proxy
      - \"8621:8621\"          # P2P port
      - \"8621:8621/udp\"      # P2P port (UDP)
    environment:
      - \"ENABLE_ACESTREAM_ENGINE=true\"
      - \"ENABLE_ACEXY=true\"
      - \"ENABLE_WARP=${ENABLE_WARP}\"
      - \"ENABLE_ZERONET=false\"
      - \"ENABLE_IPFS=false\"
      - \"WARP_ENABLE_NAT=${ENABLE_WARP}\"
    volumes:
      - ./config:/app/config
      - ./acestream_cache:/root/.ACEStream/.acestream_cache
      - ./player_data:/tmp/acestream-player
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
EOF
    cd /opt/acestream-scraper
    docker-compose up -d >/dev/null 2>&1
  "; then
    msg_error "Error al descargar o iniciar la imagen pipepito/acestream-scraper:latest."
    exit 1
  fi
  msg_ok "Contenedor acestream-scraper descargado e iniciado"

  if [[ "$APPLY_PATCH" == "true" ]]; then
    msg_info "Aplicando parche de soporte infohash para el buscador de canales"
    pct exec "$CTID" -- bash -c '
      set -euo pipefail
      mkdir -p /opt/acestream-scraper/patches
      docker cp acestream-scraper:/app/app/services/engine_client.py /opt/acestream-scraper/patches/engine_client.py
      docker cp acestream-scraper:/app/app/services/channel_status_service.py /opt/acestream-scraper/patches/channel_status_service.py

      python3 - << "PYEOF"
from pathlib import Path

p_engine = Path("/opt/acestream-scraper/patches/engine_client.py")
code = p_engine.read_text()
old_block = """    def _start_direct(self, content_id: str, pid: str, lease: PlaybackLease) -> EngineSession:
        body = self._get_json(
            f"{self.engine_url}/ace/getstream",
            params={"id": content_id, "pid": pid, "format": "json"},
        )"""
new_block = """    def _start_direct(self, content_id: str, pid: str, lease: PlaybackLease) -> EngineSession:
        try:
            body = self._get_json(
                f"{self.engine_url}/ace/getstream",
                params={"id": content_id, "pid": pid, "format": "json"},
            )
        except EngineRefusedError:
            body = self._get_json(
                f"{self.engine_url}/ace/getstream",
                params={"infohash": content_id, "pid": pid, "format": "json"},
            )"""
if old_block in code:
    p_engine.write_text(code.replace(old_block, new_block, 1))

p_status = Path("/opt/acestream-scraper/patches/channel_status_service.py")
scode = p_status.read_text()
old_status = """            if isinstance(data, dict):
                error_text = str(data.get(\x27error\x27) or \x27\x27).strip().lower()"""
new_status = """            if isinstance(data, dict) and data.get(\x27error\x27):
                alt_identifier = \x27infohash\x27 if identifier == \x27id\x27 else \x27id\x27
                alt_params = {alt_identifier: channel.id, \x27format\x27: \x27json\x27, \x27pid\x27: uuid4().hex}
                try:
                    alt_http, alt_data, alt_err = await self._fetch_engine_response(status_url, alt_params, timeout)
                    if isinstance(alt_data, dict) and not alt_data.get(\x27error\x27):
                        http_status, data, parse_error = alt_http, alt_data, alt_err
                except Exception:
                    pass
            if isinstance(data, dict):
                error_text = str(data.get(\x27error\x27) or \x27\x27).strip().lower()"""
if old_status in scode:
    p_status.write_text(scode.replace(old_status, new_status, 1))
PYEOF
    '

    pct exec "$CTID" -- bash -c "
      cat <<'EOF' > /opt/acestream-scraper/docker-compose.yml
version: \"3.8\"
services:
  acestream-scraper:
    image: pipepito/acestream-scraper:latest
    container_name: acestream-scraper
    restart: unless-stopped
    dns:
      - \"${APT_DNS}\"
    ports:
      - \"0.0.0.0:8000:8000\"  # Web interface
      - \"8080:8080\"          # Acexy proxy
      - \"8621:8621\"          # P2P port
      - \"8621:8621/udp\"      # P2P port (UDP)
    environment:
      - \"ENABLE_ACESTREAM_ENGINE=true\"
      - \"ENABLE_ACEXY=true\"
      - \"ENABLE_WARP=${ENABLE_WARP}\"
      - \"ENABLE_ZERONET=false\"
      - \"ENABLE_IPFS=false\"
      - \"WARP_ENABLE_NAT=${ENABLE_WARP}\"
    volumes:
      - ./config:/app/config
      - ./acestream_cache:/root/.ACEStream/.acestream_cache
      - ./player_data:/tmp/acestream-player
      - ./patches/engine_client.py:/app/app/services/engine_client.py:ro
      - ./patches/channel_status_service.py:/app/app/services/channel_status_service.py:ro
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
EOF
      cd /opt/acestream-scraper
      docker-compose up -d --force-recreate >/dev/null 2>&1
    "
    msg_ok "Parche aplicado y contenedor reiniciado"
  fi

  # Añadir descripción estilo Helper-Scripts en las notas de Proxmox
  pct set "$CTID" -description "<div align='center'>
  <h2 style='font-size: 24px; margin: 20px 0;'>AceStream Scraper + WARP LXC</h2>
  <p><b>Interfaz Web:</b> <a href='http://${CT_IP}:8000' target='_blank'>http://${CT_IP}:8000</a></p>
  <p><b>Proxy Acexy:</b> <code>http://${CT_IP}:8080/ace/getstream?id=...</code></p>
</div>" >/dev/null 2>&1 || true
}

# --- Ejecución principal ---
check_proxmox
start_wizard
header_info
prepare_template
create_lxc
deploy_stack

echo -e "\n${BL}==============================================================================${CL}"
echo -e " ${CM} ${GN}¡Instalación completada con éxito!${CL}"
echo -e "${BL}==============================================================================${CL}"
echo -e "  • ${YW}Contenedor LXC:${CL}  ${GN}${CTID} (${HN})${CL}"
echo -e "  • ${YW}Dirección IP:${CL}    ${GN}${CT_IP}${CL}"
echo -e "  • ${YW}Interfaz Web:${CL}    ${BL}http://${CT_IP}:8000${CL}"
echo -e "  • ${YW}Proxy Acexy:${CL}     ${BL}http://${CT_IP}:8080/ace/getstream?id=<ID>${CL}"
echo -e "  • ${YW}Ruta Compose:${CL}    ${GN}/opt/acestream-scraper/docker-compose.yml${CL}"
echo -e "${BL}==============================================================================${CL}\n"
