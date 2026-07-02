# Rol `Docker`

## Qué hace
Instalación de **sistema** (como root) que deja el equipo preparado para que
usuarios **sin privilegios** usen **Docker en modo rootless**. Hace **solo la
parte que requiere root**; la configuración por usuario la completa el rol
[`rolesUsuario/roles/DockerRootless`](../../rolesUsuario/roles/DockerRootless/CLAUDE.md).

Sigue la guía oficial <https://docs.docker.com/engine/security/rootless/>.

Se aplica desde [`../../roles.yaml`](../../roles.yaml) (play `hosts: all`,
`become: yes`).

## Reparto de responsabilidades (root vs usuario)

| Parte | Rol | Se ejecuta como |
|-------|-----|-----------------|
| Repo + paquetes, daemon de sistema, subuid/subgid, lingering | **`roles/Docker`** (este) | root |
| `dockerd-rootless-setuptool.sh`, `DOCKER_HOST`, `systemctl --user` | `rolesUsuario/roles/DockerRootless` | el propio usuario |

## Automatización por usuario en cada login (local **y dominio AD**)

> **Novedad 2026-06-16.** Antes la parte de usuario (`DockerRootless` /
> `0-ConfiguracionInicial.sh` PARTE 2) había que lanzarla **a mano** por cada
> usuario, así que un usuario nuevo o del **dominio** veía
> `failed to connect to the docker API at unix:///var/run/docker.sock` (el
> daemon de sistema está desactivado a propósito y el cliente caía al socket
> inexistente). La **sección 6** del rol lo automatiza para **cualquier** usuario
> que abra sesión, sin intervención.

Dos piezas que reproducen el mismo reparto root/usuario:

| Pieza | Qué hace | Cómo se dispara |
|-------|----------|-----------------|
| `iac-docker-rootless-prep.sh` (root) | `modprobe nf_tables` + subuid/subgid **escritos directamente a `/etc/subuid` + `/etc/subgid`** (rango único por usuario) + `loginctl enable-linger` | **hook `pam_exec`** en `common-session` (perfil pam-config `iac-docker-rootless`, activado con `pam-auth-update`), en cada apertura de sesión |
| `iac-docker-rootless-user.sh` (usuario) | `dockerd-rootless-setuptool.sh install` + `systemctl --user enable --now docker` + `docker context use rootless` | **servicio systemd de usuario global** `iac-docker-rootless.service` (`systemctl --global enable`) |

- **Por qué subuid a fichero y no `usermod`**: `usermod --add-subuids` solo opera
  sobre `/etc/passwd` → **falla con usuarios del dominio** (viven en SSSD). El
  helper ROOT calcula el siguiente rango libre y lo **escribe directamente** a
  `/etc/subuid`/`/etc/subgid` (válido para locales y de dominio; con `flock` para
  serializar logins simultáneos).
- **Por qué `docker context use rootless` y no `DOCKER_HOST` en `~/.bashrc`**: el
  contexto vive en `~/.docker` y lo respeta el cliente en **cualquier** shell
  (login, no-login, gnome-terminal) y en apps gráficas, sin depender de que se
  cargue `~/.bashrc`. (Si un usuario ya tiene `DOCKER_HOST` exportado de una
  ejecución previa, no estorba: apunta al mismo socket.)
- **Race del primer login**: el servicio de usuario espera hasta ~15 s a que el
  hook `pam_exec` haya escrito el subuid; si no, se reintenta en el siguiente
  login (el lingering garantiza que en el próximo boot ya está todo).
- **Seguridad**: NO se concede sudo a los usuarios; la parte root la hace el
  hook PAM. El perfil usa `optional` + `quiet`, así que un fallo del helper
  **nunca bloquea el login**.

## Pasos (tasks/main.yml)
1. **Repo oficial de Docker**: keyring en `/etc/apt/keyrings/docker.asc` +
   entrada APT `download.docker.com/linux/ubuntu`.
