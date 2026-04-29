#!/usr/bin/env bash
# Uso directo:
#   curl -fsSL https://raw.githubusercontent.com/.../create-raid.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/.../create-raid.sh | bash -s -- --auto
#   bash create-raid.sh --auto
#   bash create-raid.sh --dry-run

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
AUTO=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --auto)    AUTO=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Uso: bash create-raid.sh [--auto] [--dry-run]"
            echo "  --auto     Detecta discos y elige RAID automáticamente"
            echo "  --dry-run  Muestra lo que haría sin ejecutar nada"
            exit 0 ;;
    esac
done

[[ $EUID -eq 0 ]] || fatal "Ejecuta como root."

for cmd in mdadm parted partprobe mkfs.xfs blockdev lsblk blkid; do
    command -v "$cmd" &>/dev/null || fatal "Comando requerido no encontrado: $cmd"
done

# ---------------------------------------------------------------------------
# Detección de discos libres
# Libre = sin particiones + no miembro de ningún array mdadm + no contiene el OS
# ---------------------------------------------------------------------------
detect_free_disks() {
    local os_disks=()

    # Discos que contienen sistemas de ficheros montados (/, /boot, swap...)
    while IFS= read -r dev; do
        # Obtener el disco padre del dispositivo montado
        local parent
        parent=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
        [[ -n "$parent" ]] && os_disks+=("/dev/${parent}")
        # También el propio dispositivo si es un disco entero
        local dtype
        dtype=$(lsblk -no TYPE "$dev" 2>/dev/null | head -1)
        [[ "$dtype" == "disk" ]] && os_disks+=("$dev")
    done < <(lsblk -lno NAME,MOUNTPOINT | awk '$2 != "" {print "/dev/"$1}')

    # Discos ya miembros de un array mdadm activo
    local raid_disks=()
    if [[ -f /proc/mdstat ]]; then
        while IFS= read -r dev; do
            local parent
            parent=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
            [[ -n "$parent" ]] && raid_disks+=("/dev/${parent}")
        done < <(mdadm --detail --scan 2>/dev/null | grep -oP '/dev/\S+' | grep -v '^/dev/md')
    fi

    local free=()
    while IFS= read -r disk; do
        [[ "$disk" =~ ^/dev/(sd|nvme|vd|hd) ]] || continue

        # Excluir discos del OS
        local is_os=false
        for od in "${os_disks[@]}"; do
            [[ "$disk" == "$od" ]] && { is_os=true; break; }
        done
        $is_os && continue

        # Excluir discos ya en RAID
        local in_raid=false
        for rd in "${raid_disks[@]}"; do
            [[ "$disk" == "$rd" ]] && { in_raid=true; break; }
        done
        $in_raid && continue

        # Excluir discos con particiones
        local part_count
        part_count=$(lsblk -lno TYPE "$disk" | grep -c "part" || true)
        [[ "$part_count" -gt 0 ]] && continue

        free+=("$disk")
    done < <(lsblk -lno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')

    echo "${free[@]:-}"
}

# ---------------------------------------------------------------------------
# Información de disco (tipo y tamaño)
# ---------------------------------------------------------------------------
disk_type() {
    local disk="$1" name
    name=$(basename "$disk")
    if [[ "$disk" =~ nvme ]]; then echo "NVMe"
    elif [[ -f "/sys/block/${name}/queue/rotational" ]]; then
        local rot
        rot=$(cat "/sys/block/${name}/queue/rotational")
        [[ "$rot" == "0" ]] && echo "SSD" || echo "HDD"
    else echo "?"
    fi
}

disk_size_human() {
    lsblk -dno SIZE "$1" 2>/dev/null || echo "?"
}

# ---------------------------------------------------------------------------
# Elegir MD device libre
# Tiene en cuenta /dev/md/mdX (OVH) y /dev/mdX (estándar)
# ---------------------------------------------------------------------------
next_free_md() {
    local n=0
    while true; do
        # Ocupado si existe como device directo O bajo /dev/md/
        if [[ -e "/dev/md${n}" || -e "/dev/md/md${n}" ]]; then
            n=$(( n + 1 ))
        else
            break
        fi
    done
    echo "/dev/md${n}"
}

# ---------------------------------------------------------------------------
# Recomendación de RAID
# Reglas:
#   >= 4 discos → RAID10 (rendimiento + redundancia)
#    2-3 discos → RAID0  (máximo rendimiento; asumir réplica/backup externo)
#      1 disco  → sin RAID posible
# RAID5 excluido: demasiado lento para Postgres por la penalización de paridad
# ---------------------------------------------------------------------------
recommend_raid() {
    local count=$1
    if   [[ $count -ge 4 ]]; then echo "10"
    elif [[ $count -ge 2 ]]; then echo "0"
    else echo "none"
    fi
}

recommend_reason() {
    local level=$1 count=$2
    case "$level" in
        10) echo "RAID10 — rendimiento + redundancia (N/2 discos de datos con mirror)" ;;
        0)  echo "RAID0  — máximo rendimiento, sin redundancia (asegúrate de tener réplica/backup)" ;;
        *)  echo "No se puede crear RAID con $count disco(s)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Detectar discos
