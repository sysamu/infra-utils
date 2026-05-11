# postgres/ansible

Playbooks y roles Ansible para nodos bare-metal PostgreSQL (OVH, Hetzner).

## Setup inicial

```bash
cp ansible.cfg.example ansible.cfg
# editar: private_key_file con tu clave SSH (ej. ~/.ssh/sysamu-key)

cp inventory/hosts.yml.example inventory/hosts.yml
# editar: FQDNs o IPs reales, ajustar pg_primary / pg_replica según topología actual

cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
# editar: ansible_deploy_pubkey, passwords — usar ansible-vault para secrets
```

## First run — bootstrap de un nodo nuevo

El primer acceso es siempre con root (OVH y Hetzner arrancan con root por SSH).
Después del bootstrap el acceso root por SSH se mantiene intacto — la gestión
pasa a hacerse con el usuario `ansible` creado por el rol `base_user`.

```bash
# Primera vez — con root y tu clave de sistemas
ansible-playbook playbooks/bootstrap_node.yml \
  -i inventory/hosts.yml \
  -e "ansible_user=root ansible_ssh_private_key_file=~/.ssh/tu-clave" \
  --limit hapostgres01

# Ejecuciones posteriores — con usuario ansible (ya configurado en ansible.cfg)
ansible-playbook playbooks/bootstrap_node.yml \
  -i inventory/hosts.yml \
  --limit hapostgres01
```

### Por proveedor

```bash
# Solo OVH
ansible-playbook playbooks/bootstrap_node.yml -i inventory/hosts.yml \
  -e "ansible_user=root ansible_ssh_private_key_file=~/.ssh/tu-clave" \
  --limit ovh

# Solo Hetzner
ansible-playbook playbooks/bootstrap_node.yml -i inventory/hosts.yml \
  -e "ansible_user=root ansible_ssh_private_key_file=~/.ssh/tu-clave" \
  --limit hetzner

# Todos a la vez
ansible-playbook playbooks/bootstrap_node.yml -i inventory/hosts.yml \
  -e "ansible_user=root ansible_ssh_private_key_file=~/.ssh/tu-clave"
```

> El `-e "ansible_user=root ..."` sobreescribe el `ansible_user: ansible` del inventario,
> que tiene mayor prioridad que `-u root` por CLI.

## Playbooks

### Bootstrap completo de un nodo

Instala y configura: usuario `ansible`, monit (puerto 7780), smartd, mdadm,
lm-sensors, sysstat, edac-utils y todos los checks de HW.

```bash
ansible-playbook playbooks/bootstrap_node.yml -i inventory/hosts.yml --limit hapostgres01
```

### Monitorización Postgres

Autodetecta clusters via `pg_lsclusters` — solo actúa sobre los que están
corriendo (`online`, `online,recovery`). Ignora versiones antiguas paradas.
No toca el postgres_exporter si ya está instalado por el DBA.

```bash
ansible-playbook playbooks/pg_monitoring.yml -i inventory/hosts.yml --limit hapostgres01
```

### Health check puntual (RAID + disco + HW)

Seguro de relanzar en cualquier momento — solo lee y configura, nunca destruye.

```bash
ansible-playbook playbooks/raid_disk_health.yml -i inventory/hosts.yml --limit hapostgres01
```

### Actualizaciones del OS base

Actualiza paquetes del sistema operativo. Los paquetes de PostgreSQL se ponen
en `apt-mark hold` automáticamente antes del upgrade — nunca se actualizará
Postgres por este playbook. Las actualizaciones de Postgres son responsabilidad
del DBA y deben hacerse de forma controlada.

```bash
# Ver qué se actualizaría sin aplicar nada
ansible-playbook playbooks/os_updates.yml -i inventory/hosts.yml --check

# Actualizar solo OVH primero
ansible-playbook playbooks/os_updates.yml -i inventory/hosts.yml --limit ovh

# Actualizar todo
ansible-playbook playbooks/os_updates.yml -i inventory/hosts.yml
```

Si el playbook avisa de `REBOOT REQUIRED` — coordinar ventana de mantenimiento
antes de reiniciar, especialmente en el primary.

## Roles

| Rol | Qué hace |
|---|---|
| `base_user` | Crea usuario `ansible`, autoriza pubkeys, sudo NOPASSWD |
| `monit` | Instala monit en puerto 7780, fixes de systemd hardening para acceso HW |
| `postgres_monitoring` | Checks monit por cluster Postgres (autodetecta versión y puerto) |
| `raid_health` | Autodiscover arrays mdadm, verifica estado, alertas monit |
| `disk_health` | Autodiscover NVMe/SATA/SAS, SMART unificado, NVMe temp |
| `hw_health` | CPU temp por package, NIC temp (MLX5), IO saturación, NVMe wear, ECC, load |
| `os_updates` | apt upgrade seguro con Postgres en hold |

## Inventario

Los hosts se definen una sola vez bajo su proveedor (`hetzner`/`ovh`).
Los grupos `pg_primary` y `pg_replica` solo los referencian — en un failover
basta mover el hostname entre grupos, sin renombrar máquinas.

```
pg_primary:  hetzner → nodo de escritura actual
pg_replica:  hetzner (réplica local) + ovh (réplica offsite)
```

## Notas de operación

**monit systemd hardening:** El unit de monit tiene `ProtectSystem=strict`,
`NoNewPrivileges=true` y `PrivateDevices=true` que bloquean el ioctl de NVMe
aunque el proceso sea root. El rol despliega un override que desactiva estas
restricciones para que los checks de HW funcionen correctamente.

**NVMe char devices:** `/dev/nvme*` son `crw------- root root` por defecto.
El rol despliega una regla udev para dar acceso al grupo `disk`.

**Failover/switchover:** Editar `inventory/hosts.yml` moviendo el hostname
entre `pg_primary` y `pg_replica`. No hay que tocar nada más.

## Ficheros ignorados por git

`ansible.cfg`, `inventory/hosts.yml` e `inventory/group_vars/all.yml`
están en `.gitignore`. Usar siempre los `.example` como plantilla.
Secrets en `all.yml` deben cifrarse con `ansible-vault`.
