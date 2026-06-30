#!/bin/bash
# Hard locks — cuenta transacciones bloqueadas (NOT granted).
# Umbral configurable via variable de entorno PG_LOCKS_CRIT (default: 4).

[ -f /root/.pg_monit_secret ] && source /root/.pg_monit_secret

PG_PORT="${1:-5432}"
LOCKS_CRIT="${PG_LOCKS_CRIT:-4}"

LOCKS=$(/usr/bin/psql -h localhost -p "$PG_PORT" -U postgres -d postgres -w -q -t -A -c "SELECT count(*) FROM pg_locks WHERE NOT granted;" 2>/dev/null)

if [ -z "$LOCKS" ]; then
  echo "CRITICAL: base de datos no responde en puerto $PG_PORT"
  exit 2
fi

if [ "$LOCKS" -gt "$LOCKS_CRIT" ]; then
  echo "WARNING: ${LOCKS} locks esperando (crit=${LOCKS_CRIT}) en puerto $PG_PORT"
  exit 1
fi

echo "OK: locks=${LOCKS} en puerto $PG_PORT"
exit 0
