# Rol `virtualbox`

## Qué hace
Instala **Oracle VirtualBox** con Chocolatey, fijando la versión `virtualbox_version`
(por defecto `7.2.10`, la de la lista del aula).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `virtualbox_version` (vaciar para instalar la última).

## Notas
- Para forzar un downgrade desde una versión más nueva ya instalada, añadir
  `allow_downgrade: yes` a la tarea.
- El Extension Pack no se instala aquí (licencia PUEL distinta). Alternativa:
  winget `Oracle.VirtualBox`.