2. **Instala el stack + prerrequisitos rootless**: `docker-ce`, `docker-ce-cli`,
   `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`,
   `docker-ce-rootless-extras` + `uidmap`, `dbus-user-session`, `slirp4netns`,
   `fuse-overlayfs`.
3. **Habilita el reenvío IPv4** (`net.ipv4.ip_forward=1`) en
   `/etc/sysctl.d/99-iac-docker.conf` y lo aplica en caliente. Sin esto,
   `docker compose` falla con *"IPv4 forwarding is disabled. Networking will not
   work."* (configurable, `docker_enable_ip_forward`).
3b. **Carga `nf_tables`** (prerequisito de `dockerd-rootless-setuptool.sh`):
   persistente en `/etc/modules-load.d/iac-docker-rootless.conf` y en caliente
   con `modprobe`. Sin él, la instalación del daemon rootless del usuario aborta
   con *"Missing system requirements … modprobe nf_tables"* (ver Issues). Ubuntu
   26.04 no lo carga de serie en una instalación desde squashfs.
4. **Desactiva el daemon de sistema** (`docker.service`/`docker.socket`) para
   que no compita con el rootless (configurable, `docker_disable_system_daemon`).
5. **subuid/subgid + lingering por usuario**: para cada usuario de
   `docker_rootless_users` que exista en el sistema, comprueba `/etc/subuid` y
   asigna el rango si falta, y habilita `loginctl enable-linger` (el daemon de
   usuario arranca en el boot sin login gráfico). Los que no existan aún se
   omiten con un aviso.
6. **Automatización rootless por usuario en cada login** (`docker_rootless_auto`,
   por defecto `true`): instala el helper ROOT
   (`/usr/local/sbin/iac-docker-rootless-prep.sh`), el helper de usuario
   (`/usr/local/bin/iac-docker-rootless-user.sh`), el servicio de usuario
   `/etc/systemd/user/iac-docker-rootless.service` (lo habilita con
   `systemctl --global enable`) y el perfil pam-config
   `/usr/share/pam-configs/iac-docker-rootless` (lo activa con
   `pam-auth-update --enable`). Ver la sección "Automatización por usuario…"
   arriba. Usa `command` (no el módulo `systemd` con `enabled:`/`daemon_reload:`,
   que cuelga el primer arranque — bugs 2026-05-17).

## Variables (`defaults/`)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `docker_arch` | `amd64` | Arquitectura del repo APT |
| `docker_codename` | `{{ ansible_distribution_release }}` | Codename del repo Docker (ver issue) |
| `docker_packages` / `docker_rootless_prereqs` | listas | Paquetes a instalar |
| `docker_disable_system_daemon` | `true` | Parar/deshabilitar el daemon de sistema |
| `docker_enable_ip_forward` | `true` | Activar `net.ipv4.ip_forward` (fix del aviso de red de `docker compose`) |
| `docker_rootless_users` | `[usuario]` | Usuarios a preparar explícitamente en el rol (subuid/subgid + lingering) |
| `docker_subid_range` | `100000-165535` | Rango subuid/subgid si falta (ver aviso) |
| `docker_rootless_auto` | `true` | Sección 6: hook PAM + servicio de usuario global (automatiza el rootless en cada login, incl. dominio). `false` ⇒ flujo manual de `DockerRootless` |
| `docker_rootless_min_uid` | `1000` | UID mínimo para preparar a un usuario automáticamente (salta root/sistema) |
| `docker_subid_block_size` | `65536` | Tamaño del bloque subuid/subgid del helper ROOT |
| `docker_subid_block_start` | `100000` | Primer subuid/subgid disponible (rangos consecutivos sin solape) |

