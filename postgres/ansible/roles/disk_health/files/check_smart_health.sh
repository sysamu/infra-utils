#!/bin/bash
# SMART health check unificado — NVMe, SATA y SAS.
# Itera todos los discos del sistema, recoge fallos y reporta en una sola línea.
# Salida: 0=ok, 1=warning, 2=critical, 3=unknown

# Umbral de sectores reasignados antes de alertar — discos viejos estables pueden
# tener algunos sectores históricos sin riesgo real de fallo inmediato.
REALLOC_WARN=${SMART_REALLOC_WARN:-5}
PENDING_WARN=${SMART_PENDING_WARN:-1}

SMARTCTL=/usr/sbin/smartctl

if [[ ! -x "$SMARTCTL" ]]; then
  echo "UNKNOWN: smartmontools not installed"
  exit 3
fi

# Autodiscover: NVMe namespaces + SATA/SAS (excluye particiones, dm, loop)
DISKS=()
for d in /dev/nvme?n? /dev/sd?; do
  [[ -b "$d" ]] && DISKS+=("$d")
done

if [[ ${#DISKS[@]} -eq 0 ]]; then
  echo "UNKNOWN: no block devices found"
  exit 3
fi

FAILURES=()
OK=()

for DEV in "${DISKS[@]}"; do
  TYPE_ARGS=()
  IS_NVME=0
  if echo "$DEV" | grep -q nvme; then
    TYPE_ARGS=(-d nvme)
    IS_NVME=1
  fi

  # Overall health
  HEALTH=$($SMARTCTL "${TYPE_ARGS[@]}" -H "$DEV" 2>&1)
  RESULT=$(echo "$HEALTH" | grep -i "self-assessment test result")
  if ! echo "$RESULT" | grep -qi "PASSED"; then
    FAILURES+=("${DEV}:HEALTH_FAILED")
    continue
  fi

  DEV_FAILURES=()

  if [[ $IS_NVME -eq 1 ]]; then
    # NVMe: media errors
    MEDIA_ERR=$($SMARTCTL -d nvme -l error "$DEV" 2>/dev/null \
      | awk '/Media and Data Integrity Errors/ { gsub(/[^0-9]/,"",$NF); print $NF }')
    [[ -n "$MEDIA_ERR" && "$MEDIA_ERR" -gt 0 ]] && DEV_FAILURES+=("media_errors=${MEDIA_ERR}")
  else
    # SATA/SAS: reallocated + pending sectors
    ATTRS=$($SMARTCTL "${TYPE_ARGS[@]}" -A "$DEV" 2>/dev/null)
    REALLOC=$(echo "$ATTRS" | awk '/Reallocated_Sector_Ct/{print $10}')
    PENDING=$(echo "$ATTRS"  | awk '/Current_Pending_Sector/{print $10}')
    [[ -n "$REALLOC" && "$REALLOC" -ge "$REALLOC_WARN" ]] && DEV_FAILURES+=("reallocated=${REALLOC}>=${REALLOC_WARN}")
    [[ -n "$PENDING"  && "$PENDING"  -ge "$PENDING_WARN"  ]] && DEV_FAILURES+=("pending=${PENDING}")
  fi

  if [[ ${#DEV_FAILURES[@]} -gt 0 ]]; then
    FAILURES+=("${DEV}:($(IFS=,; echo "${DEV_FAILURES[*]}"))")
  else
    OK+=("$DEV")
  fi
done

OK_STR="ok=[$(IFS=,; echo "${OK[*]}")]"
FAIL_STR="failures=[$(IFS=' '; echo "${FAILURES[*]}")]"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "WARNING: ${FAIL_STR} ${OK_STR}"
  exit 1
fi

echo "OK: all disks healthy -- ${OK_STR}"
exit 0
