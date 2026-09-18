# Carpeta compartida `comparte-aula` en IF01/IF02/IF03

**Fecha:** 2026-09-18 (varias correcciones el mismo día, ver historial abajo)
**Contexto:** configuración final confirmada de las cuatro aulas —

| Aula | Disco A (sistema) | Disco B (datos) |
|---|---|---|
| IF01 / IF02 / IF03 | SSD, dos particiones ext4: `/` y `/home` | HDD magnético, ext4, montado en `/datos` |
| IF04 (ya desplegada, funciona) | NVMe: `/` en ext4 + `/home` en ZFS (`rpool_home`) | SSD, ZFS con datasets `/datos/plantillas` y `/datos/iso` |

Este documento cubre solo IF01/IF02/IF03 (ext4). IF04 usa un esquema de
carpetas distinto (`/datos/plantillas` y `/datos/iso` directamente, sin
`comparte-aula` ni este reparto de permisos) y no se toca aquí.

## Diseño final

`comparte-aula` vive físicamente en el segundo disco del **equipo del
profesor únicamente** — no en cada equipo del aula. Por eso la entrega
son dos artefactos distintos, no un solo playbook:

### 1. `preparar_comparte_aula_profesor.sh`

Script bash, se ejecuta a mano UNA vez por aula, en el propio equipo del
profesor (`sudo ./preparar_comparte_aula_profesor.sh`):

1. Formatea `/dev/sdb` en ext4 (etiqueta `DATOS`) y lo monta en `/datos`
   — idempotente (no reformatea si ya está preparado).
2. Deja `/datos` en `0777` (a petición expresa: el profesorado necesita
   poder escribir directamente en la raíz del disco).
3. Crea `comparte-aula`, `ISO` y `MV` con ACL POSIX:
   - `comparte-aula` (raíz): profesores y alumnos, lectura+escritura.
   - `ISO` y `MV`: profesores lectura+escritura, alumnos solo lectura.
4. Instala y configura Samba, publicando `[comparte-aula]` en la red
   **en modo invitado (guest)** — ver decisión de autenticación abajo.

### 2. `06_montar_comparte_aula_alumnos.yml`

Playbook de Ansible, dirigido solo a los equipos de ALUMNOS (nunca al
del profesor, que ya tiene acceso local). Monta el recurso ya publicado
en `/comparte-aula` con la opción `guest` — sin usuario ni contraseña.
Se lanza con `-e profesor_host=IF0X-00` (sin valor por defecto, a
propósito, para no montar contra el profesor equivocado).

## Decisión de autenticación: invitado (guest), no cuenta de dominio

Se evaluaron tres opciones para el acceso por red a `comparte-aula`:

1. **Cuenta de dominio dedicada** (p. ej. `svc-comparte-aula`, miembro
   de `alumnos`) — descartada: exige dar de alta la cuenta en el AD,
   gestionar su contraseña (caducidad, bajas), y **no serviría para un
   equipo fuera del dominio** — el caso de uso que decidió esto: un
   profesor necesitando copiar algo a la carpeta desde su portátil
   personal, no unido al dominio, en caso de urgencia.
2. **Reutilizar `ansible-admin`** — descartada: es una cuenta LOCAL
   (creada con `useradd` por `preparaclienteansibleadmin.sh`), no existe
   en el AD, así que no autenticaría contra un recurso `security = ads`;
   y aunque autenticara, tiene sudo sin contraseña en todos los equipos
   del aula — mala idea meter esa credencial en un fichero distribuido a
   todos los PCs de alumnos.
3. **Invitado (guest), mapeado a una cuenta LOCAL del equipo del
   profesor** (`invitado-comparte-aula`, sin contraseña, sin shell de
   login) — **la elegida**. Sin usuario ni contraseña que gestionar, sin
   depender del dominio en ningún lado de la conexión (ni servidor ni
   cliente), válido también para equipos ajenos al dominio. A cambio,
   cualquier dispositivo que llegue a la subred de esa aula concreta
   (p. ej. `10.0.16.0/24` para IF01) accede sin autenticarse, con el
   mismo nivel que un alumno (escritura en la raíz, solo lectura en
   `ISO`/`MV`) — sin trazabilidad de quién hizo qué. Se valoró y se
   aceptó ese riesgo, acotado a la subred de cada aula.

En Samba: `guest ok = yes`, `guest only = yes` (fuerza invitado siempre,
incluso si alguien manda credenciales) y `guest account =
invitado-comparte-aula`, solo en el recurso `[comparte-aula]` — el resto
de la configuración de dominio (`security = ads`, etc.) se deja intacta
por si en el futuro se añaden otros recursos que sí necesiten
autenticación real.

## Pendiente / a verificar antes de lanzarlo a un aula entera

- **Nombres de grupo**: confirmar con `getent group profesores` /
  `getent group alumnos` en un equipo que ya funcione (p. ej. IF04) —
  el script los tiene como variables editables si no coinciden.
- **Probar primero en un equipo piloto**: el script del profesor, en su
  propia máquina (no hay "aula entera" que pilotar ahí); el playbook de
  alumnos con `--limit` en un equipo antes de extenderlo al resto.
- **Confirmar el nombre/IP de cada equipo de profesor** (`IF01-00`,
  `IF02-00`, `IF03-00` según `macs.csv`) al lanzar
  `06_montar_comparte_aula_alumnos.yml` con `-e profesor_host=...`.

## Historial de correcciones (18/09)

1ª versión: un único playbook `05_comparte_aula.yml` con `hosts: all`,
asumiendo que cada equipo tenía su propio `comparte-aula` — incorrecto,
descartado.
2ª versión: separación en script (profesor) + playbook (alumnos), con
cuenta de servicio de dominio para el montaje — corregido tras aclarar
permisos de `/datos` (0777) y que `comparte-aula` también necesita
escritura para alumnos.
3ª versión (actual): la cuenta de servicio de dominio se sustituye por
acceso de invitado con cuenta local, tras valorar que un profesor podría
necesitar copiar algo desde un equipo fuera del dominio.
