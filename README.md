# infra-utils

Colección de scripts y configuraciones para infraestructura de servidores dedicados, orientado principalmente a entornos Proxmox sobre hardware OVH.

## Estructura

```
infra-utils/
├── proxmox/
│   ├── raid/           # Scripts para creación y optimización de RAID software (mdadm)
│   ├── post-install/   # Post-instalación de Proxmox (repositorios, hardening, etc.)
│   └── network/        # Configuraciones de red: bridges, VLANs, SDN
│
├── ovh/
│   ├── post-install/   # Scripts post-instalación específicos por gama
│   │   ├── so-you-start/
│   │   ├── advance-dedicated/
│   │   └── kimsufi/
│   └── models/         # Perfiles de hardware por modelo de servidor
│
├── sysctl/             # Configuraciones sysctl optimizadas (red, VM, storage)
│
└── common/
    └── lib/            # Funciones compartidas (logging, colores, checks)
```

## Uso

Cada directorio contiene su propio `README.md` con instrucciones específicas.

Los scripts asumen Debian 12 como base (Proxmox 8.x).

## Convenciones

- Los scripts deben ejecutarse como `root`.
- Variables configurables al inicio de cada script, separadas de la lógica.
- Todos los scripts hacen dry-run con `--dry-run` antes de aplicar cambios destructivos.
