#!/bin/bash
# Lag de replicación — agnóstico al rol (master/replica).
# Detecta automáticamente si es master o replica y aplica la query correspondiente.
# Umbral configurable via variable de entorno PG_LAG_CRIT (default: 300s / 5min).

# Credenciales via ~/.pgpass (método estándar) o /root/.pg_monit_secret (legacy)
[ -f /root/.pg_monit_secret ] && source /root/.pg_monit_secret

PG_PORT="${1:-5432}"
LAG_CRIT="${PG_LAG_CRIT:-300}"

LAG=$(/usr/bin/psql -h localhost -p "$PG_PORT" -U postgres -d postgres -w -q -t -A -c "
SELECT CASE
    WHEN pg_is_in_recovery() THEN
        CASE
            WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0.000000
            ELSE ROUND(COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())), 0.0)::numeric, 6)
        END
    ELSE
        ROUND(COALESCE((SELECT MAX(EXTRACT(EPOCH FROM replay_lag)) FROM pg_stat_replication), 0.0)::numeric, 6)
END AS lag_seconds;
" 2>/dev/null)

if [ -z "$LAG" ]; then
  echo "CRITICAL: base de datos no responde en puerto $PG_PORT"
  exit 2
fi

if (( $(echo "$LAG > $LAG_CRIT" | bc -l) )); then
  echo "CRITICAL: lag=${LAG}s (crit=${LAG_CRIT}s) en puerto $PG_PORT"
  exit 2
fi

echo "OK: lag=${LAG}s en puerto $PG_PORT"
exit 0
