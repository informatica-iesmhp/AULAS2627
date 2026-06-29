# CLAUDE.md — Configuración post-instalación con Ansible

Esta carpeta contiene la **configuración automática del equipo ya instalado**, basada en roles de Ansible. La lanza `3-SetupPrimerInicio.sh` en el primer arranque (`ansible-playbook roles.yaml` desde `$RAIZANSIBLE`), normalmente en modo local (`-i localhost, --connection=local`).

### Subcarpetas
- **`roles/`** — roles de Ansible que se aplican **como root** sobre el equipo (lo que describe este documento).
- **`rolesUsuario/`** — configuraciones que **todo usuario** debería tener en su propio perfil (`~/.ssh`, dotfiles, ajustes de escritorio…); se ejecutan **como el usuario**, no como root. Ver [`rolesUsuario/CLAUDE.md`](rolesUsuario/CLAUDE.md). Carpeta nueva (2026-06-08), todavía no enganchada a `roles.yaml`.
- **`pruebas/`** — playbooks sueltos de experimentación; no forman parte del despliegue.

## `roles.yaml` — el playbook maestro

Único play: `hosts: all`, `become: yes`.

- **`pre_tasks`**: un único `apt update_cache` (la caché se refresca **una sola vez** aquí; por eso casi todos los roles usan `update_cache: false`).
- **`roles`**: lista ordenada de roles a aplicar. Activos vs. comentados según estado de cada rol.

### Roles y su estado actual

| Rol | Estado en `roles.yaml` | Qué hace (resumen) |
|-----|------------------------|--------------------|
| [`basicos`](roles/basicos/CLAUDE.md) | ✅ activo (1º) | python3, pip, pipx, ansible |
| [`horaHTTP`](roles/horaHTTP/CLAUDE.md) | ✅ activo (2º) | Sincroniza la hora en **cada arranque** (NTP y, si el UDP 123 está filtrado, **fallback HTTP** vía cabecera `Date:`). Instala script + `iac-sincroniza-hora.service` + `.timer`. Corrige el desajuste del RTC en VMware/host Windows tras reinicios |
| [`clienteNAS`](roles/clienteNAS/CLAUDE.md) | ⛔ comentado | Cliente NFS del NAS del depto.: autodescubre exports (`showmount`) y los monta RO en `/mnt/nasDepInfo/` |
| [`DirtyFrag`](roles/DirtyFrag/CLAUDE.md) | ✅ activo | Evalúa/mitiga la vuln. "Dirty Frag" (CVE-2026-43284 ESP/IPsec + CVE-2026-43500 RxRPC): bloquea `esp4`/`esp6`/`rxrpc` si no está protegido |
| [`comparteaula`](roles/comparteaula/CLAUDE.md) | ⛔ no listado (en pruebas) | NFS unificado: detecta aula por IP, servidor/cliente |
| [`comparteaula32`](roles/comparteaula32/CLAUDE.md) | legacy (no listado) | NFS cliente aula SMRD (NAS) |
| [`comparteaula72`](roles/comparteaula72/CLAUDE.md) | legacy (no listado) | NFS servidor/cliente aula IABD |
| [`nvidia`](roles/nvidia/CLAUDE.md) | ✅ activo | Driver NVIDIA si hay GPU |
| [`flatpak`](roles/flatpak/CLAUDE.md) | ✅ activo | Soporte Flatpak + repo Flathub |
| [`certificados`](roles/certificados/CLAUDE.md) | ✅ activo | Claves SSH de root + authorized_keys |
| [`obs`](roles/obs/CLAUDE.md) | ✅ activo | OBS Studio |
| [`rdp`](roles/rdp/CLAUDE.md) | ✅ activo | Servidor RDP **nativo de GNOME** (`grdctl --system`); sustituye a `xrdp` |
| [`vscode`](roles/vscode/CLAUDE.md) | ✅ activo | VS Code desde .deb oficial |
| [`vmware`](roles/vmware/CLAUDE.md) | ⛔ comentado (falla compilación en 1er arranque) | VMware Workstation desde .bundle |
| [`Docker`](roles/Docker/CLAUDE.md) | ✅ activo | Instalación de **sistema** de Docker para uso **rootless** (repo, paquetes, subuid/subgid, lingering). La parte por usuario la hace [`rolesUsuario/DockerRootless`](rolesUsuario/roles/DockerRootless/CLAUDE.md). Sustituye al antiguo `contenedores` |
| [`preparaAD`](roles/preparaAD/CLAUDE.md) | ✅ activo | Prerequisitos de unión a dominio **Active Directory** `iesmhp.local` (realmd, SSSD, adcli, Kerberos, pam_mkhomedir) y comprobación de si el equipo ya está unido. **NO une al dominio** por defecto: la unión es bajo demanda con `preparaad_unir=true` + vault. Scripts de apoyo en `roles/preparaAD/utilesAD/` (cuenta delegada en el DC, vault, unión de un equipo). Cumple el TODO `predominio` |

