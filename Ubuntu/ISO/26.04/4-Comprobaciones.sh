#!/bin/bash
# =============================================================================
#  4-Comprobaciones.sh  —  Ubuntu 26.04
#  Diagnóstico del sistema instalado.
#  Funciona tanto dentro del chroot (llamado desde 2-SetupSOdesdeLiveCD.sh)
#  como en el sistema ya arrancado (llamado desde 3-SetupPrimerInicio.sh).
# =============================================================================
VERSIONSCRIPT="1.4-20260612-zfs"

# Variables comunes del proyecto (REPO, DISTRO, RAIZLOG...). Único punto de
# definición: comun.sh (mismo directorio que este script).
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_DIR/comun.sh"

mkdir -p "$RAIZLOG"
LOGFILE="$RAIZLOG/4-Comprobaciones.sh.log"

ERRORES=0
AVISOS=0

_ok()  { echo -e "\033[32m[OK ] $*\033[0m" | tee -a "$LOGFILE"; }
_err() { echo -e "\033[31m[ERR] $*\033[0m" | tee -a "$LOGFILE"; (( ERRORES++ )) || true; }
_avs() { echo -e "\033[33m[AVS] $*\033[0m" | tee -a "$LOGFILE"; (( AVISOS++ ))  || true; }
_inf() { echo -e "\033[36m[INF] $*\033[0m" | tee -a "$LOGFILE"; }

_sep() { echo "── $* $(printf '─%.0s' {1..50})" | cut -c1-70 | tee -a "$LOGFILE"; }

echo | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"
echo " 4-Comprobaciones.sh (vs$VERSIONSCRIPT) — $(date)" | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"

# ─────────────────────────────────────────────────────────────────────────────
_sep "1. KERNEL Y BOOT"

KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
if [ -z "$KERNEL" ]; then
    _err "No se encontró ningún kernel en /boot/"
else
    KVER=$(basename "$KERNEL" | sed 's/vmlinuz-//')
    _ok "Kernel: $KERNEL"

    # Módulos
    if [ -d "/lib/modules/$KVER" ]; then
        _ok "Módulos: /lib/modules/$KVER existe"
    else
        _err "Módulos: /lib/modules/$KVER NO existe — initramfs no puede incluir drivers correctamente"
    fi

    # Initramfs
    INITRD="/boot/initrd.img-$KVER"
    if [ ! -f "$INITRD" ]; then
        _err "Initramfs no encontrado: $INITRD"
    else
        SIZE=$(du -sh "$INITRD" 2>/dev/null | cut -f1)
        _ok "Initramfs: $INITRD ($SIZE)"

        # Extraer lista de contenidos (soporta gzip, lz4, zstd)
        LISTADO=$(lsinitramfs "$INITRD" 2>/dev/null \
                  || zcat "$INITRD" 2>/dev/null | cpio -t 2>/dev/null \
                  || true)

        if [ -z "$LISTADO" ]; then
            _avs "No se pudo inspeccionar el initramfs (herramienta no disponible)"
        else
            # NVMe: verificar que hay un .ko real, no solo un directorio
            if echo "$LISTADO" | grep -qE 'nvme.*\.ko'; then
                _ok "  Driver NVMe: módulo .ko presente en initramfs"
            elif echo "$LISTADO" | grep -q 'nvme'; then
                _avs "  Driver NVMe: referencia nvme en initramfs pero sin .ko — puede no cargar"
            else
                _err "  Driver NVMe: AUSENTE en initramfs → kernel panic al arrancar"
                _avs "  Fix: echo MODULES=most > /etc/initramfs-tools/conf.d/modules && update-initramfs -u -k $KVER"
            fi

            # Casper (no debe estar en un sistema instalado)
            if echo "$LISTADO" | grep -q casper; then
                _err "  Hooks casper: presentes en initramfs → sistema no arrancará como instalado"
                _avs "  Fix: apt-get remove --purge casper && update-initramfs -u -k $KVER"
            else
                _ok "  Hooks casper: no presentes (correcto para sistema instalado)"
            fi
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "2. GRUB"

