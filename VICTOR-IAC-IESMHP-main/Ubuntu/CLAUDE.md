# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Propósito del proyecto

Automatización del despliegue de Ubuntu 26.04 Desktop en equipos del IES Miguel Herrero (Torrelavega). El flujo genera una ISO personalizada de Ubuntu, que al arrancar particiona los discos, copia el sistema operativo e instala GRUB sin intervención manual.

**Metodología de trabajo**: el usuario arranca la ISO en una máquina virtual (VMware), recoge los logs y los pega aquí para diagnosticar fallos y optimizar el proceso.

### Protocolo de diagnóstico (seguir en este orden)
1. Leer el fichero de cambios más reciente en `Ubuntu/RegistroDeCambios/` para saber qué se tocó en la última sesión y qué consecuencias puede haber tenido.
2. Leer el log pegado o los ficheros de log en `Ubuntu/ISO/26.04/logs/` (ficheros `*.log` y `*.steps`)
3. **Antes de proponer un fix**, cruzar cada `[ERR]` con la lista de falsos positivos conocidos documentada más abajo — muchos errores son del propio script de diagnóstico, no del sistema instalado.
4. Si el error es real (no falso positivo), buscar en el script correspondiente la línea exacta que lo genera y proponer el cambio mínimo necesario.
5. Documentar el fix en `Ubuntu/RegistroDeCambios/YYYYMMDD-Cambios.md` (crear el fichero del día si no existe. Indicar dentro del fichero la hora de los cambios.).

---

## Cadena de ejecución completa

```
0a-CreaISO.sh          ← Se ejecuta en el equipo de desarrollo (Linux), genera la ISO
  └── [ISO bootea]
       └── iac-iesmhp-launch.sh    ← autostart GNOME del Live CD, abre terminal
            └── iac-iesmhp-run.sh  ← instalado en el squashfs por 0a-CreaISO.sh
                 └── 0b-Github.sh  ← clona el repo IAC-IESMHP desde GitHub
                      └── 1-SetupLiveCD.sh         ← particiona discos, monta squashfs capas, prepara chroot
                           └── 2-SetupSOdesdeLiveCD.sh  ← corre DENTRO del chroot, configura el SO instalado
                                └── [reboot → primer arranque]
                                     └── 3-SetupPrimerInicio.service  ← systemd oneshot, configura hostname/IP/Ansible
                                          └── 4-Comprobaciones.sh     ← diagnóstico (llamado desde 2 y 3)
```

---

## Comandos clave

### Generar la ISO (en equipo Linux con Ubuntu)
```bash
# Instalar dependencias
sudo apt install xorriso mtools squashfs-tools gdisk -y

# Actualizar el repo y generar la ISO
cd ~/xIAC-IESMHP/Ubuntu/ISO/26.04
git reset --hard origin/main && git pull && chmod +x ./0a-CreaISO.sh
sudo ./0a-CreaISO.sh ~/Descargas/ubuntu-26.04-desktop-amd64.iso 0b-Github.sh ~/Descargas/mi-ubuntu.iso
# Argumento 4 opcional: ruta a un PNG personalizado como fondo (por defecto FondoIES-Ubuntu-Gris.png)
```

### Ver logs en el equipo instalado
```bash
ls /var/log/IAC-IESMHP/Ubuntu/
# 1-SetupLiveCD.sh.log         ← particionado y copia del FS
# 2-SetupSOdesdeLiveCD.sh.log  ← configuración en chroot
# 2-SetupSOdesdeLiveCD.steps   ← resumen de pasos con timestamps (diagnóstico rápido)
# 3-SetupPrimerInicio.sh.log   ← primer arranque: log ÚNICO de TODO lo que
#                                 lanza el servicio (este script + NombreIP +
#                                 Auto-Ansible + ansible-playbook + 4-Compro-
#                                 baciones). Cada línea con hora; sobrevive a
#                                 cuelgues NVIDIA (sync periódico). Antes había
#                                 además 5-PrimerArranque.log con el MISMO
#                                 contenido — eliminado el 2026-05-18.
# 4-Comprobaciones.sh.log      ← diagnóstico
```

---

## Arquitectura y decisiones clave

### comun.sh — Variables centralizadas (única fuente de verdad)
- **`Ubuntu/ISO/26.04/comun.sh`** centraliza en **un solo sitio** todas las rutas
  y constantes "mágicas" que antes estaban duplicadas a mano en cada script:
  `GITHUB_USER`/`REPO`/`GITREPO`/`GITRAW`, `DISTRO`/`versionDISTRO`,
  `RAIZSCRIPTS` (`/opt/IAC-IESMHP`), `RAIZDISTRO`, `RAIZANSIBLE`, `RAIZLOG`,
  rutas de los sub-scripts (`SCRIPT_LIVECD`…`SCRIPT_AUTOANSIBLE`), ficheros de
  datos (`FICHERO_MACS`, `URL_MACS`, `FICHERO_AUTORIZADOS`) y redes/proxy de aula
  (`RED_IABD`/`RED_SMRD`, `PROXY_IABD`/`PROXY_SMRD`).
- Carga: cada script lo localiza relativo a `${BASH_SOURCE[0]}` y hace `source`.
  En `ISO/26.04/` → `_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`; en
  `ISO/26.04/utiles/` → `_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`;
  ambos hacen luego `source "$_DIR/comun.sh"`. No se ejecuta (lleva guarda
  `IAC_COMUN_CARGADO` y no fija `set -e`). **Para mover una ruta, editar solo este fichero.**
