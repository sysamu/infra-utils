# ovh/models

Perfiles de hardware por modelo de servidor OVH.

Cada fichero `.env` define las variables que los scripts de post-install
cargan para adaptar su comportamiento al hardware concreto.

## Formato de perfil

```bash
# ovh/models/<modelo>.env
MODEL_NAME="Rise-1"
MODEL_SERIES="advance-dedicated"

# Discos
DISK_COUNT=2
DISK_DEVICES=("/dev/sda" "/dev/sdb")
DISK_TYPE="nvme"     # sata | sas | nvme
DISK_SIZE_GB=480

# RAID por defecto para este modelo
DEFAULT_RAID_LEVEL=1
DEFAULT_MD_DEVICE="/dev/md0"

# Red
PRIMARY_IFACE=""    # vacío = autodetectar
```

## Modelos disponibles

| Fichero | Modelo | Discos | RAID |
|---------|--------|--------|------|
| *(por añadir)* | | | |
