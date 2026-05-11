#!/bin/bash
# NVMe wear level — lee "Percentage Used" de cada NVMe presente.

WARN=70
CRIT=90

SMARTCTL=$(command -v smartctl || echo /usr/sbin/smartctl)

if [[ ! -x "$SMARTCTL" ]]; then
  echo "UNKNOWN: smartmontools not installed (looked for $SMARTCTL)"
  exit 3
fi

NVME_DEVS=$(ls /dev/nvme?n? 2>/dev/null)
if [[ -z "$NVME_DEVS" ]]; then
  echo "OK: no NVMe devices found"
  exit 0
fi

WORST_PCT=0
WORST_DEV=""
DETAILS=()

for DEV in $NVME_DEVS; do
  RAW=$($SMARTCTL -d nvme -A "$DEV" 2>/dev/null)
  PCT=$(echo "$RAW" | awk '/Percentage Used/ { gsub(/[^0-9]/,"",$NF); print $NF }')
  if [[ -n "$PCT" ]]; then
    DETAILS+=("${DEV}=${PCT}%")
    if (( PCT > WORST_PCT )); then
      WORST_PCT=$PCT
      WORST_DEV="$DEV"
    fi
  fi
done

if [[ ${#DETAILS[@]} -eq 0 ]]; then
  echo "UNKNOWN: no NVMe wear data available -- smartctl=${SMARTCTL} devs=${NVME_DEVS}"
  exit 3
fi

SUMMARY="${DETAILS[*]}"

if (( WORST_PCT >= CRIT )); then
  echo "CRITICAL: NVMe wear ${WORST_DEV}=${WORST_PCT}% (threshold: ${CRIT}%) -- ${SUMMARY}"
  exit 2
fi

if (( WORST_PCT >= WARN )); then
  echo "WARNING: NVMe wear ${WORST_DEV}=${WORST_PCT}% (threshold: ${WARN}%) -- ${SUMMARY}"
  exit 1
fi

echo "OK: NVMe wear levels OK -- ${SUMMARY}"
exit 0