- **Excepción `0b-Github.sh`**: corre en el Live CD antes de clonar el repo, así
  que conserva un bloque de arranque con solo `GITHUB_USER`+`REPO` (la única
  duplicación, marcada en el código); tras clonar carga `comun.sh`. Cambiar la
  URL del repo ⇒ tocar `comun.sh` **y** esas dos líneas de `0b-Github.sh`.
- Fichero **nuevo** (2026-06-12): requiere commit+push a `main` antes de generar
  una ISO. Detalle en `Ubuntu/RegistroDeCambios/20260612-Cambios.md`.

### 0a-CreaISO.sh — Generación de la ISO
- **Squashfs multicapa (Ubuntu 26.04+)**: la ISO usa capas `minimal.squashfs` / `minimal.standard.squashfs` / `minimal.standard.live.squashfs`. El script detecta la capa `*.live.squashfs` para insertar el autostart de escritorio, que es donde vive el entorno GNOME.
- **snapd enmascarado**: se enmascaran `snapd.service`, `snapd.socket` y `snapd.seeded.service` vía symlinks a `/dev/null` en el squashfs. Esto reduce el tiempo de arranque del Live CD de ~3 min a ~10 s y bloquea definitivamente `ubuntu-desktop-bootstrap` (el instalador snap de Ubuntu 26.04).
- **Autostart GNOME**: se escribe `iac-iesmhp-setup.desktop` tanto en `/etc/skel/.config/autostart` como en `/home/ubuntu/.config/autostart` para cubrir el caso de que el home del usuario `ubuntu` preexista o se cree desde skel. El `.desktop` llama a `iac-iesmhp-launch.sh`, que aplica el fondo y luego abre un terminal con `iac-iesmhp-run.sh`.
- **Boot UEFI únicamente**: se eliminan `isolinux/` y `boot/grub/i386-pc/`. La detección del modo EFI (appended partition GPT vs El Torito) es automática vía `xorriso -report_el_torito`, con fallback a `sfdisk+dd`.

### 0b-Github.sh — Bootstrap en el Live CD
- Se embebe en la raíz del squashfs como `/0b-Github.sh` (no en PATH estándar).
- Enmascara `/usr/sbin/update-initramfs` → `/bin/true` y desactiva `man-db auto-update` antes de cualquier `apt-get install` para evitar bloqueos en el entorno live.
- Espera red con 12 reintentos (5 s cada uno) antes de clonar el repo.
- El repo se clona en `/opt/IAC-IESMHP`.

### 1-SetupLiveCD.sh — Particionado e instalación del FS (v23.x-zfs)
- **Detección de discos**: ignora USB y loop; usa `lsblk -dno NAME,SIZE,TRAN`.
  Fija una variable explícita `PERFIL` (`CEIABD` | `DISTANCIA`) que se usa en
  todos los bloques que se ramifican según hardware.
  - 2×NVMe → `PERFIL=DISTANCIA` (pequeño=`/`, grande=`/home`)
  - NVMe+SD → `PERFIL=CEIABD` (NVMe lleva `/` ext4 + `rpool` ZFS; SD lleva `tank` ZFS)
- **Esquema de particiones**:
  - **DISTANCIA (sin ZFS, intacto respecto a v22.x)**: NVMe pequeño con EFI
    512 MiB + swap 8 GiB + raíz ext4 resto; NVMe grande con una partición
    ext4 íntegra para `/home`.
  - **CEIABD (ZFS, v23.0+)**: NVMe pequeño con `sgdisk` y tipos GPT correctos:
    `p1` 1 GiB EF00 (EFI) + `p2` 16 GiB 8200 (swap) + `p3` 100 GiB 8300
    (`/` ext4) + `p4` resto BF00 (zpool `rpool` → `/home`); SDA grande con
    una única BF00 íntegra (zpool `tank` → `/datos`).
- **ZFS en CEIABD** (bloque añadido tras montar `/`+`/boot/efi`):
  - Instala `zfsutils-linux` en el entorno live (`apt-get install -y`,
    `update-initramfs` ya enmascarado por `0b-Github.sh`).
  - Detecta **Fast Dedup** (OpenZFS ≥ 2.3) y lo activa con
    `-o feature@fast_dedup=enabled` (~50% menos RAM en DDT que dedup
    clásico).
  - Limpia pools previos (`zpool list` + `zpool import -d /dev/disk/by-id`)
    por si la VM se reinstala iterativamente.
  - `zpool create rpool` con `ashift=12, autotrim=on,
    cachefile=/etc/zfs/zpool.cache, compression=zstd, dedup=on,
    recordsize=64K, acltype=posixacl, xattr=sa, atime=off, -R /mnt` sobre
    `/dev/disk/by-id/...-part4`. Crea `rpool/home` con `canmount=on
    mountpoint=/home` — dataset **único y definitivo** (desde 2026-06-12):
    el rsync vuelca /home al pool y los usuarios viven como directorios
    normales dentro; `2-SetupSOdesdeLiveCD.sh` ya NO lo reestructura.
  - `zpool create tank` análogo pero **sin dedup**, `recordsize=1M`,
    sobre el SDA entero. `zfs create tank/datos` con `mountpoint=/datos`,
    `setuid=off`, `devices=off`; `chmod 1777`.
- **Capas squashfs**: Ubuntu 26.04 combina `minimal.squashfs + minimal.standard.squashfs + minimal.standard.live.squashfs` con overlayfs en `/tmp/merged`; Ubuntu <24.04 usa `filesystem.squashfs` único.
- Copia el FS con `rsync` (excluyendo `/etc/fstab` y `/etc/machine-id`).
- **Post-rsync (CEIABD)**: copia `/etc/zfs/zpool.cache` y `/etc/hostid` del
  live a `/mnt/etc/zfs/` y `/mnt/etc/hostid` para que `zfs-import-cache`
  del sistema instalado importe los pools sin escanear discos y sin `-f`.
