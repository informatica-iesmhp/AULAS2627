#!/bin/bash
# =============================================================================
#  1-SetupLiveCD.sh  —  Ubuntu 26.04
#  Instalación manual desde el entorno Live CD (arrancado desde ISO custom).
#  Lanzado por perso.sh tras clonar el repositorio en /opt/IAC-IESMHP.
#
#  Configuraciones de disco soportadas:
#    Distancia : NVMe 0,5 TB (EFI 512M, swap 8G, / resto ext4)
#              + NVMe 2,0 TB (/home ext4)
#              → SIN ZFS (rama intacta respecto a la versión 22.x).
#    CEIABD    : NVMe 0,5 TB (EFI 1G, swap 16G, / 100G ext4, p4 ZFS rpool→/home)
#              + SATA 1,0 TB (ZFS tank→/datos sin dedup)
#              → ZFS con dedup+zstd en /home y zstd en /datos.
#  La decisión "ZFS solo en CEIABD" la fijó el usuario el 2026-05-20 al pasar
#  a FASE 1 del plan ZFS: Distancia se mantiene tal cual hasta nuevo aviso.
# =============================================================================
set -e

VERSIONSCRIPT="23.1-20260612-Ubuntu-zfs"

# Variables comunes del proyecto (REPO, GITREPO, DISTRO, RAIZSCRIPTS, RAIZLOG,
# versionDISTRO...). Único punto de definición: comun.sh (mismo directorio).
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_DIR/comun.sh"

# El repo ya está clonado por 0b-Github.sh en /opt/$REPO (= $RAIZSCRIPTS).
RAIZSCRIPTSLIVE="$RAIZSCRIPTS"
SCRIPT2="$(basename "$SCRIPT_CHROOT")"

# ─────────────── Colores ───────────────
echoverde()    { echo -e "\033[32m$1\033[0m"; }
echorojo()     { echo -e "\033[31m$1\033[0m"; }
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

# ─────────────── Log ───────────────────
# Redirigimos la salida al log desde el inicio
mkdir -p "$RAIZLOG"
exec > >(tee -a "$RAIZLOG/1-SetupLiveCD.sh.log") 2>&1

# ─────────────── Teclado ───────────────
# || true porque en entorno sin X11 setxkbmap puede fallar
setxkbmap es || true
loadkeys es   || true

# ─────────────── Cabecera ──────────────
echoverde "1-SetupLiveCD (vs$VERSIONSCRIPT)"
echo         "   Script personalizado de instalación de "
echo         "   sistema operativo $DISTRO $versionDISTRO para equipos distancia / CEIABD"
echoamarillo "   (victor.muelacarriles@educantabria.es)"
echoverde "--------------------------------------------------------------------"
echoverde "       Distancia     ->Disco pequeño: NVMe 0,5TB (EFI, swap, / ext4)"
echoverde "                     ->Disco grande:  NVMe 2,0TB (/home ext4) [SIN ZFS]"
echoverde "--------------------------------------------------------------------"
echoverde "       CEIABD        ->Disco pequeño: NVMe 0,5TB (EFI 1G, swap 16G,"
echoverde "                                       / 100G ext4, p4 ZFS rpool→/home)"
echoverde "                     ->Disco grande:  SDa  1,0TB (ZFS tank→/datos)"
echoverde "--------------------------------------------------------------------"



# ─────────────── Carpetas de trabajo ───
mkdir -p "$RAIZSCRIPTSLIVE"   # ya existe (clonado por perso.sh), mkdir -p es seguro
mkdir -p "$RAIZSCRIPTS"
mkdir -p "$RAIZLOG"
echoverde "Carpetas de trabajo: $RAIZSCRIPTSLIVE, $RAIZSCRIPTS, $RAIZLOG"

# ─────────────── Hora correcta (zona + NTP) ─────
# Misma comprobación que en 0b-Github.sh: en el Live CD (sobre todo en VMware con
# host Windows) el reloj aparece 2 h adelantado (RTC en hora local interpretado
# como UTC). En 0b a veces el NTP aún no ha confirmado sincronización; se repite
# aquí porque para este punto la red lleva más tiempo lista y suele cuajar.
echoverde "Fijando zona horaria Europe/Madrid y sincronizando hora por NTP..."
timedatectl set-timezone Europe/Madrid 2>/dev/null \
    || echoamarillo "No se pudo fijar la zona horaria con timedatectl."
# Servidores NTP por defecto (NTP= vacío → FallbackNTP de timesyncd).
timedatectl set-ntp true 2>/dev/null || true
systemctl restart systemd-timesyncd 2>/dev/null || true
# Esperar a que NTP confirme sincronización (máx ~30 s) antes de continuar.
for i in $(seq 1 15); do
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && break
    sleep 2