> Cada carpeta de rol tiene su propio `CLAUDE.md` con el detalle de tareas, variables (`defaults/`) e issues conocidos.

### Por hacer (anotado en `roles.yaml`)
`hashicorp` (terraform/packer/vagrant), `clienteOnedrive`, ¿anaconda?/¿dbeaver? (`predominio` cumplido el 2026-06-12 por el rol `preparaAD`)

## Inventarios (`*.ini`)

- `equiposIABD.ini` — aula IABD, hosts `IABD-00..20` en `10.0.72.12x`.
- `equiposSMRD.ini` — aula SMRD, hosts `SMRD-00..18` en `10.0.32.12x` (comentarios por equipo: averías conocidas).
- `EquiposSMRD-alumnos2526.ini` — variante con equipos de alumnos del curso 25/26.
- Todos: `[all:vars]` con `ansible_user=root` y `ansible_python_interpreter=auto_silent` (este último se fijó el 2026-05-15 porque Ubuntu 26.04 «resolute» no trae `python3.12`; ver Registro de cambios).

## Comandos clave

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible       # (en el repo clonado del equipo)

# Aplicar todo a un aula
ansible-playbook -i ./equiposIABD.ini roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no"

# Limitar a un equipo
ansible-playbook -i ./equiposIABD.ini roles.yaml -l IABD-17

# Modo local (lo que hace 3-SetupPrimerInicio.sh en el primer arranque)
ansible-playbook -i localhost, --connection=local roles.yaml

# Útiles
ansible all -i ./equiposIABD.ini -m ping
ansible all -i ./equiposIABD.ini -m reboot -l 'all:!IABD-01'   # reinicia todos menos uno
```

Pasar versión concreta a un rol que lo soporte (p. ej. OBS):
`ansible-playbook ... -e obs_version=30.0.2`

## Convenciones del proyecto

- **Caché apt**: refrescada una vez en `pre_tasks`; los roles usan `update_cache: false` salvo que necesiten un repo recién añadido.
- **Detección de aula**: tercer octeto de la IP (`10.0.72.x`→IABD, `10.0.32.x`→SMRD) y/o prefijo del hostname (`AULA-NN`).
- **Equipo `-00`**: suele ser el servidor (NFS) del aula cuando el aula tiene servidor propio.
- **Idempotencia**: los roles comprueban si el software ya está antes de instalar; varios tienen TODOs sobre `changed` espurios.

## Carpetas auxiliares

- `rolesUsuario/` — configuración por usuario (no root). Ver [`rolesUsuario/CLAUDE.md`](rolesUsuario/CLAUDE.md).
- `pruebas/` — playbooks sueltos de experimentación (NombreIP, NFS de NAS, perfil de alumno, etc.). No forman parte de `roles.yaml`.
- `test_nvidia.yml` — playbook suelto de prueba del driver NVIDIA.