- Pasa las particiones al chroot mediante `/mnt/tmp/.iac-partitions.env`.
  El formato del fichero ahora incluye `PERFIL=` y, solo en CEIABD,
  variables `ZFS_POOL_HOME=rpool`, `ZFS_HOME_DATASET=rpool/home`,
  `ZFS_HOME_PARTID=<by-id>`, `ZFS_POOL_DATA=tank`,
  `ZFS_DATA_DATASET=tank/datos`, `ZFS_DATA_PARTID=<by-id>`. `PART_DATA`
  queda vacío en CEIABD como marcador.
- **Pre-reboot (CEIABD)**: tras `Correcto` del script 2 y antes del
  `reboot`, desmonta bind-mounts virtuales del chroot, `zpool sync` y
  `zpool export rpool tank`. Sin esto el sistema instalado vería los
  pools "in use" por el hostid del live. En rama de fallo NO exporta:
  los pools siguen accesibles desde `/mnt` para diagnóstico manual.
- Si `2-SetupSOdesdeLiveCD.sh` termina con la línea literal `Correcto`, reinicia automáticamente; si no, espera 100000 s para diagnóstico.

### 2-SetupSOdesdeLiveCD.sh — Configuración en chroot (v23.7-20260612-zfs-homeunico)
- **Preámbulo**: carga `.iac-partitions.env` AL INICIO (antes del primer
  `paso`) y deja la variable `PERFIL` disponible globalmente. Si el fichero
  no existe (re-ejecución manual desde un sistema ya instalado), asume
  `PERFIL=DISTANCIA`.
- **Genera `/etc/fstab` bifurcado por perfil**:
  - **DISTANCIA**: 4 líneas como antes (`/`, `/boot/efi`, `/home` o
    `/datos` ext4, `swap`). El criterio `sd*`→`/datos`, `nvme*`→`/home`
    lo decide `PART_DATA` del `.iac-partitions.env`.
  - **CEIABD**: 3 líneas (`/`, `/boot/efi`, `swap`). `/home` lo monta
    `rpool/home` y `/datos` lo monta `tank/datos` vía
    `zfs-mount.service`; ambas entradas SE OMITEN del fstab. La raíz lleva
    `defaults,noatime`.
- **Bloque ZFS (solo CEIABD, tras "Verificar conectividad")**:
  - Instala `linux-headers-generic` (prerequisito de `zfs-dkms`) y luego
    `zfsutils-linux + zfs-zed + zfs-dkms + zfs-initramfs` con
    `DEBIAN_FRONTEND=noninteractive` y `Dpkg::Options::="--force-confold"`.
  - `systemctl enable zfs.target zfs-import-cache zfs-mount zfs-zed` y
    `systemctl disable zfs-import-scan` (cachefile activo → no hace falta
    escanear discos en cada boot).
  - `zpool set cachefile=/etc/zfs/zpool.cache` para `rpool` y `tank`,
    refrescando el cachefile con los binarios del sistema instalado.
- **`/home` = dataset ZFS único** (bloque "Usuarios", solo CEIABD —
  simplificación 2026-06-12, v23.7):
  - `rpool/home` (canmount=on, mountpoint=/home, creado en
    `1-SetupLiveCD.sh`) se usa tal cual. Ya NO se destruye ni se recrea
    como contenedor + dataset por usuario, NO hay cuotas, NO hay re-import
    sin altroot (no se crean datasets nuevos dentro del chroot, que era lo
    que rompía el auto-mount) y NO existe el helper `nuevo-alumno.sh`.
  - Red de seguridad: el script verifica `mountpoint -q /home` y aborta si
    el dataset no está montado (evita escribir al ext4 subyacente).
  - El usuario se crea con `useradd -m` estándar (misma rama que DISTANCIA).
    Alta de usuarios en el equipo instalado: `sudo adduser <usuario>`.
  - Snapshot global `rpool/home@inicial` tras eliminar el usuario `ubuntu`
    del Live CD (para no arrastrar `/home/ubuntu` en el snapshot).
- Genera fstab con UUIDs reales leídos de `blkid` (PART_EFI/SWAP/ROOT del
  `.iac-partitions.env`).
- **Limpia fuentes APT del Live CD (`cdrom:`)**: el rsync arrastra al sistema instalado la entrada `deb cdrom:[Ubuntu ...]/ resolute main` (o el equivalente DEB822 en `/etc/apt/sources.list.d/*.sources`) que el Live CD añade automáticamente. Sin limpiarla, `apt update` falla con "El repositorio file:/cdrom ... no tiene un fichero de Publicación". El paso depura `sources.list` y `*.list` con `sed`, y elimina los `.sources` (DEB822) cuyo `URIs:` apunte a `cdrom:`.
- **Fondo de escritorio** (dos capas): GSettings schema override (`99-iac-iesmhp-wallpaper.gschema.override`) como valor predeterminado compilado, más `dconf system-db:local` como override en runtime. Si `dconf update` falla en chroot, la capa GSettings garantiza el fondo igualmente.
- **Plymouth logos**: copia `bgrt-fallback.png` y `watermark.png` desde `imagenesIES/` a los temas spinner/bgrt **antes** de `update-initramfs`, para que la imagen instalada use los logos del IES.
- **Elimina autostart del Live CD**: borra `iac-iesmhp-setup.desktop` de `/etc/skel/.config/autostart` y `/home/ubuntu/.config/autostart` para que GNOME no lo ejecute en cada login del sistema instalado.
- **GDM — anti-autologin (multicapa)**:
  1. `AccountsService/users/ubuntu` eliminado + `usuario` registrado.
  2. `debconf-set-selections` pre-configura gdm3 con auto-login=false antes de que `dpkg --configure -a` pueda leer debconf del Live CD.
  3. `/etc/gdm3/custom.conf.d` eliminado + `custom.conf` sobrescrito con `AutomaticLoginEnable=false`, `TimedLoginEnable=false`, `InitialSetupEnable=false`, `WaylandEnable=true`.
  4. `iac-gdm-noautologin.service` (nuevo): `Before=display-manager.service` + `After=local-fs.target`, escribe `custom.conf` en **cada** arranque antes de que GDM lo lea. Cubre el caso de que postinst de gdm3 o `full-upgrade` sobreescriban la config.
  5. `casper.service` enmascarado vía symlink a `/dev/null` para impedir que casper userspace re-habilite auto-login.