done
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    echoverde "Hora sincronizada por NTP: $(date)"
else
    # Fallback HTTP: en las aulas el UDP 123 (NTP) suele estar filtrado, pero el
    # TCP 443 (HTTPS) no — de hecho 0b-Github.sh ya clonó el repo por ahí. Leemos
    # la hora de la cabecera «Date:» de una petición HTTPS: viene en GMT, así que
    # `date -s` la interpreta y la convierte sola a Europe/Madrid (zona ya fijada).
    echoamarillo "NTP no confirmó sincronización (¿UDP 123 bloqueado?); intento por HTTP..."
    HORA_HTTP=""
    for url in https://www.google.com https://github.com https://www.cloudflare.com; do
        if command -v curl >/dev/null 2>&1; then
            HORA_HTTP="$(curl -sI --max-time 10 "$url" 2>/dev/null \
                | grep -i '^[[:space:]]*date:' | head -n1 \
                | sed -E 's/^[[:space:]]*[Dd]ate:[[:space:]]*//; s/\r$//' || true)"
        else
            HORA_HTTP="$(wget -SqO /dev/null --timeout=10 "$url" 2>&1 \
                | grep -i '^[[:space:]]*date:' | head -n1 \
                | sed -E 's/^[[:space:]]*[Dd]ate:[[:space:]]*//; s/\r$//' || true)"
        fi
        if [ -n "$HORA_HTTP" ] && date -s "$HORA_HTTP" >/dev/null 2>&1; then
            hwclock --systohc 2>/dev/null || true
            echoverde "Hora sincronizada por HTTP ($url): $(date)"
            break
        fi
        HORA_HTTP=""
    done
    [ -n "$HORA_HTTP" ] || echoamarillo "Tampoco se pudo sincronizar por HTTP; se continúa con: $(date)"
fi

# ─────────────── Detectar discos ───────
# Ignoramos USB y loop
DISCOS_M2=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0 | grep -v 'usb' | grep nvme | sort -h -k2 | awk '{print $1}'))
DISCOS_SD=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0 | grep -v 'usb' | grep sd   | sort -h -k2 | awk '{print $1}'))

echoamarillo "--- Inventario completo de discos ---"
lsblk -dno NAME,SIZE,TRAN,ROTA,MODEL | grep -v '^loop' || lsblk -dno NAME,SIZE
echo "DISCOS_M2[0]: ${DISCOS_M2[0]:-<vacío>}"
echo "DISCOS_M2[1]: ${DISCOS_M2[1]:-<vacío>}"
echo "DISCOS_SD[0]: ${DISCOS_SD[0]:-<vacío>}"

if [ -z "${DISCOS_M2[0]:-}" ]; then
    echorojo "No se encontraron discos NVMe. Asegúrate de que el equipo tiene discos conectados."
    sleep 1000 && exit 1
else
    if [ -z "${DISCOS_M2[1]:-}" ]; then
        # Solo hay un NVMe → buscamos un SD como disco grande (perfil CEIABD)
        if [ -z "${DISCOS_SD[0]:-}" ]; then
            echorojo "No hay segundo disco SD (hay sólo un NVMe sin disco secundario). Detenemos."
            sleep 1000 && exit 1
        else
            DISK_SMALL="/dev/${DISCOS_M2[0]}"
            DISK_BIG="/dev/${DISCOS_SD[0]}"
            PERFIL="CEIABD"
            echoverde "Equipo NVME+SD (perfil $PERFIL, ZFS):"
            echoverde "    EFI/swap/ / ext4  -> NVMe pequeño ($DISK_SMALL)"
            echoverde "    /home (rpool ZFS) -> p4 del mismo NVMe"
            echoverde "    /datos (tank ZFS) -> SD ($DISK_BIG)"
        fi
    else
        DISK_SMALL="/dev/${DISCOS_M2[0]}"
        DISK_BIG="/dev/${DISCOS_M2[1]}"
        PERFIL="DISTANCIA"
        echoverde "Equipo 2×NVMe (perfil $PERFIL, sin ZFS):"
        echoverde "    /     -> pequeño ($DISK_SMALL)"
        echoverde "    /home -> grande  ($DISK_BIG)"
    fi
fi

if [[ "$DISK_SMALL" != *nvme* ]]; then
    echorojo "Error: se esperaba un disco NVMe para el disco pequeño"
    exit 1
fi