if [ ! -f /boot/grub/grub.cfg ]; then
    _err "grub.cfg no encontrado en /boot/grub/grub.cfg"
else
    _ok "grub.cfg encontrado"

    # Extraer cmdline real de la primera entrada Ubuntu (no del submenu)
    LINUX_LINE=$(awk '/menuentry .Ubuntu[^,]/{f=1} f && /^\s+linux\s/{print; exit}' /boot/grub/grub.cfg)
    _inf "  Cmdline del kernel: ${LINUX_LINE:-<no encontrada>}"

    GRUB_ROOT_UUID=$(echo "$LINUX_LINE" | grep -oP 'root=UUID=\K[a-fA-F0-9-]+')
    if [ -z "$GRUB_ROOT_UUID" ]; then
        # Fallback: buscar en todo el archivo
        GRUB_ROOT_UUID=$(grep -oP 'root=UUID=\K[a-fA-F0-9-]+' /boot/grub/grub.cfg | head -1)
    fi

    # Verificar parámetro root=
    ROOT_PARAM=$(echo "$LINUX_LINE" | grep -oP 'root=\S+')
    if [ -z "$ROOT_PARAM" ]; then
        _err "  Parámetro root= ausente en cmdline del kernel → kernel panic seguro"
    elif echo "$ROOT_PARAM" | grep -q 'root=UUID='; then
        _ok "  root= usa UUID (correcto)"
    elif echo "$ROOT_PARAM" | grep -q 'root=/dev/'; then
        _err "  root= usa $ROOT_PARAM en lugar de UUID — puede causar kernel panic si el dispositivo cambia de nombre"
    fi

    if [ -z "$GRUB_ROOT_UUID" ]; then
        _err "No hay root=UUID=... en grub.cfg — GRUB no sabe dónde está el root"
    else
        _inf "  UUID root en grub.cfg: $GRUB_ROOT_UUID"
        DEVICE=$(blkid -U "$GRUB_ROOT_UUID" 2>/dev/null)
        if [ -n "$DEVICE" ]; then
            _ok "  UUID root existe en: $DEVICE"
        else
            _err "  UUID root $GRUB_ROOT_UUID NO existe en ningún dispositivo → kernel panic"
        fi

        # Coherencia grub.cfg ↔ fstab
        FSTAB_ROOT_UUID=$(grep -E '\s+/\s+' /etc/fstab 2>/dev/null | grep -oP 'UUID=\K[a-fA-F0-9-]+' | head -1)
        if [ -n "$FSTAB_ROOT_UUID" ]; then
            if [ "$GRUB_ROOT_UUID" = "$FSTAB_ROOT_UUID" ]; then
                _ok "  UUID coherente: grub.cfg == fstab ($GRUB_ROOT_UUID)"
            else
                _err "  UUID INCOHERENTE: grub.cfg=$GRUB_ROOT_UUID  fstab=$FSTAB_ROOT_UUID → kernel panic seguro"
            fi
        fi
    fi

    # Verificar línea initrd — su ausencia provoca VFS panic (unknown-block 0,0)
    # porque el kernel no puede resolver UUID sin initramfs
    INITRD_LINE=$(awk '/menuentry .Ubuntu[^,]/{f=1} f && /^\s+initrd\s/{print; exit}' /boot/grub/grub.cfg)
    if [ -z "$INITRD_LINE" ]; then
        _err "  initrd: línea AUSENTE en grub.cfg → kernel arranca SIN initramfs → VFS panic (unknown-block 0,0)"
        _avs "  Fix: update-grub (con initramfs ya en /boot/) y re-aplicar parche UUID si es necesario"
    else
        INITRD_PATH=$(echo "$INITRD_LINE" | awk '{print $2}')
        _inf "  initrd line: ${INITRD_LINE}"
        INITRD_REAL=$(realpath "${INITRD_PATH}" 2>/dev/null || echo "${INITRD_PATH}")
        if [ -f "${INITRD_REAL}" ]; then
            _ok "  initrd apunta a fichero existente: ${INITRD_REAL}"
        else
            _err "  initrd apunta a ${INITRD_PATH} que NO existe → VFS panic"
            _avs "  Fix: update-initramfs -c -k all && update-grub"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "3. FSTAB"

