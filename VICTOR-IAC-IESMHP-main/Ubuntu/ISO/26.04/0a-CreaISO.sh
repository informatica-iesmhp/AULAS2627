#!/usr/bin/env bash
# =============================================================================
#  0a-CreaISO.sh
#  Genera una ISO de Ubuntu Desktop personalizada con instalación automática UEFI.
#
#  Uso:
#    sudo ./0a-CreaISO.sh <iso_origen> <0b-Github.sh> [iso_salida] [fondo.png]
#
#  ARQUITECTURA:
#    El autoinstall de Ubuntu solo actúa como disparador de arranque:
#    early-commands lanza 0b-Github.sh, que clona el repo y ejecuta
#    1-SetupLiveCD.sh (instalación completa manual desde el entorno live).
#    Subiquity nunca particiona ni instala nada por su cuenta.

# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# PARÁMETROS Y VARIABLES
# ─────────────────────────────────────────────────────────────────────────────
SOURCE_ISO="${1:?ERROR: Debes indicar la ISO de origen.
  Uso: $0 <iso_origen> <0b-Github.sh> [iso_salida] [fondo.png]}"
PERSO_SCRIPT="${2:?ERROR: Debes indicar el script de personalización (0b-Github.sh).}"
OUTPUT_ISO="${3:-ubuntu-custom-desktop-uefi.iso}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALLPAPER_PNG="${4:-${SCRIPT_DIR}/imagenesIES/FondoIES-Ubuntu.png}"

WORK_DIR="$(mktemp -d /tmp/iso_build_XXXXXX)"
ISO_DIR="${WORK_DIR}/iso"
SQUASHFS_DIR="${WORK_DIR}/squashfs"

# ─────────────────────────────────────────────────────────────────────────────
# COLORES Y LIMPIEZA
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

