# Rol `vmware`

## Qué hace
Instala **VMware Workstation** desde un instalador `.bundle` (no desde repositorio):

1. Comprueba si `vmware --version` responde y extrae la versión instalada.
2. Si no está instalado o la versión no coincide con `vmware_version`:
   - Copia el `.bundle` desde la ruta `vmware_bundle_path` (carpeta NFS remota mapeada) a `/tmp`.
   - Lo hace ejecutable.
   - Ejecuta el instalador en modo desatendido: `--eulas-agreed --required --console`.

## Estructura
- `tasks/main.yml` (versión básica: "instala y punto")
- `defaults/main.yml`:
  - `vmware_version: "17.6.4"`
  - `vmware_bundle_path: "/ComparteProfesor/Soft/VMware-Workstation-Full-17.6.4-...bundle"` — depende de que el recurso NFS `ComparteProfesor` esté montado (rol `comparteaula`).

## Issues conocidos
- **Comentado** en `roles.yaml`: el módulo de kernel de VMware **pide compilarse (como sudo) en el primer arranque**; hay que evitar esa interacción antes de activarlo en producción.
- `remote_src: true` → el `.bundle` debe existir **ya en el equipo remoto** (vía NFS), no se sube desde el controlador.
- TODO en el código: detección de instalación más limpia, redes virtuales por usuario, y carpeta común de descarga del bundle (o no ejecutar si no está disponible).
- Dependencia implícita: requiere el NFS de `comparteaula` montado para encontrar el bundle.