if [ ! -f /etc/fstab ]; then
    _err "/etc/fstab no existe"
else
    _inf "Contenido de /etc/fstab:"
    cat /etc/fstab | sed 's/^/  /' | tee -a "$LOGFILE"
    echo | tee -a "$LOGFILE"

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        UUID=$(echo "$line" | grep -oP 'UUID=\K[a-fA-F0-9-]+')
        MP=$(echo "$line" | awk '{print $2}')
        [ -z "$UUID" ] && continue
        DEV=$(blkid -U "$UUID" 2>/dev/null)
        if [ -n "$DEV" ]; then
            _ok "  UUID $UUID ($MP) → $DEV"
        else
            _err "  UUID $UUID ($MP) → ningún dispositivo con ese UUID"
        fi
    done < /etc/fstab
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "4. PARTICIONES DETECTADAS"
lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT 2>/dev/null | tee -a "$LOGFILE"

# ─────────────────────────────────────────────────────────────────────────────
_sep "5. PAQUETES CLAVE"

# casper: comprobar ficheros de hooks en disco, no el registro dpkg.
# 2-SetupSOdesdeLiveCD.sh los elimina con rm -rf sin pasar por apt
# (apt-get remove bloquea en chroot por triggers dpkg).
CASPER_HOOKS=$(find /usr/share/initramfs-tools /etc/initramfs-tools \
               -name '*casper*' 2>/dev/null | head -1)
if [ -n "$CASPER_HOOKS" ]; then
    _err "casper: hooks en disco ($CASPER_HOOKS) — eliminar antes de update-initramfs"
else
    _ok "casper: hooks no presentes en disco (correcto)"
fi
if dpkg -l casper 2>/dev/null | grep -q "^ii"; then
    _inf "casper: paquete en dpkg pero hooks eliminados — normal tras instalación desde Live CD"
fi

if dpkg -l ubiquity 2>/dev/null | grep -q "^ii"; then
    _err "ubiquity está instalado (debe eliminarse)"
else
    _ok "ubiquity: no instalado"
fi

BROKEN=$(dpkg --audit 2>/dev/null | wc -l)
if [ "$BROKEN" -gt 0 ]; then
    _avs "dpkg --audit detectó $BROKEN problema(s):"
    dpkg --audit 2>/dev/null | sed 's/^/  /' | tee -a "$LOGFILE"
else
    _ok "dpkg: sin paquetes rotos"
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "6. INITRAMFS-TOOLS CONFIG"

CONF_MODULES=/etc/initramfs-tools/conf.d/modules
CONF_RESUME=/etc/initramfs-tools/conf.d/resume

if [ -f "$CONF_MODULES" ]; then
    VAL=$(cat "$CONF_MODULES")
    _inf "  $CONF_MODULES: $VAL"
    [[ "$VAL" == *"most"* ]] && _ok "  MODULES=most (correcto para chroot)" \
                             || _avs "  MODULES no es 'most' — puede faltar driver NVMe"
else
    _avs "  $CONF_MODULES no existe (se usará el valor por defecto 'dep')"
fi

if [ -f "$CONF_RESUME" ]; then
    _ok "  $CONF_RESUME: $(cat $CONF_RESUME)"
else
    _avs "  $CONF_RESUME no existe — initramfs puede buscar swap incorrecto"
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "7. GRUB EFI INSTALADO"

