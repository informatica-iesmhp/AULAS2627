# Rol `obs`

## Qué hace
Instala **OBS Studio** desde los repositorios apt configurados:

1. Comprueba si existe `/usr/bin/obs` y, si está, obtiene la versión con `obs --version`.
2. Consulta la versión candidata en apt (`apt-cache policy obs-studio`).
3. Si no se pasó `obs_version` por variable, usa la candidata del repositorio.
4. Instala `obs-studio={{ obs_version }}*` **solo si** no está instalado o la versión instalada no coincide con la objetivo.

## Estructura
- `tasks/main.yml`
- Sin `defaults/`: `obs_version` es opcional y se puede pasar por línea de comandos o desde `roles.yaml` (`vars: obs_version: "30.0.2"`).

## Notas
- Bug menor en el nombre de una tarea: dice "Comprobar si el binario de VS Code existe" pero comprueba `/usr/bin/obs` (copy-paste del rol `vscode`).
- Bloques comentados al final: eliminar el PPA de OBS tras instalar (no activo).
- Por defecto instala la **última versión disponible** en el proxy apt del aula.
