#!/usr/bin/env bash
# Genera y aplica /etc/sysctl.d/99-postgres-tuning.conf
# con valores calculados a partir del hardware del host.
#
# Uso directo:
#   curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash -s -- --dry-run

set -euo pipefail

# ---------------------------------------------------------------------------
# Colores y logging
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal() { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run|--print) DRY_RUN=true ;;
        --help|-h)
            echo "Uso: bash apply-tuning.sh [--dry-run]"
            echo "  --dry-run  Muestra el fichero generado sin aplicar nada"
            exit 0 ;;
    esac
done

$DRY_RUN || [[ $EUID -eq 0 ]] || fatal "Ejecuta como root."

DEST="/etc/sysctl.d/99-postgres-tuning.conf"

# ---------------------------------------------------------------------------
# Detección de hardware
# ---------------------------------------------------------------------------
NCPUS=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))
RAM_GB=$(( RAM_MB / 1024 ))

header "=== PostgreSQL sysctl tuning ==="
info "Hardware detectado: ${NCPUS} CPUs | ${RAM_GB}GB RAM"

# ---------------------------------------------------------------------------
# Cálculos
# ---------------------------------------------------------------------------

# TCP buffer max: min(RAM/8, 128MB) en bytes
TCP_BUF_MAX=$(( RAM_MB * 1024 * 1024 / 8 ))
TCP_BUF_MAX_CAP=$(( 128 * 1024 * 1024 ))
[[ $TCP_BUF_MAX -gt $TCP_BUF_MAX_CAP ]] && TCP_BUF_MAX=$TCP_BUF_MAX_CAP

# somaxconn: CPUs×128, clamp [4096, 65535]
SOMAXCONN=$(( NCPUS * 128 ))
[[ $SOMAXCONN -lt 4096  ]] && SOMAXCONN=4096
[[ $SOMAXCONN -gt 65535 ]] && SOMAXCONN=65535

NETDEV_BACKLOG=$(( SOMAXCONN * 8 ))
[[ $NETDEV_BACKLOG -gt 500000 ]] && NETDEV_BACKLOG=500000

TCP_SYN_BACKLOG=$SOMAXCONN

# rps_sock_flow_entries: siguiente potencia de 2 >= CPUs×2048, techo 2^20
rps_target=$(( NCPUS * 2048 ))
rps=65536
while [[ $rps -lt $rps_target && $rps -lt 1048576 ]]; do
    rps=$(( rps * 2 ))
done
RPS_SOCK_FLOW_ENTRIES=$rps

# file-max: max(CPUs×1000, 1000000)
FILE_MAX=$(( NCPUS * 1000 ))
[[ $FILE_MAX -lt 1000000 ]] && FILE_MAX=1000000

info "Parámetros calculados:"
info "  TCP buffer max          = $(( TCP_BUF_MAX / 1024 / 1024 ))MB"
info "  somaxconn               = ${SOMAXCONN}"
info "  netdev_max_backlog      = ${NETDEV_BACKLOG}"
info "  rps_sock_flow_entries   = ${RPS_SOCK_FLOW_ENTRIES}"
info "  fs.file-max             = ${FILE_MAX}"

# ---------------------------------------------------------------------------
# Generación del fichero
# ---------------------------------------------------------------------------
CONF=$(cat <<EOF
# /etc/sysctl.d/99-postgres-tuning.conf
# Generado por infra-utils/postgres/sysctl/apply-tuning.sh
# Host: $(hostname) | CPUs: ${NCPUS} | RAM: ${RAM_GB}GB | Fecha: $(date +%F)
# Regenerar con: curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash

# -------------------------
# MEMORY / POSTGRES
# -------------------------
vm.swappiness = 5
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 100

vm.overcommit_memory = 1
vm.overcommit_ratio = 95
vm.page-cluster = 0

vm.max_map_count = 1048576
vm.vfs_cache_pressure = 50
vm.zone_reclaim_mode = 0

# -------------------------
# FILESYSTEM / LIMITS
# -------------------------
fs.file-max = ${FILE_MAX}

# -------------------------
# NETWORK CORE
# -------------------------
net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}

net.ipv4.tcp_max_syn_backlog = ${TCP_SYN_BACKLOG}
net.ipv4.ip_local_port_range = 10240 65535

# -------------------------
# TCP PERFORMANCE
# -------------------------
net.ipv4.tcp_rmem = 4096 87380 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_BUF_MAX}

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

# -------------------------
# CPU DISTRIBUTION (${NCPUS} cores)
# -------------------------
net.core.rps_sock_flow_entries = ${RPS_SOCK_FLOW_ENTRIES}

# -------------------------
# ROUTING STABILITY
# -------------------------
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
)

# ---------------------------------------------------------------------------
# Aplicar o mostrar
# ---------------------------------------------------------------------------
if $DRY_RUN; then
    header "Fichero que se escribiría en ${DEST}:"
    echo "---"
    echo "$CONF"
    echo "---"
    exit 0
fi

if [[ -f "$DEST" ]]; then
    BACKUP="${DEST}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DEST" "$BACKUP"
    warn "Backup del fichero anterior: ${BACKUP}"
fi

echo "$CONF" > "$DEST"
ok "Escrito: ${DEST}"

info "Aplicando con sysctl..."
sysctl -p "$DEST"

ok "Tuning aplicado."