- **GDM — greeter usa formulario de login, no escritorio**: Ubuntu 26.04 lanza el greeter como el usuario `gdm-greeter` con `gnome-session` sin `--session=`, lo que cae al default `'ubuntu'` y arranca el escritorio en vez del login. Tres capas para forzar `gnome-login.session`: (a) AccountsService `/var/lib/AccountsService/users/gdm-greeter` con `Session=gnome-login` + `XSession=gnome-login` + `SystemAccount=true`; (b) dconf system-db `gdm` con `session-name='gnome-login'` y lock en `/etc/dconf/db/gdm.d/locks/00-session-name`; (c) perfil `/etc/dconf/profile/gdm-greeter` apuntando a `system-db:gdm` para que el nuevo usuario lea el system-db.
- **gnome-initial-setup**: marcadores creados en rutas antiguas (`~/.config/`) y nuevas (`~/.local/share/`, Ubuntu 26.04+) para `gdm3`, `skel` y `usuario`. Evita que GDM lance el asistente de bienvenida como sesión propia ("GDM Greeter").
- **Contraseñas via Python inline**: genera hash SHA-512 con `openssl passwd -6` y lo escribe directamente en `/etc/shadow` via regex, sin pasar por PAM (`pam_pwquality` rechaza contraseñas cortas como 'root'/'usuario'). `useradd` se ejecuta **antes** de este bloque para que el usuario exista en shadow. Si el hash no queda escrito, sale con `sys.exit(1)`.
- **Check `/etc/nologin`**: si existe, bloquea todos los logins normales. El script lo detecta y elimina.
- **VMware — Wayland software rendering**: tras instalar el servicio GDM, detecta VMware con `systemd-detect-virt`. Si es VMware, escribe `LIBGL_ALWAYS_SOFTWARE=1` en `/etc/environment` para que Mesa llvmpipe permita iniciar sesiones Wayland sin aceleración 3D. En máquinas físicas, `systemd-detect-virt` devuelve "none" y este bloque no se ejecuta.
- **Timeout y menú GRUB**: `GRUB_TIMEOUT=5` y `GRUB_TIMEOUT_STYLE=menu` se fijan en `/etc/default/grub` para que el menú sea visible 5 s antes de arrancar la entrada por defecto.
- **Segunda entrada GRUB (modo texto)**: se crea `/etc/grub.d/11_iac_texto`, un script ejecutable que `update-grub` invoca en cada regeneración. Genera una entrada `'Ubuntu - Sin entorno grafico (modo texto)'` con `systemd.unit=multi-user.target`, que arranca en consola sin GDM/GNOME. El script lee el kernel, el initrd y el UUID de root dinámicamente (`/boot/vmlinuz-*`, `/boot/initrd.img-*`, `/etc/fstab`), por lo que sobrevive a actualizaciones de kernel.
- **Parche grub.cfg**: `update-grub` en chroot a veces escribe `root=/dev/nvme0n1p3` en lugar de `root=UUID=...`. El script lo detecta y parchea con `sed`.
- **Casper hooks**: se eliminan directamente con `rm -rf` (sin `apt remove`) para evitar que los triggers dpkg se bloqueen en el chroot. Hooks afectados: `/usr/share/initramfs-tools/hooks/casper` y variantes.
- `update-initramfs -c -k all` (create, no update) tarda 2–4 min; es el paso más lento. Se usa `-c` porque en sistemas instalados desde squashfs no existe initramfs previo y `-u` no crearía uno nuevo.
- **Re-ejecución de `update-grub` tras initramfs**: si grub.cfg no tiene línea `initrd` (generado cuando initrd.img aún no existía), se re-ejecuta `update-grub` y se re-aplica el parche UUID.
- Crea el servicio systemd `3-SetupPrimerInicio.service` con `WantedBy=multi-user.target`.
- Termina siempre con `echo "Correcto"` si todo fue bien (1-SetupLiveCD lo comprueba con `tail -n1`).

### 3-SetupPrimerInicio.sh — Primer arranque
- Detecta el aula por el tercer octeto de la IP: 72→IABD, 32→SMRV.
- Configura proxy apt según aula: `10.0.72.140:3128` (IABD) o `10.0.32.119:3128` (SMRV).
- `export DEBIAN_FRONTEND=noninteractive` + `debconf-set-selections` para gdm3 antes de `dpkg --configure -a`. Evita que el postinst de gdm3 regenere `custom.conf` con auto-login del Live CD.
- `dpkg --configure -a` y `apt-get full-upgrade` usan `-o Dpkg::Options::="--force-confold"` para no reemplazar `custom.conf` con la versión del paquete.
- Bloque **post-upgrade**: sobreescribe `/etc/gdm3/custom.conf` con `AutomaticLoginEnable=false` + `InitialSetupEnable=false` + `WaylandEnable=true` tras el upgrade, por si gdm3 lo regeneró.
- En VMware: instala `open-vm-tools-desktop` y confirma/añade `LIBGL_ALWAYS_SOFTWARE=1` en `/etc/environment`.
- Instala `ssh` y `ansible`, habilita `PermitRootLogin yes` y hace `apt-get full-upgrade`.
- Muestra progreso al usuario mediante diálogos `zenity` en todas las sesiones gráficas activas.
- Se autodeshabilita con triple mecanismo: `systemctl disable` + `rm` del `.service` + `mv "$0" "$0.borrado"`.
- Ejecuta `NombreIP.sh` (resuelve MAC→hostname y opcionalmente convierte DHCP a IP estática).
- Ejecuta `Auto-Ansible.sh` y lanza directamente `ansible-playbook roles.yaml` desde `$RAIZANSIBLE`.

