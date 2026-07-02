# CLAUDE.md — Configuración de equipos Windows 11 con Ansible

Despliegue de software y configuración de los equipos **Windows 11** del IES Miguel
Herrero mediante **roles de Ansible**, ejecutados **por SSH** contra el servidor
OpenSSH de Windows (cuyo shell por defecto es **PowerShell**), conectando como
usuario **Administrador**.

Es el equivalente Windows de `Ubuntu/ansible/` y sigue las **mismas convenciones**:
un rol por programa, `defaults/` para fijar versiones, un `CLAUDE.md` por rol y un
`roles.yaml` maestro.

> Software a instalar (**listado único**, sin separar por profesor): Office 365,
> Chrome, VirtualBox, Veyon, OBS, OpenShot, GIMP, ZoomIt, VS Code, Vagrant,
> Notepad++, AWS CLI, VS Community y BaseX, además de la base (Escritorio Remoto y
> Chocolatey). El servidor **OpenSSH** ya no es un rol: se instala una sola vez a
> mano (es el canal de conexión de Ansible). **VMware Workstation** está
> **comentado** en `roles.yaml`, pendiente de replantear (su paquete Choco falla).

> **Nota**: este MISMO listado de software se instala también **en local** desde
> la ISO, sin Ansible, mediante `W11/ISO/2-Aplicaciones.ps1` (winget preferente +
> chocolatey). Si cambias las apps aquí, replícalo allí (y viceversa). Ansible
> queda como vía de mantenimiento/recuperación por SSH. Ver
> [`../ISO/CLAUDE.md`](../ISO/CLAUDE.md).

---

## Cómo conecta Ansible con Windows

- **Conexión SSH**, no WinRM. El servidor OpenSSH de Windows se monta **a mano una
  sola vez** (ver [`W11/Utiles/Openssh/ProcedimientoOpenss.txt`](../Utiles/Openssh/ProcedimientoOpenss.txt)).
  **Ya no hay rol `openssh`**: al ser el canal por el que conecta Ansible, no tiene
  sentido gestionarlo desde un playbook que llega por ese mismo canal.
- En el inventario, cada equipo lleva (en `[all:vars]`):
  ```ini
  ansible_connection=ssh
  ansible_shell_type=powershell      # el DefaultShell del sshd es powershell.exe
  ansible_user=Administrador
  ```
- Autenticación por **clave pública**: la pública del equipo de control debe
  colocarse **a mano** en `%ProgramData%\ssh\administrators_authorized_keys` del
  equipo Windows (con los permisos `icacls` correctos, si no `sshd` la ignora;
  ver el procedimiento de OpenSSH).
- **No se usa `become`**: ya conectamos como Administrador.

### Requisitos en el equipo de control (Linux / WSL)
```bash
cd W11/ansible
ansible-galaxy collection install -r requirements.yml   # ansible.windows, chocolatey.chocolatey, community.windows
```

---

## `roles.yaml` — el playbook maestro

Único play: `hosts: all`, `gather_facts: yes`.

- **`pre_tasks`**: detecta el **aula** por el 3er octeto de la IP y lo guarda en
  `iac_aula` (`IABD` si `10.0.72.x`, `SMRD` si `10.0.32.x`, si no `NINGUNA`). Lo usa
  el rol `chocolatey` para fijar el proxy.
- **`vars.iac_roles`**: **listado único** de roles (sin separar por profesor). Los
  roles **base** (`chocolatey`, `basicos`, `escritorioRemoto`) van primero. Cada rol
  lleva su **propio nombre como tag**, para instalar un solo programa con
  `--tags <rol>`.
- **Continúa aunque un rol falle**: en vez de la clave `roles:`, el play recorre
  `iac_roles` en un bucle de `include_tasks: aplicar_rol.yml`, que envuelve cada rol
  en un `block`/`rescue`. Si un rol falla, se **anota** (lista `iac_roles_fallidos`)
  y se **sigue con el resto** en lugar de abortar; al final una tarea de resumen
  lista los roles que fallaron por equipo. Sigue respetando el orden de la lista y
  los `--tags`.

