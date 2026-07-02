#!/usr/bin/env bash
# CompactaW11.sh — Defrag y compactacion de VMDKs VMware
# Uso: CompactaW11.sh <archivo.vmx> | <archivo.iso> | <directorio>
# Requiere: vmrun, vmware-vdiskmanager
set -euo pipefail

# ---------------------------------------------------------------------------
# Log: todo lo que hace el script se vuelca a CompactaW11.YYYYMMDD-HHMMSS.log
# (marca de tiempo de inicio en el nombre) junto al propio script.
# ---------------------------------------------------------------------------
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/CompactaW11.$LOG_STAMP.log"
# Duplicar stdout y stderr al fichero de log conservando la salida en pantalla.
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== CompactaW11.sh — inicio $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "=== Log: $LOG_FILE ==="

# ---------------------------------------------------------------------------
# Colores ANSI
# ---------------------------------------------------------------------------
C_RESET='\033[0m'
C_VERDE='\033[0;32m'
C_AMARILLO='\033[0;33m'
C_ROJO='\033[0;31m'
C_CYAN='\033[0;36m'
C_NEGRITA='\033[1m'

ok()    { echo -e "${C_VERDE}[OK]${C_RESET}  $*"; }
warn()  { echo -e "${C_AMARILLO}[AVISO]${C_RESET} $*"; }
error() { echo -e "${C_ROJO}[ERROR]${C_RESET} $*" >&2; }
info()  { echo -e "${C_CYAN}[INFO]${C_RESET}  $*"; }
titulo(){ echo -e "\n${C_NEGRITA}${C_CYAN}=== $* ===${C_RESET}"; }

# ---------------------------------------------------------------------------
# Buscar herramientas
# ---------------------------------------------------------------------------
buscar_herramienta() {
    local nombre="$1"
    local rutas_extra=(
        "/usr/bin"
        "/usr/lib/vmware/bin"
        "/usr/local/bin"
        "/opt/vmware/bin"
    )
    # Primero en PATH
    if command -v "$nombre" &>/dev/null; then
        command -v "$nombre"
        return 0
    fi
    # Luego en rutas conocidas
    for dir in "${rutas_extra[@]}"; do
        if [[ -x "$dir/$nombre" ]]; then
            echo "$dir/$nombre"
            return 0
        fi
    done
    return 1
}

VMRUN=""
VDISKMANAGER=""

if ! VMRUN=$(buscar_herramienta "vmrun"); then
    error "No se encontro 'vmrun'. Instala VMware Workstation/Player."
    exit 1
fi

if ! VDISKMANAGER=$(buscar_herramienta "vmware-vdiskmanager"); then
    error "No se encontro 'vmware-vdiskmanager'. Instala VMware Workstation."
    exit 1
fi

info "vmrun:              $VMRUN"
info "vmware-vdiskmanager: $VDISKMANAGER"

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

