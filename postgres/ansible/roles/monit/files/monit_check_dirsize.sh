#!/bin/bash
# Comprueba que un directorio no supere un límite de tamaño en bytes.
# Uso: monit_check_dirsize.sh <path> <max_bytes>

DIR="$1"
MAX="$2"

if [ -z "$DIR" ] || [ -z "$MAX" ]; then
  echo "ERROR: uso: monit_check_dirsize.sh <path> <max_bytes>" >&2
  exit 1
fi

SIZE=$(du -sb "$DIR" 2>/dev/null | awk '{print $1}')

if [ -z "$SIZE" ]; then
  echo "ERROR: no se puede medir $DIR" >&2
  exit 1
fi

human_size() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    awk "BEGIN {printf \"%.1fGB\", $bytes/1073741824}"
  elif (( bytes >= 1048576 )); then
    awk "BEGIN {printf \"%.0fMB\", $bytes/1048576}"
  elif (( bytes >= 1024 )); then
    awk "BEGIN {printf \"%.0fKB\", $bytes/1024}"
  else
    echo "${bytes}B"
  fi
}

SIZE_H=$(human_size "$SIZE")
MAX_H=$(human_size "$MAX")

if [ "$SIZE" -gt "$MAX" ]; then
  echo "ERROR: $DIR ocupa ${SIZE_H}, supera el limite de ${MAX_H}"
  exit 1
fi

echo "OK: $DIR ocupa ${SIZE_H} (limite: ${MAX_H})"
exit 0
