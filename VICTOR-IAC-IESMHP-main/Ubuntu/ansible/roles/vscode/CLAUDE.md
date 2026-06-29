# Rol `vscode`

## Qué hace
Instala **Visual Studio Code** descargando el `.deb` oficial de Microsoft (no usa el repositorio de Microsoft, para no contaminar las fuentes apt del equipo):

1. Comprueba si existe `/usr/bin/code` (y muestra la versión si está). Si ya está instalado, no hace nada.
2. **Copia de seguridad** de `/etc/apt` → `/etc/apt.preVSCODE.bak`.
3. Descarga el último `.deb` estable desde `code.visualstudio.com`.
4. Instala el `.deb` con `apt`.
5. Borra el `.deb` temporal.
6. **Restaura `/etc/apt`** desde la copia (deshace el repo de Microsoft que el `.deb` añade en su postinst).
7. `apt update` para regenerar la caché con las fuentes originales.

## Estructura
- `tasks/main.yml`
- Sin `defaults/`: no tiene variables; siempre instala la última versión estable.

## Notas
- El patrón backup/restore de `/etc/apt` es **deliberado**: evita que VS Code deje su repo y rompa el proxy apt del aula.
- Idempotente por la comprobación de `/usr/bin/code`.
