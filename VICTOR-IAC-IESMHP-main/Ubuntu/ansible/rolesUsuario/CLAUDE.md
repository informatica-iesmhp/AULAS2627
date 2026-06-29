# CLAUDE.md — `rolesUsuario` (configuración por usuario)

Esta carpeta agrupa las **configuraciones que TODO usuario debería tener** en su
propio perfil. A diferencia de `roles/` (roles de Ansible que se aplican **como
root** sobre el equipo durante el primer arranque), aquí los scripts/roles se
ejecutan **como el usuario** y tocan su `$HOME` (`~/.ssh`, dotfiles, ajustes de
escritorio, etc.).

| Carpeta hermana | Se ejecuta como | Ámbito |
|-----------------|-----------------|--------|
| `roles/`        | root (Ansible)  | Sistema: software, drivers, NFS, claves SSH de root |
| `rolesUsuario/` | el propio usuario | Perfil personal: claves SSH del usuario, configuración de entorno |
| `pruebas/`      | —               | Experimentación, no forma parte del despliegue |

> **Estado**: carpeta nueva (2026-06-08), en construcción. Todavía no está
> enganchada a `roles.yaml` ni a `3-SetupPrimerInicio.sh`; los scripts y el
> playbook se lanzan manualmente mientras se prueban.

---

## Contenido

### `rolesUsuario.yaml` — playbook por usuario
Playbook Ansible análogo a `../roles.yaml` pero **scoped al perfil del usuario**:
`hosts: localhost`, `connection: local`, **`become: no` global**. Solo las tareas
que necesitan root usan `become: yes` puntual (por eso se lanza con `-K`). Sus
roles viven en `rolesUsuario/roles/`.

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario
ansible-playbook -i localhost, --connection=local -K rolesUsuario.yaml
```

Roles actuales:

| Rol | Estado | Qué hace |
|-----|--------|----------|
| [`DockerRootless`](roles/DockerRootless/CLAUDE.md) | ✅ activo (1º) | Completa Docker **rootless** para el usuario actual (socket en `/run/user/<uid>/docker.sock`). La parte de sistema la hace [`../roles/Docker`](../roles/Docker/CLAUDE.md) como root |

### `0-ConfiguracionInicial.sh`
Configuración por usuario en **dos partes**. **Se ejecuta como el usuario, no
como root** (aborta si detecta `uid 0`). Es idempotente.

**PARTE 1 — SSH "auto" (login a sí mismo):**

1. Asegura `~/.ssh` con permisos `0700`. **Self-heal de propiedad**: si
   `~/.ssh` o `authorized_keys` pertenecen a root (caso habitual en equipos ya
   provisionados, donde el instalador escribió las claves como root sin
   `chown`), el script lo detecta (`[ -O ... ]`) y reasigna la propiedad al
   usuario con `sudo chown -R` (el contenido —claves de admin/profes— se
   conserva). Si falta `sudo`, indica el comando exacto a ejecutar y aborta.
2. Si el usuario **no tiene** par de claves, genera `~/.ssh/id_ed25519`
   (ed25519, sin passphrase, comentario `usuario@hostname`). Si ya existe, no
   lo regenera.
3. Añade la clave pública a `~/.ssh/authorized_keys` (`0600`) para permitir el
   **login a sí mismo**.
4. Registra `localhost` / `127.0.0.1` / `$(hostname)` en `~/.ssh/known_hosts`
   con `ssh-keyscan`.
5. Verifica la conexión con `ssh localhost "exit 0"` (guarda el resultado en
   `SSH_OK`, ya **no** sale aquí: continúa a la PARTE 2).

**PARTE 2 — Docker rootless para ESTE usuario (añadida 2026-06-09):**

Equivalente en bash al rol [`DockerRootless`](roles/DockerRootless/CLAUDE.md),
pero **autosuficiente**: da por hecha la parte de sistema (rol
[`../roles/Docker`](../roles/Docker/CLAUDE.md), como root) y completa lo que cabe
en permisos del usuario, resolviendo lo que falta con `sudo`.

6. **Comprueba la parte de sistema**: si no existe
   `dockerd-rootless-setuptool.sh`, avisa (hay que aplicar `roles/Docker` como
   root antes) y sale `2`.
7. **subuid/subgid**: si el usuario no tiene rango en `/etc/subuid`+`/etc/subgid`
   (sin ellos el daemon rootless no arranca), lo asigna **escribiéndolo a
   fichero** (rango único, sin solape) — **NO** con `usermod --add-subuids`, que
   solo conoce `/etc/passwd` y **falla con usuarios del dominio** (SSSD). Si el
   rol `roles/Docker` dejó su helper `/usr/local/sbin/iac-docker-rootless-prep.sh`
   (subuid a fichero + lingering, ver [`../roles/Docker`](../roles/Docker/CLAUDE.md)),
   delega en él; si no, lo hace inline (vía `sudo tee`).
8. **Lingering**: `sudo loginctl enable-linger <usuario>` para que el daemon de
   usuario arranque en el boot sin sesión gráfica (y exista `/run/user/<uid>`).
   Luego espera (hasta 10 s) a que el gestor systemd de usuario monte
   `XDG_RUNTIME_DIR`.
8b. **`nf_tables`** (paso 2.3b, añadido 2026-06-17): si el módulo no está
   cargado (`lsmod`), lo carga vía `sudo modprobe nf_tables`. Sin él, el
   `dockerd-rootless-setuptool.sh install` del paso siguiente aborta con
   *"Missing system requirements … modprobe nf_tables"*. En el flujo automático
   lo deja cargado el rol [`../roles/Docker`](../roles/Docker/CLAUDE.md) (paso
   3b: modules-load.d + hook PAM); aquí es la red de seguridad del lanzamiento
   manual en un equipo recién instalado.
9. **Instala el daemon rootless del usuario**: `dockerd-rootless-setuptool.sh
   install` (idempotente: se salta si ya existe
   `~/.config/systemd/user/docker.service`).
10. **`~/.bashrc`**: añade un bloque marcado
    (`# >>> IAC-IESMHP DockerRootless >>>`) con `export PATH=/usr/bin:$PATH` y
    `export DOCKER_HOST=unix:///run/user/<uid>/docker.sock`. Mismo formato que el
    rol `DockerRootless` (que usa `blockinfile`), por lo que **no se duplica**.
