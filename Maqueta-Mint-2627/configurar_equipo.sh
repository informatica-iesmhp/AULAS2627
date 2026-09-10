#!/usr/bin/env bash
#
# configurar_equipo.sh
# ---------------------------------------------------------------
# Aprovisionamiento de equipos de aula (Linux Mint / NetworkManager)
#
# Qué hace:
#   1. Clona/descarga el CSV maestro de MACs desde el repositorio
#      público (informatica-iesmhp/AULAS2627).
#   2. Detecta la MAC de la interfaz de red principal del equipo.
#   3. Busca esa MAC en el CSV (sea cual sea el aula: IF01-IF04,
#      CEIABD, DISTANCIA...) y obtiene el nombre de equipo y el
#      último octeto de IP que le corresponde.
#   4. Toma la configuración de red ACTUAL (obtenida por DHCP:
#      subred, máscara, gateway, DNS) y solo sustituye el último
#      octeto por el indicado en el CSV, convirtiendo la conexión
#      a IP estática (tal y como indica el propio CSV en sus
#      comentarios).
#   5. Cambia el hostname si no coincide.
#
# El script es idempotente: si se ejecuta varias veces y el equipo
# ya tiene el nombre e IP correctos, no hace nada.
#
# Uso:
#   sudo ./configurar_equipo.sh          # aplica los cambios
#   sudo ./configurar_equipo.sh --dry-run   # solo muestra qué haría
#
# ---------------------------------------------------------------

set -euo pipefail

REPO_URL="https://github.com/informatica-iesmhp/AULAS2627.git"
RAW_URL="https://raw.githubusercontent.com/informatica-iesmhp/AULAS2627/main/macs.csv"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Tabla de referencia aula -> subred, solo para avisar si algo no
# cuadra; el script NO depende de esta tabla para funcionar, ya que
# busca directamente por MAC (más robusto y fácil de mantener).
declare -A AULA_SUBRED=(
    [IF01]="10.0.16"
    [IF02]="10.0.13"
    [IF03]="10.0.10"
    [IF04]="10.0.22"
)

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }
run()  { # ejecuta el comando salvo en --dry-run
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        eval "$@"
    fi
}

[[ $EUID -eq 0 ]] || err "Este script debe ejecutarse como root (sudo)."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
CSV_PATH="$WORKDIR/macs.csv"

# ------------------------------------------------------------------
# 1. Descargar el CSV maestro (clona el repo; si no hay git, cae en
#    curl sobre el fichero "raw").
# ------------------------------------------------------------------
log "Descargando listado de equipos desde el repositorio..."
if command -v git &>/dev/null; then
    if git clone --depth 1 --quiet "$REPO_URL" "$WORKDIR/repo" 2>/dev/null; then
        cp "$WORKDIR/repo/macs.csv" "$CSV_PATH"
    fi
fi
if [[ ! -s "$CSV_PATH" ]]; then
    command -v curl &>/dev/null || err "Se necesita 'git' o 'curl' para descargar el CSV."
    curl -fsSL "$RAW_URL" -o "$CSV_PATH" || err "No se ha podido descargar macs.csv (ni por git ni por curl)."
fi
# normaliza posibles finales de línea CRLF
sed -i 's/\r$//' "$CSV_PATH"
log "CSV disponible en $CSV_PATH"

# ------------------------------------------------------------------
# 2. Detectar interfaz de red principal y su MAC
# ------------------------------------------------------------------
IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[[ -n "$IFACE" ]] || err "No se ha podido determinar la interfaz de red principal (¿hay conexión activa?)."

MAC_NORM="$(tr '[:lower:]' '[:upper:]' < /sys/class/net/"$IFACE"/address)"
log "Interfaz principal: $IFACE   MAC: $MAC_NORM"

