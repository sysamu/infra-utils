# infra-utils — Context for Claude

## What this repo is

A suite of infrastructure scripts and configurations for bare-metal PostgreSQL, Proxmox, and OVH dedicated servers.

Two GitHub remotes:
- https://github.com/sysamu/infra-utils
- https://github.com/Admin-Hallon/infra-utils

## Structure

```
postgres/
├── ansible/             # Ansible for bare-metal Postgres nodes (see section below)
├── raid/
│   ├── create-raid.sh   # Unified RAID 0/1/10 for PostgreSQL bare-metal
│   └── README.md
└── sysctl/
    ├── apply-tuning.sh  # Auto-generates sysctl config from hardware
    └── README.md

proxmox/
├── ansible/             # (future) Ansible for Proxmox hosts
├── post-install/        # Proxmox post-install scripts
└── network/             # Bridge, VLAN, SDN configs

ovh/
├── ansible/             # (future) Ansible for OVH-specific provisioning
├── post-install/        # Per-range post-install (so-you-start, advance-dedicated, kimsufi)
└── models/              # Hardware profiles per server model (.env files)

sysctl/
└── proxmox-vm-host.conf # sysctl for Proxmox hypervisor hosts

common/
├── ansible/
│   └── roles/           # Shared roles (e.g. base_user) — referenced via roles_path
└── lib/
    └── utils.sh         # Shared: logging, dry_run_guard, require_root, etc.
```

## Key conventions

- Target OS: **Ubuntu or Debian** (bare-metal). Proxmox scripts assume Debian 12 / Proxmox 8.x.
- All scripts must run as **root**.
- Every script supports **`--dry-run`** — no destructive changes without it.
- `create-raid.sh` also supports **`--auto`** for unattended provisioning.
- Configurable variables live at the top of each script, separated from logic.
- The `common/lib/utils.sh` library is sourced by scripts that live on disk. Scripts designed for `curl | bash` embed their own minimal logging instead.

## RAID decisions (PostgreSQL)

- **RAID10** when 4+ free disks — always preferred.
- **RAID0** when 2–3 free disks — assumes Postgres streaming replication + external backup.
- **RAID5 is never used** — write penalty from parity makes it unsuitable for Postgres workloads.
- "Free disk" = no partitions + not a member of an existing mdadm array + does not contain any mounted filesystem (OS excluded automatically).

## sysctl tuning

- `postgres/sysctl/apply-tuning.sh` auto-calculates values from `nproc` and `/proc/meminfo`.
- Fixed values (swappiness, dirty ratios, overcommit) are hardcoded — they don't vary by hardware.
- Dynamic values: TCP buffer max, somaxconn, rps_sock_flow_entries, file-max.
- `proxmox/sysctl/proxmox-vm-host.conf` is a static file for hypervisor hosts — different tuning goals.

## OVH server profiles

- Each model gets a `.env` profile under `ovh/models/` defining disk layout, RAID defaults, and primary interface.
- Post-install scripts under `ovh/post-install/<range>/` source the relevant profile.

## Ansible (bare-metal PostgreSQL)

Located under `postgres/ansible/`. Each domain has its own `ansible/` subtree — Proxmox and OVH will get theirs when needed. Shared roles live in `common/ansible/roles/` and are referenced via `roles_path`.

```
postgres/ansible/
├── ansible.cfg                         # remote_user=ansible, key=~/.ssh/id_ansible
│                                       # roles_path = roles:../../common/ansible/roles
├── inventory/
│   ├── hosts.yml.example               # groups: pg_primary, pg_replica, pg_all, bare_metal
│   └── group_vars/all.yml.example      # alert_email, pg_*, ansible_deploy_*
├── playbooks/
│   ├── bootstrap.yml                   # run with -u root --private-key ~/.ssh/id_sistemas
│   ├── pg_monitoring.yml
│   └── raid_disk_health.yml
└── roles/
    ├── base_user/            # creates 'ansible' user, authorizes pubkeys, disables root SSH
    ├── postgres_monitoring/  # postgres_exporter + monit checks
    ├── raid_health/          # autodiscovers mdadm arrays, checks state, monit alerts
    └── disk_health/          # autodiscovers NVMe/SATA/SAS, smartd config, monit alerts
```

### Ansible conventions

- **Bootstrap flow**: first run uses `-u root --private-key ~/.ssh/id_sistemas`; after that, `remote_user: ansible` with `~/.ssh/id_ansible`.
- `raid_health` and `disk_health` autodiscover everything — no need to declare disks or arrays in inventory.
- `disk_health` handles NVMe (`-d nvme`), SATA, and SAS transparently.
- Check scripts in `/usr/local/bin/` (`check_smart.sh`, `check_mdadm.sh`) are used by monit and return 0=ok / 1=warn-or-critical.
- Secrets (`pg_monitoring_password`) go in `group_vars/all.yml` encrypted with `ansible-vault`.

## What's not here

- Postgres configuration (`postgresql.conf`, `pg_hba.conf`) — out of scope.
- Proxmox Ansible playbooks — separate repo (`proxmox-infra/ansible`).
- Monitoring stack (Prometheus, Grafana) — separate repo.
