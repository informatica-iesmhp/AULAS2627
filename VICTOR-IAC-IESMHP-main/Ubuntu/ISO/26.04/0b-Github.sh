#!/usr/bin/env bash
# =============================================================================
#  0b-Github.sh
#  Script de personalización embebido en la ISO.
#  Se ejecuta como early-command desde el entorno live de Ubuntu.
#  Clona el repositorio IAC-IESMHP y lanza 1-SetupLiveCD.sh.
# =============================================================================
set -euo pipefail

# ── BLOQUE DE ARRANQUE (única duplicación inevitable del proyecto) ───────────
# 0b-Github.sh corre en el Live CD ANTES de clonar el repo, así que todavía no
# puede hacer `source comun.sh` (aún no existe en disco). Estos dos valores son
# los ÚNICOS que se repiten fuera de comun.sh y DEBEN COINCIDIR con los de
# Ubuntu/ISO/26.04/comun.sh. Todo lo demás (SCRIPT_INSTALL, rutas...) se obtiene
# cargando comun.sh tras clonar (ver más abajo).
GITHUB_USER="victormuelacarriles"
REPO="IAC-IESMHP"
# ─────────────────────────────────────────────────────────────────────────────
GITREPO="https://github.com/${GITHUB_USER}/${REPO}.git"
DESTDIR="/opt/${REPO}"

RAIZLOG="/var/log/${REPO}/Ubuntu"
LOG0B="${RAIZLOG}/0b-Github.sh.log"

#export DISPLAY=:0
#export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/999/bus
#zenity --info --text="Configurando..." --timeout=3 || true
# Authorization required, but no authorization protocol specified

# ─────────────── Colores ───────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[perso][+]${NC} $*"; }
warn() { echo -e "${YELLOW}[perso][!]${NC} $*"; }
err()  { echo -e "${RED}[perso][✗]${NC} $*" >&2; exit 1; }

# ─────────────── Log persistente ───────
mkdir -p "$RAIZLOG"
exec > >(tee -a "$LOG0B") 2>&1

log "=== 0b-Github.sh iniciado: $(date) ==="
log "REPO=$REPO  GITREPO=$GITREPO  DESTDIR=$DESTDIR"
log "Kernel: $(uname -r)  CPU: $(nproc) cores  RAM: $(free -h | awk '/^Mem:/{print $2}')"

# ─────────────── Red: esperar DHCP ─────
log "Comprobando conectividad..."
for i in $(seq 1 12); do
    if ping -c1 -W2 github.com &>/dev/null; then
        log "Red disponible."
        break
    fi
    warn "Sin red, reintento ${i}/12..."
    sleep 5
done
ping -c1 -W2 github.com &>/dev/null || err "No hay conexión a Internet. Abortando."

# ─────────────── Hora correcta (zona + NTP) ─────
# En el Live CD (sobre todo en VMware con host Windows) el reloj suele aparecer
# 2 h adelantado: el RTC lleva hora local de Madrid pero Linux lo interpreta
# como UTC y le suma el desfase de la zona. Con red disponible, fijamos la zona
# Europe/Madrid y forzamos sincronización NTP (servidores por defecto de
# systemd-timesyncd) para que la hora —y por tanto los timestamps de logs y de
# los ficheros que crean los scripts siguientes— sean correctos.
log "Fijando zona horaria Europe/Madrid y sincronizando hora por NTP..."
timedatectl set-timezone Europe/Madrid 2>/dev/null \
    || warn "No se pudo fijar la zona horaria con timedatectl."
# Servidores NTP por defecto (NTP= vacío → FallbackNTP de timesyncd).
timedatectl set-ntp true 2>/dev/null || true
systemctl restart systemd-timesyncd 2>/dev/null || true
# Esperar a que NTP confirme sincronización (máx ~30 s) antes de continuar.
for i in $(seq 1 15); do
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
    sleep 2
done
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    log "Hora sincronizada por NTP: $(date)"
else
    # Fallback HTTP: en las aulas el UDP 123 (NTP) suele estar filtrado, pero el
    # TCP 443 (HTTPS) no — el clonado del repo de más abajo va por ahí. Leemos la
    # hora de la cabecera «Date:» de una petición HTTPS: viene en GMT, así que
    # `date -s` la interpreta y la convierte sola a Europe/Madrid (zona ya fijada).
    # Con `set -euo pipefail` cada pipeline lleva `|| true` para que un grep sin
    # coincidencia no aborte el script.
    warn "NTP no confirmó sincronización (¿UDP 123 bloqueado?); intento por HTTP..."
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
        if [[ -n "$HORA_HTTP" ]] && date -s "$HORA_HTTP" >/dev/null 2>&1; then
            hwclock --systohc 2>/dev/null || true
            log "Hora sincronizada por HTTP ($url): $(date)"
            break
        fi
        HORA_HTTP=""
    done
    [[ -n "$HORA_HTTP" ]] || warn "Tampoco se pudo sincronizar por HTTP; se continúa con: $(date)"
