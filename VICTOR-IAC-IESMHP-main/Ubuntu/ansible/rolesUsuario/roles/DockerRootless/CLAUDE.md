# Rol `DockerRootless`

## Qué hace
Completa **Docker en modo rootless** para el **usuario que ejecuta el playbook**
(no para root), **sin permisos root**. El daemon corre dentro del namespace de
usuario: sin privilegios, con el socket en `/run/user/<uid>/docker.sock`.

Es la **contrapartida por usuario** del rol de sistema
[`roles/Docker`](../../../../roles/Docker/CLAUDE.md): aquel hace toda la parte que
requiere root (repo, paquetes, subuid/subgid, lingering, desactivar el daemon de
sistema); **este solo hace lo que cabe en los permisos del usuario**.

Sigue la guía oficial <https://docs.docker.com/engine/security/rootless/>. Es el
primer rol de `rolesUsuario/` y se invoca desde
[`../../rolesUsuario.yaml`](../../rolesUsuario.yaml) (`become: no`).

## Reparto de responsabilidades (root vs usuario)

| Parte | Rol | Se ejecuta como |
|-------|-----|-----------------|
| Repo + paquetes, daemon de sistema, subuid/subgid, lingering | `roles/Docker` | root |
| `dockerd-rootless-setuptool.sh`, `DOCKER_HOST`, `systemctl --user` | **`DockerRootless`** (este) | el propio usuario |

## Pasos (tasks/main.yml)
1. **Aborta si uid 0** — el rol es para un usuario normal, no root.
2. **Verifica prerrequisitos de sistema**: que `dockerd-rootless-setuptool.sh`
   exista (lo instala `roles/Docker`); si falta, aborta indicando que se aplique
   antes ese rol. Avisa también si el usuario no tiene rango en `/etc/subuid`.
3. **`dockerd-rootless-setuptool.sh install`** (COMO el usuario): crea la unit
   `~/.config/systemd/user/docker.service`. Idempotente (se salta si la unit ya
   existe).
4. **`~/.bashrc`**: exporta `PATH=/usr/bin:$PATH` y
   `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` (bloque marcado, idempotente).
5. **`systemctl --user enable --now docker`** + verificación final con
   `docker info`.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` — solo usuario/home/uid (de los facts). Las listas de
  paquetes, el rango de subids y el flag de desactivar el daemon de sistema
  viven ahora en `roles/Docker`.

## Variables (`defaults/`)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `dr_user` / `dr_user_uid` / `dr_user_home` | facts del usuario | Quién recibe el Docker rootless |

## Uso
```bash
# 1) Una vez, como root (parte de sistema):
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i localhost, --connection=local roles.yaml --tags docker

# 2) Como el USUARIO (parte de perfil):
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario
ansible-playbook -i localhost, --connection=local rolesUsuario.yaml --tags docker
```
Tras instalarlo, en una **sesión nueva** del usuario (para que `~/.bashrc`
exporte `DOCKER_HOST`):
```bash
docker run --rm hello-world
```

## Issues conocidos
- **`docker info` falla justo tras la instalación**: el bus/manager systemd del
  usuario puede no estar listo en la misma ejecución (sobre todo si el lingering
  se acaba de habilitar y no hay sesión activa). El servicio queda `enabled`; se
  resuelve al reiniciar la sesión del usuario o el equipo. La tarea de
  verificación es `failed_when: false` para no abortar el playbook por esto.
- **Falta la parte de sistema**: si no se aplicó `roles/Docker` antes, el rol
  aborta en la comprobación de `dockerd-rootless-setuptool.sh` con un mensaje que
  indica el comando a ejecutar.
- **No enganchado al despliegue todavía**: `rolesUsuario.yaml` se lanza a mano.
  Pendiente decidir cómo integrarlo en el primer arranque (ver
  [`../../CLAUDE.md`](../../CLAUDE.md) → "Por hacer").

## Relación con otros roles
- [`roles/Docker`](../../../../roles/Docker/CLAUDE.md) hace la instalación de
  **sistema** (como root) que este rol da por hecha. Sustituye al antiguo rol
  `contenedores` (borrado), que estaba incompleto y comentado.
