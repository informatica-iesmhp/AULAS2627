# Rol `comparteaula72` (legacy — aula IABD)

## Qué hace
Versión **antigua/específica** del rol de NFS para el aula **IABD (subred 10.0.72.x)**, donde el propio equipo `-00` es el servidor:

- **Si `numero_equipo == "00"`** → servidor NFS: instala `nfs-kernel-server`, crea `/home/ComparteProfesor`, enlace simbólico a `/ComparteProfesor`, escribe `/etc/exports` para `10.0.72.0/24`, `exportfs -a`, reinicia el servicio y abre NFS en UFW.
- **Si `numero_equipo != "00"`** → cliente NFS: instala `nfs-common`, crea el punto de montaje y monta vía `/etc/fstab` el recurso del servidor `10.0.72.120`.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml`:
  - Servidor: `disco_hd: /home`, `carpeta_nfs: /home/ComparteProfesor`
  - Cliente: `nfs_server_ip: 10.0.72.120`, `nfs_server_path: /home/ComparteProfesor`, `nfs_mount_point: /ComparteProfesor`, opciones RW (`rw,hard,intr,rsize/wsize=262144,timeo=600`).

## Estado
- **Legacy**: sustituido por el rol unificado [`comparteaula`](../comparteaula/CLAUDE.md). Se conserva como referencia/fallback.
- La subred `10.0.72.0/24` está **hardcodeada** en este rol (en el unificado es `nfs_export_subnet`).
