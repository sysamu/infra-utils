#!/usr/bin/env bash
# Genera y aplica /etc/sysctl.d/99-postgres-tuning.conf,
# instala irqbalance y despliega el servicio de tuning en tiempo real del MD.
#
# Uso directo:
#   curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash -s -- --first-init
#   curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash -s -- --prod-ready
#   curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash -s -- --prod-ready --dry-run

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
RAID_MODE=""   # first-init | prod-ready

for arg in "$@"; do
    case "$arg" in
        --dry-run|--print) DRY_RUN=true ;;
        --first-init)      RAID_MODE="first-init" ;;
        --prod-ready)      RAID_MODE="prod-ready" ;;
        --help|-h)
            echo "Uso: bash apply-tuning.sh [--first-init|--prod-ready] [--dry-run]"
            echo "  --first-init  RAID resync a tope — para el resync inicial tras crear el array"
            echo "  --prod-ready  RAID resync limitado — para no impactar I/O de Postgres en prod"
            echo "  --dry-run     Muestra lo que haría sin aplicar nada"
            exit 0 ;;
    esac
done

[[ -n "$RAID_MODE" ]] || fatal "Especifica el modo: --first-init o --prod-ready"
$DRY_RUN || [[ $EUID -eq 0 ]] || fatal "Ejecuta como root."

DEST="/etc/sysctl.d/99-postgres-tuning.conf"
MD_TUNING_SCRIPT="/usr/local/sbin/md-postgres-tuning.sh"
MD_TUNING_SERVICE="/etc/systemd/system/md-postgres-tuning.service"

# ---------------------------------------------------------------------------
# RAID resync speed según modo
# ---------------------------------------------------------------------------
case "$RAID_MODE" in
    first-init)
        RAID_SPEED_MIN=4000000
        RAID_SPEED_MAX=6000000
        ;;
    prod-ready)
        RAID_SPEED_MIN=1000000
        RAID_SPEED_MAX=3000000
        ;;
esac

# ---------------------------------------------------------------------------
# Detección de hardware
# ---------------------------------------------------------------------------
NCPUS=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))
RAM_GB=$(( RAM_MB / 1024 ))

header "=== PostgreSQL sysctl tuning ==="
info "Hardware detectado: ${NCPUS} CPUs | ${RAM_GB}GB RAM"
info "Modo RAID resync:   ${RAID_MODE} (min=${RAID_SPEED_MIN} max=${RAID_SPEED_MAX})"

# ---------------------------------------------------------------------------
# Detección del MD de PostgreSQL
# Busca el MD que tiene /var/lib/postgresql montado,
# o en su defecto el primer MD activo que no sea del OS.
# ---------------------------------------------------------------------------
detect_postgres_md() {
    # Primero: MD montado en /var/lib/postgresql
    local md
    md=$(findmnt -n -o SOURCE /var/lib/postgresql 2>/dev/null || true)
    if [[ -n "$md" ]]; then
        basename "$md"
        return
    fi

    # Segundo: cualquier MD activo que no esté montado en / /boot /efi
    while IFS= read -r name; do
        local mount
        mount=$(findmnt -n -o TARGET "/dev/${name}" 2>/dev/null || true)
        if [[ -z "$mount" || ! "$mount" =~ ^(/|/boot|/efi) ]]; then
            echo "$name"
            return
        fi
    done < <(lsblk -lno NAME,TYPE | awk '$2=="raid"{print $1}')

    echo ""
}

POSTGRES_MD=$(detect_postgres_md)

if [[ -n "$POSTGRES_MD" ]]; then
    info "MD detectado:       /dev/${POSTGRES_MD}"
else
    warn "No se detectó ningún MD de PostgreSQL. El servicio de tuning se instalará pero no podrá aplicar hasta que exista el array."
    POSTGRES_MD="md0"   # placeholder que el script de tuning re-detectará en runtime
fi

# ---------------------------------------------------------------------------
# Cálculos de parámetros
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

# ---------------------------------------------------------------------------
# Parámetros del MD tuning script
#
# group_thread_cnt: hilos de I/O del MD. CPUs/4, clamp [4, 32].
#   Más hilos = más paralelismo en rebuild y escrituras concurrentes,
#   pero demasiados compiten con Postgres. 16 es el sweet spot para 80 cores.
#
# nr_requests: profundidad de cola del bloque. Para NVMe con alta concurrencia
#   el valor por defecto (256) se queda corto. 16384 permite saturar el
#   hardware sin bloquear la cola.
# ---------------------------------------------------------------------------
GROUP_THREAD_CNT=$(( NCPUS / 4 ))
[[ $GROUP_THREAD_CNT -lt 4  ]] && GROUP_THREAD_CNT=4
[[ $GROUP_THREAD_CNT -gt 32 ]] && GROUP_THREAD_CNT=32

NR_REQUESTS=16384   # fijo — óptimo para NVMe con colas profundas
SETRA=65536         # 32MB read-ahead (512B sectores): óptimo para rebuild + sequential