# ---------------------------------------------------------------------------
header "=== PostgreSQL RAID Setup ==="
info "Detectando discos libres..."

mapfile -t FREE_DISKS < <(detect_free_disks | tr ' ' '\n' | grep -v '^$' || true)
NDISKS=${#FREE_DISKS[@]}

if [[ $NDISKS -eq 0 ]]; then
    fatal "No se encontraron discos libres (sin particiones, sin RAID, sin OS)."
fi

header "Discos disponibles:"
for disk in "${FREE_DISKS[@]}"; do
    echo -e "  ${BOLD}${disk}${NC}  $(disk_type "$disk")  $(disk_size_human "$disk")"
done
echo

# ---------------------------------------------------------------------------
# Elegir nivel de RAID
# ---------------------------------------------------------------------------
REC_LEVEL=$(recommend_raid "$NDISKS")

if [[ "$REC_LEVEL" == "none" ]]; then
    fatal "Solo se detectó $NDISKS disco libre. Se necesitan al menos 2."
fi

REC_REASON=$(recommend_reason "$REC_LEVEL" "$NDISKS")

if $AUTO; then
    RAID_LEVEL="$REC_LEVEL"
    SELECTED_DISKS=("${FREE_DISKS[@]}")
    info "Modo --auto: ${REC_REASON}"
else
    header "Recomendación:"
    echo -e "  ${GREEN}RAID${REC_LEVEL}${NC} — ${REC_REASON}"
    echo

    # Mostrar opciones válidas según número de discos
    echo "Niveles disponibles con $NDISKS disco(s):"
    echo "  0   → RAID0  (máximo rendimiento, sin redundancia)"
    [[ $NDISKS -ge 2 ]] && echo "  1   → RAID1  (mirror, solo 2 discos)"
    [[ $NDISKS -ge 4 ]] && echo "  10  → RAID10 (rendimiento + redundancia, recomendado)"
    echo

    while true; do
        read -rp "¿Qué nivel de RAID quieres usar? [${REC_LEVEL}]: " INPUT_LEVEL
        INPUT_LEVEL="${INPUT_LEVEL:-$REC_LEVEL}"

        case "$INPUT_LEVEL" in
            0)  RAID_LEVEL=0; break ;;
            1)
                if [[ $NDISKS -lt 2 ]]; then
                    warn "RAID1 requiere exactamente 2 discos."
                else
                    RAID_LEVEL=1; break
                fi ;;
            5)
                warn "RAID5 no está disponible: demasiado lento para PostgreSQL (penalización de paridad en escritura)."
                ;;
            10)
                if [[ $NDISKS -lt 4 ]]; then
                    warn "RAID10 requiere mínimo 4 discos. Tienes $NDISKS."
                else
                    RAID_LEVEL=10; break
                fi ;;
            *) warn "Opción no válida: $INPUT_LEVEL" ;;
        esac
    done

    # Para RAID1 usar solo los 2 primeros discos; el resto quedan libres
    if [[ "$RAID_LEVEL" == "1" ]]; then
        SELECTED_DISKS=("${FREE_DISKS[0]}" "${FREE_DISKS[1]}")
        [[ $NDISKS -gt 2 ]] && warn "RAID1 usa solo 2 discos. Los demás quedan sin tocar."
    else
        SELECTED_DISKS=("${FREE_DISKS[@]}")
    fi
