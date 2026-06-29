#!/bin/bash
set -e
VERSIONSCRIPT="23.7-20260612-zfs-homeunico"

# Variables comunes del proyecto (REPO, DISTRO, RAIZSCRIPTS, RAIZDISTRO,
# RAIZLOG, versionDISTRO...). Único punto de definición: comun.sh (mismo
# directorio; este script corre dentro del chroot con ruta absoluta).
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_DIR/comun.sh"

SCRIPT3="$(basename "$SCRIPT_PRIMERINICIO")"

# ─── Logging propio ───────────────────────────────────────────────────────────
# Todo stdout/stderr va al terminal (via tee del padre) Y a este log.
# Además se genera un fichero .steps con una línea por paso, para diagnóstico rápido.
mkdir -p "$RAIZLOG"
LOG2="$RAIZLOG/2-SetupSOdesdeLiveCD.sh.log"
STEPS="$RAIZLOG/2-SetupSOdesdeLiveCD.steps"
exec > >(tee -a "$LOG2") 2>&1
: > "$STEPS"   # vaciar/crear fichero de pasos

_PASO=0
paso() {
    _PASO=$((_PASO + 1))
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  PASO ${_PASO}: $*"
    echo "  ${ts}"
    echo "════════════════════════════════════════════════════════════"
    echo "[PASO${_PASO}][${ts}] INICIO: $*" >> "$STEPS"
}
ok()   { echo -e "  \033[32m[OK ]\033[0m  $(date '+%H:%M:%S') $*";  echo "  [OK ] $(date '+%H:%M:%S') $*" >> "$STEPS"; }
err()  { echo -e "  \033[31m[ERR]\033[0m  $(date '+%H:%M:%S') $*" >&2; echo "  [ERR] $(date '+%H:%M:%S') $*" >> "$STEPS"; }
info() { echo -e "  \033[36m[INF]\033[0m  $(date '+%H:%M:%S') $*";  echo "  [INF] $(date '+%H:%M:%S') $*" >> "$STEPS"; }

# Funciones de colores (compatibilidad con código existente)
echoverde()    { echo -e "\033[32m$1\033[0m"; }
echorojo()     { echo -e "\033[31m$1\033[0m"; }
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

paso "Inicio — $0 (vs$VERSIONSCRIPT) — chroot $(hostname)"
info "RAIZLOG=$RAIZLOG  RAIZDISTRO=$RAIZDISTRO"
info "Log completo : $LOG2"
info "Fichero pasos: $STEPS"

# ─────────────────────────────────────────────────────────────────────────────
# Cargar perfil y variables de partición pasadas por 1-SetupLiveCD.sh.
# Se hace AQUÍ (antes del primer bloque) porque varios bloques posteriores
# se ramifican según PERFIL (CEIABD = ZFS, DISTANCIA = ext4) y según existencia
# de variables ZFS_*. Si el fichero no existe (re-ejecución manual del script
# desde un sistema ya instalado), se asume DISTANCIA por compatibilidad.
# ─────────────────────────────────────────────────────────────────────────────
PARTS_FILE_GLOBAL=/tmp/.iac-partitions.env
if [ -f "$PARTS_FILE_GLOBAL" ]; then
    # shellcheck disable=SC1090
    source "$PARTS_FILE_GLOBAL"
    info "Perfil cargado: PERFIL=${PERFIL:-<no fijado>}"
    if [ "$PERFIL" = "CEIABD" ]; then
        info "  ZFS_POOL_HOME=${ZFS_POOL_HOME:-} HOME=${ZFS_HOME_DATASET:-} → ${ZFS_HOME_PARTID:-}"
        info "  ZFS_POOL_DATA=${ZFS_POOL_DATA:-} DATA=${ZFS_DATA_DATASET:-} → ${ZFS_DATA_PARTID:-}"
    fi
else
    info "No se encontró $PARTS_FILE_GLOBAL — asumiendo PERFIL=DISTANCIA (compatibilidad)"
    PERFIL="${PERFIL:-DISTANCIA}"
fi
: "${PERFIL:=DISTANCIA}"   # default por si .env existe pero no la define

# ─────────────────────────────────────────────────────────────────────────────
paso "Idioma, teclado y zona horaria"
# ─────────────────────────────────────────────────────────────────────────────
sed -i 's/# es_ES.UTF-8/es_ES.UTF-8/g' /etc/locale.gen
locale-gen es_ES.UTF-8

printf 'LANG=es_ES.UTF-8\nLC_ALL=es_ES.UTF-8\nLANGUAGE=es_ES\n' > /etc/default/locale
printf 'XKBLAYOUT=es\nXKBMODEL=pc105\nXKBVARIANT=\nXKBOPTIONS=\n' > /etc/default/keyboard

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-language << 'LANGEOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'es')]

[org/gnome/system/locale]
region='es_ES.UTF-8'
LANGEOF
ok "Idioma y teclado configurados"

ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
echo "Europe/Madrid" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
ok "Zona horaria configurada: Europe/Madrid ($(date '+%Z %z'))"

# ─────────────────────────────────────────────────────────────────────────────
paso "Fondo de escritorio (todos los usuarios)"
# ─────────────────────────────────────────────────────────────────────────────
# Estrategia de dos capas para cubrir todos los casos:
#
#  1. GSettings schema override  → establece el DEFAULT de GSettings compilado
#     en disco. No requiere D-Bus. Se aplica a todos los usuarios que no tengan
#     un valor en su user-db (es decir, cualquier usuario recién creado).
#
#  2. dconf system-db:local      → override de sistema en tiempo de ejecución.
#     Tiene prioridad sobre el schema default pero requiere que dconf update
#     compile el fichero binario. En chroot puede fallar; si falla, la capa 1
#     garantiza el fondo correcto igualmente.

# ── Capa 1: GSettings schema override ──────────────────────────────────────
mkdir -p /usr/share/glib-2.0/schemas
cat > /usr/share/glib-2.0/schemas/99-iac-iesmhp-wallpaper.gschema.override << 'GSEOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-uri-dark='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-options='zoom'
GSEOF
glib-compile-schemas /usr/share/glib-2.0/schemas/ \
    && ok "GSettings schema de fondo compilado (fondo predeterminado para todos los usuarios)" \
    || info "glib-compile-schemas falló en chroot — se recompilará en el primer arranque"

# Borrar el user-db de skel si contiene un fondo distinto al nuestro,
# para que nuevos usuarios partan del schema default (nuestro fondo).
_SKEL_DCONF=/etc/skel/.config/dconf/user
if [ -f "$_SKEL_DCONF" ]; then
    rm -f "$_SKEL_DCONF"
    ok "Eliminado $_SKEL_DCONF (evita que nuevos usuarios hereden el fondo estándar de Ubuntu)"
fi

# ── Capa 2: dconf system-db:local ──────────────────────────────────────────
mkdir -p /etc/dconf/profile
[ -f /etc/dconf/profile/user ] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-wallpaper << 'WALLEOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-uri-dark='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-options='zoom'
WALLEOF

# Pantalla de inicio de sesión GDM: logotipo del IES
_GDM_WM="$RAIZDISTRO/imagenesIES/watermark.png"
if [ -f "$_GDM_WM" ]; then
    cp "$_GDM_WM" /usr/share/backgrounds/iac-iesmhp-watermark.png
    cat > /etc/dconf/profile/gdm << 'GDMPROF'
user-db:user
system-db:gdm
GDMPROF
    mkdir -p /etc/dconf/db/gdm.d
    cat > /etc/dconf/db/gdm.d/00-login-screen << 'GDMEOF'
[org/gnome/login-screen]
logo='/usr/share/backgrounds/iac-iesmhp-watermark.png'
GDMEOF
    ok "Logo GDM configurado: /usr/share/backgrounds/iac-iesmhp-watermark.png"
else
    info "watermark.png no encontrado en $RAIZDISTRO/imagenesIES/ — logo GDM omitido"
fi