# ------------------------------------------------------------------
# 3. Buscar la MAC en el CSV (se ignoran líneas de comentario '#')
# ------------------------------------------------------------------
LINEA="$(awk -F',' -v mac="$MAC_NORM" '
    {
        m = $1
        gsub(/^[ \t]+|[ \t]+$/, "", m)
        if (m ~ /^#/ || m == "") next
        if (toupper(m) == mac) { print; exit }
    }
' "$CSV_PATH")"

[[ -n "$LINEA" ]] || err "La MAC $MAC_NORM no aparece en macs.csv. Revisa el listado o añade el equipo en el repositorio."

EQUIPO="$(echo "$LINEA"     | awk -F',' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}')"
IPF="$(echo "$LINEA"        | awk -F',' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}')"
COMENTARIO="$(echo "$LINEA" | awk -F',' '{v=$4; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}')"

[[ -n "$EQUIPO" && -n "$IPF" ]] || err "Entrada encontrada en el CSV pero incompleta: $LINEA"

log "Equipo localizado -> Nombre: $EQUIPO | Octeto final IP: $IPF | Comentario: ${COMENTARIO:-<ninguno>}"

# ------------------------------------------------------------------
# 4. Leer la configuración de red ACTUAL (la que ha dado el DHCP)
# ------------------------------------------------------------------
CONN_NAME="$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v i="$IFACE" '$2==i {print $1; exit}')"
[[ -n "$CONN_NAME" ]] || err "No se ha encontrado una conexión de NetworkManager activa para $IFACE."

CIDR="$(nmcli -g IP4.ADDRESS con show "$CONN_NAME" | head -n1)"
GATEWAY="$(nmcli -g IP4.GATEWAY con show "$CONN_NAME" | head -n1)"
DNS="$(nmcli -g IP4.DNS con show "$CONN_NAME" | tr '|' ' ')"

[[ -n "$CIDR" ]] || err "No se ha podido leer la IP actual de la conexión '$CONN_NAME'."

IP_ACTUAL="${CIDR%%/*}"
PREFIX="${CIDR##*/}"
SUBRED="${IP_ACTUAL%.*}"
NUEVA_IP="${SUBRED}.${IPF}/${PREFIX}"

log "Configuración actual -> $CIDR (gateway $GATEWAY, dns: ${DNS:-<ninguno>})"
log "Subred detectada: ${SUBRED}.x"

# Aviso informativo si la subred no coincide con la tabla de referencia
AULA_PREFIJO="${EQUIPO%%-*}"
if [[ -n "${AULA_SUBRED[$AULA_PREFIJO]:-}" && "${AULA_SUBRED[$AULA_PREFIJO]}" != "$SUBRED" ]]; then
    log "AVISO: la subred detectada (${SUBRED}.x) no coincide con la esperada para $AULA_PREFIJO (${AULA_SUBRED[$AULA_PREFIJO]}.x). Se continúa igualmente porque la búsqueda se hace por MAC."
fi

# ------------------------------------------------------------------
# 5. Aplicar hostname (si hace falta)
# ------------------------------------------------------------------
HOSTNAME_ACTUAL="$(hostname)"
if [[ "$HOSTNAME_ACTUAL" != "$EQUIPO" ]]; then
    log "Cambiando hostname: '$HOSTNAME_ACTUAL' -> '$EQUIPO'"
    run "hostnamectl set-hostname '$EQUIPO'"
    run "sed -i 's/^127\.0\.1\.1.*/127.0.1.1\t$EQUIPO/' /etc/hosts"
else
    log "El hostname ya es correcto ($EQUIPO), no se modifica."
fi

# ------------------------------------------------------------------
# 6. Aplicar IP estática (si hace falta)
# ------------------------------------------------------------------
if [[ "$CIDR" == "$NUEVA_IP" ]]; then
    log "La IP ya es la correcta ($NUEVA_IP), no se modifica."
else
    log "Configurando IP estática: $NUEVA_IP (gateway $GATEWAY, dns: ${DNS:-<ninguno>})"
    run "nmcli con mod '$CONN_NAME' ipv4.addresses '$NUEVA_IP' ipv4.gateway '$GATEWAY' ipv4.dns '$DNS' ipv4.method manual"
    run "nmcli con down '$CONN_NAME' && nmcli con up '$CONN_NAME'"
fi

log "Configuración completada: $EQUIPO / $NUEVA_IP"
[[ "$HOSTNAME_ACTUAL" != "$EQUIPO" ]] && log "Puede que algunos servicios necesiten un reinicio para ver el nuevo hostname."

exit 0