### Configuración Ansible (post-instalación)
La fase Ansible (software, NFS de aula, drivers, claves SSH…) está **documentada con sus propios CLAUDE.md** dentro de `Ubuntu/ansible/`:
- `Ubuntu/ansible/CLAUDE.md` — describe `roles.yaml` (playbook maestro), inventarios `*.ini`, comandos de ejecución, estado de cada rol (activo/comentado/legacy) y convenciones (caché apt, detección de aula por IP, equipo `-00` = servidor NFS).
- `Ubuntu/ansible/roles/<rol>/CLAUDE.md` — un fichero por rol (`basicos`, `horaHTTP` (sincroniza la hora en cada arranque por NTP y, si está filtrado el UDP 123, por HTTP; service+timer), `clienteNAS`, `certificados`, `comparteaula` + legacy `comparteaula32`/`comparteaula72`, `DirtyFrag`, `flatpak`, `nvidia`, `obs`, `vscode`, `rdp` (servidor RDP nativo de GNOME; sustituye al antiguo `xrdp`), `vmware`, `Docker` (instalación de sistema para uso rootless; sustituye al antiguo `contenedores`), `preparaAD` (prerequisitos de unión a dominio Active Directory; no une por defecto)) con tareas, variables e issues conocidos.
- `Ubuntu/ansible/rolesUsuario/CLAUDE.md` — configuraciones por usuario (`~/.ssh`, dotfiles…), ejecutadas **como el usuario** (no root). Carpeta nueva, en construcción; aún no enganchada a `roles.yaml`.
- **Al diagnosticar/modificar la fase Ansible, leer primero esos CLAUDE.md** (sobre todo el de `Ubuntu/ansible/` para saber qué roles están activos en `roles.yaml`).

### 4-Comprobaciones.sh — Diagnóstico (v1.4-20260612-zfs)
Comprueba en 9 secciones: (1) kernel+initramfs+NVMe+casper, (2) grub.cfg con UUIDs+línea initrd, (3) fstab vs blkid, (4) lsblk particiones, (5) paquetes clave (casper por ficheros en disco, no dpkg; ubiquity; dpkg --audit), (6) initramfs-tools config (MODULES=most, RESUME=none), (7) GRUB EFI instalado (grubx64.efi, módulos), (8) servicios systemd fallidos + SSH (solo si sistema arrancado, no en chroot), **(9) ZFS — solo si hay zpool importado: salud de pools, datasets esperados (`rpool/home` montado en `/home`, `tank/datos` en `/datos`), propiedades dedup/compresión/fast_dedup, servicios systemd zfs-*, módulo zfs.ko en initramfs**. Genera resumen ERRORES/AVISOS al final. **Cuando ERRORES=0, reinicia automáticamente tras cuenta atrás de 30 s.** Útil como primer análisis al pegar un log.

**Falsos positivos conocidos en 4-Comprobaciones.sh** — verificar antes de asumir que el sistema está roto:

| Mensaje `[ERR]` en el log | Causa real | ¿Es un problema real? |
|---|---|---|
| `casper está instalado` (sección 5, pre-2026-04-30) | dpkg lo marca como instalado pero los hooks ya fueron borrados con `rm -rf` en el chroot | No — los hooks no están en disco; el initramfs se generó limpio |
| `UUID 68 (/boot/efi) → ningún dispositivo` (sección 3, pre-2026-04-30) | Regex `[a-f0-9-]+` trunca UUIDs FAT con mayúsculas (`68AA-2FED` → `68`) | No — la partición EFI existe; era un bug del regex |

**Diagnóstico rápido de la sección 3 (FSTAB)**: si hay un `[ERR]` de UUID para `/boot/efi` pero `lsblk` (sección 4) muestra esa partición con un UUID del tipo `XXXX-YYYY` (4+4 hex en mayúsculas, formato FAT), es falso positivo — el UUID FAT usa mayúsculas y el regex debe ser `[a-fA-F0-9-]+`.

**Diagnóstico rápido de la sección 5 (casper)**: si la sección 1 dice `[OK] Hooks casper: no presentes` pero la sección 5 dice `[ERR] casper está instalado`, es falso positivo — dpkg tiene el registro pero los hooks no existen en disco y no afectan al initramfs.

---

## Configuraciones de hardware soportadas

| Aula      | Disco pequeño       | Disco grande      |
|-----------|---------------------|-------------------|
| Distancia | NVMe 0.5 TB (EFI 512M, swap 8G, `/` ext4 resto) | NVMe 2.0 TB (`/home` ext4) |
| CEIABD    | NVMe 0.5 TB (EFI 1G, swap 16G, `/` 100G ext4, p4 ZFS → `rpool`) | SDA 1.0 TB (ZFS → `tank` → `/datos`) |

