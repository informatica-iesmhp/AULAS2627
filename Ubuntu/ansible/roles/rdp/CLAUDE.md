# Rol `rdp`

## Contexto
Sustituye al antiguo rol **`xrdp`**. En **Ubuntu Desktop 26.04** ya no tiene
sentido instalar el paquete `xrdp`: GNOME trae un **servidor RDP nativo**
(`gnome-remote-desktop`, instancia *system*). Este rol lo deja accesible por
RDP de forma desatendida.

**`grdctl` NO se usa para configurar** (solo para leer estado). En
gnome-remote-desktop 50 + VM sin TPM, `grdctl --system rdp set-tls-*/enable`
solo persistía con el daemon vivo y se perdía en el primer arranque (ver bugs
abajo). En su lugar el rol **escribe directamente los dos ficheros de
configuración**, que son texto plano y deterministas.

## Qué hace
1. Instala el paquete **`gnome-remote-desktop`**.
2. **PolicyKit — que los popups de autenticación admin no se bloqueen**:
   despliega `rdp_polkit_rules_file`
   (`/etc/polkit-1/rules.d/49-allow-user-admin-rdp.rules`, desde
   `templates/49-allow-user-admin-rdp.rules.j2`). Concede directamente
   (`polkit.Result.YES`, **sin diálogo**) a los miembros de
   `rdp_polkit_admin_group` (`sudo`) las acciones cuyo `action.id` empieza por
   alguno de los prefijos de `rdp_polkit_admin_actions` (cuentas/usuarios,
   packagekit, systemd1, NetworkManager, timedate1, locale1, hostname1,
   color-manager, udisks2, GNOME control-center). `polkitd` recarga `rules.d`
   solo (sin `daemon-reload` ni reinicio de polkit → no cuelga el primer
   arranque, ver bugs 2026-05-17).
3. Crea `rdp_tls_dir` (`/etc/gnome-remote-desktop`).
4. Genera el **certificado TLS autofirmado** (`tls.key`+`tls.crt`) con `openssl`
   **solo si no existe** (`creates:`), válido `rdp_cert_days` días; propietario
   `gnome-remote-desktop:gnome-remote-desktop`, modo `0600`.
5. Despliega **`/usr/local/sbin/iac-rdp-config.sh`** (desde
   `templates/iac-rdp-config.sh.j2`, `no_log`) que escribe de forma
   determinista:
   - `/etc/gnome-remote-desktop/grd.conf` → `enabled=true` + rutas TLS
     (owner `gnome-remote-desktop`, `0664`).
   - `…/.local/share/gnome-remote-desktop/credentials.ini` → usuario/contraseña
     en formato GVariant (owner `gnome-remote-desktop`, `0600`).
6. Despliega `iac-rdp-config.service` (desde `files/iac-rdp-config.service`):
   `oneshot`, `Wants=gnome-remote-desktop.service`,
   `Before=gnome-remote-desktop.service`, `WantedBy=multi-user.target`. Lo
   **habilita creando el symlink `.wants` a mano** (módulo `file`, no
   `systemd`/`daemon-reload`/`enable` — ver bugs 2026-05-17). En cada arranque
   reafirma los ficheros **y arrastra (`Wants=`) al daemon RDP** ordenado
   después (mismo patrón que `iac-gdm-noautologin.service`).
7. Lee `grdctl --system status` y, **solo si el RDP no está ya habilitado con
   las rutas TLS correctas**: para el daemon → ejecuta `iac-rdp-config.sh` →
   arranca el daemon (con el daemon parado nadie puede pisar `grd.conf`).
8. Asegura `gnome-remote-desktop.service` (instancia *system*) `started` **solo
   para este arranque** (`state: started`, **sin `enabled`** — el arranque
   automático lo da `iac-rdp-config.service` con `Wants=`; `systemctl enable`
   desde Ansible se cuelga en el primer arranque).
9. **Verifica** con `grdctl --system status` que quedó `enabled` con las rutas
   TLS; si no, el play **falla** (no termina "ok" con el RDP apagado).

## Estructura
- `tasks/main.yml`
- `templates/iac-rdp-config.sh.j2` — script que escribe `grd.conf` +
  `credentials.ini` (usa `rdp_username`/`rdp_password`/`rdp_tls_dir`/
  `rdp_creds_dir`).
- `files/iac-rdp-config.service` — unidad systemd `Before=gnome-remote-desktop`.
- `templates/49-allow-user-admin-rdp.rules.j2` — regla PolicyKit que concede
  las acciones admin (sin diálogo) al grupo `rdp_polkit_admin_group` para los
  prefijos de `rdp_polkit_admin_actions`.
- `handlers/main.yml` — **sin handlers** (el de reinicio se eliminó el
  2026-05-16; reintroducía la carrera que perdía la config).
