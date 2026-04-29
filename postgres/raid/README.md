# postgres/raid

Script interactivo para crear RAID software con mdadm para PostgreSQL bare-metal.
Niveles soportados: **0, 1, 10** (RAID5 excluido — demasiado lento para Postgres).

## One-liner

```bash
# Interactivo (recomienda y pregunta)
curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/raid/create-raid.sh | sudo bash

# Automático sin preguntas
curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/raid/create-raid.sh | sudo bash -s -- --auto

# Dry-run (no toca nada)
curl -fsSL https://raw.githubusercontent.com/sysamu/infra-utils/main/postgres/raid/create-raid.sh | sudo bash -s -- --dry-run
```

## Lógica de detección y recomendación

**Discos libres** = sin particiones + no miembros de ningún array mdadm + no contienen el OS

| Discos libres | Recomendación | Razón |
|---|---|---|
| 4 o más | **RAID10** | Rendimiento + redundancia. Siempre preferible. |
| 2 o 3 | **RAID0** | Máximo rendimiento. Asumir réplica Postgres + backup externo. |
| 1 | Error | No se puede crear RAID. |

En modo interactivo se muestra la recomendación pero se puede elegir otro nivel válido.
RAID5 no está disponible en ningún modo — la penalización de paridad en escritura lo hace inadecuado para Postgres.

## Qué hace el script

1. Detecta discos libres y muestra tipo (NVMe/SSD/HDD) y tamaño
2. Recomienda nivel de RAID y pide confirmación (o aplica directamente con `--auto`)
3. Wipe + particionado GPT (1MiB offset)
4. Limpieza de superblocks mdadm anteriores
5. Crea el array con `bitmap=internal` y `metadata=1.2`
6. Filesystem XFS optimizado para Postgres (`su/sw` coherentes con el RAID, log 1GB, inode 512B)
7. Monta en `/var/lib/postgresql` con `noatime,nodiratime`
8. Entrada en `/etc/fstab` por UUID — no duplica si ya existe
9. Entrada en `/etc/mdadm/mdadm.conf` por UUID del array — no duplica
10. `swapoff -a` + swap comentada en fstab
11. `update-initramfs -u`
12. I/O scheduler: `none` para NVMe, `mq-deadline` para SATA/SAS
13. Read-ahead del array → 4MB

## Parámetros XFS por nivel

| Nivel | su   | sw    | Mount opts extra |
|-------|------|-------|-----------------|
| RAID0 | 256k | N     | — |
| RAID1 | —    | —     | `logbufs=8,logbsize=256k` |
| RAID10| 256k | N/2   | `logbufs=8,logbsize=256k` |

## Nota sobre resync

RAID1 y RAID10 son usables inmediatamente aunque el resync continúe en background.
La config mdadm se guarda al crear el array, no hay que esperar.

```bash
watch -n2 cat /proc/mdstat
```