**Distancia** mantiene ext4 íntegro (sin ZFS). **CEIABD** lleva ZFS en `/home`
(zpool `rpool` con dedup + zstd) y `/datos` (zpool `tank` con zstd). Detalle
operativo en la sección "ZFS — operación" más abajo.

---

## ZFS — operación (solo CEIABD)

### Pools y datasets

```
rpool                         (ashift=12, autotrim=on, compression=zstd, dedup=on,
                               recordsize=64K, feature@fast_dedup=enabled si ≥ 2.3)
└── rpool/home                (canmount=on, mountpoint=/home — dataset ÚNICO, SIN cuotas;
                               todos los usuarios son directorios normales dentro)

tank                          (ashift=12, autotrim=on, compression=zstd, recordsize=1M)
└── tank/datos                (canmount=on, mountpoint=/datos, setuid=off,
                               devices=off, permisos 1777)
```

> **Simplificación 2026-06-12**: antes `rpool/home` era un contenedor
> `canmount=off` con un dataset hijo por usuario (`rpool/home/usuario`,
> `rpool/home/<alumno>` vía helper `nuevo-alumno.sh`). Todo eso se eliminó:
> un solo dataset, sin cuotas, sin helper. Los equipos instalados antes de
> esa fecha conservan la estructura antigua.

- `/etc/zfs/zpool.cache` se copia desde el live al sistema instalado para que
  `zfs-import-cache.service` importe los pools sin escanear discos al boot.
- `/etc/hostid` se copia también para que `zfs-import-cache` no necesite `-f`
  (los labels ZFS guardan el hostid del creador).
- `/etc/fstab` NO contiene entradas para `/home` ni `/datos`: las monta
  `zfs-mount.service`.

### Alta de un usuario nuevo

```bash
sudo adduser <usuario>
# Privilegios opcionales a posteriori:
sudo usermod -aG sudo <usuario>      # administrador
sudo usermod -aG docker <usuario>    # uso de Docker
```

Flujo estándar de Linux: el home es un directorio normal dentro del dataset
`rpool/home` (hereda compresión y dedup del pool automáticamente). No hay
datasets por usuario ni cuotas. El antiguo helper
`/usr/local/sbin/nuevo-alumno.sh` fue eliminado el 2026-06-12 (puede seguir
presente en equipos instalados antes de esa fecha — no usarlo).

### Operaciones habituales

```bash
# Estado y espacio
zpool status            # salud de vdevs
zpool list              # tamaño, dedupratio, capacidad
zfs list                # datasets, used, avail, mountpoint
zfs list -t snapshot    # snapshots existentes

# Ratio de deduplicación (clave para decidir si compensa)
zpool get dedupratio rpool

# Rollback al snapshot @inicial — OJO: afecta a TODO /home (todos los usuarios)
zfs rollback rpool/home@inicial

# Snapshot manual de todo /home (cron sugerido)
zfs snapshot rpool/home@$(date +%Y%m%d)

# Borrar snapshots antiguos (conserva @inicial)
zfs list -H -o name -t snapshot rpool/home | grep -v '@inicial' | xargs -r -n1 zfs destroy

# Cuotas: NO se usan (dataset único sin cuota). Si algún día hiciera falta
# limitar por usuario sin datasets, ZFS soporta cuotas de usuario POSIX:
zfs userspace rpool/home                  # consumo por usuario
zfs set userquota@<u>=200G rpool/home     # cuota por usuario (opcional)
zfs set userquota@<u>=none rpool/home     # quitarla

# Backup vía zfs send (incremental, requiere snapshot común)
zfs snapshot rpool/home@backup-20260601
zfs send -i @inicial rpool/home@backup-20260601 | ssh backup-host "zfs recv tank-backup/home"

# Scrub manual (programado por zfs-zed mensualmente por defecto)
zpool scrub rpool
zpool scrub tank
```

### Diagnóstico

`4-Comprobaciones.sh` sección 9 cubre: salud de pools, datasets esperados
(`rpool/home` montado en `/home`, `tank/datos` montado en `/datos`),
propiedades (`compression`, `dedup`, `recordsize`, `dedupratio`, feature
`fast_dedup`), servicios systemd (`zfs-import-cache`, `zfs-mount`,
`zfs-zed`) y módulo `zfs.ko` en initramfs.

---

## Ficheros de datos

- `macs.csv` — en raíz del repo (`/opt/IAC-IESMHP/macs.csv`). Formato: `MAC, Equipo, IPf, Comentario` (las líneas que empiezan por `#` son comentarios). Por la MAC se asigna el nombre del equipo (`prefijo-NN`, `-00` reservado al profesor) y, si la interfaz está en DHCP, se convierte a IP estática conservando máscara/gateway/DNS y cambiando solo el último octeto por `IPf`. Usado por `2-SetupSOdesdeLiveCD.sh` y `NombreIP.sh`.
- `Autorizados.txt` — claves SSH públicas autorizadas para `root` y `usuario`.
- `FondoIES-Ubuntu-Gris.png` — fondo de escritorio embebido en el squashfs. Vive en `Ubuntu/ISO/26.04/imagenesIES/` (junto a los demás fondos y los logos Plymouth `bgrt-fallback.png`/`watermark.png`), **no** en la raíz del repo.

---

## Registro de cambios

Los cambios realizados en cada sesión de trabajo se documentan en:
```
Ubuntu/RegistroDeCambios/YYYYMMDD-Cambios.md
```
Antes de modificar un script, consulta ese directorio para evitar repetir correcciones ya aplicadas que funcionaron mal. Los nuevos cambios regístralos allí indicando también la hora y minuto en que los realizastes. 

---

## Issues conocidos y áreas en optimización