dconf update && ok "dconf actualizado (system-db compilado)" \
    || info "dconf update falló en chroot — el schema override (capa 1) garantiza el fondo igualmente"

# ─────────────────────────────────────────────────────────────────────────────
paso "Eliminar autostart del Live CD del sistema instalado"
# ─────────────────────────────────────────────────────────────────────────────
# iac-iesmhp-setup.desktop se embebe en el squashfs para arrancar el script de
# instalación durante el Live CD. El rsync lo copia al sistema instalado, por
# lo que sin este paso GNOME lo ejecutaría en cada login del sistema ya instalado.
# Se elimina de skel (antes de crear el usuario 'usuario') y del home de ubuntu.
for _autostart_file in \
    /etc/skel/.config/autostart/iac-iesmhp-setup.desktop \
    /home/ubuntu/.config/autostart/iac-iesmhp-setup.desktop
do
    if [ -f "$_autostart_file" ]; then
        rm -f "$_autostart_file"
        ok "Eliminado: $_autostart_file"
    else
        info "No presente: $_autostart_file"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
paso "Rehabilitar snapd y eliminar el instalador de Ubuntu (sistema instalado)"
# ─────────────────────────────────────────────────────────────────────────────
# 0a-CreaISO.sh enmascara snapd en el squashfs (symlinks a /dev/null) para que el
# Live CD arranque en ~10 s en lugar de ~3 min. El rsync de 1-SetupLiveCD.sh solo
# excluye /etc/fstab y /etc/machine-id, así que esos symlinks se copian al sistema
# instalado y snapd queda MASKED → Firefox (snap) no arranca
# ("Unit snapd.service is masked"). Aquí se DESenmascara y habilita SOLO en el
# sistema instalado; el squashfs (y por tanto el arranque rápido del Live CD) no
# se toca.
for _snapunit in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
    _link="/etc/systemd/system/$_snapunit"
    if [ -L "$_link" ] && [ "$(readlink "$_link" 2>/dev/null)" = "/dev/null" ]; then
        rm -f "$_link"
        info "  Desenmascarado (symlink → /dev/null eliminado): $_link"
    fi
done
systemctl unmask snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service 2>/dev/null || true
# `systemctl enable` es offline-capable en chroot: solo crea los symlinks de la
# sección [Install]; snapd.service/snapd.seeded se activan vía snapd.socket.
systemctl enable snapd.socket snapd.seeded.service snapd.apparmor.service 2>/dev/null || true
if [ -L /etc/systemd/system/snapd.service ] || [ -L /etc/systemd/system/snapd.socket ]; then
    err "snapd sigue enmascarado tras el intento de desenmascarar — revisar manualmente"
else
    ok "snapd desenmascarado y snapd.socket habilitado en el sistema instalado"
fi

# El instalador de Ubuntu (snap 'ubuntu-desktop-bootstrap', el mismo asistente
# "Instalar Ubuntu" que aparece en el Live CD) viene en el squashfs y el rsync lo
# arrastra al sistema instalado. En un equipo ya desplegado NO debe ofrecerse
# instalar Ubuntu. Se neutraliza por dos vías complementarias:
#   1) override de autostart Hidden=true (protección inmediata, system-wide → vale
#      también para usuarios nuevos, antes de que snapd reseed/arranque el snap).
#   2) `snap remove --purge` en 3-SetupPrimerInicio.sh (snapd ya en marcha).
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/ubuntu-desktop-bootstrap.desktop << 'BSDESKTOP'
[Desktop Entry]
Type=Application
Name=Ubuntu Desktop Bootstrap
X-GNOME-Autostart-enabled=false
NoDisplay=true
Hidden=true
BSDESKTOP
# Neutralizar también los .desktop que snapd expone para este snap.
for _d in /var/lib/snapd/desktop/applications/ubuntu-desktop-bootstrap*.desktop \
          /var/lib/snapd/desktop/autostart/ubuntu-desktop-bootstrap*.desktop; do
    if [ -e "$_d" ]; then
        rm -f "$_d"
        info "  Eliminado .desktop de snapd: $_d"
    fi
done
ok "Instalador de Ubuntu desactivado vía autostart override (purga real en 3-Setup)"

# ─────────────────────────────────────────────────────────────────────────────
paso "Configurar /etc/fstab"
# ─────────────────────────────────────────────────────────────────────────────
# lsblk dentro del chroot ve los mount points del HOST (/mnt, /mnt/boot/efi…),
# no los del sistema instalado. Las particiones vienen del fichero creado por 1-SetupLiveCD.sh.
# En CEIABD el "disco grande" (SDA) y la p4 del NVMe pequeño viven en ZFS:
#   - rpool/home    montado en /home  (dedup + zstd, recordsize=64K)
#   - tank/datos    montado en /datos (zstd sin dedup, recordsize=1M)
# zfs-mount.service del sistema instalado los monta al arrancar leyendo
# /etc/zfs/zpool.cache (copiado al sistema en 1-SetupLiveCD.sh). Por eso
# /etc/fstab NO lleva entradas para /home ni /datos en CEIABD.
#
# En DISTANCIA el flujo es el clásico ext4: /home en el NVMe grande;
# se mantiene la lógica histórica intacta.
EFI="${PART_EFI##*/}"
SWAP="${PART_SWAP##*/}"
ROOT="${PART_ROOT##*/}"
DATA_DEV=""
DATA_MNT=""
if [ "$PERFIL" = "DISTANCIA" ] && [ -n "${PART_DATA:-}" ]; then
    DATA_DEV="${PART_DATA##*/}"
    if [[ "$PART_DATA" == *nvme* ]]; then
        DATA_MNT="/home"
    else
        DATA_MNT="/datos"
    fi
fi

if [ -z "$ROOT" ]; then
    # Fallback con lsblk si no había .iac-partitions.env (caso de re-ejecución).
    err "AVISO: variables PART_* no presentes — detección automática"
    EFI=$(lsblk  -rno NAME,MOUNTPOINT | awk '$2 == "/mnt/boot/efi" {print $1}')
    SWAP=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "[SWAP]"        {print $1}')
    ROOT=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/mnt"          {print $1}')
    if [ "$PERFIL" = "DISTANCIA" ]; then
        DATA_DEV=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/mnt/home" {print $1}')
        if [ -n "$DATA_DEV" ]; then
            DATA_MNT="/home"
        else
            DATA_DEV=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/mnt/datos" {print $1}')
            DATA_MNT="/datos"
        fi
    fi
fi

if [ "$PERFIL" = "DISTANCIA" ]; then
    ok "Particiones leídas: EFI=$EFI  SWAP=$SWAP  ROOT=$ROOT  DATA=$DATA_DEV → $DATA_MNT"
else
    ok "Particiones leídas: EFI=$EFI  SWAP=$SWAP  ROOT=$ROOT  (ZFS gestiona /home y /datos)"
fi

info "EFI=/dev/$EFI  SWAP=/dev/$SWAP  ROOT=/dev/$ROOT"
[ -n "$ROOT" ] || { err "ERROR: no se pudo determinar la partición root"; exit 1; }

UUID_ROOT=$(blkid -s UUID -o value "/dev/$ROOT")
UUID_EFI=$(blkid  -s UUID -o value "/dev/$EFI")
UUID_SWAP=$(blkid -s UUID -o value "/dev/$SWAP")
UUID_DATA=""
if [ -n "$DATA_DEV" ]; then
    UUID_DATA=$(blkid -s UUID -o value "/dev/$DATA_DEV")
fi
info "UUID ROOT=$UUID_ROOT  EFI=$UUID_EFI  SWAP=$UUID_SWAP$( [ -n "$UUID_DATA" ] && echo "  DATA=$UUID_DATA ($DATA_MNT)")"