EFI_DIR=/boot/efi/EFI
if [ ! -d "$EFI_DIR" ]; then
    _err "$EFI_DIR no existe — grub-install no ejecutado o partición EFI no montada"
    _avs "  Fix: mount /dev/nvme0n1p1 /boot/efi && grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu"
else
    _inf "  Contenido de $EFI_DIR: $(ls "$EFI_DIR" 2>/dev/null | tr '\n' ' ')"
    GRUB_EFI=$(find "$EFI_DIR" \( -name 'grubx64.efi' -o -name 'shimx64.efi' \) 2>/dev/null | head -1)
    if [ -n "$GRUB_EFI" ]; then
        _ok "  EFI bootloader: $GRUB_EFI ($(du -sh "$GRUB_EFI" 2>/dev/null | cut -f1))"
    else
        _err "  No se encontró grubx64.efi ni shimx64.efi en $EFI_DIR → GRUB no instalado en EFI → equipo no arrancará"
        _avs "  Fix: grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu"
    fi

    GRUB_MODS=/boot/grub/x86_64-efi
    if [ -d "$GRUB_MODS" ] && [ "$(ls -A "$GRUB_MODS" 2>/dev/null | wc -l)" -gt 10 ]; then
        _ok "  Módulos GRUB EFI: presentes ($GRUB_MODS)"
    else
        _err "  Módulos GRUB EFI ausentes en $GRUB_MODS → GRUB no puede arrancar"
        _avs "  Fix: grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Servicios systemd (solo si el sistema está arrancado, no en chroot)
if systemctl is-system-running &>/dev/null 2>&1; then
    _sep "8. SERVICIOS SYSTEMD"
    FAILED=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    if [ "$FAILED" -gt 0 ]; then
        _avs "$FAILED servicio(s) fallido(s):"
        systemctl --failed --no-legend 2>/dev/null | sed 's/^/  /' | tee -a "$LOGFILE"
    else
        _ok "Todos los servicios activos correctamente"
    fi
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        _ok "SSH: activo"
    else
        _avs "SSH: no activo"
    fi
