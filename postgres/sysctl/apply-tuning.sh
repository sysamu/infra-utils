#!/usr/bin/env bash
# Genera y aplica /etc/sysctl.d/99-postgres-tuning.conf
# con valores calculados a partir del hardware del host.
#
# Uso:
#   bash apply-tuning.sh           # detecta hardware y aplica
#   bash apply-tuning.sh --dry-run # muestra el fichero generado sin aplicar
#   bash apply-tuning.sh --print   # igual que --dry-run

set -euo pipefail
source "$(dirname "$0")/../../common/lib/utils.sh"

DEST="/etc/sysctl.d/99-postgres-tuning.conf"
DRY_RUN="${DRY_RUN:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--print) DRY_RUN=true; shift ;;
        *) log_fatal "Argumento desconocido: $1" ;;
    esac
done

[[ "$DRY_RUN" == "true" ]] || require_root

# ---------------------------------------------------------------------------
# Detección de hardware
# ---------------------------------------------------------------------------
NCPUS=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))
RAM_GB=$(( RAM_MB / 1024 ))

log_info "Hardware detectado: ${NCPUS} CPUs | ${RAM_GB}GB RAM"

# ---------------------------------------------------------------------------
# Cálculos derivados
#
# Principios:
#   - tcp buffers: escalar con RAM hasta un techo razonable (128MB)
#   - rps_sock_flow_entries: potencia de 2 >= ncpus*1024, techo 1M
#   - somaxconn / backlog: escalar con CPUs
#   - dirty ratios: fijos para Postgres (escritura predecible)
# ---------------------------------------------------------------------------

# TCP buffer max: min(RAM/8, 128MB) en bytes
TCP_BUF_MAX=$(( RAM_MB * 1024 * 1024 / 8 ))
TCP_BUF_MAX_CAP=$(( 128 * 1024 * 1024 ))
[[ $TCP_BUF_MAX -gt $TCP_BUF_MAX_CAP ]] && TCP_BUF_MAX=$TCP_BUF_MAX_CAP

# TCP rmem/wmem: 4K mínimo, 87380 default, max calculado
TCP_RMEM="4096 87380 ${TCP_BUF_MAX}"
TCP_WMEM="4096 65536 ${TCP_BUF_MAX}"

# somaxconn y backlog: 1024 por cada 8 CPUs, mínimo 4096, techo 65535
SOMAXCONN=$(( NCPUS * 1024 / 8 ))
[[ $SOMAXCONN -lt 4096  ]] && SOMAXCONN=4096
[[ $SOMAXCONN -gt 65535 ]] && SOMAXCONN=65535

NETDEV_BACKLOG=$(( SOMAXCONN * 8 ))
[[ $NETDEV_BACKLOG -gt 500000 ]] && NETDEV_BACKLOG=500000

TCP_SYN_BACKLOG=$SOMAXCONN

# rps_sock_flow_entries: siguiente potencia de 2 >= ncpus*2048, techo 2^20
rps_target=$(( NCPUS * 2048 ))
rps=65536
while [[ $rps -lt $rps_target && $rps -lt 1048576 ]]; do
    rps=$(( rps * 2 ))
done
RPS_SOCK_FLOW_ENTRIES=$rps

# file-max: 1000 * ncpus, mínimo 1M
FILE_MAX=$(( NCPUS * 1000 ))
[[ $FILE_MAX -lt 1000000 ]] && FILE_MAX=1000000

log_info "Parámetros calculados:"
log_info "  TCP_BUF_MAX          = ${TCP_BUF_MAX} bytes ($(( TCP_BUF_MAX / 1024 / 1024 ))MB)"
log_info "  somaxconn            = ${SOMAXCONN}"
log_info "  netdev_max_backlog   = ${NETDEV_BACKLOG}"
log_info "  rps_sock_flow_entries= ${RPS_SOCK_FLOW_ENTRIES}"
log_info "  fs.file-max          = ${FILE_MAX}"
echo

# ---------------------------------------------------------------------------
# Generación del fichero
# ---------------------------------------------------------------------------
CONF=$(cat <<EOF
# /etc/sysctl.d/99-postgres-tuning.conf
# Generado por infra-utils/postgres/sysctl/apply-tuning.sh
# Host: $(hostname) | CPUs: ${NCPUS} | RAM: ${RAM_GB}GB | Fecha: $(date +%F)
# NO editar manualmente — regenerar con apply-tuning.sh

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
net.ipv4.tcp_rmem = ${TCP_RMEM}
net.ipv4.tcp_wmem = ${TCP_WMEM}

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
if [[ "$DRY_RUN" == "true" ]]; then
    echo
    log_warn "[DRY-RUN] Fichero que se escribiría en ${DEST}:"
    echo "---"
    echo "$CONF"
    echo "---"
    exit 0
fi

# Backup del fichero anterior si existe
if [[ -f "$DEST" ]]; then
    BACKUP="${DEST}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DEST" "$BACKUP"
    log_warn "Backup del fichero anterior: ${BACKUP}"
fi

echo "$CONF" > "$DEST"
log_ok "Escrito: ${DEST}"

log_info "Aplicando parámetros con sysctl..."
sysctl -p "$DEST"

log_ok "Tuning aplicado. Verifica con: sysctl -a | grep <param>"