# ─────────────── Limpiar LVM si existe ─
if lsblk -o NAME,TYPE | grep -q "lvm"; then
    echoamarillo "Detectadas particiones LVM. Eliminando..."
    vgchange -an || true
    for part in $(lsblk -o NAME,TYPE | grep "lvm" | awk '{print $1}'); do
        echoamarillo "  Borrando LVM: $part"
        sgdisk --zap-all "/dev/$part" || true
    done
    echoverde "Particiones LVM eliminadas"
fi

# ─────────────── Particionar ───────────
echo && echoamarillo "Borrando y particionando: $DISK_SMALL y $DISK_BIG (perfil=$PERFIL)"
lsblk -o NAME,SIZE,TYPE

sgdisk --zap-all "$DISK_SMALL"
sgdisk --zap-all "$DISK_BIG"
# wipefs por si quedan firmas LVM/ZFS/mdadm residuales que sgdisk --zap-all no toca
wipefs -a "$DISK_SMALL" 2>/dev/null || true
wipefs -a "$DISK_BIG"   2>/dev/null || true

if [ "$PERFIL" = "DISTANCIA" ]; then
    # Distancia: layout histórico ext4 (mantener intacto, sin cambios respecto
    # a la versión 22.x — decisión del usuario al iniciar FASE 1 de ZFS).
    parted -s "$DISK_SMALL" mklabel gpt
    parted -s "$DISK_BIG"   mklabel gpt
    # Disco pequeño: EFI (512 MiB) + swap (8 GiB) + raíz (resto)
    parted -s "$DISK_SMALL" mkpart ESP      fat32      1MiB    513MiB
    parted -s "$DISK_SMALL" set 1 esp on
    parted -s "$DISK_SMALL" mkpart primary  linux-swap 513MiB  8705MiB
    parted -s "$DISK_SMALL" mkpart primary  ext4       8705MiB 100%
    # Disco grande: /home (2×NVMe)
    parted -s "$DISK_BIG"   mkpart primary  ext4       1MiB    100%
else
    # CEIABD: layout nuevo con p4 ZFS en el NVMe pequeño y SDA íntegro en ZFS.
    # Códigos de tipo GPT (sgdisk):
    #   EF00 = EFI System Partition
    #   8200 = Linux swap
    #   8300 = Linux filesystem (para / ext4)
    #   BF00 = Solaris root (= tipo "ZFS root pool" en gdisk; el aceptado por OpenZFS)
    # Tamaños:
    #   p1 EFI 1 GiB (holgura para varios kernels + shim/MOK + EFI vendors)
    #   p2 swap 16 GiB (partición, NO zvol: evita el deadlock ARC↔swap documentado en OpenZFS)
    #   p3 / 100 GiB ext4 (cachés apt/snap/docker, CUDA, VMware, /opt Anaconda)
    #   p4 ZFS resto → zpool rpool con dedup+zstd (recordsize=64K) montado en /home
    sgdisk \
        -n 1:0:+1G    -t 1:EF00 -c 1:"EFI"   \
        -n 2:0:+16G   -t 2:8200 -c 2:"swap"  \
        -n 3:0:+100G  -t 3:8300 -c 3:"root"  \
        -n 4:0:0      -t 4:BF00 -c 4:"rpool" \
        "$DISK_SMALL"
    # SDA íntegro en BF00 → zpool tank con zstd (sin dedup, recordsize=1M)
    sgdisk \
        -n 1:0:0 -t 1:BF00 -c 1:"tank" \
        "$DISK_BIG"
fi

echoverde "Discos particionados: $DISK_SMALL y $DISK_BIG"

echoamarillo "Esperando detección de particiones por el kernel..."
# udevadm settle es más fiable que sleep ciego; partprobe fuerza la relectura
# por si sgdisk no la disparó (raro pero observado en entornos VMware).
partprobe "$DISK_SMALL" "$DISK_BIG" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 5

echoamarillo "--- Layout de particiones ---"
sgdisk -p "$DISK_SMALL" 2>/dev/null || parted -s "$DISK_SMALL" print 2>/dev/null || true
sgdisk -p "$DISK_BIG"   2>/dev/null || parted -s "$DISK_BIG"   print 2>/dev/null || true

# ─────────────── Asignar particiones ───
EFI="${DISK_SMALL}p1"
SWAP="${DISK_SMALL}p2"
ROOT="${DISK_SMALL}p3"

# La nomenclatura de partición difiere entre NVMe (/dev/nvmeXnYpZ)
# y discos SD/SATA (/dev/sdXN). En CEIABD el grande siempre es SATA,
# pero conservamos las dos ramas por seguridad.
if [[ "$DISK_BIG" == *sd* ]]; then
    DATA_PART="${DISK_BIG}1"
elif [[ "$DISK_BIG" == *nvme* ]]; then
    DATA_PART="${DISK_BIG}p1"
else
    echorojo "Error: no se pudo determinar la partición del disco grande"
    exit 1