## Uso
```bash
# Como parte del despliegue (roles.yaml ya corre con become: yes):
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i localhost, --connection=local roles.yaml --tags docker

# Preparar usuarios concretos:
ansible-playbook ... roles.yaml --tags docker -e '{"docker_rootless_users":["usuario","alvaro"]}'
```
Después, **cada usuario** completa su Docker rootless con el rol
`DockerRootless` (ver su CLAUDE.md).

## Issues conocidos
- **`Missing system requirements … modprobe nf_tables` al instalar el daemon
  rootless (2026-06-17)**: `dockerd-rootless-setuptool.sh install` aborta si el
  módulo `nf_tables` no está cargado (iptables-nft lo necesita para el
  port-mapping). Ubuntu 26.04 NO lo carga de serie en una instalación desde
  squashfs, así que tanto el servicio de usuario (sección 6) como el script
  manual `0-ConfiguracionInicial.sh` fallaban en silencio y el usuario se
  quedaba SIN Docker rootless. **Fix**: paso **3b** del rol (modules-load.d +
  `modprobe`) y, como red de seguridad por sesión, `modprobe nf_tables` en el
  hook ROOT `iac-docker-rootless-prep.sh`. El script manual también lo carga
  (vía `sudo`) antes del setuptool. En equipos ya instalados: reaplicar el rol
  (`--tags docker`) o `sudo modprobe nf_tables` + reabrir sesión. Comprobar:
  `lsmod | grep nf_tables`.
- **Usuario nuevo o del dominio: `failed to connect to the docker API at
  unix:///var/run/docker.sock` (2026-06-16)**: el daemon de SISTEMA está
  desactivado (rootless) y el usuario nunca configuró su daemon rootless. **Fix**:
  sección 6 (hook PAM `iac-docker-rootless-prep.sh` + servicio de usuario global
  `iac-docker-rootless.service`) lo configura automáticamente en cada login,
  **incluidos los usuarios del dominio** (el subuid se escribe a fichero, no con
  `usermod`, que no conoce SSSD). Diagnóstico en el equipo:
  `journalctl -t iac-docker-rootless-prep -t iac-docker-rootless-user`,
  `grep iac-docker-rootless-prep /etc/pam.d/common-session`,
  `getent subuid <usuario>`, `systemctl --global is-enabled iac-docker-rootless.service`.
  Tras el **primer** login el daemon puede tardar una sesión en quedar listo
  (race subuid); en la siguiente sesión `docker run hello-world` ya va.
- **"IPv4 forwarding is disabled. Networking will not work." (2026-06-09)**: al
  levantar un `docker compose` la red de los contenedores no funcionaba porque
  el kernel tenía `net.ipv4.ip_forward=0`. **Fix**: paso 3 del rol que fija
  `net.ipv4.ip_forward=1` en `/etc/sysctl.d/99-iac-docker.conf` y lo aplica en
  caliente (`docker_enable_ip_forward`, por defecto `true`). En equipos ya
  instalados basta con reaplicar el rol (`--tags docker`).
- **Codename `resolute` (Ubuntu 26.04)**: si Docker aún no publica el repo para
  `resolute`, "Añadir el repositorio APT de Docker" fallará en `apt update`.
  Solución: `-e docker_codename=noble` (u otro LTS). Considerar fijarlo en
  `defaults/` cuando se confirme cuál sirve en el aula.
- **Rango subuid compartido**: `docker_subid_range` es un único rango; si lo
  aplicas a varios usuarios SIN subids, colisionarían. En la práctica `useradd`
  de Ubuntu asigna un rango distinto a cada usuario al crearlo, así que el
  fallback solo importa para el usuario principal. Ver nota en `defaults/`.

## Relación con otros roles
- Sustituye al antiguo rol `contenedores` (borrado), que estaba incompleto y
  comentado y dependía de sub-roles externos.
- Su contrapartida por usuario es
  [`rolesUsuario/roles/DockerRootless`](../../rolesUsuario/roles/DockerRootless/CLAUDE.md).
