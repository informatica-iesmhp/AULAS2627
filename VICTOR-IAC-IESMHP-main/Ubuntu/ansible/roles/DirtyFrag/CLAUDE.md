# Rol `DirtyFrag`

## Qué hace
Evalúa y mitiga la vulnerabilidad **"Dirty Frag"** (escalada local de privilegios en el kernel Linux):

- **CVE-2026-43284** — ESP (Encapsulating Security Protocol) de IPsec.
- **CVE-2026-43500** — RxRPC (sistemas de ficheros distribuidos).

Afecta a todas las versiones de Ubuntu desde 14.04 LTS hasta 26.04 LTS. Ref:
<https://ubuntu.com/blog/dirty-frag-linux-vulnerability-fixes-available>

### Lógica
1. **Evalúa** si el equipo es susceptible:
   - mira qué módulos vulnerables (`esp4`, `esp6`, `rxrpc`) están cargados en `/proc/modules`;
   - comprueba si existe `/etc/modprobe.d/dirty-frag.conf` con la blacklist de los tres módulos.
   - **PROTEGIDO** = ningún módulo cargado **y** blacklist presente.
2. Si está **PROTEGIDO** → lo indica con un `debug` (`✅ PROTEGIDO de DirtyFrag`) y no toca nada.
3. Si **NO está protegido** → lo indica (`⚠️ NO PROTEGIDO`) y aplica la mitigación del blog de Ubuntu:
   - escribe `/etc/modprobe.d/dirty-frag.conf` con `install <mod> /bin/false` por cada módulo;
   - `update-initramfs -u -k all` (solo si el fichero cambió; tarda 2–4 min);
   - `modprobe -r` de los módulos que estuvieran cargados;
   - re-comprueba y, si algún módulo sigue cargado, avisa de **reiniciar**.

## Estructura
- `tasks/main.yml` — evaluación + mitigación idempotente.
- `defaults/main.yml` — `dirtyfrag_modulos` (lista de módulos) y `dirtyfrag_conf` (ruta del fichero).

## Notas
- **Idempotente**: si ya está protegido, no marca cambios ni regenera initramfs.
- No depende de `community.general` (usa `modprobe -r` por `command`).
- Es **mitigación**, no parche: bloquea los módulos vulnerables. Cuando lleguen los
  parches de kernel oficiales, **eliminar** `/etc/modprobe.d/dirty-frag.conf` y volver a
  ejecutar `update-initramfs -u -k all`.
- Si los módulos no se pueden descargar en caliente (están en uso), la blacklist los
  impedirá al siguiente arranque → el rol pide reiniciar.