- **`0b-Github.sh` línea 54**: comentario `#####FALLA AQUí!` — en alguna versión se bloqueaba antes del `apt-get install git`. Mitigado enmascarando `update-initramfs` (tanto `/usr/local/sbin/` como `/usr/sbin/`) y `man-db` antes de cualquier apt.
- **`Auto-Ansible.sh` línea 38**: `ssh-keygen -F $HOSTNAME` falla. Pendiente de corrección.
- **snapd en Live CD**: si en futuras ISOs snapd vuelve a arrancar, los síntomas son arranque lento (~3 min) y bloqueo de `ubuntu-desktop-bootstrap` antes del autostart.
- **Wayland en VMware sin 3D**: si la sesión Wayland sigue fallando en la VM (GDM vuelve al login sin mensaje de error), verificar **Habilitar aceleración 3D** en Display → Accelerate 3D graphics de VMware. Con eso y `open-vm-tools-desktop`, Wayland funciona sin necesidad de `LIBGL_ALWAYS_SOFTWARE`.
- **Hora en VMware**: en una máquina virtual VMware, activar **Settings → Options → VMware Tools → "Synchronize guest time with host"**. El UDP 123 (NTP) suele estar filtrado en las aulas y en VMware con host Windows el RTC se reinterpreta en cada arranque, así que el reloj del guest deriva entre reinicios. Con esta opción el host mantiene la hora correcta (complementa al rol `horaHTTP`; imprescindible si el equipo se une a un dominio AD, donde Kerberos exige <5 min de desfase con el DC).

### Bugs corregidos (historial para no repetirlos)