11. **Arranca el servicio**: `systemctl --user enable --now docker.service` y
    verifica con `docker info`.

> **Por qué un usuario NUEVO falla** con
> `failed to connect to the docker API at unix:///var/run/docker.sock`: el daemon
> de **sistema** está desactivado a propósito (modo rootless). Si el usuario
> nunca completó la PARTE 2, no tiene `DOCKER_HOST` ni daemon de usuario, así que
> el cliente cae al socket de sistema inexistente. La PARTE 2 lo corrige. Tras
> ejecutarla hay que **abrir un terminal nuevo** (para que `~/.bashrc` exporte
> `DOCKER_HOST`).

**Códigos de salida**: `0` = todo OK (SSH verificado **y** `docker info`
respondiendo) · `1` = error duro (lanzado como root o fallo al generar la clave)
· `2` = parte(s) configurada(s) pero no verificada(s): SSH pendiente (sshd no
disponible) o falta la parte de sistema de Docker · `3` = fallo en la PARTE 2
(no se pudo asignar subuid/subgid o falló `dockerd-rootless-setuptool.sh`).

**Uso**:
```bash
bash 0-ConfiguracionInicial.sh        # como el usuario actual
```

**Relación con el rol `certificados`**: aquel hace lo mismo que la PARTE 1 pero
**para root** (`/root/.ssh`), vía Ansible. La PARTE 2 es la versión en bash del
rol [`DockerRootless`](roles/DockerRootless/CLAUDE.md). Ver también
[../roles/certificados/CLAUDE.md](../roles/certificados/CLAUDE.md).

---

## Convenciones de esta carpeta

- **Numeración**: los scripts llevan prefijo de orden (`0-`, `1-`, …) según la
  secuencia en que deben ejecutarse.
- **Idempotencia**: relanzar cualquier script no debe duplicar entradas ni
  romper configuración existente.
- **Nunca como root**: estos scripts configuran el perfil del usuario; si
  necesitan privilegios deben pedirlos puntualmente, no ejecutarse enteros como
  root.

## Por hacer
- Enganchar la ejecución al despliegue (¿perfil de `/etc/skel`, autostart en el
  primer login del usuario, o un rol Ansible que itere sobre los usuarios?).
- Dotfiles / ajustes de GNOME comunes.