info "Parámetros calculados:"
info "  TCP buffer max          = $(( TCP_BUF_MAX / 1024 / 1024 ))MB"
info "  somaxconn               = ${SOMAXCONN}"
info "  netdev_max_backlog      = ${NETDEV_BACKLOG}"
info "  rps_sock_flow_entries   = ${RPS_SOCK_FLOW_ENTRIES}"
info "  fs.file-max             = ${FILE_MAX}"
info "  md group_thread_cnt     = ${GROUP_THREAD_CNT}  (CPUs/4, clamp 4-32)"
info "  md nr_requests          = ${NR_REQUESTS}"
info "  md read-ahead           = $(( SETRA / 2 ))MB"

# ---------------------------------------------------------------------------
# Contenido del sysctl
# ---------------------------------------------------------------------------
CONF=$(cat <<EOF
# /etc/sysctl.d/99-postgres-tuning.conf
# Generado por infra-utils/postgres/sysctl/apply-tuning.sh
# Host: $(hostname) | CPUs: ${NCPUS} | RAM: ${RAM_GB}GB | Fecha: $(date +%F)
# Regenerar: curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash -s -- --${RAID_MODE}

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

# -------------------------
# MDADM RAID RESYNC (${RAID_MODE})
# -------------------------
dev.raid.speed_limit_min = ${RAID_SPEED_MIN}
dev.raid.speed_limit_max = ${RAID_SPEED_MAX}
EOF
)

# ---------------------------------------------------------------------------
# Contenido del script de tuning en runtime del MD
# Re-detecta el MD en cada arranque para no depender de un nombre hardcodeado.
# ---------------------------------------------------------------------------
MD_SCRIPT=$(cat <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Detectar el MD montado en /var/lib/postgresql
MD=$(findmnt -n -o SOURCE /var/lib/postgresql 2>/dev/null | xargs -r basename || true)

if [[ -z "$MD" ]]; then
    echo "md-postgres-tuning: no MD found at /var/lib/postgresql, skipping." >&2
    exit 0
fi

echo "Applying MD runtime tuning to /dev/${MD}"

NCPUS=$(nproc)
GROUP_THREAD_CNT=$(( NCPUS / 4 ))
[[ $GROUP_THREAD_CNT -lt 4  ]] && GROUP_THREAD_CNT=4
[[ $GROUP_THREAD_CNT -gt 32 ]] && GROUP_THREAD_CNT=32

echo ${GROUP_THREAD_CNT} > /sys/block/${MD}/md/group_thread_cnt 2>/dev/null || true
echo 16384               > /sys/block/${MD}/queue/nr_requests    2>/dev/null || true
blockdev --setra 65536     /dev/${MD}

echo "Done: group_thread_cnt=${GROUP_THREAD_CNT} nr_requests=16384 read-ahead=32MB"
SCRIPT
)

# ---------------------------------------------------------------------------
# Contenido del unit de systemd
# ---------------------------------------------------------------------------
MD_UNIT=$(cat <<EOF
[Unit]
Description=PostgreSQL MD runtime tuning
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${MD_TUNING_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
)

# ---------------------------------------------------------------------------
# Dry-run: mostrar todo y salir
# ---------------------------------------------------------------------------
if $DRY_RUN; then
    header "sysctl → ${DEST}"
    echo "---"; echo "$CONF"; echo "---"

    header "MD tuning script → ${MD_TUNING_SCRIPT}"
    echo "---"; echo "$MD_SCRIPT"; echo "---"

    header "systemd unit → ${MD_TUNING_SERVICE}"
    echo "---"; echo "$MD_UNIT"; echo "---"

    info "irqbalance: se instalaría y habilitaría"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. sysctl
# ---------------------------------------------------------------------------
header "1/4 — Aplicando sysctl..."
if [[ -f "$DEST" ]]; then
    cp "$DEST" "${DEST}.bak.$(date +%Y%m%d%H%M%S)"
    warn "Backup del fichero anterior guardado."
fi
echo "$CONF" > "$DEST"
sysctl -p "$DEST"
ok "sysctl aplicado."

# ---------------------------------------------------------------------------
# 2. irqbalance
# ---------------------------------------------------------------------------
header "2/4 — Instalando irqbalance..."
if command -v irqbalance &>/dev/null; then
    ok "irqbalance ya instalado."
else
    apt-get install -y -q irqbalance
    ok "irqbalance instalado."
fi
systemctl enable --now irqbalance
ok "irqbalance activo."

# ---------------------------------------------------------------------------
# 3. MD tuning script
# ---------------------------------------------------------------------------
header "3/4 — Instalando script de tuning del MD..."
echo "$MD_SCRIPT" > "$MD_TUNING_SCRIPT"
chmod 750 "$MD_TUNING_SCRIPT"
ok "Script instalado en ${MD_TUNING_SCRIPT}"

# ---------------------------------------------------------------------------
# 4. Systemd unit
# ---------------------------------------------------------------------------
header "4/4 — Registrando servicio systemd..."
echo "$MD_UNIT" > "$MD_TUNING_SERVICE"
systemctl daemon-reload
systemctl enable --now md-postgres-tuning.service
ok "Servicio md-postgres-tuning activo y habilitado en el arranque."

# ---------------------------------------------------------------------------
# Estado final
# ---------------------------------------------------------------------------
header "=== Completado ==="
systemctl status md-postgres-tuning.service --no-pager || true
ok "Tuning aplicado. Modo: ${RAID_MODE}"
