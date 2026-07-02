# Rol `flatpak`

## Qué hace
Instala el **soporte de Flatpak** en el equipo y registra el repositorio
**Flathub** a nivel de sistema, dejando el equipo listo para instalar
aplicaciones Flatpak (desde GNOME Software o por línea de comandos).

1. Instala los paquetes `flatpak` y `gnome-software-plugin-flatpak` (este
   último integra las apps Flatpak en GNOME Software / "Centro de Software").
2. Comprueba los remotos ya configurados con `flatpak remotes --system`.
3. Añade el remoto `flathub` (`https://flathub.org/repo/flathub.flatpakrepo`)
   con `remote-add --if-not-exists` **solo si** no estaba presente.

## Estructura
- `tasks/main.yml`
- Sin `defaults/`: el rol no necesita variables.

## Notas
- **Caché apt**: usa `update_cache: false` porque `roles.yaml` ya refresca la
  caché una sola vez en `pre_tasks` (convención del proyecto).
- **Idempotencia**: `remote-add --if-not-exists` no falla si Flathub ya está;
  además el `changed_when`/`when` evita marcar `changed` espurio comprobando
  antes la salida de `flatpak remotes`.
- El remoto se añade a nivel de **sistema** (`--system`), no por usuario, para
  que esté disponible para todas las cuentas del equipo.
- Tras aplicar el rol, instalar apps con, p. ej.:
  `flatpak install flathub org.videolan.VLC`. Puede requerir cerrar y reabrir
  la sesión para que GNOME Software muestre el origen Flathub.