fi

# En CEIABD necesitamos también la 4ª partición del NVMe pequeño (BF00 → rpool)
# y referencias persistentes (/dev/disk/by-id/...) para que el zpool sobreviva
# a renombrados de devnode entre arranques (más estable que /dev/nvmeXnYpZ).
if [ "$PERFIL" = "CEIABD" ]; then
    ZFS_HOME_PART="${DISK_SMALL}p4"
    ZFS_DATA_PART="$DATA_PART"     # SDA en CEIABD; la rama nvme no se da aquí

    # Resolver by-id: recorremos los enlaces que apunten al devnode concreto.
    # Preferimos identificadores estables (ata-*, nvme-MODELO-*) sobre wwn-*
    # (que puede no estar presente en algunos firmwares NVMe).
    _resolver_byid() {
        local devnode="$1" link target best="" fallback=""
        for link in /dev/disk/by-id/*; do
            [ -L "$link" ] || continue
            target=$(readlink -f "$link" 2>/dev/null || true)
            [ "$target" = "$devnode" ] || continue
            case "$(basename "$link")" in
                wwn-*)     [ -z "$fallback" ] && fallback="$link" ;;
                *-part[0-9]*) best="$link"; break ;;
                *)         [ -z "$best" ] && best="$link" ;;
            esac
        done
        if [ -n "$best" ]; then
            echo "$best"
        elif [ -n "$fallback" ]; then
            echo "$fallback"
        else
            echo "$devnode"
        fi
    }
    ZFS_HOME_BYID=$(_resolver_byid "$ZFS_HOME_PART")
    ZFS_DATA_BYID=$(_resolver_byid "$ZFS_DATA_PART")
    echoverde "  ZFS rpool by-id: $ZFS_HOME_BYID"
    echoverde "  ZFS tank  by-id: $ZFS_DATA_BYID"
fi

# ─────────────── Formatear ─────────────
# En CEIABD las particiones BF00 (ZFS) NO se formatean aquí: las inicializa
# 'zpool create' más abajo. En Distancia se formatea todo a ext4 como siempre.
if [ "$PERFIL" = "DISTANCIA" ]; then
    echoamarillo "Formateando (EFI=$EFI, SWAP=$SWAP, ROOT=$ROOT, DATA=$DATA_PART)..."
else
    echoamarillo "Formateando ext4/FAT/swap (EFI=$EFI, SWAP=$SWAP, ROOT=$ROOT); ZFS se crea aparte"
fi
mkfs.fat -F32 "$EFI"
mkswap "$SWAP"
mkfs.ext4 -F "$ROOT"
if [ "$PERFIL" = "DISTANCIA" ]; then
    mkfs.ext4 -F "$DATA_PART"
    _UUID_CHECK=("$EFI" "$SWAP" "$ROOT" "$DATA_PART")
else
    _UUID_CHECK=("$EFI" "$SWAP" "$ROOT")
fi

_FALLOS=0
for _p in "${_UUID_CHECK[@]}"; do
    blkid "$_p" >/dev/null 2>&1 || { echorojo "  blkid sin datos para $_p"; _FALLOS=$((_FALLOS+1)); }
done
if [ "$_FALLOS" -gt 0 ]; then
    echorojo "Error: no se pudieron formatear correctamente las particiones"
    sleep 10 && exit 1
fi
echoamarillo "--- UUIDs asignados ---"
for _p in "${_UUID_CHECK[@]}"; do
    blkid "$_p" 2>/dev/null || echorojo "  blkid sin datos para $_p"
done
echoverde "Particiones formateadas correctamente"

# ─────────────── Montar ────────────────
echoamarillo "Montando sistemas de ficheros..."
mount "$ROOT"      /mnt
mkdir -p /mnt/boot/efi
mount "$EFI"       /mnt/boot/efi
swapon "$SWAP"

if [ "$PERFIL" = "DISTANCIA" ]; then
    # Distancia (sin ZFS): el disco grande lleva ext4 y se monta aquí.
    # Conservamos las dos ramas (sd*/nvme*) por seguridad ante hardware fuera
    # del catálogo, aunque en Distancia el grande es siempre NVMe.
    if [[ "$DISK_BIG" == *sd* ]]; then
        mkdir -p /mnt/datos
        mount "$DATA_PART" /mnt/datos
        echoverde "Disco grande (SD) montado en /mnt/datos"
    else
        mkdir -p /mnt/home
        mount "$DATA_PART" /mnt/home
        echoverde "Disco grande (NVMe) montado en /mnt/home"
    fi
