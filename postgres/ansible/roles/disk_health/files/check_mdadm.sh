#!/bin/bash
# Usado por monit para verificar la salud de un array mdadm.
# Uso: check_mdadm.sh <md-device>   (ej: check_mdadm.sh md0)
# Salida: 0=ok, 1=degraded/failed/rebuilding

DEVICE="${1:-md0}"
DETAIL=$(mdadm --detail "/dev/${DEVICE}" 2>/dev/null)

if [[ -z "$DETAIL" ]]; then
  echo "ERROR: /dev/${DEVICE} not found"
  exit 1
fi

STATE=$(echo "$DETAIL" | grep -oP 'State\s*:\s*\K.*' | tr -d ' ')

case "$STATE" in
  clean|active)
    echo "OK: /dev/${DEVICE} state=${STATE}"
    exit 0
    ;;
  clean,resyncing|active,resyncing|clean,recovering|active,recovering)
    PCT=$(grep -oP '\d+\.\d+%' /proc/mdstat 2>/dev/null | head -1)
    echo "WARNING: /dev/${DEVICE} state=${STATE} progress=${PCT}"
    exit 1
    ;;
  *)
    echo "CRITICAL: /dev/${DEVICE} state=${STATE}"
    exit 1
    ;;
esac
