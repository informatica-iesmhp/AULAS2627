# Carpeta compartida `comparte-aula` en IF01/IF02/IF03

**Fecha:** 2026-09-18 (diseño); 2026-10-07/08 (pruebas en IF03, causa real del fallo de montaje encontrada y corregida; validado de extremo a extremo en IF03-21)
**Contexto:** configuración final confirmada de las cuatro aulas —

| Aula | Disco A (sistema) | Disco B (datos) |
|---|---|---|
| IF01 / IF02 / IF03 | SSD, dos particiones ext4: `/` y `/home` | HDD magnético, ext4, montado en `/datos` |
| IF04 (ya desplegada, funciona) | NVMe: `/` en ext4 + `/home` en ZFS (`rpool_home`) | SSD, ZFS con datasets `/datos/plantillas` y `/datos/iso` |

Este documento cubre solo IF01/IF02/IF03 (ext4). IF04 usa un esquema de
carpetas distinto y no se toca aquí.

## Estado

| Aula | Profesor (script) | Alumnos (playbook) |
|---|---|---|
| IF03 | ✅ IF03-00 preparado (security = user) | ✅ IF03-21 validado (montaje + permisos); resto pendiente |
| IF01 | pendiente | pendiente |
| IF02 | pendiente | pendiente |

Validación en IF03-21 (08/10), como usuario no root (`ansible-admin`,
sin `become`): lista `/comparte-aula`, escribe en la raíz, y `touch` en
`ISO` da "Permiso denegado".

## Diseño final

`comparte-aula` vive físicamente en el segundo disco del **equipo del
profesor únicamente**. Dos artefactos:

### 1. `preparar_comparte_aula_profesor.sh` (equipo del profesor, a mano, una vez por aula)

1. Formatea `/dev/sdb` en ext4 (etiqueta `DATOS`) y lo monta en `/datos`
   — idempotente (no reformatea si ya está preparado).
2. `/datos` en `0777` (a petición expresa).
3. Crea `comparte-aula`, `ISO` y `MV` con ACL POSIX:
   - `comparte-aula` (raíz): profesores y alumnos, lectura+escritura.
     Uso previsto: cada profesor crea ahí la carpeta de su módulo
     (p. ej. `PROG`, `SI`, `BD`, `LMSGI` en IF03) para recoger trabajos;
     esas carpetas heredan la escritura para alumnos.
   - `ISO` y `MV`: profesores lectura+escritura, alumnos solo lectura.
4. Samba como **servidor independiente (`security = user`)**, publicando
   `[comparte-aula]` en modo invitado, mapeado a la cuenta LOCAL
   `invitado-comparte-aula`. Bloque global que inserta el script:
   ```
   workgroup = IESMHP
   security = user
   map to guest = Bad User
   guest account = invitado-comparte-aula
   ```
   Recurso: `guest ok = yes`, `guest only = yes`, `read only = no`,
   `force user = invitado-comparte-aula`, `force group = grupoprofesores`.

Grupos del AD: **`grupoprofesores`** y **`grupoalumnos`** (ya puestos
por defecto en el script).

El script **refresca siempre** sus bloques de `smb.conf` (los borra y
los reescribe, incluidos los de versiones anteriores del script), así
que relanzarlo en un equipo ya preparado lo deja al día. Muestra los
ERROR/WARNING de `testparm` en vez de silenciarlos.

### 2. `06_montar_comparte_aula_alumnos.yml` (Ansible, equipos de alumnos)

Monta `//<profesor>/comparte-aula` en `/comparte-aula` con:
`guest,vers=2.0,uid=0,gid=0,file_mode=0666,dir_mode=0777,_netdev,x-systemd.automount`.
Se lanza con `-e profesor_host=...` (de momento la IP, ver pendientes).
`file_mode=0666`/`dir_mode=0777` para que el cliente no bloquee la
escritura de un alumno normal antes de llegar al servidor; los permisos
reales los aplica el servidor (ACL de la cuenta de invitado).
En IF03-00 la copia local es `playbooks/10_montar_comparte_aula_alumnos.yml`.

Lanzamiento (desde el equipo del profesor, excluyéndolo a él):
```
ansible-playbook -i inventarios/IF03.ini playbooks/10_montar_comparte_aula_alumnos.yml \
    -u ansible-admin --limit 'all:!IF03-00' -e profesor_host=10.0.10.100
```
Comprobación rápida de permisos sin entrar en el alumno:
```
ansible -i inventarios/IF03.ini IF03-21 -u ansible-admin -m shell -a "ls /comparte-aula; touch /comparte-aula/prueba_alumno.txt && echo RAIZ-OK; touch /comparte-aula/ISO/no_deberia.txt && echo ISO-MAL || echo ISO-BLOQUEADO-OK; rm -f /comparte-aula/prueba_alumno.txt"
```