- **2026-05-20 — `/home/usuario` queda root:root sin skel tras instalar (CEIABD)**: el pool `rpool` se importa en `1-SetupLiveCD.sh` con `zpool create -R /mnt` (altroot) para que los datasets se monten bajo `/mnt/*` durante el rsync. Esa `altroot` PERSISTE en el pool (es runtime-only, solo se puede cambiar via export+import). Dentro del chroot, cuando `2-SetupSOdesdeLiveCD.sh` hace `zfs create -o canmount=on rpool/home/usuario`, el auto-mount calcula `path = altroot + mountpoint = /mnt + /home/usuario = /mnt/home/usuario` y se lo pasa al syscall `mount`; el kernel resuelve esa ruta relativa al root del proceso (chroot root = host:`/mnt`) → host:`/mnt/mnt/home/usuario`, fuera del árbol → mount falla silenciosamente (no afecta al exit code de `zfs create`). `useradd -m`, `cp -aT /etc/skel` y `chown -R` siguientes caen al **ext4 subyacente**, el snapshot `@inicial` se toma del dataset ZFS vacío y, al rebotar, `zfs-mount.service` monta el dataset encima ocultando el contenido bueno. Síntoma: GDM «Sin Carpeta Personal», `mkdir` denegado en `/home/usuario`, dataset con `used` mínimo y solo `verLog.sh` (que escribe `3-SetupPrimerInicio.sh`). Pista: `zfs list` dentro del chroot muestra los mountpoints con prefijo `/mnt/` (delata la altroot residual). **Fix**: en `2-SetupSOdesdeLiveCD.sh` PASO 11, entre destruir `rpool/home` y recrearlo, `zpool export rpool && zpool import -d /dev/disk/by-id rpool` (sin `-R`) + `zpool set cachefile=`. Tras esto altroot=`-` y el auto-mount funciona. Además: red de seguridad `mountpoint -q /home/usuario || (err; exit 1)`, `useradd` sin `-m`, y `cp skel + chown + chmod 750` incondicionales. Mismo patrón de verificación de mount en el helper `nuevo-alumno.sh`. Versión `2-SetupSOdesdeLiveCD.sh`: `23.3` → `23.6` (intermedias: `23.4` redes de seguridad de mount, `23.5` re-import sin altroot, `23.6` `useradd` sin `-k` — Ubuntu 26.04 rechaza `-k` sin `-m`). **Nota 2026-06-12 (v23.7)**: el flujo de reestructuración y su re-import sin altroot fueron eliminados al pasar a dataset único `rpool/home` — dentro del chroot ya no se crean datasets, así que el problema de la altroot no aplica; solo queda la red de seguridad `mountpoint -q /home`.
- **2026-05-15 — `3-SetupPrimerInicio.sh.log` con cada línea duplicada**: la unidad `3-SetupPrimerInicio.service` tenía `StandardOutput/StandardError=append:$RAIZLOG/$SCRIPT3.log` **además** del `exec > >(tee -a "$FLOG") 2>&1` del propio script → cada línea se grababa dos veces (tee + re-append de systemd al mismo fichero). Pista: la línea previa al `exec` aparece una sola vez. **Fix**: en `2-SetupSOdesdeLiveCD.sh`, la unidad pasa a `StandardOutput=journal`/`StandardError=journal` (único escritor del fichero = el `tee` del script); en `3-SetupPrimerInicio.sh`, `bash "$SCRIPT4" 2>&1 | tee -a "$FLOG"` → `bash "$SCRIPT4"` (el `exec` ya redirige a `$FLOG`).
- **2026-05-15 — Ansible falla con `The module interpreter '/usr/bin/python3.12' was not found`**: `3-SetupPrimerInicio.sh` pasaba `-e ansible_python_interpreter=/usr/bin/python3.12` codificado a fuego; Ubuntu 26.04 «resolute» no trae python3.12 → `ansible-playbook` aborta (`failed=1, ok=0`, rc=127). **Fix**: resolver el intérprete en runtime con `PYINT="$(command -v python3 || echo /usr/bin/python3)"` y pasar `-e "ansible_python_interpreter=$PYINT"`; inventarios `Ubuntu/ansible/*.ini` cambiados a `auto_silent` (Mint/ no se toca).
- **2026-05-15 — `apt update` falla con "file:/cdrom resolute Release no tiene un fichero de Publicación"**: el Live CD añade automáticamente una entrada `deb cdrom:` apuntando al ISO montado en `/cdrom`. El rsync de `1-SetupLiveCD.sh` copia esa entrada al sistema instalado, donde `/cdrom` no existe → `apt update` falla en cada ejecución. **Fix**: nuevo paso "Limpiar fuentes APT del Live CD (cdrom:)" en `2-SetupSOdesdeLiveCD.sh` que (a) borra con `sed` líneas `deb cdrom:` de `/etc/apt/sources.list` y `*.list`, y (b) elimina ficheros `.sources` (DEB822) cuyo `URIs:` apunte a `cdrom:`.
- **2026-05-14 — GDM Greeter arranca el escritorio Ubuntu en lugar del login**: Ubuntu 26.04 introduce el usuario de sistema `gdm-greeter` (uid 60578) separado de `gdm`. GDM lo lanza con `gdm-wayland-session gnome-session` sin `--session=`, así que `gnome-session` lee `/org/gnome/desktop/session/session-name` del dconf del usuario; al no estar fijada, cae al default del sistema (`'ubuntu'`) → carga `ubuntu.session` (`gnome-shell --mode=ubuntu`, escritorio completo) en vez de `gnome-login.session` (`Kiosk=true`, formulario de login). Síntoma: tras instalar el SO, tty1 muestra un escritorio GNOME funcional bajo el usuario `gdm-greeter` sin formulario de login. **Fix**: (1) `session-name='gnome-login'` añadido a `/etc/dconf/db/gdm.d/00-login-screen` + lock en `/etc/dconf/db/gdm.d/locks/00-session-name`; (2) nuevo `/etc/dconf/profile/gdm-greeter` apuntando a `system-db:gdm`; (3) `/var/lib/AccountsService/users/gdm-greeter` con `Session=gnome-login` + `XSession=gnome-login` + `SystemAccount=true`.
- **2026-05-04 — GRUB sin menú visible y sin opción de modo texto**: el timeout era 0 (`GRUB_TIMEOUT_STYLE=hidden`) y solo existía una entrada de arranque. **Fix**: `GRUB_TIMEOUT=5` + `GRUB_TIMEOUT_STYLE=menu` en `/etc/default/grub`; nuevo `/etc/grub.d/11_iac_texto` que genera la segunda entrada `systemd.unit=multi-user.target` en cada `update-grub`.
- **2026-05-03 — Login imposible: `useradd` después del bloque Python de contraseñas**: el bloque Python (línea ~252) corría antes de `useradd`. 'usuario' no existía en `/etc/shadow` → Python imprimía `[WARN]` y continuaba; `useradd` creaba al usuario con contraseña bloqueada (`*`). **Fix**: `useradd` movido antes del bloque Python; `[WARN]` → `[ERR]` + `sys.exit(1)` si el usuario no existe en shadow.
- **2026-05-03 — Contraseñas rechazadas por `pam_pwquality`**: `chpasswd` en Ubuntu 26.04 aplica PAM con mínimo 8 caracteres. 'root' (4) y 'usuario' (7) son rechazadas silenciosamente. **Fix**: Python inline genera hash SHA-512 con `openssl passwd -6` y lo escribe directamente en `/etc/shadow` via regex, sin pasar por PAM.
- **2026-05-03 — GDM Greeter automático en primer arranque**: `3-SetupPrimerInicio.service` llega `After=graphical.target` → tarde para corregir `custom.conf` si casper.service o postinst de gdm3 lo sobreescribieron. **Fix**: nuevo `iac-gdm-noautologin.service` con `Before=display-manager.service` que escribe `custom.conf` en cada arranque antes de que GDM lo lea.
- **2026-05-03 — `gnome-initial-setup` lanzado como sesión GDM**: Ubuntu 26.04 necesita `InitialSetupEnable=false` en `custom.conf` y marcadores en `~/.local/share/gnome-initial-setup-done` (ruta nueva ≥ 46) además de `~/.config/`. **Fix**: añadido `InitialSetupEnable=false` a todos los configs GDM; marcadores creados en ambas rutas.
- **2026-05-03 — Auto-login en squashfs rompía Live CD**: escribir `AutomaticLoginEnable=false` en `0a-CreaISO.sh` impedía que casper configurara el auto-login del Live CD en runtime. **Fix**: revertido; el fix correcto es solo en el chroot (`2-SetupSOdesdeLiveCD.sh`).
- **2026-05-02 — Línea `initrd` ausente en grub.cfg (sección 2 de comprobaciones)**: `update-grub` corre antes de que exista el initramfs → grub.cfg sin línea `initrd` → kernel panic `unknown-block(0,0)`. **Fix**: re-ejecutar `update-grub` tras `update-initramfs`; nuevo check en sección 2 de `4-Comprobaciones.sh`.
- **2026-05-02 — Falso positivo NVMe (sección 1)**: `grep -q nvme` coincidía con directorios sin `.ko` real. **Fix**: `grep -qE 'nvme.*\.ko'`.
- **2026-04-30 — Falso positivo casper (sección 5)**: check con `dpkg -l` marcaba error aunque los hooks ya estuvieran borrados del disco. **Fix**: `find` en disco; si no hay ficheros → `[OK]`.
- **2026-04-30 — Falso positivo UUID EFI (sección 3)**: regex `[a-f0-9-]+` truncaba UUIDs FAT con mayúsculas (`68AA-2FED` → `68`). **Fix**: `[a-fA-F0-9-]+`.
