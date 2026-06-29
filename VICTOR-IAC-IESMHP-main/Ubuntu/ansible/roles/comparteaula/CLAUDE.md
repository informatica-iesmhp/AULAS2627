# Rol `comparteaula` (unificado)

## Qué hace
Rol **unificado** de NFS que sustituye a `comparteaula32` y `comparteaula72`. Detecta automáticamente el aula y decide si el equipo es **servidor** o **cliente** NFS, sin necesidad de un rol distinto por aula.

### Lógica
1. Calcula del hostname (`AULA-NN`): `aula_equipo` (prefijo) y `numero_equipo` (sufijo).
2. Calcula `aula_id` = **tercer octeto** de la IP (`10.0.XX.y` → `XX`).
3. Aborta (`fail`) si `aula_id` no está en el diccionario `aulas` de `defaults/main.yml`.
4. Carga `config_aula = aulas[aula_id]`.
5. **Servidor NFS**: solo si `numero_equipo == "00"` **y** `config_aula.es_servidor_nfs`. Instala `nfs-kernel-server`, crea la carpeta compartida + enlace simbólico, escribe `/etc/exports`, `exportfs -a`, reinicia el servicio y abre el puerto NFS en UFW para la subred.
6. **Cliente NFS**: todos los demás equipos (sufijo ≠ 00, o aulas sin servidor propio → NAS externo). Instala `nfs-common`, crea el punto de montaje y añade la entrada a `/etc/fstab` montándola.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` — diccionario `aulas`:
  - `"72"` (IABD): servidor propio en el equipo `-00` (`10.0.72.120`), comparte `/home/ComparteProfesor` → `/ComparteProfesor`, RW.
  - `"32"` (SMRD): **sin** servidor propio; todos clientes de un NAS (`10.0.32.253`), monta `/mnt/nasFAST` en **solo lectura**.

## Cómo añadir un aula nueva
Editar el diccionario `aulas` en `defaults/main.yml` añadiendo la clave del tercer octeto con sus campos (`es_servidor_nfs`, `nfs_server_ip`, `nfs_server_path`, `nfs_mount_point`, `nfs_mount_options`, y para servidor `carpeta_nfs` + `nfs_export_subnet`). No hay que tocar `tasks/main.yml`.

## Notas
- Actualmente **comentado** en `roles.yaml` (se prueba antes de activarlo en producción).
- Reemplaza a los roles legacy `comparteaula32` / `comparteaula72`.
- Útil: `showmount -e <ip>` para ver lo exportado por un servidor NFS.
