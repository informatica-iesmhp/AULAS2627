# Rol `comparteaula32` (legacy — aula SMRD)

## Qué hace
Versión **antigua/específica** del rol de NFS para el aula **SMRD (subred 10.0.32.x)**. Configura **únicamente cliente** NFS contra un NAS externo (no hay servidor en el aula):

1. Calcula `numero_equipo`/`aula_equipo` del hostname.
2. Instala `nfs-common`.
3. Crea el punto de montaje si no existe.
4. Añade la entrada a `/etc/fstab` y monta el recurso del NAS.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` — cliente fijo:
  - `nfs_server_ip: 10.0.32.253`
  - `nfs_server_path: /mnt/DiscosRapidos/PruebaRapidosX3`
  - `nfs_mount_point: /mnt/nasFAST`
  - `nfs_mount_options: ro,defaults,_netdev` (solo lectura)

## Estado
- **Legacy**: sustituido por el rol unificado [`comparteaula`](../comparteaula/CLAUDE.md), que detecta el aula por IP. Se conserva como referencia/fallback.
- No tiene bloque de servidor (el aula SMRD usa NAS).