cleanup() {
    log "Limpiando directorio temporal: ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# 0. VERIFICACIONES
# ─────────────────────────────────────────────────────────────────────────────
check_root() {
    step "Verificando permisos de ejecucion"
    if [[ "$EUID" -ne 0 ]]; then
        err "Este script debe ejecutarse como root.\n  Uso: sudo $0 ${SOURCE_ISO} ${PERSO_SCRIPT} ${OUTPUT_ISO}"
    fi
    log "Ejecutando como root: OK"
}

check_deps() {
    step "Verificando dependencias"
    local missing=()
    for dep in xorriso mtools file openssl sfdisk unsquashfs; do
        if command -v "$dep" &>/dev/null; then
            log "  $dep → OK"
        else
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Faltan dependencias: ${missing[*]}\n  Instálalas con: sudo apt install squashfs-tools ${missing[*]}"
    fi
}

check_inputs() {
    step "Verificando ficheros de entrada"
    [[ -f "$SOURCE_ISO" ]]    || err "No se encuentra la ISO: ${SOURCE_ISO}"
    [[ -f "$PERSO_SCRIPT" ]]  || err "No se encuentra el script: ${PERSO_SCRIPT}"
    if [[ "$(realpath "$SOURCE_ISO")" == "$(realpath "$OUTPUT_ISO")" ]]; then
        err "La ISO de origen y la de salida son el mismo fichero."
    fi
    log "ISO origen   : ${SOURCE_ISO}"
    log "0b-Github.sh : ${PERSO_SCRIPT}"
    log "ISO salida   : ${OUTPUT_ISO}"
    log "Wallpaper    : ${WALLPAPER_PNG}"
    [[ -f "$WALLPAPER_PNG" ]] || err "No se encuentra el PNG: ${WALLPAPER_PNG}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. EXTRAER ISO
# ─────────────────────────────────────────────────────────────────────────────
extract_iso() {
    step "Extrayendo ISO → ${ISO_DIR}"
    mkdir -p "${ISO_DIR}"
    xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "${ISO_DIR}" 2>/dev/null || err "xorriso falló al extraer."
    chmod -R u+w "${ISO_DIR}"
    log "Extracción completada"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. PERSONALIZAR ENTORNO LIVE (SQUASHFS)
# ─────────────────────────────────────────────────────────────────────────────
customize_squashfs() {
    step "Personalizando el entorno Live (SquashFS)"

    # ── Localizar el/los ficheros .squashfs ───────────────────────────────
    # Ubuntu cambia el nombre según versión:
    #   <= 23.04  -> casper/filesystem.squashfs
    #   24.04+    -> casper/ubuntu-desktop.squashfs  (u otro nombre)
    log "Buscando ficheros .squashfs en la ISO..."
    local all_squashfs=()
    mapfile -t all_squashfs < <(find "${ISO_DIR}" -type f -name "*.squashfs" | sort)

    if [[ ${#all_squashfs[@]} -eq 0 ]]; then
        warn "No se encontro ningun .squashfs. Estructura real de la ISO extraida:"
        find "${ISO_DIR}" -maxdepth 3 | sort | sed "s|${ISO_DIR}||" | head -60 | sed 's/^/    /'
        warn "Ficheros grandes (>100 MB):"
        find "${ISO_DIR}" -size +100M -printf "    %s  %p\n" 2>/dev/null | sort -rn | head -10
        err "No se encontro ningun .squashfs. Revisa la estructura listada arriba."
    fi

    local squashfs_path
    if [[ ${#all_squashfs[@]} -eq 1 ]]; then
        squashfs_path="${all_squashfs[0]}"
        log "SquashFS encontrado: ${squashfs_path#"${ISO_DIR}/"}"
    else
        info "Se encontraron ${#all_squashfs[@]} ficheros .squashfs:"
        for f in "${all_squashfs[@]}"; do
            info "  $(du -sh "$f" | cut -f1)  ->  ${f#"${ISO_DIR}/"}"
        done

        # Ubuntu 24.04+ usa capas superpuestas (overlayfs):
        #   minimal.squashfs              → sistema base (~3 GB)
        #   minimal.standard.squashfs    → paquetes estándar
        #   minimal.standard.live.squashfs → escritorio GNOME + sesión live  ← aquí está gnome-terminal y autostart
        #   minimal.*.squashfs           → paquetes de idioma
        #
        # Para añadir un autostart de escritorio debemos modificar la capa LIVE,
        # no la base. Buscamos primero *.live.squashfs (sin enhanced-secureboot).
        local live_layer
        live_layer=$(printf "%s\n" "${all_squashfs[@]}" \
            | grep -v "enhanced-secureboot" \
            | grep "\.live\.squashfs$" \
            | head -1)

        if [[ -n "$live_layer" ]]; then
            squashfs_path="$live_layer"
            log "Capa live seleccionada: ${squashfs_path#"${ISO_DIR}/"}"
        else
            # Fallback: la mayor (Ubuntu < 24.04 con filesystem.squashfs unico)
            squashfs_path=$(du -s "${all_squashfs[@]}" | sort -rn | head -1 | awk '{print $2}')
            warn "No se encontro capa live especifica, usando la mayor: ${squashfs_path#"${ISO_DIR}/"}"
        fi
    fi

    log "Desempaquetando SquashFS..."
    unsquashfs -d "${SQUASHFS_DIR}" "${squashfs_path}" || err "Fallo al desempaquetar SquashFS."

    log "Copiando 0b-Github.sh al sistema Live"
    cp "${PERSO_SCRIPT}" "${SQUASHFS_DIR}/0b-Github.sh"
    chmod +x "${SQUASHFS_DIR}/0b-Github.sh"

    # ── Desactivar el instalador predeterminado de Ubuntu ──────────────────
    # Ubuntu 22.04 y anteriores: ubiquity / installer lanzados desde /etc/xdg/autostart/
    # Ubuntu 24.04+: ubuntu-desktop-bootstrap es un snap; su .desktop está en
    #   /snap/ubuntu-desktop-bootstrap/<rev>/meta/gui/ y se activa via xdg-autostart.
    #   Se neutraliza creando un override en /etc/xdg/autostart/ con Hidden=true.
    step "Desactivando instalador predeterminado de Ubuntu"

    # Instaladores legacy (ubiquity / subiquity / calamares)
    local installer_desktops=(
        "${SQUASHFS_DIR}/etc/xdg/autostart/ubiquity.desktop"
        "${SQUASHFS_DIR}/etc/xdg/autostart/installer.desktop"
        "${SQUASHFS_DIR}/etc/xdg/autostart/install-ubuntu.desktop"
        "${SQUASHFS_DIR}/etc/xdg/autostart/io.calamares.calamares.desktop"
    )
    for f in "${installer_desktops[@]}"; do
        if [[ -f "$f" ]]; then
            if grep -q "X-GNOME-Autostart-enabled" "$f"; then
                sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' "$f"
            else
                echo "X-GNOME-Autostart-enabled=false" >> "$f"
            fi
            log "  Instalador legacy desactivado: $(basename "$f")"
        fi
    done

    # ubuntu-desktop-bootstrap (snap, Ubuntu 24.04+)
    # Su .desktop real está dentro del snap (solo lectura); lo anulamos con un
    # override en /etc/xdg/autostart/ que GNOME session lee con prioridad.
    mkdir -p "${SQUASHFS_DIR}/etc/xdg/autostart"
    cat > "${SQUASHFS_DIR}/etc/xdg/autostart/ubuntu-desktop-bootstrap.desktop" << 'BSEOF'
[Desktop Entry]
Type=Application
Name=Ubuntu Desktop Bootstrap
X-GNOME-Autostart-enabled=false
Hidden=true
BSEOF
    log "  ubuntu-desktop-bootstrap desactivado vía override en /etc/xdg/autostart/"

    # ── Deshabilitar snapd completamente ──────────────────────────────────
    # En Ubuntu 26.04 live, snapd tarda 2-3 minutos en el seeding (14+ snaps).
    # Para nuestro caso de uso (solo ejecutar el script de instalación), no
    # necesitamos ningún snap. Al deshabilitar snapd:
    #   - El arranque pasa de ~3 min a ~10 s
    #   - ubuntu-desktop-bootstrap (instalador) queda bloqueado definitivamente
    #     porque es un snap gestionado por snapd
    step "Desactivando snapd para acelerar el arranque"

    mkdir -p "${SQUASHFS_DIR}/etc/systemd/system"
    ln -sf /dev/null "${SQUASHFS_DIR}/etc/systemd/system/snapd.service"
    ln -sf /dev/null "${SQUASHFS_DIR}/etc/systemd/system/snapd.socket"
    ln -sf /dev/null "${SQUASHFS_DIR}/etc/systemd/system/snapd.seeded.service"
    log "  snapd.service, snapd.socket y snapd.seeded.service enmascarados"

    # ── Script wrapper: se copia al sistema live y lo llama el .desktop ────
    # Usar un script separado evita los problemas de comillas anidadas en
    # el campo Exec= del .desktop.
    log "Creando script wrapper /usr/local/bin/iac-iesmhp-run.sh en el squashfs"
    mkdir -p "${SQUASHFS_DIR}/usr/local/bin"
    cat > "${SQUASHFS_DIR}/usr/local/bin/iac-iesmhp-run.sh" << 'WRAPEOF'
#!/usr/bin/env bash
# Lanzado por el autostart de GNOME al arrancar el Live CD.
# Ejecuta 0b-Github.sh mostrando toda la salida en el terminal.
set -uo pipefail

LOG_FILE="/tmp/iac-install.log"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   IAC-IESMHP  —  Script de instalación   ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Log: ${LOG_FILE}"
echo "  Script: /0b-Github.sh"
echo "  Inicio: $(date)"
echo ""
echo "──────────────────────────────────────────"

# Cerrar el instalador estándar si todavía está activo
sudo systemctl stop snap.ubuntu-desktop-bootstrap.subiquity-server.service 2>/dev/null || true
pkill -f "ubuntu-desktop-bootstrap" 2>/dev/null || true



echo "Actualizamos repositorios..."
sudo apt-get update -qq

echo "Instalamos git en el entorno live... "
sudo DEBIAN_FRONTEND=noninteractive apt-get install git -y -qq

echo "Instalamos ssh en el entorno live... "
sudo DEBIAN_FRONTEND=noninteractive apt-get install openssh-server -y -qq

echo "Establecemos contraseña para el usuario 'ubuntu' (ubuntu/ubuntu)..."
sudo -S sh -c 'echo "ubuntu:ubuntu" | chpasswd'

IP=$(hostname -I | awk '{print $1}')
if [[ -n "$IP" ]]; then
    echo "SSH activo. Puedes conectarte a este entorno live con:"
    echo "  ssh ubuntu@${IP}  (contraseña: ubuntu)"
else
    echo "No se pudo detectar la IP. SSH puede no estar accesible."
fi

echo "Lanzamos el script github de instalación (0b-Github.sh)..."
sudo /bin/bash /0b-Github.sh 2>&1 | tee "${LOG_FILE}"
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "──────────────────────────────────────────"
if [[ "${EXIT_CODE}" -eq 0 ]]; then
    echo "✓  Script finalizado correctamente ($(date))."
else
    echo "✗  El script terminó con error — código de salida: ${EXIT_CODE}"
    echo "   Log completo en: ${LOG_FILE}"
fi
echo ""
echo "  Este terminal permanece abierto. Escribe 'exit' para cerrarlo."
exec bash
WRAPEOF
    chmod +x "${SQUASHFS_DIR}/usr/local/bin/iac-iesmhp-run.sh"
    log "Script wrapper creado."

    # ── Script de lanzamiento de terminal (auto-detección) ─────────────────
    # Necesario porque kgx (GNOME Console) puede no estar en todas las ISOs.
    log "Creando script de lanzamiento de terminal /usr/local/bin/iac-iesmhp-launch.sh"
    cat > "${SQUASHFS_DIR}/usr/local/bin/iac-iesmhp-launch.sh" << 'LAUNCHEOF'
#!/usr/bin/env bash
SCRIPT=/usr/local/bin/iac-iesmhp-run.sh
# Fondo de escritorio en el Live CD (se ejecuta con el entorno gráfico del usuario ubuntu)
FONDO=file:///usr/share/backgrounds/iac-iesmhp.png
gsettings set org.gnome.desktop.background picture-uri      "$FONDO" 2>/dev/null || true
gsettings set org.gnome.desktop.background picture-uri-dark "$FONDO" 2>/dev/null || true
gsettings set org.gnome.desktop.background picture-options  'zoom'   2>/dev/null || true
if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal -- "$SCRIPT"
elif command -v kgx >/dev/null 2>&1; then
    exec kgx -- "$SCRIPT"
elif command -v xterm >/dev/null 2>&1; then
    exec xterm -e "$SCRIPT"
elif command -v x-terminal-emulator >/dev/null 2>&1; then
    exec x-terminal-emulator -e "$SCRIPT"
fi
LAUNCHEOF
    chmod +x "${SQUASHFS_DIR}/usr/local/bin/iac-iesmhp-launch.sh"
    log "Script de lanzamiento creado."

    # ── Autostart .desktop ─────────────────────────────────────────────────
    # Ubuntu live: el home del usuario 'ubuntu' puede preexistir en el squashfs
    # o crearse desde /etc/skel al primer login. Se escribe en ambos sitios
    # para cubrir los dos casos.
    #
    # NOTA: Ubuntu 23.10+ reemplaza gnome-terminal por GNOME Console (kgx).
    # Se usa 'kgx' como terminal. Si la ISO es anterior a 23.10 y no tiene kgx,
    # sustituye 'kgx' por 'gnome-terminal --maximize' en el campo Exec= siguiente.
    log "Creando entrada de autostart en squashfs"
    local autostart_locations=(
        "${SQUASHFS_DIR}/etc/skel/.config/autostart"
        "${SQUASHFS_DIR}/home/ubuntu/.config/autostart"
    )
    for autostart_dir in "${autostart_locations[@]}"; do
        mkdir -p "${autostart_dir}"
        cat > "${autostart_dir}/iac-iesmhp-setup.desktop" << 'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Instalacion IAC-IESMHP
Comment=Lanza el script de configuracion con salida visible en terminal
Exec=/usr/local/bin/iac-iesmhp-launch.sh
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
DESKTOPEOF
        log "  .desktop escrito en: ${autostart_dir}"
    done

    # ── Fondo de escritorio ────────────────────────────────────────────────
    step "Instalando fondo de escritorio en el squashfs"
    mkdir -p "${SQUASHFS_DIR}/usr/share/backgrounds"
    cp "${WALLPAPER_PNG}" "${SQUASHFS_DIR}/usr/share/backgrounds/iac-iesmhp.png"
    log "  PNG copiado → /usr/share/backgrounds/iac-iesmhp.png"

    # Perfil dconf: asegura que el sistema db tenga efecto en el sistema instalado
    mkdir -p "${SQUASHFS_DIR}/etc/dconf/profile"
    if [[ ! -f "${SQUASHFS_DIR}/etc/dconf/profile/user" ]]; then
        printf 'user-db:user\nsystem-db:local\n' > "${SQUASHFS_DIR}/etc/dconf/profile/user"
        log "  Perfil dconf creado: user-db:user / system-db:local"
    fi

    # Override dconf para el fondo (plantilla que 2-SetupSO compila en el chroot)
    mkdir -p "${SQUASHFS_DIR}/etc/dconf/db/local.d"
    cat > "${SQUASHFS_DIR}/etc/dconf/db/local.d/01-wallpaper" << 'DCONFEOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-uri-dark='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-options='zoom'
DCONFEOF
    log "  Override dconf creado: /etc/dconf/db/local.d/01-wallpaper"

    # Plymouth: logos personalizados en la capa live del squashfs.
    # El Live CD monta todas las capas squashfs en un overlayfs; la capa live es la superior,
    # así que sus ficheros tienen prioridad sobre los de capas inferiores.
    # Plymouth (fase spinner, después de que casper monta el squashfs) lee de este overlayfs,
    # por lo que nuestras imágenes reemplazan las de Ubuntu durante la instalación.
    local _bgrt_src="${SCRIPT_DIR}/imagenesIES/bgrt-fallback.png"
    local _wm_src="${SCRIPT_DIR}/imagenesIES/watermark.png"
    if [[ -f "$_bgrt_src" ]] && [[ -f "$_wm_src" ]]; then
        for _plym_dir in \
            "${SQUASHFS_DIR}/usr/share/plymouth/themes/spinner" \
            "${SQUASHFS_DIR}/usr/share/plymouth/themes/bgrt"; do
            mkdir -p "$_plym_dir"
            cp "$_bgrt_src" "${_plym_dir}/bgrt-fallback.png"
            log "  bgrt-fallback.png → ${_plym_dir#"${SQUASHFS_DIR}"}"
        done
        mkdir -p "${SQUASHFS_DIR}/usr/share/plymouth/themes/spinner"
        cp "$_wm_src" "${SQUASHFS_DIR}/usr/share/plymouth/themes/spinner/watermark.png"
        log "  watermark.png → /usr/share/plymouth/themes/spinner/"
    else
        warn "Plymouth: faltan imágenes en imagenesIES/ — Live CD usará logos Ubuntu"
    fi

    # GDM: NO se toca custom.conf en el squashfs.
    # Casper escribe /etc/gdm3/custom.conf en tiempo de ejecución para habilitar
    # el auto-login de 'ubuntu' en el Live CD. Si ponemos AutomaticLoginEnable=false
    # aquí, ese valor prevalece y el Live CD se queda en la pantalla de login.
    # El sistema instalado lo gestiona 2-SetupSOdesdeLiveCD.sh (chroot) +
    # 3-SetupPrimerInicio.sh (post-upgrade), que son las capas correctas.

    # ── Zona horaria del Live CD ───────────────────────────────────────────────
    step "Configurando zona horaria Europe/Madrid en el squashfs"
    ln -sf /usr/share/zoneinfo/Europe/Madrid "${SQUASHFS_DIR}/etc/localtime"
    echo "Europe/Madrid" > "${SQUASHFS_DIR}/etc/timezone"
    log "  Zona horaria Live CD: Europe/Madrid"

    log "Reempaquetando SquashFS..."
    rm "${squashfs_path}"
    mksquashfs "${SQUASHFS_DIR}" "${squashfs_path}" -noappend || err "Fallo al reempaquetar SquashFS."

    log "Entorno Live personalizado."
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. PERSONALIZAR PLYMOUTH EN EL INITRD DEL LIVE CD
# ─────────────────────────────────────────────────────────────────────────────
customize_plymouth_initrd() {
    step "Personalizando Plymouth en el initrd del Live CD"

    local initrd_path="${ISO_DIR}/casper/initrd"
    local bgrt_png="${SCRIPT_DIR}/imagenesIES/bgrt-fallback.png"
    local watermark_png="${SCRIPT_DIR}/imagenesIES/watermark.png"

    if [[ ! -f "$initrd_path" ]]; then
        warn "No se encontró casper/initrd — splash del Live CD sin personalizar."
        return 0
    fi
    if [[ ! -f "$bgrt_png" ]] || [[ ! -f "$watermark_png" ]]; then
        warn "Faltan imágenes Plymouth en imagenesIES/ — splash del Live CD sin personalizar."
        return 0
    fi

    local overlay_dir="${WORK_DIR}/plymouth_initrd_overlay"
    local found_bgrt=0
    local found_watermark=0

    # Detectar rutas reales con lsinitramfs si está disponible (initramfs-tools)
    if command -v lsinitramfs &>/dev/null; then
        log "  Escaneando initrd con lsinitramfs..."
        while IFS= read -r rel; do
            rel="${rel#./}"
            case "$(basename "$rel")" in
                bgrt-fallback.png)
                    mkdir -p "${overlay_dir}/$(dirname "$rel")"
                    cp "${bgrt_png}" "${overlay_dir}/${rel}"
                    log "  bgrt-fallback.png → ${rel}"
                    found_bgrt=1
                    ;;
                watermark.png)
                    mkdir -p "${overlay_dir}/$(dirname "$rel")"
                    cp "${watermark_png}" "${overlay_dir}/${rel}"
                    log "  watermark.png → ${rel}"
                    found_watermark=1
                    ;;
            esac
        done < <(lsinitramfs "${initrd_path}" 2>/dev/null | grep '\.png$' || true)
    fi

    # Fallback: rutas conocidas de Ubuntu 24.04+/26.04
    # 2-SetupSOdesdeLiveCD.sh copia bgrt-fallback.png a ambos directorios (spinner y bgrt)
    if [[ "$found_bgrt" -eq 0 ]]; then
        [[ "$found_bgrt" -eq 0 ]] && warn "  lsinitramfs no detectó bgrt-fallback.png → usando rutas por defecto"
        for rel in \
            "usr/share/plymouth/themes/bgrt/bgrt-fallback.png" \
            "usr/share/plymouth/themes/spinner/bgrt-fallback.png"; do
            mkdir -p "${overlay_dir}/$(dirname "$rel")"
            cp "${bgrt_png}" "${overlay_dir}/${rel}"
            log "  bgrt-fallback.png → ${rel} (ruta por defecto)"
        done
    fi
    if [[ "$found_watermark" -eq 0 ]]; then
        local wm_rel="usr/share/plymouth/themes/spinner/watermark.png"
        warn "  lsinitramfs no detectó watermark.png → usando ruta por defecto"
        mkdir -p "${overlay_dir}/$(dirname "$wm_rel")"
        cp "${watermark_png}" "${overlay_dir}/${wm_rel}"
        log "  watermark.png → ${wm_rel} (ruta por defecto)"
    fi

    # Empaquetar como cpio sin comprimir.
    local overlay_cpio="${WORK_DIR}/plymouth_overlay.cpio"
    (cd "${overlay_dir}" && find . | sort | cpio --create --owner 0:0 --format=newc 2>/dev/null) \
        > "${overlay_cpio}"

    # APPEND con gzip: nuestro CPIO va AL FINAL del initrd, comprimido con gzip.
    #
    # Por qué no PREPEND sin comprimir (enfoque anterior, incorrecto):
    #   El kernel procesa los segmentos initrd en orden; el ÚLTIMO sobreescribe duplicados.
    #   Con PREPEND, el initramfs principal (que va después) sobreescribe nuestras
    #   imágenes Plymouth → Plymouth muestra los logos estándar de Ubuntu.
    #
    # Por qué no APPEND sin comprimir:
    #   El kernel encuentra magic CPIO (070701) tras el stream comprimido y lo interpreta
    #   como otro stream comprimido → "invalid magic at start of compressed archive".
    #
    # Con APPEND gzip: el kernel ve magic gzip (1f 8b) → nuevo segmento comprimido válido
    #   → extrae nuestras imágenes DESPUÉS del initramfs principal → nuestros ficheros ganan.
    local overlay_cpio_gz="${WORK_DIR}/plymouth_overlay.cpio.gz"
    gzip -9 -c "${overlay_cpio}" > "${overlay_cpio_gz}"
    local patched_initrd="${WORK_DIR}/initrd_patched"
    cat "${initrd_path}" "${overlay_cpio_gz}" > "${patched_initrd}"
    cp "${patched_initrd}" "${initrd_path}"
    log "Plymouth del Live CD personalizado: overlay gzip ($(du -sh "${overlay_cpio_gz}" | cut -f1)) añadido al final del initrd."
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CONFIGURAR GRUB PARA ARRANQUE AUTOMÁTICO
# ─────────────────────────────────────────────────────────────────────────────
configure_grub() {
    step "Configurando GRUB para arranque en modo Live CD"
    local grub_cfg="${ISO_DIR}/boot/grub/grub.cfg"

    if [[ ! -f "$grub_cfg" ]]; then
        grub_cfg=$(find "${ISO_DIR}" -name "grub.cfg" | head -1)
        [[ -z "$grub_cfg" ]] && err "No se encontró grub.cfg en la ISO."
    fi

    cp "$grub_cfg" "${grub_cfg}.orig"
    # locale=es_ES.UTF-8  → casper carga automaticamente las capas *.es.squashfs
    # keyboard-configuration/layoutcode=es → teclado español desde el arranque
    # console-setup/layoutcode=es          → idem para la consola de texto
    cat > "$grub_cfg" << 'GRUBEOF'
set default=0
set timeout=5
set timeout_style=hidden

menuentry "Instalar Ubuntu Personalizado (IAC-IESMHP)" {
    linux   /casper/vmlinuz  boot=casper quiet splash locale=es_ES.UTF-8 keyboard-configuration/layoutcode=es console-setup/layoutcode=es ---
    initrd  /casper/initrd
}
menuentry "Probar Ubuntu en Espanol (Live)" {
    linux   /casper/vmlinuz  boot=casper quiet splash locale=es_ES.UTF-8 keyboard-configuration/layoutcode=es console-setup/layoutcode=es ---
    initrd  /casper/initrd
}
menuentry 'UEFI Firmware Settings' {
    fwsetup
}
GRUBEOF
    log "GRUB configurado: locale=es_ES.UTF-8, teclado español."
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. ELIMINAR BIOS/LEGACY BOOT
# ─────────────────────────────────────────────────────────────────────────────
remove_bios_boot() {
    step "Eliminando componentes BIOS/Legacy"

    if [[ -d "${ISO_DIR}/isolinux" ]]; then
        rm -rf "${ISO_DIR}/isolinux"
        log "  isolinux/ eliminado"
    fi

    if [[ -d "${ISO_DIR}/boot/grub/i386-pc" ]]; then
        rm -rf "${ISO_DIR}/boot/grub/i386-pc"
        log "  boot/grub/i386-pc/ eliminado"
    fi

    if [[ -f "${ISO_DIR}/boot/grub/boot_hybrid.img" ]]; then
        rm -f "${ISO_DIR}/boot/grub/boot_hybrid.img"
        log "  boot_hybrid.img eliminado"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. OBTENER PARÁMETROS EFI (VERSIÓN ROBUSTA sfdisk)
# ─────────────────────────────────────────────────────────────────────────────
get_efi_boot_params() {
    step "Leyendo parámetros EFI de la ISO original"
    EFI_PARAMS=$(xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null || true)
    EFI_IMG_PATH=$(echo "$EFI_PARAMS" | grep -oP '(?<=-e\s|--efi-boot\s|--interval:appended_partition)\S+' | head -1 || true)

    USE_APPENDED_PARTITION=false
    if echo "$EFI_PARAMS" | grep -q "appended_partition"; then
        USE_APPENDED_PARTITION=true
    fi

    if xorriso -osirrox on -indev "$SOURCE_ISO" -extract /boot/grub/efi.img "${WORK_DIR}/efi.img" 2>/dev/null; then
        EFI_IMG_FILE="${WORK_DIR}/efi.img"
        log "efi.img extraído exitosamente desde la ruta interna."
    else
        local appended_file
        appended_file=$(echo "$EFI_PARAMS" | grep -oP '(?<=-append_partition 2 [a-f0-9-]+ )\S+' | head -1 || true)

        if [[ -n "$appended_file" ]] && xorriso -osirrox on -indev "$SOURCE_ISO" -extract "$appended_file" "${WORK_DIR}/efi.img" 2>/dev/null; then
            EFI_IMG_FILE="${WORK_DIR}/efi.img"
            log "Partición adjunta EFI extraída exitosamente con xorriso."
        else
            warn "xorriso falló. Extrayendo sectores a bajo nivel con sfdisk+dd..."
            local part_info
            part_info=$(sfdisk -d "$SOURCE_ISO" 2>/dev/null | grep -i -E 'type=ef|type=C12A7328' | head -1)

            if [[ -n "$part_info" ]]; then
                local efi_start efi_size
                efi_start=$(echo "$part_info" | grep -oP 'start=\s*\K[0-9]+')
                efi_size=$(echo "$part_info" | grep -oP 'size=\s*\K[0-9]+')

                if [[ -n "$efi_start" ]] && [[ -n "$efi_size" ]]; then
                    dd if="$SOURCE_ISO" of="${WORK_DIR}/efi.img" bs=512 skip="$efi_start" count="$efi_size" 2>/dev/null
                    EFI_IMG_FILE="${WORK_DIR}/efi.img"
                    log "EFI extraído vía sfdisk+dd (Inicio: ${efi_start}, Sectores: ${efi_size})."
                else
                    err "sfdisk localizó la partición pero no se pudieron calcular los sectores."
                fi
            else
                err "sfdisk no pudo encontrar ninguna partición EFI en la ISO de origen."
            fi
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. REEMPAQUETAR ISO UEFI
# ─────────────────────────────────────────────────────────────────────────────
repack_iso() {
    step "Reempaquetando ISO UEFI → ${OUTPUT_ISO}"
    [[ -f "$OUTPUT_ISO" ]] && rm -f "$OUTPUT_ISO"

    if [[ "$USE_APPENDED_PARTITION" == "true" ]]; then
        local EFI_PART_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
        xorriso -as mkisofs -r -V "UBUNTU_CUSTOM_DESKTOP" -o "${OUTPUT_ISO}" \
            --no-pad -J --joliet-long -rational-rock -partition_offset 16 \
            -appended_part_as_gpt -append_partition 2 "${EFI_PART_TYPE}" "${EFI_IMG_FILE}" \
            -e "--interval:appended_partition_2:::" -no-emul-boot "${ISO_DIR}" \
        || err "Fallo en xorriso (modo GPT)."
    else
        local efi_rel
        efi_rel=$(realpath --relative-to="${ISO_DIR}" "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null || echo "boot/grub/efi.img")
        xorriso -as mkisofs -r -V "UBUNTU_CUSTOM_DESKTOP" -o "${OUTPUT_ISO}" \
            --no-pad -J --joliet-long -rational-rock -e "${efi_rel}" -no-emul-boot \
            -boot-load-size 4 -boot-info-table --efi-boot "${efi_rel}" \
            -efi-boot-part --efi-boot-image "${ISO_DIR}" \
        || err "Fallo en xorriso (modo El Torito)."
    fi

    log "ISO completada: ${OUTPUT_ISO} ($(du -sh "${OUTPUT_ISO}" | cut -f1))"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    check_root
    check_deps
    check_inputs
    extract_iso
    customize_squashfs
    # customize_plymouth_initrd  # desactivado: el gzip-append degrada Plymouth a modo texto
    configure_grub
    remove_bios_boot
    get_efi_boot_params
    repack_iso

    echo -e "${GREEN}✓ ISO Desktop lista: ${OUTPUT_ISO}${NC}"
}

main "$@"