fi
# En CEIABD los datasets ZFS se crean y montan en el bloque ZFS de más abajo
# (rpool/home → /mnt/home, tank/datos → /mnt/datos). Aquí no se hace nada
# para no anticipar montajes que ZFS gestionará con su altroot.

lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,UUID
echoamarillo "--- Espacio disponible en puntos de montaje ---"
df -h /mnt /mnt/boot/efi 2>/dev/null || df -h /mnt
echoverde "Sistemas de ficheros montados"

# ─────────────── ZFS (solo CEIABD) ─────
# Sólo el perfil CEIABD usa ZFS. Distancia mantiene ext4 íntegro.
# Decisión documentada en Ubuntu/RegistroDeCambios/20260520-Cambios.md.
if [ "$PERFIL" = "CEIABD" ]; then
    echoamarillo "Instalando zfsutils-linux en el entorno live..."
    # 0b-Github.sh ya enmascaró update-initramfs → la postinst de zfs-* no se
    # cuelga reconstruyendo el initramfs del live. El módulo zfs viene con
    # firma Canonical en el kernel del live, no requiere DKMS aquí.
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y zfsutils-linux
    modprobe zfs || { echorojo "Error: no se pudo cargar el módulo ZFS en el live"; sleep 10 && exit 1; }
    ZFS_VER=$(zfs version 2>/dev/null | head -1 | awk '{print $NF}' | sed -e 's/^zfs-//' -e 's/-.*//')
    echoverde "  ZFS versión: ${ZFS_VER:-desconocida}"

    # Fast Dedup (OpenZFS ≥ 2.3) ahorra ~50 % de RAM en la DDT respecto al
    # dedup clásico. Si está disponible lo activamos; si no, dedup clásico.
    FAST_DEDUP_OPT=""
    if [ -n "$ZFS_VER" ] && printf '%s\n2.3.0\n' "$ZFS_VER" | sort -V -C 2>/dev/null; then
        FAST_DEDUP_OPT="-o feature@fast_dedup=enabled"
        echoverde "  Fast Dedup disponible (OpenZFS ≥ 2.3) → activado"
    else
        echoamarillo "  Fast Dedup NO disponible (ZFS < 2.3) → dedup clásico"
    fi

    # Limpiar pools preexistentes (de pruebas previas en el mismo equipo).
    # Sin esto, 'zpool create' falla con "device already in use".
    for _pool in rpool tank; do
        if zpool list -H -o name 2>/dev/null | grep -qx "$_pool"; then
            echoamarillo "  zpool $_pool ya importado en el live — exportando..."
            zpool export "$_pool" 2>/dev/null || zpool destroy -f "$_pool" 2>/dev/null || true
        fi
        if zpool import -d /dev/disk/by-id 2>/dev/null | grep -qE "pool:[[:space:]]+$_pool\b"; then
            echoamarillo "  zpool $_pool importable de instalación previa — destruyendo..."
            zpool import -f -d /dev/disk/by-id "$_pool" 2>/dev/null \
                && zpool destroy -f "$_pool" 2>/dev/null || true
        fi
    done
    # sgdisk --zap-all + wipefs ya hicieron limpieza; este wipefs final cubre
    # cualquier label ZFS residual escrito tras el zap (raro pero posible).
    wipefs -a "$ZFS_HOME_PART" 2>/dev/null || true
    wipefs -a "$ZFS_DATA_PART" 2>/dev/null || true

    mkdir -p /mnt/etc/zfs

    echoamarillo "Creando zpool rpool (dedup=on + zstd, recordsize=64K) en $ZFS_HOME_BYID..."
    # -R /mnt = altroot: los datasets se montan bajo /mnt/* mientras estamos
    #           en el live; al exportar/reimportar en el sistema instalado
    #           pasan a /home, /datos, etc. directos.
    # cachefile=/etc/zfs/zpool.cache + copia posterior a /mnt/etc/zfs/ permite
    # que zfs-mount.service del sistema instalado importe el pool sin escanear
    # discos al arrancar.
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -o cachefile=/etc/zfs/zpool.cache \
        $FAST_DEDUP_OPT \
        -O acltype=posixacl -O xattr=sa \
        -O atime=off -O relatime=on \
        -O canmount=off -O mountpoint=none \
        -O compression=zstd \
        -O dedup=on \
        -O recordsize=64K \
        -R /mnt \
        rpool "$ZFS_HOME_BYID"
    # Dataset ÚNICO y DEFINITIVO: rpool/home canmount=on mountpoint=/home.
    # El rsync vuelca /home (squashfs) al pool y los usuarios viven como
    # directorios normales dentro (sin datasets por usuario ni cuotas —
    # simplificación 2026-06-12; antes 2-SetupSOdesdeLiveCD.sh lo
    # reestructuraba en contenedor + rpool/home/<usuario>).
    zfs create -o canmount=on -o mountpoint=/home rpool/home
    echoverde "  rpool creado, dataset rpool/home montado en /mnt/home"

    echoamarillo "Creando zpool tank (zstd, sin dedup, recordsize=1M) en $ZFS_DATA_BYID..."
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -o cachefile=/etc/zfs/zpool.cache \
        -O acltype=posixacl -O xattr=sa \
        -O atime=off -O relatime=on \
        -O canmount=off -O mountpoint=none \
        -O compression=zstd \
        -O recordsize=1M \
        -R /mnt \
        tank "$ZFS_DATA_BYID"
    # /datos: área compartida estilo /tmp (sticky); setuid/devices=off por seguridad.
    zfs create -o canmount=on -o mountpoint=/datos -o setuid=off -o devices=off tank/datos
    chmod 1777 /mnt/datos
    echoverde "  tank creado, dataset tank/datos montado en /mnt/datos (1777)"

    echoamarillo "--- zpool status ---"
    zpool status
    echoamarillo "--- zfs list ---"
    zfs list -o name,used,avail,refer,mountpoint
    echoverde "ZFS listo para el rsync (datasets visibles bajo /mnt)"