# Punto de montaje del disco grande (solo Distancia con /datos ext4).
# En CEIABD, /datos lo gestiona ZFS (tank/datos) y no hay que crearlo aquí
# — el chroot ve /datos como dataset montado vía el altroot del live CD.
if [ "$DATA_MNT" = "/datos" ]; then
    mkdir -p /datos
    chmod 1777 /datos
    ok "Punto de montaje /datos creado (1777, área de datos compartida)"
fi

if [ "$PERFIL" = "DISTANCIA" ]; then
    cat > /etc/fstab << EOF
# /etc/fstab — generado por $0 el $(date) (perfil DISTANCIA, ext4)
UUID=$UUID_ROOT  /          ext4  defaults  0 1
UUID=$UUID_EFI   /boot/efi  vfat  umask=0077  0 1
UUID=$UUID_DATA  $DATA_MNT      ext4  defaults  0 2
UUID=$UUID_SWAP  none       swap  sw          0 0
EOF
    ok "fstab generado con UUIDs (disco grande → $DATA_MNT)"
else
    # CEIABD: ZFS monta /home y /datos vía zfs-mount.service en cada arranque.
    # En fstab quedan solo /, /boot/efi y swap.
    cat > /etc/fstab << EOF
# /etc/fstab — generado por $0 el $(date) (perfil CEIABD, ZFS para /home y /datos)
# /home  ← rpool/home  (zfs-mount.service, ver /etc/zfs/zpool.cache)
# /datos ← tank/datos  (zfs-mount.service)
UUID=$UUID_ROOT  /          ext4  defaults,noatime  0 1
UUID=$UUID_EFI   /boot/efi  vfat  umask=0077        0 1
UUID=$UUID_SWAP  none       swap  sw                0 0
EOF
    ok "fstab generado con UUIDs (/home y /datos los monta ZFS)"
fi
cat /etc/fstab

# ─────────────────────────────────────────────────────────────────────────────
paso "Limpiar fuentes APT del Live CD (cdrom:)"
# ─────────────────────────────────────────────────────────────────────────────
# El Live CD añade una entrada APT que apunta al ISO montado en /cdrom. Puede
# venir con dos formatos de URI:
#   - 'cdrom:[Ubuntu ...]/'   (apt-cdrom tradicional)
#   - 'file:/cdrom'           (Ubuntu 26.04 DEB822, observado en la práctica)
# El rsync copia esa configuración al sistema instalado, donde /cdrom no existe
# → 'apt update' falla con:
#   "El repositorio file:/cdrom resolute Release no tiene un fichero de Publicación"
#
# Cubrimos las dos ubicaciones posibles:
#  - /etc/apt/sources.list (formato clásico una-línea)
#  - /etc/apt/sources.list.d/*.list y *.sources (DEB822, usado por Ubuntu 26.04)

CDROM_LIMPIO=0

# Regex de URI cdrom (ambos formatos): 'cdrom:' o 'file:/cdrom'
_CDROM_URI='(cdrom:|file:/+cdrom)'

# 1) sources.list clásico y ficheros .list: eliminar líneas 'deb [opts] cdrom...'
for _src in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$_src" ] || continue
    if grep -qE "^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?${_CDROM_URI}" "$_src"; then
        info "Antes de limpiar — entradas cdrom en $_src:"
        grep -nE "${_CDROM_URI}" "$_src" | sed 's/^/    /' || true
        sed -i -E "/^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?${_CDROM_URI}/d" "$_src"
        ok "Eliminadas líneas cdrom de $_src"
        CDROM_LIMPIO=$((CDROM_LIMPIO + 1))
    fi
done

