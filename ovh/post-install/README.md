# ovh/post-install

Scripts de post-instalación para servidores OVH, organizados por gama.

## Gamas soportadas

| Directorio | Gama | Ejemplos de modelos |
|---|---|---|
| `so-you-start/` | So You Start (SYS) | E3-SAT-1, E3-SSD-3 |
| `advance-dedicated/` | Advance / Rise / Scale | Rise-1, Scale-1 |
| `kimsufi/` | Kimsufi (KS) | KS-1, KS-2, KS-3 |

## Estructura de cada gama

```
<gama>/
├── README.md          # Modelos soportados y notas específicas
├── post-install.sh    # Script principal
└── profiles/          # Perfiles por modelo (discos, red, etc.)
    └── <modelo>.env
```

## Qué hace el post-install

1. Configura repositorios Proxmox (sin suscripción)
2. Aplica sysctl optimizado para la gama
3. Configura red (bridge vmbr0 sobre interfaz detectada)
4. Instala paquetes base (htop, iotop, tmux, qemu-guest-agent, etc.)
5. Aplica RAID según perfil del modelo
6. Hardening básico SSH