fi

# ─────────────── Copiar squashfs ───────
# Ubuntu <24.04 usa un único filesystem.squashfs.
# Ubuntu 26.04+ usa capas minimal.*.squashfs que se combinan con overlayfs.
SQ_MOUNTS=()
SRC=""

SQUASHFS_SINGLE=$(find /cdrom -name "filesystem.squashfs" 2>/dev/null | head -1)
if [[ -n "$SQUASHFS_SINGLE" ]]; then
    echoamarillo "Montando squashfs único: $SQUASHFS_SINGLE ..."
    mkdir -p /tmp/sq0
    mount -o loop "$SQUASHFS_SINGLE" /tmp/sq0
    SQ_MOUNTS+=("/tmp/sq0")
    SRC=/tmp/sq0
else
    echoamarillo "Ubuntu 26.04+: combinando capas squashfs con overlayfs..."
    LOWER=""
    i=0
    # Las capas se aplican de menos a más específica; overlayfs quiere la más específica primero (izquierda)
    for layer in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
        f="/cdrom/casper/$layer"
        [[ -f "$f" ]] || continue
        mnt="/tmp/sq$i"; mkdir -p "$mnt"
        mount -o loop,ro "$f" "$mnt"
        SQ_MOUNTS+=("$mnt")
        LOWER="${mnt}${LOWER:+:$LOWER}"   # prepend → la más nueva queda a la izquierda (mayor prioridad)
        echoverde "  + capa $i: $layer"
        (( i++ )) || true
    done
    if [[ ${#SQ_MOUNTS[@]} -eq 0 ]]; then
        echorojo "No se encontró ningún squashfs en /cdrom/casper. Disponibles:"
        find /cdrom -name "*.squashfs" 2>/dev/null || true
        sleep 10 && exit 1
    fi
    mkdir -p /tmp/merged
    mount -t overlay overlay -o lowerdir="$LOWER" /tmp/merged
    SRC=/tmp/merged
fi

echoamarillo "Copiando sistema de archivos a /mnt ..."
rsync -a --info=progress2 --exclude=/etc/fstab --exclude=/etc/machine-id "$SRC/" /mnt/ >/dev/tty
echoverde "Sistema de archivos copiado desde $SRC"
if [ -f /mnt/usr/share/backgrounds/iac-iesmhp.png ]; then
    echoverde "  Fondo de escritorio copiado: /usr/share/backgrounds/iac-iesmhp.png (OK)"
else
    echoamarillo "  AVISO: /usr/share/backgrounds/iac-iesmhp.png no encontrado en /mnt — el fondo no se aplicará"
fi

# Desmontar todo
[[ "$SRC" == "/tmp/merged" ]] && umount /tmp/merged
for mnt in "${SQ_MOUNTS[@]}"; do umount "$mnt"; done

# ─────────────── ZFS: copiar zpool.cache + hostid al sistema instalado ─
# Se hace AHORA, después del rsync, porque el rsync arrastra /etc/ del squashfs
# y podría sobrescribir lo que hubiéramos puesto antes.
# 1) zpool.cache: zfs-mount.service del sistema instalado importa los pools
#    enumerados en este fichero sin escanear /dev/disk al arranque.
# 2) /etc/hostid: los labels ZFS de los discos contienen el hostid del SO que
#    los creó (el live). zfs-import-cache compara ese hostid con el de
#    /etc/hostid del sistema; si difieren, falla "pool last accessed by host..."
#    Copiar el hostid del live al sistema instalado garantiza que coinciden.
if [ "$PERFIL" = "CEIABD" ]; then
    mkdir -p /mnt/etc/zfs
    if [ -f /etc/zfs/zpool.cache ]; then
        cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
        echoverde "zpool.cache copiado a /mnt/etc/zfs/ ($(stat -c%s /mnt/etc/zfs/zpool.cache) bytes)"
    else
        echoamarillo "AVISO: /etc/zfs/zpool.cache no existe en el live — zfs-mount escaneará discos al arrancar"
    fi
    if [ -f /etc/hostid ]; then
        cp /etc/hostid /mnt/etc/hostid
        echoverde "/etc/hostid copiado al sistema instalado ($(od -An -tx4 /etc/hostid 2>/dev/null | tr -d ' '))"
    else
        # En ese caso ZFS importará con -f en el sistema (no crítico, sí ruidoso)
        echoamarillo "AVISO: /etc/hostid no existe en el live — el sistema instalado importará con -f"
    fi
fi

# ─────────────── Preparar chroot ───────
# Solo los filesystems virtuales del kernel; /bin y /lib vienen del squashfs instalado
for dir in /dev /proc /sys /run; do
    mkdir -p "/mnt$dir"
    mount --bind "$dir" "/mnt$dir"
done
mount --bind /dev/pts /mnt/dev/pts 2>/dev/null || true

# ─────────────── Copiar scripts al destino ─
# RAIZSCRIPTSDISTRO: ruta dentro del sistema instalado donde estarán los scripts
RAIZSCRIPTSDISTRO="/mnt${RAIZSCRIPTS}/${DISTRO}/ISO/${versionDISTRO}"
DISTROLOGS="/mnt${RAIZLOG}"

mkdir -p "$RAIZSCRIPTSDISTRO"
mkdir -p "$DISTROLOGS"

echo
echoamarillo "Copiando ${RAIZSCRIPTSLIVE}/*.* → /mnt${RAIZSCRIPTS}/"
cp "${RAIZSCRIPTSLIVE}"/*.* "/mnt${RAIZSCRIPTS}/" 2>/dev/null || true

# CAMBIO: destino usa $DISTRO en lugar de "Mint" hardcodeado
echoamarillo "Copiando ${RAIZSCRIPTSLIVE}/${DISTRO}/ → /mnt${RAIZSCRIPTS}/${DISTRO}/"
mkdir -p "/mnt${RAIZSCRIPTS}/${DISTRO}"
cp -r "${RAIZSCRIPTSLIVE}/${DISTRO}/." "/mnt${RAIZSCRIPTS}/${DISTRO}/"

# ─────────────── Verificar SCRIPT2 ─────
if [ ! -f "$RAIZSCRIPTSDISTRO/$SCRIPT2" ]; then
    echorojo "No se encontró el script de configuración: $RAIZSCRIPTSDISTRO/$SCRIPT2"
    sleep 10 && exit 1
else
    chmod +x "${RAIZSCRIPTSDISTRO}"/*.sh
fi

# ─────────────── Verificar entorno chroot ──
echoamarillo "Verificando entorno chroot..."
if [ ! -f /mnt/usr/bin/bash ]; then
    echorojo "Error: /mnt/usr/bin/bash no existe — el squashfs no se copió correctamente"
    sleep 10 && exit 1
fi
echoverde "  OK: /mnt/usr/bin/bash existe $(ls -la /mnt/usr/bin/bash | awk '{print $5, $9}')"

if [ ! -e /mnt/lib64 ]; then
    echorojo "Error: /mnt/lib64 no existe — falta el intérprete ELF en el chroot"
    sleep 10 && exit 1
fi
echoverde "  OK: /mnt/lib64 → $(readlink /mnt/lib64 2>/dev/null || echo '(directorio)')"

if ! chroot /mnt /bin/bash --version &>/dev/null; then
    echorojo "Error: chroot /mnt /bin/bash falla — el entorno chroot no es funcional"
    echoamarillo "  Intérprete ELF: $(readelf -l /mnt/usr/bin/bash 2>/dev/null | grep interpreter | awk -F'[][]' '{print $2}' || echo 'no se pudo leer')"
    sleep 10 && exit 1
fi
echoverde "  OK: chroot funcional — $(chroot /mnt /bin/bash --version 2>&1 | head -1)"


# ─────────────── Log de este script ────
echoamarillo "Copiando logs a $DISTROLOGS/"
cp "$RAIZLOG/1-SetupLiveCD.sh.log" "$DISTROLOGS/1-SetupLiveCD.sh.log"
# 0b-Github.sh escribe su log en el mismo RAIZLOG del live CD
if [ -f "$RAIZLOG/0b-Github.sh.log" ]; then
    cp "$RAIZLOG/0b-Github.sh.log" "$DISTROLOGS/0b-Github.sh.log"
    echoverde "  0b-Github.sh.log copiado"
fi

# ─────────────── Pasar particiones al chroot ──
# lsblk dentro del chroot ve los mount points del HOST (/mnt, /mnt/boot/efi...),
# no los del sistema instalado (/,/boot/efi...). Se pasa la info en un fichero.
# El fichero ahora distingue perfil DISTANCIA (ext4) vs CEIABD (ZFS): el
# script de chroot decide cómo montar y qué entradas escribir en /etc/fstab
# según presencia de las variables ZFS_*.
mkdir -p /mnt/tmp
{
    echo "PERFIL=$PERFIL"
    echo "PART_EFI=$EFI"
    echo "PART_SWAP=$SWAP"
    echo "PART_ROOT=$ROOT"
    if [ "$PERFIL" = "DISTANCIA" ]; then
        echo "PART_DATA=$DATA_PART"
    else
        # CEIABD: el "data" lógico vive en ZFS — no hay UUID ext4.
        # PART_DATA queda vacío como marcador para 2-SetupSOdesdeLiveCD.sh.
        echo "PART_DATA="
        echo "ZFS_POOL_HOME=rpool"
        echo "ZFS_HOME_DATASET=rpool/home"
        echo "ZFS_HOME_PARTID=$ZFS_HOME_BYID"
        echo "ZFS_POOL_DATA=tank"
        echo "ZFS_DATA_DATASET=tank/datos"
        echo "ZFS_DATA_PARTID=$ZFS_DATA_BYID"
    fi
} > /mnt/tmp/.iac-partitions.env

echoverde "Particiones escritas para el chroot (perfil=$PERFIL):"
sed 's/^/  /' /mnt/tmp/.iac-partitions.env

# ─────────────── Ejecutar SCRIPT2 ──────
echoamarillo "Ejecutando $SCRIPT2 en chroot... (${RAIZSCRIPTSDISTRO#/mnt}/$SCRIPT2)"
echo "chroot /mnt ${RAIZSCRIPTSDISTRO#/mnt}/$SCRIPT2 2>&1 | tee $DISTROLOGS/$SCRIPT2.log" 
chroot /mnt "${RAIZSCRIPTSDISTRO#/mnt}/$SCRIPT2" 2>&1 | tee "$DISTROLOGS/$SCRIPT2.log"

# ─────────────── Resultado ─────────────
echo && echo
if [[ "$(tail -n 1 "$DISTROLOGS/$SCRIPT2.log")" == "Correcto" ]]; then
    # Antes del reboot, exportar los pools ZFS limpiamente. Sin esto el sistema
    # instalado vería los pools marcados "in use" (por el hostid del live) y
    # zfs-import-cache.service tendría que importarlos con -f, o peor, fallar.
    # Los bind-mounts /dev /proc /sys /run del chroot se desmontan en el shutdown
    # de systemd antes de invocar el export; aquí los desmontamos a mano para
    # que el umount de /mnt/home y /mnt/datos no falle por filesystems busy.
    if [ "$PERFIL" = "CEIABD" ]; then
        echoamarillo "Exportando zpools antes del reboot..."
        # Quitar bind-mounts virtuales del chroot (orden inverso al bind).
        umount -l /mnt/dev/pts 2>/dev/null || true
        for _d in /mnt/run /mnt/sys /mnt/proc /mnt/dev; do
            umount -l "$_d" 2>/dev/null || true
        done
        # Pequeño sync explícito y export con -f por si quedó un mount lazy.
        sync
        zpool sync rpool tank 2>/dev/null || true
        zpool export tank 2>/dev/null || zpool export -f tank 2>/dev/null || \
            echoamarillo "  tank no se pudo exportar limpiamente (el sistema lo importará con -f)"
        zpool export rpool 2>/dev/null || zpool export -f rpool 2>/dev/null || \
            echoamarillo "  rpool no se pudo exportar limpiamente (el sistema lo importará con -f)"
        echoverde "Zpools exportados."
    fi
    echo -e "\e[32mInstalación completada. Reinicia el sistema para iniciar $DISTRO $versionDISTRO.\e[0m"
    sleep 10 && reboot
else
    setxkbmap es || true
    echo -e "\e[31mInstalación fallida. Revisa logs: /mnt${RAIZLOG}\e[0m"
    # En fallo NO exportamos los pools: queremos que sigan accesibles desde /mnt
    # para diagnóstico (zfs list, zpool status, navegar /mnt/home, /mnt/datos).
    sleep 100000
fi