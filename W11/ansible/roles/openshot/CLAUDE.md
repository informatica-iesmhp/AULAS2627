# Rol `openshot`

## Qué hace
Instala **OpenShot Video Editor** con Chocolatey (`openshot`), fijando
`openshot_version` (por defecto `3.5.1`).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `openshot_version` (vaciar para la última).

## Notas
- Si el id del paquete en Choco fuese `openshot-video-editor` en alguna versión,
  ajustar el `name`. Alternativa: winget `OpenShot.OpenShot`.
