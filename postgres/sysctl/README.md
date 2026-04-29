# postgres/sysctl

Script que genera y aplica `/etc/sysctl.d/99-postgres-tuning.conf` con valores
calculados a partir del hardware del host (CPUs y RAM).

## One-liner

```bash
# Aplicar
curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash

# Dry-run (muestra el fichero generado sin tocar nada)
curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/sysctl/apply-tuning.sh | sudo bash -s -- --dry-run
```

## Parámetros fijos (no dependen del hardware)

| Parámetro | Valor | Razón |
|-----------|-------|-------|
| `vm.swappiness` | 5 | Postgres gestiona su propio cache; swap mata latencia |
| `vm.dirty_ratio` | 15 | Permite acumular escrituras sin presión excesiva |
| `vm.dirty_background_ratio` | 5 | Flush en background antes de llegar al límite |
| `vm.overcommit_memory` | 1 | Necesario para hugepages y shared_buffers grandes |
| `vm.zone_reclaim_mode` | 0 | Evitar reclaim local en NUMA, perjudica Postgres |
| `vm.page-cluster` | 0 | Sin readahead de swap (swap debería estar off) |
| `net.ipv4.tcp_slow_start_after_idle` | 0 | Conexiones persistentes no pagan cold start |

## Parámetros calculados por hardware

| Parámetro | Fórmula |
|-----------|---------|
| `net.core.rmem_max / wmem_max` | min(RAM/8, 128MB) |
| `net.core.somaxconn` | clamp(CPUs×128, 4096, 65535) |
| `net.core.netdev_max_backlog` | somaxconn×8, techo 500000 |
| `net.core.rps_sock_flow_entries` | siguiente potencia de 2 ≥ CPUs×2048 |
| `fs.file-max` | max(CPUs×1000, 1000000) |
