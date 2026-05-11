# postgres/ansible

Playbooks y roles Ansible para nodos bare-metal PostgreSQL (OVH, Hetzner).

## Setup inicial

```bash
cp ansible.cfg.example ansible.cfg
# editar: private_key_file con tu clave SSH

cp inventory/hosts.yml.example inventory/hosts.yml
# editar: IPs o FQDNs reales, ajustar pg_primary / pg_replica

cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
# editar: ansible_deploy_pubkey, passwords (usar ansible-vault para secrets)
```

## Playbooks

### Bootstrap completo de un nodo (primera vez, con root)

```bash
ansible-playbook playbooks/bootstrap_node.yml \
  -u root \
  --private-key ~/.ssh/tu-clave \
  --limit hapostgres01
```

Instala y configura: usuario `ansible`, monit (puerto 7780), smartd, mdadm alerts, lm-sensors y checks de HW.
Ejecuciones posteriores sin `-u root` ni `--private-key`.

### Monitorización Postgres

```bash
ansible-playbook playbooks/pg_monitoring.yml --limit hapostgres01
```

Autodetecta clusters via `pg_lsclusters` — solo actúa sobre los que están corriendo. Ignora versiones antiguas paradas.

### Health check puntual (RAID + disco + HW)

```bash
ansible-playbook playbooks/raid_disk_health.yml --limit hapostgres01
```

Seguro de relanzar en cualquier momento — solo lee y configura, nunca destruye.

## Roles

| Rol | Qué hace |
|---|---|
| `base_user` | Crea usuario `ansible`, autoriza claves, deshabilita login root por SSH |
| `monit` | Instala monit, configura httpd en puerto 7780, checks de sistema |
| `postgres_monitoring` | `postgres_exporter` como systemd + checks monit por cluster |
| `raid_health` | Autodiscover arrays mdadm, verifica estado, alertas email + monit |
| `disk_health` | Autodiscover NVMe/SATA/SAS, configura smartd, checks SMART en monit |
| `hw_health` | CPU temp (lm-sensors), IO congestion (iostat), NVMe wear, ECC, load avg |

## Inventario

Los hosts se definen una sola vez bajo su proveedor (`hetzner`/`ovh`). Los grupos `pg_primary` y `pg_replica` solo los referencian — en un failover basta mover el hostname entre grupos.

```
pg_primary:  hetzner → escribe
pg_replica:  hetzner (réplica local) + ovh (réplica offsite)
```

## Ficheros ignorados por git

`ansible.cfg`, `inventory/hosts.yml` e `inventory/group_vars/all.yml` están en `.gitignore`. Usar siempre los `.example` como plantilla.