fi
# ─────────────────────────────────────────────────────────────────────────────
# 9. ZFS — solo si hay zpool (perfil CEIABD). En Distancia no hay nada que ver.
if command -v zpool >/dev/null 2>&1 && zpool list -H 2>/dev/null | grep -q .; then
    _sep "9. ZFS (perfil con pools)"

    _inf "Pools detectados:"
    zpool list -o name,size,allocated,free,fragmentation,capacity,dedupratio,health 2>/dev/null | sed 's/^/  /' | tee -a "$LOGFILE"

    # Estado de los vdevs
    if zpool status -x 2>/dev/null | grep -q 'all pools are healthy'; then
        _ok "  Todos los pools en estado healthy"
    else
        _err "  Algún pool no está healthy — revisar 'zpool status' a mano"
        zpool status 2>/dev/null | sed 's/^/    /' | tee -a "$LOGFILE"
    fi

    # Datasets clave esperados en CEIABD (desde 2026-06-12: rpool/home es un
    # dataset ÚNICO montado en /home — sin datasets por usuario ni cuotas)
    for _ds in rpool/home tank/datos; do
        if zfs list -H -o name "$_ds" >/dev/null 2>&1; then
            _MP=$(zfs get -H -o value mountpoint "$_ds" 2>/dev/null)
            _MOUNTED=$(zfs get -H -o value mounted "$_ds" 2>/dev/null)
            _OK_MNT="?"
            case "$_MOUNTED:$_MP" in
                yes:/home)  _OK_MNT="OK" ;;
                yes:/datos) _OK_MNT="OK" ;;
                *)          _OK_MNT="REVISAR ($_MOUNTED, $_MP)" ;;
            esac
            _ok "  $_ds → mountpoint=$_MP mounted=$_MOUNTED  [$_OK_MNT]"
        else
            _avs "  Dataset $_ds NO encontrado (esperado en CEIABD)"
        fi
    done

    # Propiedades del pool rpool relevantes para dedup/compresión
    if zfs list -H -o name rpool >/dev/null 2>&1; then
        _COMP=$(zfs get -H -o value compression rpool 2>/dev/null)
        _DEDUP=$(zfs get -H -o value dedup rpool 2>/dev/null)
        _RECS=$(zfs get -H -o value recordsize rpool/home 2>/dev/null)
        _DRATIO=$(zpool get -H -o value dedupratio rpool 2>/dev/null)
        _inf "  rpool       : compression=$_COMP  dedup=$_DEDUP  dedupratio=$_DRATIO"
        _inf "  rpool/home  : recordsize=$_RECS"
        # Fast Dedup
        if zpool get -H -o property,value all rpool 2>/dev/null | grep -q '^feature@fast_dedup.*\bactive\|^feature@fast_dedup.*\benabled'; then
            _ok "  Fast Dedup activo (OpenZFS ≥ 2.3)"
        else
            _inf "  Fast Dedup NO activo (dedup clásica)"
        fi
    fi

    # Servicios systemd ZFS (solo informativo si el sistema está arrancado)
    if systemctl is-system-running &>/dev/null 2>&1; then
        for _svc in zfs-import-cache.service zfs-mount.service zfs-zed.service; do
            if systemctl is-enabled --quiet "$_svc" 2>/dev/null; then
                if systemctl is-active --quiet "$_svc" 2>/dev/null; then
                    _ok "  $_svc enabled+active"
                else
                    _avs "  $_svc enabled pero NO active"
                fi
            else
                _avs "  $_svc no habilitado"
            fi
        done
    fi

    # Módulo ZFS en initramfs (informativo: con / en ext4 no es estrictamente
    # necesario, pero zfs-initramfs lo añade por defecto y es señal de salud).
    if [ -n "${KVER:-}" ] && [ -f "/boot/initrd.img-${KVER}" ]; then
        if lsinitramfs "/boot/initrd.img-${KVER}" 2>/dev/null | grep -q 'zfs\.ko'; then
            _ok "  Módulo zfs.ko presente en initramfs"
        else
            _inf "  Módulo zfs.ko no presente en initramfs (no crítico: / es ext4)"
        fi
    fi

    # Helper nuevo-alumno.sh ELIMINADO (2026-06-12): con dataset único en /home
    # el alta de usuarios es el flujo estándar (sudo adduser <u>). Si aparece
    # en un equipo es resto de una instalación anterior — solo informativo.
    if [ -x /usr/local/sbin/nuevo-alumno.sh ]; then
        _inf "  Helper nuevo-alumno.sh presente (legacy, instalación pre-2026-06-12)"
    fi
else
    _sep "9. ZFS"
    _inf "  Sin zpools (perfil DISTANCIA o ZFS no instalado) — sección omitida"
fi

IP=$(hostname -I | awk '{print $1}')
# ─────────────────────────────────────────────────────────────────────────────
echo | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"
echo " RESUMEN: $ERRORES error(es)  |  $AVISOS aviso(s)" | tee -a "$LOGFILE"
if [ "$ERRORES" -eq 0 ]; then
    echo -e "\033[32m Sistema listo para arrancar correctamente\033[0m" | tee -a "$LOGFILE"
else
    echo -e "\033[31m $ERRORES problema(s) detectado(s) que pueden impedir el arranque\033[0m" | tee -a "$LOGFILE"
fi
echo " ssh ubuntu@${IP}   Log: /mnt$LOGFILE      " | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"
if [ "$ERRORES" -eq 0 ]; then
    for i in 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
        echo -ne "\r Reiniciando en $i segundos... (Ctrl+C para cancelar)  " | tee -a "$LOGFILE"
        sleep 1
    done
    echo | tee -a "$LOGFILE"
    echo "Descomentar la línea 'reboot' para reiniciar el sistema" | tee -a "$LOGFILE"
    reboot
else
    read -n 1 -s -r -p "Presiona cualquier tecla para continuar..."
fi