- `defaults/main.yml`:
  - `rdp_username` / `rdp_password` — credenciales RDP (por defecto
    `ubuntu` / `ubuntu`).
  - `rdp_tls_dir` — directorio cert + `grd.conf` (`/etc/gnome-remote-desktop`).
  - `rdp_creds_dir` — directorio de `credentials.ini`
    (`/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop`).
  - `rdp_cert_days` (3650) / `rdp_cert_subject` (`/CN=gnome-remote-desktop`).
  - `rdp_polkit_rules_file` — destino de la regla PolicyKit
    (`/etc/polkit-1/rules.d/49-allow-user-admin-rdp.rules`).
  - `rdp_polkit_admin_group` (`sudo`) — grupo al que se conceden las acciones.
  - `rdp_polkit_admin_actions` — lista de **prefijos** de `action.id`
    permitidos sin diálogo (ampliar/recortar aquí según necesidades de aula;
    es el punto donde se afina el compromiso seguridad/comodidad).

## Estado / Notas
- **Activo** en `roles.yaml` (sustituye a la línea comentada `#- xrdp`).
- **Idempotente**: el certificado solo se genera si falta; el ciclo
  parar→escribir→arrancar solo corre si `status` no muestra el RDP ya
  habilitado con las rutas TLS correctas. El script y los ficheros son
  idempotentes (mismo contenido = sin cambios).
- **Limitación**: `rdp_password` no debe contener comillas simples ni barras
  invertidas (se interpola en el GVariant de `credentials.ini`). Para
  `ubuntu`/`ubuntu` por defecto no hay problema.
- **PolicyKit (compromiso seguridad/comodidad)**: la regla concede las
  acciones admin **sin pedir contraseña** a todo el grupo `sudo` (no solo evita
  que el popup se bloquee: lo elimina). Es lo pedido para administrar el aula
  por RDP sin fricción; si se quiere endurecer, cambiar en la plantilla
  `polkit.Result.YES` por `polkit.Result.AUTH_ADMIN_KEEP` (pide la contraseña
  admin una vez y la recuerda) y/o recortar `rdp_polkit_admin_actions`.
- Es la instancia **system** del servidor, independiente de que haya o no
  sesión gráfica iniciada — adecuado para el primer arranque desatendido.
- Cambiar usuario/contraseña: sobrescribir `rdp_username`/`rdp_password` por
  inventario, `-e` o `vars:` en `roles.yaml`.

### Historial de bugs (no repetir)
- **2026-05-16 — RDP `disabled` tras el primer reboot (handler restart)**: los
  `grdctl --system` corrían con el daemon vivo; escribían `grd.conf` pero el
  daemon mantenía estado vacío en memoria y el handler que reiniciaba al final
  del play hacía que el daemon viejo volcara ese estado vacío sobre `grd.conf`.
  1er intento de fix: `parar → grdctl set-*/enable → arrancar` + verificación.
- **2026-05-17 — el 1er fix tampoco bastó (parar el daemon rompe `grdctl`)**:
  con el daemon **parado**, `grdctl --system rdp set-credentials` persiste
  (almacén GKeyFile propio) pero `set-tls-*`/`enable` **no** (necesitan el
  daemon vivo) → quedaba `Status: disabled`, `TLS (null)`, `Password: hidden`,
  y la verificación hacía `failed=1` (vscode y posteriores no se ejecutaban).
  **Fix**: no usar `grdctl` para configurar; **escribir directamente**
  `grd.conf` y `credentials.ini` (contenido capturado de una máquina donde
  funcionó y persistió tras reboot) + `iac-rdp-config.service` que los
  reafirma `Before=gnome-remote-desktop` en cada arranque.
- **2026-05-17 (2) — cuelgue al habilitar `iac-rdp-config.service`
  (`daemon_reload`)**: el módulo `systemd` con `daemon_reload` →
  `systemctl daemon-reload` dentro de `3-SetupPrimerInicio.service` se bloquea.
  **Fix**: habilitar el unit con el módulo `file` (symlink
  `multi-user.target.wants/…`, sin `systemctl`/`daemon-reload`); `WantedBy=`
  pasa a `multi-user.target`.
- **2026-05-17 (3) — el cuelgue se movió a `Asegurar … enabled: true`**:
  resuelto (2), el play avanzó por todo el bloque (`grdctl status` salió
  `enabled` y persistió tras reboot) pero se volvió a colgar en la tarea
  siguiente, `systemd: state: started, enabled: true` sobre
  `gnome-remote-desktop.service`. Patrón confirmado: el módulo `systemd`
  ejecutando **`systemctl enable`** (igual que `daemon-reload`) se cuelga en el
  primer arranque dentro de `3-SetupPrimerInicio.service`; `stop`/`started`
  (sin `enabled`) **no** cuelgan. En el run viejo no pasaba porque
  `gnome-remote-desktop.service` ya venía `enabled` (enable = no-op). **Fix**:
  quitar `enabled: true` (queda solo `state: started` para este arranque);
  `iac-rdp-config.service` añade `Wants=gnome-remote-desktop.service` para
  arrastrar el daemon en cada arranque → no se necesita `systemctl enable`
  desde Ansible.