## Decisión de autenticación: invitado con cuenta local

Se descartaron cuenta de servicio de dominio (contraseña que gestionar,
no sirve fuera del dominio) y reutilizar `ansible-admin` (sudo sin
contraseña en todos los equipos). Se eligió invitado mapeado a una
cuenta LOCAL: sin credenciales, válido también desde el portátil
personal de un profesor fuera del dominio. Riesgo aceptado: cualquier
equipo de la subred del aula entra con nivel alumno, sin trazabilidad.
**Consecuencia adicional:** por red todos los alumnos son el mismo
usuario, así que cualquiera puede borrar lo que haya dejado otro en las
carpetas de módulo; no se puede evitar con permisos.

## Incidencia principal: `mount error(22): Invalid argument` (07-08/10)

**Síntoma:** desde un alumno (IF03-21), `mount -t cifs ... -o guest`
fallaba con `mount error(22)`. `dmesg` con `cifsFYI`:
`STATUS_MORE_PROCESSING_REQUIRED` → `STATUS_NOT_FOUND` →
`STATUS_INVALID_PARAMETER_MIX`. `smbclient -N -L` sí funcionaba.

**Causa real:** el Samba del profesor estaba en `security = ads` con
**winbind inactivo**. Desde Samba 4.8, `security = ads` exige winbind; en
estos equipos el dominio lo gestiona SSSD. El invitado iniciaba sesión
pero Samba rechazaba la entrada al recurso: `smbclient -N
//localhost/comparte-aula` → `tree connect failed:
NT_STATUS_INVALID_PARAMETER_MIX`.

**Arreglo:** `security = user`. El recurso es solo de invitado con
cuenta local, así que Samba no necesita el dominio; los inicios de
sesión de dominio del equipo siguen por SSSD. Si algún día se quiere
otro recurso con usuarios del AD en este equipo, habrá que unir Samba
de verdad (`net ads join` + winbind), no basta con volver a `ads`.

**Cómo se llegó (lecciones):**
- `smbclient -N -L` solo prueba el listado (IPC$), no la entrada al
  recurso: la prueba buena es `smbclient -N //servidor/recurso -c ls`,
  que reproduce el fallo en el propio servidor sin pasar por el cliente.
- `STATUS_MORE_PROCESSING_REQUIRED` (paso normal de NTLMSSP) y
  `STATUS_NOT_FOUND` (consulta DFS, normal en un Samba sin DFS) eran
  ruido; el único error real era `INVALID_PARAMETER_MIX`.
- Pistas falsas descartadas: versión SMB (`vers=3.0`→`2.0`), opciones
  `sec=`, firma SMB (`server signing = no`), Kerberos/`cifs.upcall` en
  el cliente, `/proc/fs/cifs/SecurityFlags`. Ninguna cambió el
  resultado.
- Correcciones reales por el camino (avisadas por `testparm`):
  `guest account` debe ir en `[global]`, no en el recurso; `idmap
  config * : backend = sss` no es válido (ya irrelevante con
  `security = user`).

## Otras incidencias en IF03

- **Nombres de grupo:** `profesores`/`alumnos` no existen; son
  `grupoprofesores`/`grupoalumnos`. Con `set -euo pipefail` el script
  se paraba en el paso 7 (`chown: grupo inválido`) sin llegar a Samba.
- **DNS:** `IF03-00` no resuelve desde los alumnos (`could not resolve
  address`); se usa la IP `10.0.10.100`.
- **YAML:** partir `opts:` en varias líneas con `>-` metía un espacio en
  la cadena de opciones. Va en una sola línea entre comillas.
- **Copias del script:** en IF03-00 se ejecutó por error una copia
  antigua (con `security = ads`) que deshizo el arreglo. El repositorio
  clonado está en `~/ansible-aulas/AULAS2627`; las copias de trabajo en
  `~/ansible-aulas` (script del profesor:
  `10_preparar_comparte_aula_profesor.sh`). Conviene renombrar o borrar
  las versiones viejas.
- **Samba se actualiza al lanzar el script:** `apt-get install samba`
  sube de versión si hay actualización disponible (pasó de 9.7 a 9.8 en
  IF03-00). Es normal, no afecta.

## Pendiente

- Lanzar el playbook al resto de alumnos de IF03 (`--limit 'all:!IF03-00'`).
- Reiniciar algún alumno y comprobar que `/comparte-aula` vuelve a
  aparecer solo (persistencia del montaje con `x-systemd.automount`).
- Resolución de nombres: FQDN (`IF03-00.iesmhp.local`) o `/etc/hosts`
  vía Ansible, en vez de IPs a mano.
- Repetir en IF01 e IF02 (script en su equipo de profesor + playbook).
