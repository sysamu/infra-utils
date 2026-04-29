#!/usr/bin/env bash
# Tuning en runtime del array MD de PostgreSQL.
# Gestionado por md-postgres-tuning.service — se ejecuta en cada arranque.
# Instalado en /usr/local/sbin/md-postgres-tuning.sh por apply-tuning.sh

set -euo pipefail

# Detectar el MD montado en /var/lib/postgresql
MD=$(findmnt -n -o SOURCE /var/lib/postgresql 2>/dev/null | xargs -r basename || true)

if [[ -z "$MD" ]]; then
    echo "md-postgres-tuning: no MD found at /var/lib/postgresql, skipping." >&2
    exit 0
fi

echo "Applying MD runtime tuning to /dev/${MD}"

NCPUS=$(nproc)

# group_thread_cnt: hilos de I/O del array. CPUs/4, clamp [4, 32].
GROUP_THREAD_CNT=$(( NCPUS / 4 ))
[[ $GROUP_THREAD_CNT -lt 4  ]] && GROUP_THREAD_CNT=4
[[ $GROUP_THREAD_CNT -gt 32 ]] && GROUP_THREAD_CNT=32

# nr_requests: profundidad de cola. 16384 para saturar NVMe sin bloquear.
NR_REQUESTS=16384

# read-ahead: 32MB — óptimo para rebuild y workloads secuenciales de Postgres.
SETRA=65536

echo ${GROUP_THREAD_CNT} > /sys/block/${MD}/md/group_thread_cnt 2>/dev/null || true
echo ${NR_REQUESTS}      > /sys/block/${MD}/queue/nr_requests    2>/dev/null || true
blockdev --setra ${SETRA}  /dev/${MD}

echo "Done: group_thread_cnt=${GROUP_THREAD_CNT} nr_requests=${NR_REQUESTS} read-ahead=$(( SETRA / 2 ))MB"
