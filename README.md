# infra-utils

Colección de scripts, configuraciones y playbooks Ansible para infraestructura bare-metal — PostgreSQL, Proxmox y servidores dedicados OVH/Hetzner.

## Estructura

```
infra-utils/
├── postgres/
│   ├── ansible/            # Playbooks y roles para nodos bare-metal PostgreSQL
│   │   ├── ansible.cfg.example
│   │   ├── inventory/
│   │   │   ├── hosts.yml.example
│   │   │   └── group_vars/all.yml.example
│   │   ├── playbooks/
│   │   │   ├── bootstrap_node.yml    # Bootstrap completo (monit, RAID, disco, HW)
│   │   │   ├── pg_monitoring.yml     # postgres_exporter + checks Postgres
│   │   │   └── raid_disk_health.yml  # RAID + disco + HW health standalone
│   │   └── roles/
│   │       ├── base_user/            # Crea usuario ansible, autoriza claves, deshabilita root SSH
│   │       ├── monit/                # Instala y configura monit (puerto 7780)
│   │       ├── postgres_monitoring/  # postgres_exporter + checks monit Postgres
│   │       ├── raid_health/          # Autodiscover arrays mdadm, salud, alertas
│   │       ├── disk_health/          # Autodiscover NVMe/SATA/SAS, smartd, SMART checks
│   │       └── hw_health/            # CPU temp, IO congestion, NVMe wear, ECC, load
│   ├── raid/
│   │   ├── create-raid.sh            # Creación unificada RAID 0/1/10 para PostgreSQL
│   │   └── README.md
│   └── sysctl/
│       ├── apply-tuning.sh           # Genera sysctl desde hardware (nproc, meminfo)
│       └── README.md
│
├── proxmox/
│   ├── ansible/            # (futuro) Playbooks para hosts Proxmox
│   ├── post-install/       # Post-instalación Proxmox (repos, hardening, etc.)
│   └── network/            # Bridges, VLANs, SDN
│
├── ovh/
│   ├── ansible/            # (futuro) Playbooks para provisioning OVH
│   ├── post-install/       # Scripts post-instalación por gama (so-you-start, kimsufi...)
│   └── models/             # Perfiles de hardware por modelo (.env)
│
├── sysctl/
│   └── proxmox-vm-host.conf  # sysctl para hypervisores Proxmox
│
└── common/
    ├── ansible/
    │   └── roles/          # Roles compartidos entre dominios (referenciados via roles_path)
    └── lib/
        └── utils.sh        # Funciones compartidas: logging, dry_run_guard, require_root
```

## Ansible

Cada dominio tiene su propio `ansible/` con inventario y `ansible.cfg` independientes. Ver el README de cada uno:

- [postgres/ansible/README.md](postgres/ansible/README.md)
- `proxmox/ansible/` — pendiente
- `ovh/ansible/` — pendiente

Roles compartidos van en `common/ansible/roles/` y se referencian via `roles_path`.

## Scripts bash

Los scripts son independientes, sin Ansible. Target: Ubuntu/Debian bare-metal.

- Ejecutar como `root`
- Soportan `--dry-run` — nunca aplican cambios destructivos sin él
- Variables configurables al inicio de cada script, separadas de la lógica

## Convenciones

- `ansible.cfg`, `inventory/hosts.yml` e `inventory/group_vars/all.yml` están en `.gitignore` — usar los `.example` como plantilla.
- Secrets en `all.yml` deben cifrarse con `ansible-vault`.
- Cada dominio (`postgres/`, `proxmox/`, `ovh/`) tiene su propio `ansible/` con su propio inventario y `ansible.cfg`.
- Roles compartidos van en `common/ansible/roles/` y se referencian via `roles_path`.
