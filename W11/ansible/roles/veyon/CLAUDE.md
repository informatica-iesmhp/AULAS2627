# Rol `veyon`

## Qué hace
Instala **Veyon** ([veyon.io](https://veyon.io)) con Chocolatey (`veyon`), fijando
`veyon_version` (por defecto `4.10.4`). Veyon es software libre de **gestión y
monitorización de aula** (ver pantallas de los alumnos, bloquear, difundir la del
profesor, control remoto…).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `veyon_version` (vaciar para la última), `veyon_choco_name`.

## Notas / TODO
- **Roles Master vs Client**: Veyon distingue el equipo del **profesor** (Master) de
  los de los **alumnos** (servicio Veyon). Este rol instala el software en todos;
  la diferencia es de **configuración**, no de instalación.
- **Configuración desatendida**: Veyon se configura con `veyon-cli` (claves de
  autenticación, salas/aulas, ACLs). Lo idóneo es generar un fichero de config en
  el Master y distribuirlo:
  ```
  veyon-cli config import C:\ruta\veyon-config.json
  veyon-cli authkeys import teacher/public C:\ruta\teacher_public_key.pem
  ```
  Se puede ampliar el rol con tareas `win_copy` + `win_command` cuando defináis la
  config del centro (y un grupo de inventario para marcar quién es Master).
- Alternativa de instalación: winget `Veyon.Veyon`. Si el id de Choco fallara,
  Veyon también ofrece instalador `.exe` (NSIS, silencioso con `/S`) → patrón del
  rol `basex`.