fi

# ─────────────── git ───────────────────




# update-initramfs tarda 2-4 min reconstruyendo el initramfs del kernel.
# En un live CD no sirve para nada; lo sustituimos por un no-op antes de
# llamar a apt para que dpkg no lo ejecute al procesar los triggers pendientes.
mkdir -p /usr/local/sbin
ln -sf /bin/true /usr/local/sbin/update-initramfs
export PATH="/usr/local/sbin:$PATH"
# Los scripts postinst del kernel llaman a /usr/sbin/update-initramfs con ruta
# absoluta, ignorando el PATH. Hay que enmascarar también el binario real.
ln -sf /bin/true /usr/sbin/update-initramfs
log "update-initramfs enmascarado (no-op en entorno live)."

log "Desactivamos actualización de man-db"
rm -f /var/lib/man-db/auto-update
log "Actualizando lista de paquetes..."
DEBIAN_FRONTEND=noninteractive apt-get update -q
log "Asegurando que git está instalado..."
DEBIAN_FRONTEND=noninteractive apt-get install git -y
log "git instalado: $(git --version 2>/dev/null || echo 'no encontrado')"


# ─────────────── Clonar repo ───────────
if [[ -d "${DESTDIR}/.git" ]]; then
    warn "El repositorio ya existe en ${DESTDIR}. Actualizando..."
    git -C "${DESTDIR}" pull --ff-only
    log "Repo actualizado: $(git -C "${DESTDIR}" log -1 --oneline 2>/dev/null || echo 'sin commits')"
else
    log "Clonando ${GITREPO} → ${DESTDIR} ..."
    git clone "${GITREPO}" "${DESTDIR}"
    log "Repo clonado: $(git -C "${DESTDIR}" log -1 --oneline 2>/dev/null || echo 'sin commits')"
fi

# ─────────────── Cargar variables comunes ──
# El repo ya está clonado: a partir de aquí comun.sh es la única fuente de
# verdad. Obtenemos de ahí la ruta del script de instalación (SCRIPT_LIVECD)
# en vez de codificar a fuego la versión (26.04) y la ruta.
VERSIONUBUNTU="$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d'"' -f2 || true)"
COMUN="${DESTDIR}/Ubuntu/ISO/${VERSIONUBUNTU:-26.04}/comun.sh"
if [[ -f "$COMUN" ]]; then
    # shellcheck disable=SC1090
    source "$COMUN"
    SCRIPT_INSTALL="$SCRIPT_LIVECD"
    log "comun.sh cargado — SCRIPT_INSTALL=$SCRIPT_INSTALL"
else
    # Fallback si comun.sh no estuviera (repo antiguo): ruta directa.
    SCRIPT_INSTALL="${DESTDIR}/Ubuntu/ISO/${VERSIONUBUNTU:-26.04}/1-SetupLiveCD.sh"
    warn "comun.sh no encontrado en $COMUN — usando ruta directa $SCRIPT_INSTALL"
fi

# ─────────────── Verificar script ──────
[[ -f "${SCRIPT_INSTALL}" ]] \
    || err "No se encontró el script de instalación: ${SCRIPT_INSTALL}"

chmod +x "${SCRIPT_INSTALL}"

# ─────────────── Lanzar instalación ────


log "=== 0b-Github.sh finalizado: $(date) — lanzando ${SCRIPT_INSTALL} ==="
bash "${SCRIPT_INSTALL}"


# echo "1. Ver qué procesos están corriendo en ese momento:"
# ps axf | grep -E "(apt|dpkg|git|iac|bash)" --color=never
# echo "2. Ver en qué función de kernel está bloqueado dpkg (el más útil):"
# cat /proc/$(pgrep -f dpkg | head -1)/wchan 2>/dev/null

# echo "3. Comprobar si hay locks de apt/dpkg activos:"
# ls -la /var/lib/dpkg/lock* /var/lib/apt/lists/lock* 2>/dev/null
# fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null

# echo "4. Ver si systemd está haciendo algo:"
# systemctl status --no-pager | head -20
# journalctl -n 30 --no-pager

# echo "5. Ver los triggers dpkg pendientes:"
# ls /var/lib/dpkg/triggers/