### Roles y su estado

| Rol | Estado | Qué hace (resumen) |
|-----|--------|--------------------|
| [`chocolatey`](roles/chocolatey/CLAUDE.md) | ✅ 1º | Instala Chocolatey + proxy de aula |
| [`basicos`](roles/basicos/CLAUDE.md) | ✅ | NuGet + comprueba winget |
| [`escritorioRemoto`](roles/escritorioRemoto/CLAUDE.md) | ✅ | Habilita RDP (registro + firewall) |
| [`energiaAltoRendimiento`](roles/energiaAltoRendimiento/CLAUDE.md) | ✅ | Plan de energía "Alto rendimiento" + desactiva la suspensión (`powercfg`) |
| [`office365`](roles/office365/CLAUDE.md) | ✅ | Microsoft 365 Apps (sin activar licencia) |
| [`chrome`](roles/chrome/CLAUDE.md) | ✅ | Google Chrome |
| [`virtualbox`](roles/virtualbox/CLAUDE.md) | ✅ | VirtualBox `7.2.10` |
| [`veyon`](roles/veyon/CLAUDE.md) | ✅ | Veyon `4.10.4` — gestión/monitorización de aula ([veyon.io](https://veyon.io)) |
| [`obs`](roles/obs/CLAUDE.md) | ✅ | OBS Studio `32.1.2` |
| [`openshot`](roles/openshot/CLAUDE.md) | ✅ | OpenShot `3.5.1` |
| [`gimp`](roles/gimp/CLAUDE.md) | ✅ | GIMP `3.2.4` |
| [`zoomit`](roles/zoomit/CLAUDE.md) | ✅ | ZoomIt (Sysinternals) |
| [`vscode`](roles/vscode/CLAUDE.md) | ✅ | Visual Studio Code `1.125` |
| [`vagrant`](roles/vagrant/CLAUDE.md) | ✅ | HashiCorp Vagrant |
| [`vmware`](roles/vmware/CLAUDE.md) | 💤 comentado | VMware Workstation Pro — el paquete Choco falla; pendiente de replantear (instalar desde el NAS) |
| [`notepadpp`](roles/notepadpp/CLAUDE.md) | ✅ | Notepad++ `8.9.6.4` |
| [`awscli`](roles/awscli/CLAUDE.md) | ✅ | AWS CLI v2 |
| [`vsCommunity`](roles/vsCommunity/CLAUDE.md) | ✅ (id 2022→2026) | Visual Studio Community |
| [`basex`](roles/basex/CLAUDE.md) | ✅ (verificar URL) | BaseX `12.4` (descarga directa + JRE) |

> Cada carpeta de rol tiene su propio `CLAUDE.md` con detalle de tareas, variables
> (`defaults/`) y TODOs.

---

## Inventario (`equiposW11.ini`)

- Grupo `[W11]` con un equipo de prueba (`W11-PRUEBA`). Plantillas comentadas para
  los grupos `[IABD]` (`.72`) y `[SMRD]` (`.32`).
- `[all:vars]` con la conexión SSH→PowerShell (ver arriba).

---

## Comandos clave

```bash
cd W11/ansible

# Probar conectividad
ansible all -i ./equiposW11.ini -m ansible.windows.win_ping

# Aplicar TODO
ansible-playbook -i ./equiposW11.ini roles.yaml

# Un solo equipo
ansible-playbook -i ./equiposW11.ini roles.yaml -l W11-PRUEBA

# Un solo programa (cada rol lleva su nombre como tag)
ansible-playbook -i ./equiposW11.ini roles.yaml --tags chrome

# Varios programas a la vez
ansible-playbook -i ./equiposW11.ini roles.yaml --tags chrome,vscode,obs

# Pasar/forzar una versión concreta a un rol
ansible-playbook -i ./equiposW11.ini roles.yaml --tags obs -e obs_version=31.0.0
```

---

## Medir el tiempo de instalación

El tiempo (total, por rol y por tarea) se obtiene con **callbacks de Ansible**,
activados en `ansible.cfg`
(`callbacks_enabled = timer, ansible.posix.profile_roles, ansible.posix.profile_tasks`).
No tocan el playbook ni los roles: imprimen un **resumen al final** de cada ejecución.

- **`timer`** (de serie): línea final con el tiempo **total** del playbook, p. ej.
  `Playbook run took 0 days, 0 hours, 6 minutes, 12 seconds`.
- **`ansible.posix.profile_roles`** (colección `ansible.posix`, en `requirements.yml`):
  **desglose por rol** ordenado, para ver cuál es el más lento.
- **`ansible.posix.profile_tasks`** (misma colección): tiempo de **cada tarea** (lo
  muestra junto a cada `ok/changed`) y, al final, el ranking de las tareas **más
  lentas**. Es el detalle más fino para optimizar (p. ej. ver qué `win_chocolatey`
  tarda más).

Los tiempos son **agregados de todos los equipos** del inventario; para medir uno
solo, ejecutar con `-l W11-PRUEBA`. El `win_ping` previo de `rolesW11.sh` queda
fuera de la medición (corre antes del playbook).

---

## Convenciones del proyecto

- **Gestor de paquetes: Chocolatey** (`win_chocolatey`) como base — es el más
  "Ansible-native" y permite **fijar versión** igual que el `apt` de Ubuntu
  (`obs-studio={{version}}` ↔ `version: "{{ obs_version }}"`). Para lo que no está
  bien en Choco se usa **winget** o **descarga directa** (patrón en el rol `basex`).
- **Versiones**: cada rol versionado tiene la versión de la lista del aula en su
  `defaults/main.yml`. Vaciar la variable (`""`) instala la última; pasarla por `-e`
  la sobreescribe. Para **bajar** de versión hace falta `allow_downgrade: yes`.
- **Detección de aula**: 3er octeto de la IP (`10.0.72.x`→IABD, `10.0.32.x`→SMRD),
  igual que en Ubuntu. Se usa para el **proxy de Chocolatey** (IABD
  `10.0.72.140:3128`, SMRD `10.0.32.119:3128`).
- **Listado único de roles** (sin separar por profesor). Cada rol lleva su nombre
  como **tag** (`--tags chrome`, `--tags vscode`…) para instalar uno o varios
  programas sueltos.
- **Idempotencia**: `win_chocolatey` ya es idempotente; los roles de configuración
  (p. ej. `escritorioRemoto`) controlan `changed_when` a mano.
- **Tolerancia a fallos**: el playbook **no aborta** si un rol falla; lo anota y
  sigue con el resto (`aplicar_rol.yml`, `block`/`rescue`). Revisar el resumen final
  para ver qué roles fallaron.

---

## TODO / pendientes de verificar

1. **`veyon`** — instala Veyon en todos los equipos; falta definir la **configuración**
   Master (profesor) vs Client (alumnos) con `veyon-cli` y un grupo de inventario.
   Ver `roles/veyon/CLAUDE.md`.
2. **`vmware`** — **comentado** en `roles.yaml` (el paquete Choco falla). Replantear:
   probablemente descargar el instalador desde una carpeta del NAS e instalarlo en
   silencio (en vez de `win_chocolatey`). El rol sigue en `roles/vmware/` como base.
3. **`vsCommunity`** — cambiar a `visualstudio2026community` cuando exista (la lista
   pide "Community 26").
4. **`basex`** — verificar la URL del ZIP (`files.basex.org/releases/12.4/BaseX124.zip`).
5. **`office365`** — la activación de licencia M365 es manual (no la hace el rol).
6. Rellenar los inventarios reales de `[IABD]`/`[SMRD]` y ajustar `ansible_user` al
   nombre real de la cuenta administradora.
7. Posible futura carpeta `rolesUsuario/` (extensiones de VS Code, dotfiles…), como
   en Ubuntu.
