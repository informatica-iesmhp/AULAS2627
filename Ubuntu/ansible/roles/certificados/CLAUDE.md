# Rol `certificados`

## Qué hace
Gestiona las claves SSH del usuario **root** del equipo:

1. Crea `/root/.ssh` (0700) si no existe.
2. Genera un par `ed25519` para root (`/root/.ssh/id_ed25519`) **solo si no existe**, con comentario `root@<hostname>`.
3. Añade la clave pública recién generada a `/root/.ssh/authorized_keys` (login a sí mismo).
4. Intenta registrar el propio host en `known_hosts` conectándose por SSH a `localhost`/`$(hostname)`.
5. **Claves externas**: si existe el fichero apuntado por `external_keys_file`, lee cada línea y la añade a `authorized_keys` (claves de administradores/profesores autorizados).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` — `external_keys_file: "/root/extra_authorized_keys"` (comentada la alternativa `/opt/iesmhpMint/Autorizados.txt`).

## Avisos / TODO conocidos
- El bloque *known_hosts* (tareas 4) está marcado como problemático en el propio fichero: `ssh-keygen -F` funciona pero la conexión SSH a sí mismo puede fallar. Mantener vigilado.
- `external_keys_file` apunta a una ruta local (`/root/extra_authorized_keys`) que **no se actualiza desde GitHub** todavía (TODO en el código).
- Pendiente: opción para *eliminar* de `authorized_keys` las claves que ya no estén en el fichero externo (controlado por variable).