fi

MD_DEVICE=$(next_free_md)
MOUNT="/var/lib/postgresql"
CHUNK_KB=256

# ---------------------------------------------------------------------------
# Calcular parámetros XFS
# ---------------------------------------------------------------------------
case "$RAID_LEVEL" in
    0)  XFS_SW=${#SELECTED_DISKS[@]}; MDADM_LAYOUT="" ;;
    1)  XFS_SW=1;                     MDADM_LAYOUT="" ;;
    10) XFS_SW=$(( ${#SELECTED_DISKS[@]} / 2 )); MDADM_LAYOUT="--layout=n2" ;;
esac
XFS_SU="${CHUNK_KB}k"

# ---------------------------------------------------------------------------
# Resumen final + confirmación
# ---------------------------------------------------------------------------
header "Resumen de la operación:"
echo -e "  Nivel RAID:  ${BOLD}RAID${RAID_LEVEL}${NC}"
echo    "  Discos:      ${SELECTED_DISKS[*]}"
echo    "  Device:      ${MD_DEVICE}"
echo    "  Mount:       ${MOUNT}"
echo    "  Filesystem:  XFS  su=${XFS_SU} sw=${XFS_SW}"
echo    "  DRY_RUN:     ${DRY_RUN}"
echo

if ! $AUTO && ! $DRY_RUN; then
    echo -e "${RED}${BOLD}ADVERTENCIA: Se BORRARÁN todos los datos en: ${SELECTED_DISKS[*]}${NC}"
    read -rp "Escribe 'si' para confirmar: " CONFIRM
    [[ "${CONFIRM,,}" == "si" ]] || { info "Cancelado."; exit 0; }
fi

run() {
    if $DRY_RUN; then
        warn "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# 1. Wipe + particionado GPT
# ---------------------------------------------------------------------------
header "1/9 — Particionando discos..."
PARTS=()
for disk in "${SELECTED_DISKS[@]}"; do
    run wipefs -a "$disk"
    run parted -s "$disk" mklabel gpt
    run parted -s "$disk" mkpart primary 1MiB 100%
    if [[ "$disk" =~ nvme ]]; then
        PARTS+=("${disk}p1")
    else
        PARTS+=("${disk}1")
    fi
done
run partprobe
$DRY_RUN || sleep 2

# ---------------------------------------------------------------------------
# 2. Limpiar superblocks anteriores
# ---------------------------------------------------------------------------
header "2/9 — Limpiando superblocks mdadm..."
for part in "${PARTS[@]}"; do
    run mdadm --zero-superblock --force "$part" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 3. Crear array RAID
# ---------------------------------------------------------------------------
header "3/9 — Creando RAID${RAID_LEVEL} en ${MD_DEVICE}..."
run mdadm \
    --create "$MD_DEVICE" \
    --level="$RAID_LEVEL" \
    --raid-devices="${#PARTS[@]}" \
    --chunk="${CHUNK_KB}" \
    --bitmap=internal \
    --metadata=1.2 \
    $MDADM_LAYOUT \
    "${PARTS[@]}"

$DRY_RUN || sleep 3

# ---------------------------------------------------------------------------
# 4. Filesystem XFS
# ---------------------------------------------------------------------------
header "4/9 — Creando filesystem XFS..."
if [[ "$RAID_LEVEL" == "1" ]]; then
    run mkfs.xfs -f \
        -l size=1g,version=2 \
        -i size=512 \
        "$MD_DEVICE"
else
    run mkfs.xfs -f \
        -d "su=${XFS_SU},sw=${XFS_SW}" \
        -l size=1g,version=2 \
        -i size=512 \
        "$MD_DEVICE"
fi

# ---------------------------------------------------------------------------
# 5. Mount
# ---------------------------------------------------------------------------
header "5/9 — Montando..."
run mkdir -p "$MOUNT"
if [[ "$RAID_LEVEL" == "0" ]]; then
    MOUNT_OPTS="noatime,nodiratime"
else
    MOUNT_OPTS="noatime,nodiratime,logbufs=8,logbsize=256k"
fi
run mount -o "$MOUNT_OPTS" "$MD_DEVICE" "$MOUNT"

# ---------------------------------------------------------------------------
# 6. fstab (por UUID, sin duplicar)
# ---------------------------------------------------------------------------
header "6/9 — Actualizando /etc/fstab..."
if ! $DRY_RUN; then
    UUID=$(blkid -s UUID -o value "$MD_DEVICE")
    FSTAB_LINE="UUID=${UUID}  ${MOUNT}  xfs  ${MOUNT_OPTS}  0 0"
    if grep -qsF "$UUID" /etc/fstab; then
        warn "UUID ${UUID} ya existe en /etc/fstab — no se duplica."
    else
        echo "# PostgreSQL RAID${RAID_LEVEL} — $(date +%F)" >> /etc/fstab
        echo "$FSTAB_LINE" >> /etc/fstab
        ok "fstab: ${FSTAB_LINE}"
    fi
else
    warn "[DRY-RUN] Se añadiría entrada UUID=<uuid> a /etc/fstab"
fi

# ---------------------------------------------------------------------------
# 7. mdadm.conf — añadir solo este array, sin duplicar
# ---------------------------------------------------------------------------
header "7/9 — Actualizando /etc/mdadm/mdadm.conf..."
if ! $DRY_RUN; then
    MDADM_CONF="/etc/mdadm/mdadm.conf"
    MD_UUID=$(mdadm --detail "$MD_DEVICE" | awk '/UUID/{print $3}')

    if grep -qsF "$MD_UUID" "$MDADM_CONF" 2>/dev/null; then
        warn "Array ${MD_DEVICE} (UUID=${MD_UUID}) ya presente en ${MDADM_CONF} — no se duplica."
    else
        # Construir solo la línea ARRAY de este MD, sin tocar los demás
        ARRAY_LINE=$(mdadm --detail --scan "$MD_DEVICE")
        echo "$ARRAY_LINE" >> "$MDADM_CONF"
        ok "mdadm.conf: añadido ${ARRAY_LINE}"
    fi
else
    warn "[DRY-RUN] Se añadiría la línea ARRAY de ${MD_DEVICE} a /etc/mdadm/mdadm.conf"
fi

# ---------------------------------------------------------------------------
# 8. Swap off
# ---------------------------------------------------------------------------
header "8/9 — Deshabilitando swap..."
run swapoff -a
if ! $DRY_RUN; then
    sed -i.bak 's|^\([^#].*\bswap\b.*\)$|# [postgres-raid] \1|' /etc/fstab
    ok "Swap deshabilitada y comentada en fstab."
else
    warn "[DRY-RUN] Se ejecutaría swapoff -a y se comentaría swap en fstab"
fi

# ---------------------------------------------------------------------------
# 9. initramfs + optimizaciones I/O
# ---------------------------------------------------------------------------
header "9/9 — Optimizaciones finales..."
run update-initramfs -u

if ! $DRY_RUN; then
    # Scheduler: none para NVMe, mq-deadline para SATA/SAS
    for disk in "${SELECTED_DISKS[@]}"; do
        name=$(basename "$disk")
        sched="/sys/block/${name}/queue/scheduler"
        if [[ -f "$sched" ]]; then
            if [[ "$disk" =~ nvme ]]; then
                echo none > "$sched" 2>/dev/null || true
            else
                echo mq-deadline > "$sched" 2>/dev/null || true
            fi
        fi
    done

    # Read-ahead 4MB en el array
    blockdev --setra 8192 "$MD_DEVICE" 2>/dev/null || true
    ok "read-ahead → 4MB"

    ok "Scheduler configurado por tipo de disco."
fi

# ---------------------------------------------------------------------------
# Estado final
# ---------------------------------------------------------------------------
header "=== Completado ==="
if ! $DRY_RUN; then
    echo
    lsblk
    echo
    df -h "$MOUNT"
    echo
    cat /proc/mdstat
    echo
    [[ "$RAID_LEVEL" != "0" ]] && warn "Resync en curso en background. Monitoriza con: watch -n2 cat /proc/mdstat"
    ok "RAID${RAID_LEVEL} listo en ${MOUNT}"
else
    ok "Dry-run completado. Ningún dato fue modificado."
fi