# 2) DEB822 (.sources): si el bloque tiene URI cdrom (cualquier formato), o si
#    el propio nombre del fichero contiene 'cdrom' (p.ej. ubuntu-cdrom.sources
#    en Ubuntu 26.04), borrar el fichero entero.
for _src in /etc/apt/sources.list.d/*.sources; do
    [ -f "$_src" ] || continue
    _name=$(basename "$_src")
    _match=0
    if grep -qE "^URIs:[[:space:]]*${_CDROM_URI}" "$_src" \
       || grep -qE "^URIs:.*[[:space:]]${_CDROM_URI}" "$_src"; then
        _match=1
    fi
    case "$_name" in
        *cdrom*) _match=1 ;;
    esac
    if [ "$_match" -eq 1 ]; then
        info "Fichero DEB822 con cdrom: $_src — contenido:"
        sed 's/^/    /' "$_src"
        rm -f "$_src"
        ok "Eliminado: $_src"
        CDROM_LIMPIO=$((CDROM_LIMPIO + 1))
    fi
done

if [ "$CDROM_LIMPIO" -eq 0 ]; then
    info "Ninguna fuente APT con cdrom encontrada (nada que limpiar)"
else
    ok "Total de fuentes APT con cdrom limpiadas: $CDROM_LIMPIO"
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "Verificar conectividad a Internet"
# ─────────────────────────────────────────────────────────────────────────────
while ! ping -c 1 -W 3 1.1.1.1 &>/dev/null; do
    echoamarillo "Sin Internet. Reintentando en 10 s… (Ctrl+C para abortar)"
    sleep 10
done
ok "Internet disponible"

# ─────────────────────────────────────────────────────────────────────────────
if [ "$PERFIL" = "CEIABD" ]; then
paso "Instalar ZFS en el sistema instalado y habilitar servicios"
# ─────────────────────────────────────────────────────────────────────────────
# Los pools rpool y tank YA existen y están importados (los creó 1-SetupLiveCD.sh
# fuera del chroot con altroot=/mnt → dentro del chroot se ven en /home y /datos).
# Aquí instalamos los binarios y el módulo DKMS dentro del sistema instalado
# para que el primer arranque pueda importar y montar los pools sin depender
# del entorno live.

# Deshabilitar os-prober ANTES del primer apt-get install que pueda disparar
# update-grub vía postinst de kernel. Justificación: la instalación de
# linux-headers-generic arrastra un kernel nuevo (linux-image-7.0.0-15-generic
# + linux-main-modules-zfs-...); su postinst llama a /etc/kernel/postinst.d/
# en cadena (initramfs-tools, kdump-tools, ..., zz-update-grub). El último
# ejecuta update-grub → os-prober, que en chroot ve TODO el /dev del live
# (loops snap + zpool rpool/tank importados con altroot=/mnt) e intenta
# montar cada bloque en RO. Con ZFS importado se cuelga indefinidamente
# (síntoma observado 2026-05-20: install bloqueado tras
# "W: kdump-tools: Executing in a chroot, skipping initramfs generation").
# Además es el ajuste correcto en el sistema instalado: solo Ubuntu, sin
# dual-boot — os-prober no aporta nada y añade ruido al arrancar.
if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
fi
info "GRUB_DISABLE_OS_PROBER=true en /etc/default/grub (evita cuelgue de os-prober durante update-grub en chroot)"

apt-get update -y -o Dpkg::Options::="--force-confold" >/dev/null

# Instalar SOLO los binarios y el daemon ZFS — NO actualizar el kernel.
#
# Historia del cuelgue (intentos previos fallidos, documentados en secciones
# 8 y 9 del registro del 2026-05-20):
#   1. GRUB_DISABLE_OS_PROBER=true antes del install → no resolvió.
#   2. chmod -x en hooks /etc/kernel/postinst.d/{unattended-upgrades,
#      update-notifier,zz-flash-kernel,zz-update-grub} → tampoco resolvió.
# El log se cortaba SIEMPRE en el mismo punto:
#   "W: kdump-tools: Executing in a chroot, skipping initramfs generation"
# Conclusión: el cuelgue está en algún mecanismo POSTERIOR a los hooks de
# kernel-postinst.d (probablemente un trigger de dpkg de otro paquete:
# initramfs-tools, grub-efi-amd64 o dbus), que no se controla con chmod -x.
#
# Solución real: NO arrastrar el kernel nuevo en el chroot.
# Antes se instalaba `linux-headers-generic` (requerido por zfs-dkms), pero
# eso provocaba upgrade de los meta-paquetes HWE → instalación de un kernel
# nuevo (linux-image-7.0.0-15-generic + linux-main-modules-zfs-...) → cadena
# de postinst de kernel en chroot que se cuelga.
#
# Razones por las que NO hacen falta linux-headers-generic, zfs-dkms ni
# zfs-initramfs aquí:
#   - El módulo ZFS YA viene en el kernel del squashfs (Canonical lo
#     distribuye precompilado y firmado como `linux-main-modules-zfs-X.Y.Z`,
#     incluido por defecto en el HWE meta-paquete). Prueba: 1-SetupLiveCD.sh
#     hace `modprobe zfs` con éxito → el módulo está en `/lib/modules/X.Y.Z`
#     del squashfs → el rsync ya lo copió a /mnt/lib/modules/.
#   - `/` es ext4 → zfs-initramfs (hook que mete zfs en initrd para boot
#     desde ZFS) no aplica. Los pools se importan vía zfs-import-cache.
#     service tras boot, no en initramfs.
#   - zfs-dkms compila el módulo cuando no hay precompilado → no hace falta
#     mientras usemos kernels HWE oficiales con su `linux-main-modules-zfs-*`.
#
# Si en un futuro `apt-get full-upgrade` (en 3-SetupPrimerInicio.sh) actualiza
# el kernel, el postinst se ejecutará FUERA del chroot (sistema arrancado,
# con systemd/D-Bus reales) → los hooks no se cuelgan. El nuevo kernel
# arrastrará su `linux-main-modules-zfs-X.Y.Z` correspondiente
# automáticamente y todo seguirá funcionando.
info "Instalando solo binarios y daemon ZFS (sin upgrade de kernel)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confold" \
    --no-install-recommends \
    zfsutils-linux zfs-zed \
    || err "Instalación ZFS falló — el primer arranque tendrá que reinstalar (3-SetupPrimerInicio.sh)"

# Habilitar servicios systemd. apt los activa por defecto al instalar; lo
# hacemos explícito por robustez (si en el futuro un postinst los deshabilita
# por algún preset, esta línea los reactiva).
for _svc in zfs.target zfs-import-cache.service zfs-mount.service zfs-zed.service; do
    if systemctl enable "$_svc" 2>/dev/null; then
        ok "  systemctl enable $_svc"
    else
        info "  $_svc no presente o ya habilitado"
    fi
done
# Deshabilitar zfs-import-scan.service: con cachefile activo, escanear todos
# los discos cada arranque es redundante y aumenta el tiempo de boot.
systemctl disable zfs-import-scan.service 2>/dev/null || true

# Refrescar cachefile desde el chroot. Los pools heredan el contexto del live;
# regrabar el cachefile con los binarios del sistema instalado garantiza que
# las propiedades y composición quedan consistentes con su hostid.
# (El fichero /etc/hostid se copió a /mnt en 1-SetupLiveCD.sh tras el rsync.)
zpool set cachefile=/etc/zfs/zpool.cache rpool 2>/dev/null \
    && ok "  cachefile refrescado para rpool" \
    || info "  zpool set rpool cachefile no fue posible (cachefile copiado del live sigue válido)"
zpool set cachefile=/etc/zfs/zpool.cache tank 2>/dev/null \
    && ok "  cachefile refrescado para tank" \
    || info "  zpool set tank cachefile no fue posible"

ok "ZFS instalado y configurado en el chroot"
info "zpool status:"
zpool status 2>/dev/null | sed 's/^/  /' || info "  (zpool status no disponible)"
info "zfs list:"
zfs list -o name,used,avail,refer,mountpoint 2>/dev/null | sed 's/^/  /' || info "  (zfs list no disponible)"

fi

# ─────────────────────────────────────────────────────────────────────────────
paso "MAC, hostname y claves SSH autorizadas"
# ─────────────────────────────────────────────────────────────────────────────
MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
info "MAC detectada: $MAC"
mkdir -p /root/.ssh
LOCAL_MACS="$RAIZSCRIPTS/macs.csv"
LOCAL_AUTORIZADOS="$RAIZSCRIPTS/Autorizados.txt"
cp "$LOCAL_AUTORIZADOS" /root/.ssh/authorized_keys
ok "authorized_keys copiado"

# Nombre por defecto si la MAC no está en macs.csv: 'ld' + fecha de instalación
# (AAAAMMDDHHMM). Se genera UNA sola vez aquí (momento de la instalación) y
# NombreIP.sh lo conserva en el primer arranque, de modo que cada equipo sin
# entrada en macs.csv obtiene un hostname único y trazable (p. ej. ld202606160934).
EQUIPOENMACS="ld$(date +%Y%m%d%H%M)"
if [ ! -f "$LOCAL_MACS" ]; then
    err "No se encontró $LOCAL_MACS — el equipo quedará con nombre '$EQUIPOENMACS'"
else
    if ! grep -q -i "$MAC" "$LOCAL_MACS"; then
        err "MAC $MAC no encontrada en macs.csv — nombre por defecto '$EQUIPOENMACS'"
    else
        INFO_MACS=$(grep -i "$MAC" "$LOCAL_MACS")
        info "Entrada en macs.csv: $INFO_MACS"
        echo "$INFO_MACS" > "$LOCAL_MACS"
        EQUIPOENMACS=$(echo "$INFO_MACS" | cut -d',' -f2 | xargs)
    fi
fi

EQUIPOACTUAL=$(hostname)
if [ "$EQUIPOACTUAL" != "$EQUIPOENMACS" ]; then
    echo "$EQUIPOENMACS" > /etc/hostname
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$EQUIPOENMACS" > /etc/hosts
    hostnamectl set-hostname "$EQUIPOENMACS" 2>/dev/null || true
    ok "Hostname cambiado: $EQUIPOACTUAL → $EQUIPOENMACS"
else
    ok "Hostname correcto: $EQUIPOENMACS"
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "Usuarios (root y usuario)"
# ─────────────────────────────────────────────────────────────────────────────
# CEIABD: /home es el dataset ÚNICO rpool/home (canmount=on, mountpoint=/home),
# creado en 1-SetupLiveCD.sh y montado en este chroot vía la altroot del live
# (host:/mnt/home = chroot:/home). Todos los usuarios viven como directorios
# normales dentro de él: SIN datasets por usuario, SIN cuotas, SIN helper de
# alta (simplificación 2026-06-12; antes había contenedor canmount=off +
# rpool/home/<u> + /usr/local/sbin/nuevo-alumno.sh — ver RegistroDeCambios).
# Alta de usuarios en el equipo instalado: sudo adduser <usuario>.
# Red de seguridad: si el dataset NO estuviera montado, useradd -m escribiría
# al ext4 subyacente y el contenido quedaría oculto al arrancar (zfs-mount
# montaría el dataset encima). Mejor abortar aquí.
if [ "$PERFIL" = "CEIABD" ] && zpool list rpool >/dev/null 2>&1; then
    if ! mountpoint -q /home; then
        err "rpool/home NO está montado en /home — abortando antes de escribir al fs subyacente"
        exit 1
    fi
    ok "rpool/home montado en /home (dataset único, sin cuotas)"
fi

if id usuario &>/dev/null; then
    info "Usuario 'usuario' ya existe"
else
    useradd -m -s /bin/bash -p '*' usuario
    ok "Usuario 'usuario' creado"
fi
adduser usuario sudo 2>/dev/null || usermod -aG sudo usuario
ok "Usuario 'usuario' en grupo sudo"

# Ubuntu 26.04: chpasswd usa PAM con pam_pwquality (mínimo 8 chars).
# Escribir hash SHA-512 directamente en /etc/shadow para evitar pam_pwquality.
# IMPORTANTE: 'usuario' debe existir en /etc/shadow antes de este bloque.
# Por eso useradd está ANTES de aquí (movido de su posición original).
python3 - << 'PYEOF'
import subprocess, re, sys
for user, pw in [('root', 'root'), ('usuario', 'usuario')]:
    h = subprocess.check_output(['openssl', 'passwd', '-6', pw], text=True).strip()
    with open('/etc/shadow', 'r') as f:
        content = f.read()
    updated = re.sub(r'^(' + re.escape(user) + r'):[^:]*:',
                     r'\g<1>:' + h.replace('\\', '\\\\') + ':',
                     content, flags=re.MULTILINE)
    if updated == content:
        print(f'[ERR] {user} no encontrado en /etc/shadow', flush=True)
        sys.exit(1)
    else:
        with open('/etc/shadow', 'w') as f:
            f.write(updated)
        with open('/etc/shadow', 'r') as f:
            check = f.read()
        found = re.search(r'^' + re.escape(user) + r':(\$[^:]+):', check, re.MULTILINE)
        if found:
            print(f'[OK ] {user}: hash {found.group(1)[:8]}... escrito en shadow', flush=True)
        else:
            print(f'[ERR] {user}: hash NO quedó en shadow', flush=True)
            sys.exit(1)
PYEOF
ok "Contraseñas root y usuario establecidas en /etc/shadow"

# Diagnóstico: verificar /etc/nologin (bloquea login de TODOS los usuarios normales)
if [ -f /etc/nologin ]; then
    err "/etc/nologin existe — bloqueará logins! Eliminando..."
    rm -f /etc/nologin
else
    ok "Sin /etc/nologin (correcto)"
fi

if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p /home/usuario/.ssh
    cp /root/.ssh/authorized_keys /home/usuario/.ssh/
    # IMPORTANTE: chown del DIRECTORIO .ssh, no solo del fichero. mkdir lo crea
    # como root (este script corre como root en el chroot); si no se reasigna,
    # el usuario no puede chmod ni escribir su propia clave en ~/.ssh.
    chown -R usuario:usuario /home/usuario/.ssh
    chmod 700 /home/usuario/.ssh
    chmod 600 /home/usuario/.ssh/authorized_keys
    ok "authorized_keys copiado a /home/usuario/.ssh/ (.ssh → usuario:usuario 700)"
fi

# Helper /usr/local/sbin/nuevo-alumno.sh ELIMINADO (2026-06-12): con el
# dataset único rpool/home ya no hay que crear datasets por usuario, así que
# el alta de un usuario nuevo es el flujo estándar: sudo adduser <usuario>.

# ─────────────────────────────────────────────────────────────────────────────
paso "Eliminar usuario ubuntu (Live CD) y deshabilitar auto-login GDM"
# ─────────────────────────────────────────────────────────────────────────────
# El Live CD configura GDM con AutomaticLogin=ubuntu. El rsync copia esa config
# al sistema instalado → arranque sin pantalla de login → sesión como 'ubuntu',
# cuya cuenta puede estar bloqueada en el sistema instalado (PAM la rechaza →
# "cuenta no disponible" en el terminal). El dconf personal de 'ubuntu' también
# sobreescribe el fondo personalizado del IES.
if id ubuntu &>/dev/null; then
    userdel -r ubuntu 2>/dev/null || userdel ubuntu 2>/dev/null || true
    rm -rf /home/ubuntu 2>/dev/null || true
    ok "Usuario 'ubuntu' del Live CD eliminado"
else
    info "Usuario 'ubuntu' no presente"
fi

# CEIABD: snapshot @inicial del dataset único rpool/home. Se toma DESPUÉS de
# eliminar /home/ubuntu (Live CD) para no arrastrarlo en el snapshot. Ancla de
# rollback global: zfs rollback rpool/home@inicial devuelve TODO /home (todos
# los usuarios) al estado post-instalación — usar con cuidado.
if [ "$PERFIL" = "CEIABD" ] && zfs list -H -o name rpool/home >/dev/null 2>&1; then
    if zfs list -H -t snapshot rpool/home@inicial >/dev/null 2>&1; then
        info "Snapshot rpool/home@inicial ya existe"
    else
        zfs snapshot rpool/home@inicial \
            && ok "Snapshot rpool/home@inicial creado" \
            || info "No se pudo crear el snapshot inicial (no crítico)"
    fi
fi

# AccountsService: GDM lee AccountsService con MAYOR PRIORIDAD que /etc/gdm3/custom.conf.
# El Live CD crea /var/lib/AccountsService/users/ubuntu con AutomaticLogin=true.
# El rsync lo copia al sistema instalado. Tot y que custom.conf diga AutomaticLoginEnable=False,
# GDM intenta auto-loguear 'ubuntu' via AccountsService. Como 'ubuntu' no existe en /etc/passwd,
# GDM queda en la sesión greeter (visible como "GDM Greeter").
ACCTS_DIR=/var/lib/AccountsService/users
info "Contenido de $ACCTS_DIR/ (diagnóstico):"
ls -la "$ACCTS_DIR/" 2>/dev/null | while read -r l; do info "  $l"; done || info "  (directorio no existe)"
if [ -f "$ACCTS_DIR/ubuntu" ]; then
    info "Contenido de $ACCTS_DIR/ubuntu:"
    cat "$ACCTS_DIR/ubuntu" | while read -r l; do info "  $l"; done
    rm -f "$ACCTS_DIR/ubuntu"
    ok "AccountsService: auto-login de ubuntu eliminado"
fi
# Registrar 'usuario' en AccountsService para que GDM lo muestre en el selector
mkdir -p "$ACCTS_DIR"
cat > "$ACCTS_DIR/usuario" << 'ACCTEOF'
[User]
Language=es_ES.UTF-8
XSession=ubuntu
SystemAccount=false
ACCTEOF
ok "AccountsService: usuario 'usuario' registrado"

# Registrar 'gdm-greeter' (Ubuntu 26.04+) en AccountsService para forzar la sesión
# de login. Sin esto, GDM lanza para el greeter 'gnome-session' sin --session=, que
# cae al valor por defecto de dconf (session-name='ubuntu') → el greeter arranca el
# escritorio Ubuntu en vez del formulario de login. SystemAccount=true lo oculta del
# selector de usuarios.
if id gdm-greeter &>/dev/null; then
    cat > "$ACCTS_DIR/gdm-greeter" << 'ACCTGRTEOF'
[User]
Session=gnome-login
XSession=gnome-login
SystemAccount=true
ACCTGRTEOF
    ok "AccountsService: gdm-greeter forzado a sesión 'gnome-login'"
else
    info "Usuario 'gdm-greeter' no presente en este sistema — se omite AccountsService"
fi

GDM_CONF=/etc/gdm3/custom.conf
mkdir -p /etc/gdm3

# Diagnóstico: mostrar TODO lo que hay en /etc/gdm3/ para identificar fuentes de auto-login.
info "── Diagnóstico /etc/gdm3/ ──"
find /etc/gdm3 -type f 2>/dev/null | sort | while read -r f; do
    info "Fichero: $f"
    while IFS= read -r l; do info "  $l"; done < "$f"
done || info "  (directorio /etc/gdm3 vacío o no existe)"

# Diagnóstico: PAM gdm — auto-login bypasea contraseña via pam_gdm_autologin
info "── Diagnóstico PAM gdm* ──"
ls /etc/pam.d/gdm* 2>/dev/null | while read -r f; do
    info "Fichero PAM: $f"
    while IFS= read -r l; do info "  $l"; done < "$f"
done || info "  (no hay ficheros pam.d/gdm*)"

# Diagnóstico: debconf values de gdm3 (postinst puede regenerar custom.conf con estos valores)
info "── Diagnóstico debconf gdm3 ──"
debconf-show gdm3 2>/dev/null | while read -r l; do info "  $l"; done || info "  (debconf-show gdm3 falló)"

# Pre-configurar debconf para que el postinst de gdm3 no regenere auto-login.
# dpkg --configure -a (en 3-SetupPrimerInicio.sh) puede ejecutar el postinst de gdm3,
# el cual lee debconf para regenerar custom.conf con AutomaticLoginEnable.
echo "gdm3 gdm3/daemon_section/AutomaticLoginEnable boolean false" | debconf-set-selections 2>/dev/null || true
echo "gdm3 gdm3/daemon_section/AutomaticLogin string " | debconf-set-selections 2>/dev/null || true
info "debconf gdm3 pre-configurado (auto-login=false)"

# Eliminar cualquier fichero drop-in del Live CD que pueda re-habilitar el auto-login.
# Ubuntu 26.04 puede usar /etc/gdm3/custom.conf.d/ para sus overrides de live session.
if [ -d /etc/gdm3/custom.conf.d ]; then
    info "Contenido de /etc/gdm3/custom.conf.d/ antes de limpiar:"
    ls -la /etc/gdm3/custom.conf.d/ | while read -r l; do info "  $l"; done
    rm -rf /etc/gdm3/custom.conf.d
    ok "Directorio /etc/gdm3/custom.conf.d eliminado (evita overrides de auto-login del Live CD)"
fi

cat > "$GDM_CONF" << 'GDMEOF'
[daemon]
AutomaticLoginEnable=false
TimedLoginEnable=false
InitialSetupEnable=false
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
GDMEOF
ok "GDM config sobrescrita (auto-login e initial-setup deshabilitados, Wayland habilitado)"
info "Contenido final de $GDM_CONF:"
while IFS= read -r l; do info "  $l"; done < "$GDM_CONF"

# gnome-initial-setup se lanza en el primer arranque si no existe este flag.
# GDM lo detecta y muestra el asistente de bienvenida EN VEZ de la pantalla de login,
# resultando en "acceder directamente al escritorio" + "cuenta no disponible" al abrir terminal.
# Rutas antiguas (gnome-initial-setup < 46, Ubuntu <= 24.04)
mkdir -p /var/lib/gdm3/.config
touch /var/lib/gdm3/.config/gnome-initial-setup-done
mkdir -p /etc/skel/.config
touch /etc/skel/.config/gnome-initial-setup-done
# Rutas nuevas (gnome-initial-setup >= 46, Ubuntu 26.04+)
mkdir -p /var/lib/gdm3/.local/share
touch /var/lib/gdm3/.local/share/gnome-initial-setup-done
mkdir -p /etc/skel/.local/share
touch /etc/skel/.local/share/gnome-initial-setup-done
if [ -d /home/usuario ]; then
    mkdir -p /home/usuario/.config /home/usuario/.local/share
    touch /home/usuario/.config/gnome-initial-setup-done
    touch /home/usuario/.local/share/gnome-initial-setup-done
    chown -R usuario:usuario /home/usuario/.config /home/usuario/.local
fi
ok "gnome-initial-setup marcado como completado (rutas antiguas y nuevas)"

# Deshabilitar el bloqueo de pantalla en la sesión del GDM greeter.
# GDM en Ubuntu 26.04 corre el greeter como sesión Wayland del usuario 'gdm-greeter'.
# Si el screensaver lo bloquea, aparece "GDM Greeter" en la pantalla de bloqueo
# y el usuario no puede desbloquearlo (no conoce la contraseña del usuario greeter).
#
# Y CRÍTICO: session-name='gnome-login' fuerza a gnome-session (invocado sin --session=
# para el usuario gdm-greeter) a cargar /usr/share/gnome-session/sessions/gnome-login.session
# (Kiosk=true → formulario de login). Sin esto, gnome-session lee session-name del dconf
# del usuario y cae al valor por defecto del sistema ('ubuntu') → el greeter arranca el
# escritorio Ubuntu (gnome-shell --mode=ubuntu) en lugar del login. Se bloquea la clave
# en /etc/dconf/db/gdm.d/locks/ para que ningún dconf de usuario pueda sobreescribirla.
mkdir -p /etc/dconf/db/gdm.d /etc/dconf/db/gdm.d/locks
cat >> /etc/dconf/db/gdm.d/00-login-screen << 'GDMLOCKEOF'

[org/gnome/desktop/session]
idle-delay=uint32 0
session-name='gnome-login'

[org/gnome/desktop/screensaver]
lock-enabled=false
lock-delay=uint32 3600
GDMLOCKEOF
cat > /etc/dconf/db/gdm.d/locks/00-session-name << 'GDMLOCKSESS'
/org/gnome/desktop/session/session-name
GDMLOCKSESS
ok "Screensaver del GDM greeter deshabilitado y session-name='gnome-login' fijado+bloqueado"

# Perfil dconf para el nuevo usuario 'gdm-greeter' (Ubuntu 26.04+). Apunta al mismo
# system-db que el usuario 'gdm' para que ambos lean session-name='gnome-login'.
# Sin este perfil, el gdm-greeter usa el profile por defecto y no ve el system-db gdm.
cat > /etc/dconf/profile/gdm-greeter << 'GDMGRTPROF'
user-db:user
system-db:gdm
GDMGRTPROF
ok "Perfil dconf /etc/dconf/profile/gdm-greeter creado (apunta a system-db:gdm)"

dconf update && ok "dconf recompilado (gdm screensaver + session-name)" \
    || info "dconf update falló en chroot — las bases GDM se compilarán en el primer arranque"

# ── Servicio early-boot: escribe GDM config ANTES de que display-manager arranque ─────
# Garantía final contra auto-login: aunque algo sobreescriba /etc/gdm3/custom.conf
# (casper.service, postinst de gdm3 durante full-upgrade, etc.), este servicio
# se ejecuta en CADA arranque Before=display-manager.service y lo corrige.
# 3-SetupPrimerInicio tiene After=graphical.target → llega tarde; este servicio
# llega a tiempo.
cat > /usr/local/sbin/iac-gdm-noautologin.sh << 'GDMEARLYSCRIPT'
#!/bin/bash
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf << 'GDM3EARLY'
[daemon]
AutomaticLoginEnable=false
TimedLoginEnable=false
InitialSetupEnable=false
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
GDM3EARLY
GDMEARLYSCRIPT
chmod +x /usr/local/sbin/iac-gdm-noautologin.sh

cat > /etc/systemd/system/iac-gdm-noautologin.service << 'GDMEARLYUNIT'
[Unit]
Description=IAC: enforce GDM sin auto-login antes de display-manager
DefaultDependencies=no
Before=display-manager.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/iac-gdm-noautologin.sh

[Install]
WantedBy=display-manager.service
GDMEARLYUNIT
systemctl enable iac-gdm-noautologin.service
ok "Servicio iac-gdm-noautologin habilitado (Before=display-manager en cada arranque)"

# Soporte Wayland en VMware: mutter (compositor GNOME) necesita EGL/DRM para Wayland.
# En VMware sin aceleración 3D habilitada, mutter falla al iniciarse → GDM vuelve al
# login sin mensaje de error. LIBGL_ALWAYS_SOFTWARE=1 fuerza llvmpipe (software renderer
# de Mesa) y permite que Wayland funcione sin GPU virtual. Solo se aplica si el chroot
# detecta entorno VMware; las máquinas físicas no entran en este bloque.
_VIRT_CHR=$(systemd-detect-virt 2>/dev/null || true)
info "Entorno de virtualización detectado en chroot: ${_VIRT_CHR:-ninguno}"
if echo "$_VIRT_CHR" | grep -qi "vmware"; then
    grep -q 'LIBGL_ALWAYS_SOFTWARE' /etc/environment 2>/dev/null \
        || echo 'LIBGL_ALWAYS_SOFTWARE=1' >> /etc/environment
    ok "VMware: LIBGL_ALWAYS_SOFTWARE=1 → /etc/environment (Wayland funciona sin GPU 3D)"
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "GRUB (grub-install + update-grub)"
# ─────────────────────────────────────────────────────────────────────────────
info "Instalando GRUB EFI en /boot/efi  (bootloader-id=$DISTRO)"
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --bootloader-id="$DISTRO" --recheck --no-floppy
ok "grub-install OK"

sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub \
    || echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub

# Mostrar el menú 5 s antes de arrancar la entrada por defecto
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/'           /etc/default/grub
grep -q '^GRUB_TIMEOUT='       /etc/default/grub || echo 'GRUB_TIMEOUT=5'          >> /etc/default/grub
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
ok "GRUB: timeout=5 s y menú visible"

# Ocultar submenu "Advanced options" y entradas "Memory test"
sed -i '/^GRUB_DISABLE_SUBMENU=/d' /etc/default/grub
echo 'GRUB_DISABLE_SUBMENU=y' >> /etc/default/grub
for _memtest in /etc/grub.d/20_memtest86+ /etc/grub.d/30_memtest86+; do
    [ -f "$_memtest" ] && chmod -x "$_memtest" && info "Deshabilitado: $_memtest"
done
ok "GRUB: Advanced options y Memory test deshabilitados (quedan: Ubuntu, texto, UEFI)"

# Segunda entrada GRUB: arrancar sin entorno gráfico (systemd.unit=multi-user.target).
# El script /etc/grub.d/11_iac_texto se ejecuta en cada update-grub, por lo que
# la entrada sobrevive a actualizaciones de paquetes que regeneren grub.cfg.
cat > /etc/grub.d/11_iac_texto << 'GRUBTEXT'
#!/bin/bash
# IAC-IESMHP: entrada GRUB sin entorno grafico
LINUX=$(ls /boot/vmlinuz-* 2>/dev/null | grep -v '\.old$' | sort -V | tail -1)
INITRD=$(ls /boot/initrd.img-* 2>/dev/null | grep -v '\.old$' | sort -V | tail -1)
[ -z "$LINUX" ] && exit 0
[ -z "$INITRD" ] && exit 0
LINUX_BASE="${LINUX#/boot/}"
INITRD_BASE="${INITRD#/boot/}"
ROOT_UUID=$(awk '$2 == "/" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab 2>/dev/null)
[ -z "$ROOT_UUID" ] && ROOT_UUID=$(grub-probe -t fs_uuid / 2>/dev/null || true)
[ -z "$ROOT_UUID" ] && exit 0
cat << EOF
menuentry 'Ubuntu - Sin entorno grafico (modo texto)' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux   /boot/${LINUX_BASE} root=UUID=${ROOT_UUID} ro text systemd.unit=multi-user.target
    initrd  /boot/${INITRD_BASE}
}
EOF
GRUBTEXT
chmod +x /etc/grub.d/11_iac_texto
ok "Script /etc/grub.d/11_iac_texto creado (segunda entrada: sin entorno grafico)"

info "Ejecutando update-grub..."
update-grub
ok "update-grub OK"
info "Entradas 'linux' en grub.cfg (verificación root=):"
grep -E '^\s*linux\s' /boot/grub/grub.cfg 2>/dev/null | sed 's/^/    /' || info "  (grub.cfg no encontrado aún)"

# update-grub en chroot a veces genera root=/dev/XXX en lugar de root=UUID=...
# porque grub-probe no puede resolver el UUID del dispositivo desde dentro del chroot.
# Lo corregimos reemplazando la ruta de dispositivo por el UUID real en grub.cfg.
GRUB_CFG=/boot/grub/grub.cfg
if grep -q 'root=UUID=' "$GRUB_CFG" 2>/dev/null; then
    ok "grub.cfg usa UUID para root — correcto"
else
    ROOT_DEV="/dev/$ROOT"
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)
    if [ -n "$ROOT_UUID" ]; then
        # Reemplazar root=/dev/nvme0n1p3 → root=UUID=xxxx en todas las entradas linux
        sed -i "s|root=${ROOT_DEV}\b|root=UUID=${ROOT_UUID}|g" "$GRUB_CFG"
        ok "grub.cfg parcheado: root=${ROOT_DEV} → root=UUID=${ROOT_UUID}"
    else
        err "grub.cfg usa nombre de dispositivo para root y no se pudo obtener UUID de $ROOT_DEV"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "Machine-ID"
# ─────────────────────────────────────────────────────────────────────────────
rm -f /etc/machine-id
dbus-uuidgen > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
ok "machine-id generado: $(cat /etc/machine-id)"

# ─────────────────────────────────────────────────────────────────────────────
paso "Plymouth: logos personalizados IES Miguel Herrero"
# ─────────────────────────────────────────────────────────────────────────────
# Los ficheros de tema Plymouth se embeben en el initramfs por update-initramfs.
# Se copian ANTES de ese paso para que la imagen instalada use los logos del IES.
_PLY_BGRT="$RAIZDISTRO/imagenesIES/bgrt-fallback.png"
_PLY_WM="$RAIZDISTRO/imagenesIES/watermark.png"
_PLY_COPIED=0
for _ply_dir in /usr/share/plymouth/themes/spinner /usr/share/plymouth/themes/bgrt; do
    if [ -d "$_ply_dir" ] && [ -f "$_PLY_BGRT" ]; then
        cp "$_PLY_BGRT" "$_ply_dir/bgrt-fallback.png"
        ok "bgrt-fallback.png → $_ply_dir/"
        _PLY_COPIED=$((_PLY_COPIED + 1))
    fi
done
if [ -d /usr/share/plymouth/themes/spinner ] && [ -f "$_PLY_WM" ]; then
    cp "$_PLY_WM" /usr/share/plymouth/themes/spinner/watermark.png
    ok "watermark.png → /usr/share/plymouth/themes/spinner/"
    _PLY_COPIED=$((_PLY_COPIED + 1))
fi
[ "$_PLY_COPIED" -gt 0 ] && ok "Logos Plymouth copiados ($_PLY_COPIED fichero/s)" \
                          || info "Ningún directorio de tema Plymouth encontrado — se omite"

# ─────────────────────────────────────────────────────────────────────────────
paso "Eliminar hooks de casper y generar initramfs"
# ─────────────────────────────────────────────────────────────────────────────
# casper tiene hooks en /usr/share/initramfs-tools/hooks/ diseñados para Live CD.
# Si están presentes, update-initramfs los ejecuta, fallan silenciosamente y el
# initramfs no se genera → el sistema no arranca.
#
# NO usamos apt-get remove porque el procesamiento de dpkg triggers (man-db,
# initramfs-tools, etc.) se bloquea en el chroot. Borramos directamente los
# ficheros de hooks — es todo lo que necesitamos para que update-initramfs funcione.

info "Eliminando hooks de casper directamente (sin apt, sin triggers dpkg)..."
CASPER_HOOKS_REMOVED=0
for f in \
    /usr/share/initramfs-tools/hooks/casper \
    /usr/share/initramfs-tools/scripts/casper \
    /usr/share/initramfs-tools/scripts/casper-bottom \
    /usr/share/initramfs-tools/scripts/casper-premount \
    /etc/initramfs-tools/hooks/casper \
    /etc/casper.conf \
; do
    if [ -e "$f" ]; then
        rm -rf "$f"
        info "  Eliminado: $f"
        CASPER_HOOKS_REMOVED=$((CASPER_HOOKS_REMOVED + 1))
    fi
done
# Eliminar cualquier otro fichero de casper en initramfs-tools que pudiera existir
find /usr/share/initramfs-tools /etc/initramfs-tools \
     -name '*casper*' -exec rm -rf {} + 2>/dev/null || true
ok "Hooks de casper eliminados ($CASPER_HOOKS_REMOVED ficheros/dirs encontrados)"

# Enmascarar casper.service en systemd: en Ubuntu 26.04 casper puede tener un
# servicio de userspace que modifica /etc/gdm3/custom.conf antes del primer login.
ln -sf /dev/null /etc/systemd/system/casper.service 2>/dev/null || true
info "casper.service enmascarado en systemd (symlink → /dev/null)"

info "Configurando MODULES=most y RESUME=none..."
mkdir -p /etc/initramfs-tools/conf.d
echo "MODULES=most" > /etc/initramfs-tools/conf.d/modules
echo "RESUME=none"  > /etc/initramfs-tools/conf.d/resume

# Recuperar update-initramfs si fue enmascarado como /bin/true.
# El rsync copia desde el squashfs (read-only), que normalmente no incluye
# las modificaciones del live, pero verificamos de todas formas.
# En merged-usr Ubuntu 26.04: /usr/sbin → bin, así que comprobamos también /usr/bin.
_UPDATE_INITRAMFS_REAL=true
for _masked in /usr/local/sbin/update-initramfs /usr/sbin/update-initramfs /usr/bin/update-initramfs; do
    if [ -L "$_masked" ] && readlink "$_masked" | grep -qE "(^|/)true$"; then
        rm -f "$_masked"
        info "  Eliminada máscara: $_masked → $(readlink $_masked)"
        _UPDATE_INITRAMFS_REAL=false
    fi
done
if [ "$_UPDATE_INITRAMFS_REAL" = "false" ]; then
    info "Reinstalando initramfs-tools para recuperar update-initramfs real..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall initramfs-tools 2>&1 | sed 's/^/    /'
    ok "update-initramfs restaurado: $(readlink -f $(command -v update-initramfs))"
fi

# Protección extra: verificar que el binario no es un no-op por tamaño
_UI_BIN=$(readlink -f "$(command -v update-initramfs 2>/dev/null || echo '')" 2>/dev/null || echo "")
if [ -n "$_UI_BIN" ]; then
    _UI_SIZE=$(stat -c%s "$_UI_BIN" 2>/dev/null || echo "0")
    info "update-initramfs → $_UI_BIN (${_UI_SIZE} bytes)"
    if [ "$_UI_SIZE" -lt 200 ]; then
        info "  → binario sospechoso, reinstalando initramfs-tools..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall initramfs-tools 2>&1 | sed 's/^/    /'
    fi
fi

# update-initramfs sale silenciosamente con código 0 si detecta entorno de
# contenedor/chroot. Causas: /run bind-mount trae /run/systemd/container del
# live CD (VMware), o DPKG_MAINTSCRIPT_PACKAGE heredad de apt previo activa
# la guarda ischroot. Limpiamos antes de llamarlo.
unset DPKG_MAINTSCRIPT_PACKAGE DPKG_MAINTSCRIPT_NAME DPKG_RUNNING_VERSION 2>/dev/null || true
rm -f /run/systemd/container /run/container_type 2>/dev/null || true

# Kernel instalado: preferir el de /lib/modules/ (el del chroot) sobre uname -r (kernel del host live)
KERNEL_INSTALADO=$(ls /lib/modules/ 2>/dev/null | sort -V | tail -1)
info "Kernels en /lib/modules/: $(ls /lib/modules/ 2>/dev/null | tr '\n' ' ' || echo 'NINGUNO')"
info "Ficheros en /boot/ antes de generar initramfs:"
ls -lh /boot/ 2>/dev/null | sed 's/^/    /' || info "  /boot/ vacío o inaccesible"

# Usar -c (create) en lugar de -u (update): -u no crea initramfs nuevos si no
# existe uno previo, lo que ocurre en sistemas instalados desde squashfs live.
info "Ejecutando update-initramfs -c -k all -v (puede tardar 2-4 min)..."
update-initramfs -c -k all -v
ok "update-initramfs terminado"

# Verificar que el initramfs se creó; usar kernel del chroot, no del host live
KERNEL="${KERNEL_INSTALADO:-$(uname -r)}"
if [ -f "/boot/initrd.img-${KERNEL}" ]; then
    INITRAMFS_SIZE=$(du -sh "/boot/initrd.img-${KERNEL}" | cut -f1)
    ok "Initramfs generado: /boot/initrd.img-${KERNEL} (${INITRAMFS_SIZE})"
else
    err "Initramfs NO encontrado en /boot/initrd.img-${KERNEL} — el sistema no arrancará"
    info "Ficheros en /boot/:"
    ls -lh /boot/ | sed 's/^/    /'
    info "Kernels en /lib/modules/: $(ls /lib/modules/ 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

# ── Asegurar línea initrd en grub.cfg ──────────────────────────────────────────
# grub.cfg se generó en el paso anterior cuando initrd.img-${KERNEL} aún no existía
# (solo había symlinks colgantes). grub/10_linux usa 'test -e' → omite la línea
# initrd → el kernel arranca sin initramfs → VFS panic (unknown-block 0,0).
# Ahora que el initramfs existe, regeneramos grub.cfg con la línea initrd correcta.
info "Verificando línea initrd en grub.cfg..."
if ! grep -qE '^\s+initrd\s' "$GRUB_CFG" 2>/dev/null; then
    info "  grub.cfg sin línea initrd — re-ejecutando update-grub..."
    update-grub 2>&1 | grep -E '^(Found|Generating|done|Warning|Adding)' | sed 's/^/    /' || true
    # Re-aplicar parche UUID (update-grub en chroot escribe root=/dev/...)
    ROOT_DEV_STEP10="/dev/$ROOT"
    ROOT_UUID_STEP10=$(blkid -s UUID -o value "$ROOT_DEV_STEP10" 2>/dev/null || true)
    if [ -n "$ROOT_UUID_STEP10" ] && grep -q "root=${ROOT_DEV_STEP10}" "$GRUB_CFG" 2>/dev/null; then
        sed -i "s|root=${ROOT_DEV_STEP10}\b|root=UUID=${ROOT_UUID_STEP10}|g" "$GRUB_CFG"
        ok "grub.cfg re-parcheado: root=${ROOT_DEV_STEP10} → root=UUID=${ROOT_UUID_STEP10}"
    fi
    ok "grub.cfg regenerado con línea initrd"
else
    ok "grub.cfg ya tiene línea initrd — correcto"
fi
info "Líneas linux+initrd en grub.cfg (verificación final):"
grep -E '^\s*(linux|initrd)\s' "$GRUB_CFG" 2>/dev/null | head -8 | sed 's/^/    /' || true

# ─────────────────────────────────────────────────────────────────────────────
paso "Servicio 3-SetupPrimerInicio (primer arranque)"
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$RAIZDISTRO/$SCRIPT3" ]; then
    err "No se encontró $RAIZDISTRO/$SCRIPT3"
    exit 1
fi
chmod +x "$RAIZDISTRO/$SCRIPT3"

cat > /etc/systemd/system/3-SetupPrimerInicio.service << EOF
[Unit]
Description=IAC-IESMHP Configuracion primer arranque
DefaultDependencies=no
Wants=network-online.target
After=network-online.target graphical.target
Conflicts=shutdown.target

[Service]
Type=oneshot
Environment=LC_ALL=es_ES.UTF-8
ExecStart=/bin/bash $RAIZDISTRO/$SCRIPT3
# El log al fichero lo gestiona el propio script con 'exec > >(tee -a ...)'.
# NO usar StandardOutput/StandardError=append: aqui o cada linea se grabaria
# DOS veces (una por el tee del script, otra por systemd). Se deja en journal.
StandardOutput=journal
StandardError=journal
TimeoutSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable 3-SetupPrimerInicio.service
ok "Servicio 3-SetupPrimerInicio habilitado"
info "ExecStart=/bin/bash $RAIZDISTRO/$SCRIPT3"
info "Log primer arranque: $RAIZLOG/$SCRIPT3.log"

# ─────────────────────────────────────────────────────────────────────────────
paso "Comprobaciones finales (4-Comprobaciones.sh)"
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT4="$RAIZDISTRO/4-Comprobaciones.sh"
if [ -f "$SCRIPT4" ]; then
    chmod +x "$SCRIPT4"
    bash "$SCRIPT4" || true   # diagnóstico no bloquea el proceso
else
    info "4-Comprobaciones.sh no encontrado en $SCRIPT4 — omitiendo diagnóstico"
fi

paso "FIN — 2-SetupSOdesdeLiveCD.sh completado"
info "Log completo : $LOG2"
info "Resumen pasos: $STEPS"
echo ""
echo "Correcto"
