#!/bin/bash
# Usado por monit para chequear salud SMART de un disco.
# Uso: check_smart.sh <device>   (ej: /dev/sda, /dev/nvme0n1)
# Salida: 0=ok, 1=warning/critical

DEV="${1}"
if [[ -z "$DEV" || ! -b "$DEV" ]]; then
  echo "ERROR: device '${DEV}' not found or not a block device"
  exit 1
fi

TYPE_ARGS=()
if echo "$DEV" | grep -q nvme; then
  TYPE_ARGS=(-d nvme)
fi

# Overall health — busca PASSED explícitamente en la línea del resultado
HEALTH=$(smartctl "${TYPE_ARGS[@]}" -H "$DEV" 2>&1)
RESULT_LINE=$(echo "$HEALTH" | grep -i "self-assessment test result")
if ! echo "$RESULT_LINE" | grep -qi "PASSED"; then
  echo "CRITICAL: ${DEV} SMART overall health FAILED"
  echo "$RESULT_LINE"
  exit 1
fi

# Reallocated sectors (SATA/SAS attr 5)
REALLOC=$(smartctl "${TYPE_ARGS[@]}" -A "$DEV" 2>/dev/null | awk '/Reallocated_Sector_Ct/{print $10}')
if [[ -n "$REALLOC" && "$REALLOC" -gt 0 ]]; then
  echo "WARNING: ${DEV} has ${REALLOC} reallocated sectors"
  exit 1
fi

# Pending sectors (SATA/SAS attr 197)
PENDING=$(smartctl "${TYPE_ARGS[@]}" -A "$DEV" 2>/dev/null | awk '/Current_Pending_Sector/{print $10}')
if [[ -n "$PENDING" && "$PENDING" -gt 0 ]]; then
  echo "WARNING: ${DEV} has ${PENDING} pending sectors"
  exit 1
fi

# NVMe: media errors
if echo "$DEV" | grep -q nvme; then
  MEDIA_ERR=$(smartctl -d nvme -l error "$DEV" 2>/dev/null | grep -oP 'Media and Data Integrity Errors:\s+\K\d+' || echo 0)
  if [[ "$MEDIA_ERR" -gt 0 ]]; then
    echo "WARNING: ${DEV} NVMe media errors: ${MEDIA_ERR}"
    exit 1
  fi
fi

echo "OK: ${DEV} SMART health passed"
exit 0
