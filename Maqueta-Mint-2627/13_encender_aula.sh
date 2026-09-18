#!/usr/bin/env bash
#
# encender_aula.sh
#
# Enciende por Wake-on-LAN los equipos de un aula (todos los de
# macs.csv menos el del profesor, que ya está encendido: es quien
# lanza este script).
#
# IMPORTANTE: esto NO es un playbook de Ansible. Los equipos a encender
# están apagados, así que no hay nada a lo que conectar por SSH todavía
# — es un script normal, que se ejecuta A MANO en el equipo del
# profesor del aula que se quiera encender.
#
# Requisitos previos, una sola vez por equipo del aula:
#   1. BIOS/UEFI: "Wake on LAN" / "Power On by PCI-E" activado a mano
#      (no se puede hacer por software — hay que entrar a la BIOS de
#      cada equipo, una vez).
#   2. Sistema operativo: haber lanzado 09_habilitar_wol.yml contra el
#      aula (deja el soporte de WoL reactivado en cada arranque).
#   3. Los equipos deben seguir teniendo alimentación de verdad (enchufe
#      / regleta encendida) — si se corta la corriente del todo por la
#      noche, no hay energía de espera y WoL no puede funcionar, por
#      mucho que la BIOS y el sistema operativo estén bien configurados.
#
# Uso:
#   ./encender_aula.sh IF01                  # aula entera
#   ./encender_aula.sh IF01 --verificar       # + hace ping a cada uno
#   ./encender_aula.sh IF01 --solo=IF01-05    # un único equipo del aula
#
# Requiere el paquete 'wakeonlan' (sudo apt install wakeonlan) y el
# macs.csv del proyecto accesible en la ruta indicada más abajo.

set -euo pipefail

AULA="${1:-}"
shift || true

VERIFICAR=""
SOLO=""
for arg in "$@"; do
    case "$arg" in
        --verificar) VERIFICAR="1" ;;
        --solo=*) SOLO="${arg#--solo=}" ;;
        *) echo "Argumento no reconocido: $arg" >&2; exit 1 ;;
    esac
done

# Ajusta esta ruta si el script no vive junto al repo clonado
MACS_CSV="$(dirname "$0")/../macs.csv"

if [[ -z "$AULA" ]]; then
    echo "Uso: $0 <AULA> [--verificar] [--solo=IF0X-NN]"
    echo "Ejemplo: $0 IF01 --verificar"
    exit 1
fi

if ! command -v wakeonlan >/dev/null 2>&1; then
    echo "Falta 'wakeonlan'. Instálalo con: sudo apt install wakeonlan" >&2
    exit 1
fi

if [[ ! -f "$MACS_CSV" ]]; then
    echo "No encuentro macs.csv en: $MACS_CSV" >&2
    echo "Edita la variable MACS_CSV al principio del script con la ruta correcta." >&2
    exit 1
fi

# Líneas de equipos de esta aula en macs.csv: "MAC, NOMBRE, octeto, descripcion"
mapfile -t LINEAS < <(grep -E "^[[:space:]]*([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}[[:space:]]*,[[:space:]]*${AULA}-[0-9]+" "$MACS_CSV")

if [[ ${#LINEAS[@]} -eq 0 ]]; then
    echo "No hay equipos de '$AULA' en $MACS_CSV (¿nombre de aula correcto? p.ej. IF01)" >&2
    exit 1
fi

echo "Aula: $AULA — equipos encontrados en macs.csv: ${#LINEAS[@]} (se excluye ${AULA}-00, el profesor)"

DESPERTADOS=()
for linea in "${LINEAS[@]}"; do
    MAC=$(echo "$linea" | awk -F',' '{print $1}' | xargs)
    NOMBRE=$(echo "$linea" | awk -F',' '{print $2}' | xargs)

    # El equipo del profesor ya está encendido: es quien ejecuta esto
    [[ "$NOMBRE" == "${AULA}-00" ]] && continue

    # Si se pidió --solo=X, salta todo lo que no sea ese equipo
    if [[ -n "$SOLO" && "$NOMBRE" != "$SOLO" ]]; then
        continue
    fi

    echo "  -> Despertando $NOMBRE ($MAC)"
    wakeonlan "$MAC" >/dev/null
    DESPERTADOS+=("$NOMBRE")
done

if [[ ${#DESPERTADOS[@]} -eq 0 ]]; then
    echo "No se ha despertado ningún equipo (¿--solo=$SOLO no coincide con ningún nombre de $AULA?)" >&2
    exit 1
fi

echo "Enviados ${#DESPERTADOS[@]} paquetes mágicos."

if [[ -n "$VERIFICAR" ]]; then
    echo "Esperando 30s antes de comprobar (el arranque tarda)..."
    sleep 30
    for nombre in "${DESPERTADOS[@]}"; do
        # Ping por nombre: depende de que el DNS del dominio resuelva los
        # hostnames del aula — si no, comprueba a mano con la IP del
        # inventario (inventarios/<AULA>.ini).
        if ping -c1 -W1 "$nombre" >/dev/null 2>&1; then
            echo "  OK   $nombre responde"
        else
            echo "  --   $nombre no responde todavía (puede tardar más en arrancar, o el DNS no resuelve ese nombre)"
        fi
    done
fi
