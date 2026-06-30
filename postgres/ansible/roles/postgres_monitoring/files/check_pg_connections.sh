#!/bin/bash
# Conexiones totales e idle — umbrales pasados por parámetro.
# Uso: check_pg_connections.sh <port> <max_total> <max_idle>

[ -f /root/.pg_monit_secret ] && source /root/.pg_monit_secret

PG_PORT="${1:-5432}"
MAX_TOTAL="${2:-200}"
MAX_IDLE="${3:-50}"

DATA=$(/usr/bin/psql -h localhost -p "$PG_PORT" -U postgres -d postgres -w -q -t -A -c "
    SELECT count(*), COALESCE(count(*) FILTER (WHERE state = 'idle'), 0)
    FROM pg_stat_activity;
" 2>/dev/null)

if [ -z "$DATA" ]; then
  echo "CRITICAL: base de datos no responde en puerto $PG_PORT"
  exit 2
fi

TOTAL=$(echo "$DATA" | cut -d'|' -f1)
IDLE=$(echo "$DATA" | cut -d'|' -f2)

if [ "$TOTAL" -gt "$MAX_TOTAL" ]; then
  echo "WARNING: conexiones totales ${TOTAL}/${MAX_TOTAL} en puerto $PG_PORT"
  exit 1
fi

if [ "$IDLE" -gt "$MAX_IDLE" ]; then
  echo "WARNING: conexiones idle ${IDLE}/${MAX_IDLE} en puerto $PG_PORT"
  exit 1
fi

echo "OK: conexiones total=${TOTAL}/${MAX_TOTAL} idle=${IDLE}/${MAX_IDLE} en puerto $PG_PORT"
exit 0