# Devuelve los VMDKs base referenciados en el .vmx
# Filtra los de snapshot (-s NNN, -000NNN) y los descriptores .vmdk que
# apuntan a extent files (*-flat.vmdk se excluyen con el patron de nombre).
parsear_vmdks() {
    local vmx="$1"
    local dir
    dir="$(dirname "$vmx")"

    # Extraer lineas tipo:  scsiX:Y.fileName = "ruta/disco.vmdk"
    grep -iE '^\s*[a-z]+[0-9]+:[0-9]+\.filename\s*=' "$vmx" \
        | sed -E 's/.*=\s*"([^"]+)".*/\1/' \
        | while read -r ruta; do
            # Ruta relativa → absoluta
            if [[ "$ruta" != /* ]]; then
                ruta="$dir/$ruta"
            fi
            ruta="$(realpath -m "$ruta")"
            local base
            base="$(basename "$ruta")"
            # Excluir snapshots: contienen -s NNN o -000 o -delta
            if echo "$base" | grep -qE -- '-s[0-9]+\.vmdk$|-[0-9]{6}\.vmdk$|-delta\.vmdk$'; then
                continue
            fi
            # Excluir extent files planos
            if echo "$base" | grep -qE -- '-flat\.vmdk$'; then
                continue
            fi
            # Solo incluir si el fichero existe
            if [[ -f "$ruta" ]]; then
                echo "$ruta"
            fi
        done | sort -u
}

# Detecta si el VMDK es thin o thick leyendo el descriptor
tipo_vmdk() {
    local vmdk="$1"
    # createType en el descriptor indica el tipo
    local ctype
    ctype=$(grep -i 'createType' "$vmdk" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    case "${ctype,,}" in
        *sparse*|*thin*)        echo "thin" ;;
        *flat*|*thick*|*eager*) echo "thick" ;;
        *)                      echo "desconocido ($ctype)" ;;
    esac
}

# Tamanio real en disco del VMDK (descriptor + extents)
tamano_vmdk() {
    local vmdk="$1"
    local dir
    dir="$(dirname "$vmdk")"
    local base
    base="$(basename "$vmdk" .vmdk)"

    # Sumar descriptor + todos los ficheros de extent asociados
    {
        echo "$vmdk"
        # Extents planos: base-flat.vmdk, base-s001.vmdk, base-000001.vmdk …
        find "$dir" -maxdepth 1 -name "${base}*.vmdk" ! -name "$base.vmdk" 2>/dev/null || true
    } | sort -u | xargs du -scb 2>/dev/null | tail -1 | awk '{print $1}'
}

# Formatea bytes en formato humano
bytes_a_human() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.1f GiB\", $bytes/1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.1f MiB\", $bytes/1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.1f KiB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

# ---------------------------------------------------------------------------
# Comprueba que la VM esta apagada
# ---------------------------------------------------------------------------
verificar_apagada() {
    local vmx="$1"
    local vmx_real
    vmx_real="$(realpath "$vmx")"

    info "Verificando estado de la VM: $vmx_real"
    local lista
    lista="$("$VMRUN" list 2>/dev/null)" || true

    while IFS= read -r linea; do
        [[ -z "$linea" ]] && continue
        # Comparar normalizando rutas
        local linea_real
        linea_real="$(realpath -m "$linea" 2>/dev/null || echo "$linea")"
        if [[ "$linea_real" == "$vmx_real" ]]; then
            error "La VM esta en ejecucion: $vmx_real"
            error "Apaga la VM antes de compactar."
            return 1
        fi
    done <<< "$lista"

    ok "VM apagada."
    return 0
}

# ---------------------------------------------------------------------------
# Comprueba que no hay snapshots
# ---------------------------------------------------------------------------
verificar_sin_snapshots() {
    local vmx="$1"
    info "Verificando snapshots..."

    local num
    num="$("$VMRUN" listSnapshots "$vmx" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo "0")"

    if (( num > 0 )); then
        error "La VM tiene $num snapshot(s) activo(s)."
        error "Elimina todos los snapshots antes de compactar (Snapshot > Delete All Snapshots)."
        return 1
    fi

    ok "Sin snapshots."
    return 0
}

# ---------------------------------------------------------------------------
# Proceso de una sola VM (.vmx)
# Devuelve via variables globales el ahorro total (bytes) para el resumen
# ---------------------------------------------------------------------------
declare -a TABLA_RESUMEN=()    # lineas de la tabla final
TOTAL_ANTES_BYTES=0
TOTAL_DESPUES_BYTES=0

procesar_vm() {
    local vmx="$1"

    titulo "VM: $(basename "$vmx")"
    info "Fichero: $vmx"

    # Normalizar ruta
    if [[ ! -f "$vmx" ]]; then
        error "No existe el fichero: $vmx"
        return 1
    fi
    vmx="$(realpath "$vmx")"

    # Comprobaciones previas
    verificar_apagada "$vmx"    || return 1
    verificar_sin_snapshots "$vmx" || return 1

    # Obtener lista de VMDKs
    local vmdks=()
    while IFS= read -r v; do
        vmdks+=("$v")
    done < <(parsear_vmdks "$vmx")

    if (( ${#vmdks[@]} == 0 )); then
        warn "No se encontraron VMDKs base en: $vmx"
        return 0
    fi

    info "VMDKs encontrados: ${#vmdks[@]}"

    # Espacio en host antes
    local host_disco
    host_disco="$(df -h "$(dirname "$vmx")" | tail -1 | awk '{print "libre="$4" total="$2" uso="$5}')"
    info "Espacio host antes: $host_disco"

    local vm_antes_bytes=0
    local vm_despues_bytes=0

    for vmdk in "${vmdks[@]}"; do
        local nombre_vmdk
        nombre_vmdk="$(basename "$vmdk")"
        local tipo
        tipo="$(tipo_vmdk "$vmdk")"

        titulo "VMDK: $nombre_vmdk  [$tipo]"

        local antes_bytes
        antes_bytes="$(tamano_vmdk "$vmdk")"
        local antes_human
        antes_human="$(bytes_a_human "$antes_bytes")"
        info "Tamano antes:  $antes_human  ($antes_bytes bytes)"
        info "Ubicacion: $vmdk"

        if [[ "$tipo" == thick* ]] || [[ "$tipo" == "desconocido"* ]]; then
            warn "El VMDK parece de tipo thick/flat; la compactacion puede no reducir espacio."
        fi

        # --- Defrag ---
        titulo "Paso 1/2 — Defragmentando: $nombre_vmdk"
        if "$VDISKMANAGER" -d "$vmdk"; then
            ok "Defrag completado."
        else
            warn "Defrag termino con error (puede ser normal en VMDKs thin ya compactos)."
        fi

        # --- Compactar ---
        titulo "Paso 2/2 — Compactando: $nombre_vmdk"
        if "$VDISKMANAGER" -k "$vmdk"; then
            ok "Compactacion completada."
        else
            error "La compactacion fallo para: $vmdk"
            # Registrar sin ahorro y continuar
            TABLA_RESUMEN+=("$(printf '  %-45s  %8s  %8s  %8s' "$nombre_vmdk" "$antes_human" "$antes_human" "0 B")")
            continue
        fi

        local despues_bytes
        despues_bytes="$(tamano_vmdk "$vmdk")"
        local despues_human
        despues_human="$(bytes_a_human "$despues_bytes")"
        local ahorro_bytes=$(( antes_bytes - despues_bytes ))
        local ahorro_human
        ahorro_human="$(bytes_a_human "$ahorro_bytes")"

        if (( ahorro_bytes > 0 )); then
            ok "Tamano despues: $despues_human  (ahorro: ${C_VERDE}$ahorro_human${C_RESET})"
        else
            warn "Tamano despues: $despues_human  (sin reduccion significativa)"
            ahorro_bytes=0
            ahorro_human="0 B"
        fi

        vm_antes_bytes=$(( vm_antes_bytes + antes_bytes ))
        vm_despues_bytes=$(( vm_despues_bytes + despues_bytes ))
        TOTAL_ANTES_BYTES=$(( TOTAL_ANTES_BYTES + antes_bytes ))
        TOTAL_DESPUES_BYTES=$(( TOTAL_DESPUES_BYTES + despues_bytes ))

        TABLA_RESUMEN+=("$(printf '  %-45s  %8s  %8s  %8s' "$nombre_vmdk" "$antes_human" "$despues_human" "$ahorro_human")")
    done

    # Espacio en host despues
    local host_disco_post
    host_disco_post="$(df -h "$(dirname "$vmx")" | tail -1 | awk '{print "libre="$4" total="$2" uso="$5}')"
    info "Espacio host despues: $host_disco_post"

    local vm_ahorro=$(( vm_antes_bytes - vm_despues_bytes ))
    local vm_ahorro_human
    vm_ahorro_human="$(bytes_a_human "$vm_ahorro")"
    ok "Ahorro total para $(basename "$vmx"): $vm_ahorro_human"
}

# ---------------------------------------------------------------------------
# Analisis de una ISO
# Las imagenes ISO (ISO 9660 / UDF) son de solo lectura y NO son comprimibles
# con vmware-vdiskmanager. Se analizan (tamano) para informar y se continua.
# ---------------------------------------------------------------------------
procesar_iso() {
    local iso="$1"
    if [[ ! -f "$iso" ]]; then
        error "No existe el fichero: $iso"
        return 1
    fi
    iso="$(realpath "$iso")"

    titulo "ISO: $(basename "$iso")"
    local bytes
    bytes="$(du -b "$iso" 2>/dev/null | awk '{print $1}')"
    bytes="${bytes:-0}"
    local human
    human="$(bytes_a_human "$bytes")"
    info "Tamano: $human  ($bytes bytes)"
    info "Ubicacion: $iso"
    warn "Las imagenes ISO son de solo lectura (ISO 9660/UDF) y NO son comprimibles."
    warn "Se omite la compactacion de esta ISO y se continua."

    TABLA_RESUMEN+=("$(printf '  %-45s  %8s  %8s  %8s' "$(basename "$iso") [ISO]" "$human" "$human" "n/a")")
}

# ---------------------------------------------------------------------------
# Tabla resumen final
# ---------------------------------------------------------------------------
mostrar_resumen() {
    titulo "RESUMEN FINAL"
    echo -e "${C_NEGRITA}$(printf '  %-45s  %8s  %8s  %8s' "VMDK" "ANTES" "DESPUES" "AHORRO")${C_RESET}"
    echo "  $(printf '%0.s-' {1..75})"
    for linea in "${TABLA_RESUMEN[@]}"; do
        echo -e "  $linea"
    done
    echo "  $(printf '%0.s-' {1..75})"
    local total_ahorro=$(( TOTAL_ANTES_BYTES - TOTAL_DESPUES_BYTES ))
    local total_ahorro_human
    total_ahorro_human="$(bytes_a_human "$total_ahorro")"
    local total_antes_human
    total_antes_human="$(bytes_a_human "$TOTAL_ANTES_BYTES")"
    local total_despues_human
    total_despues_human="$(bytes_a_human "$TOTAL_DESPUES_BYTES")"
    echo -e "${C_NEGRITA}$(printf '  %-45s  %8s  %8s  %8s' "TOTAL" "$total_antes_human" "$total_despues_human" "$total_ahorro_human")${C_RESET}"
    echo ""
    if (( total_ahorro > 0 )); then
        ok "Espacio liberado en host: ${C_VERDE}${C_NEGRITA}$total_ahorro_human${C_RESET}"
    else
        warn "No se libero espacio significativo."
    fi
}

# ---------------------------------------------------------------------------
# Entrada principal
# ---------------------------------------------------------------------------
if (( $# != 1 )); then
    echo -e "${C_NEGRITA}Uso:${C_RESET}  $(basename "$0") <archivo.vmx> | <archivo.iso> | <directorio>"
    echo ""
    echo "  <archivo.vmx>   Compacta la VM especificada."
    echo "  <archivo.iso>   Analiza la ISO (informa de que NO es comprimible)."
    echo "  <directorio>    Busca todos los .vmx (y .iso) bajo el directorio y los procesa."
    exit 1
fi

OBJETIVO="$1"

if [[ -f "$OBJETIVO" && "$OBJETIVO" == *.vmx ]]; then
    # Un solo .vmx
    procesar_vm "$OBJETIVO"
    mostrar_resumen
elif [[ -f "$OBJETIVO" && "${OBJETIVO,,}" == *.iso ]]; then
    # Una sola ISO: informativo (no comprimible)
    procesar_iso "$OBJETIVO"
    mostrar_resumen
elif [[ -d "$OBJETIVO" ]]; then
    # Directorio: buscar todos los .vmx y todas las .iso
    info "Modo directorio: buscando .vmx e .iso en '$OBJETIVO'..."
    vmx_encontrados=()
    while IFS= read -r f; do
        vmx_encontrados+=("$f")
    done < <(find "$OBJETIVO" -maxdepth 4 -name "*.vmx" | sort)

    iso_encontradas=()
    while IFS= read -r f; do
        iso_encontradas+=("$f")
    done < <(find "$OBJETIVO" -maxdepth 4 -iname "*.iso" | sort)

    if (( ${#vmx_encontrados[@]} == 0 && ${#iso_encontradas[@]} == 0 )); then
        warn "No se encontraron ficheros .vmx ni .iso en: $OBJETIVO"
        exit 0
    fi

    info "VMs encontradas:  ${#vmx_encontrados[@]}"
    info "ISOs encontradas: ${#iso_encontradas[@]} (se analizan pero NO se comprimen)"

    errores=0
    for vmx in "${vmx_encontrados[@]}"; do
        if ! procesar_vm "$vmx"; then
            warn "Se omite la VM por error: $(basename "$vmx")"
            (( errores++ )) || true
        fi
    done

    # ISOs: solo analisis informativo, nunca abortan el proceso
    for iso in "${iso_encontradas[@]}"; do
        procesar_iso "$iso" || true
    done

    mostrar_resumen

    if (( errores > 0 )); then
        warn "$errores VM(s) no pudieron procesarse (ver mensajes anteriores)."
        exit 2
    fi
else
    error "El argumento '$OBJETIVO' no es un fichero .vmx/.iso ni un directorio valido."
    exit 1
fi
