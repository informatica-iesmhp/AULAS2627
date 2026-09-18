#!/bin/bash
#
# config-pantallas-profesor.sh
#
# Configura la salida gráfica del PC DEL PROFESOR (aulas IF01-IF04):
#   - Duplica (mirror) un monitor + el proyector -> lo que ve la clase
#   - Deja el otro monitor en modo extendido -> privado, solo lo ve el profesor
#
# SOLO para equipos de profesor. NO tiene sentido en equipos de alumno
# (que normalmente solo tienen una salida conectada).
#
# -----------------------------------------------------------------
# INSTRUCCIONES DE USO (paso a paso, copiar/pegar en una terminal)
# -----------------------------------------------------------------
#
# 0) Copia este fichero al PC del profesor (por USB, por correo, como
#    prefieras) y abre una terminal en la carpeta donde lo hayas dejado.
#    Dale permiso de ejecución (solo hace falta una vez):
#
#       chmod +x config-pantallas-profesor.sh
#
# 1) Averigua los nombres reales de las 3 salidas de ESTE equipo:
#
#       ./config-pantallas-profesor.sh --detectar
#
#    Te dará algo como:
#       DP-1 connected 1920x1080+0+0 ...
#       HDMI-1 connected 1920x1080+1920+0 ...
#       DP-2 connected 1920x1080+3840+0 ...
#
#    Los nombres (DP-1, HDMI-1, DP-2...) pueden variar de un aula a
#    otra según el cableado o la tarjeta gráfica, así que haz esta
#    comprobación en cada equipo de profesor antes de dar por bueno
#    el script; no asumas que son iguales en las 4 aulas.
#
# 2) Abre el propio fichero con un editor de texto:
#
#       xed config-pantallas-profesor.sh
#       (o nano config-pantallas-profesor.sh desde la terminal)
#
#    y edita las 4 variables de la sección "CONFIGURA AQUÍ" (más abajo
#    en este mismo fichero) con los nombres/posición que correspondan
#    a los datos que te dio el paso 1. Guarda el fichero.
#
# 3) Pruébalo a mano, con el proyector y los 2 monitores ya conectados:
#
#       ./config-pantallas-profesor.sh
#
#    Si todo está bien configurado, el monitor público y el proyector
#    mostrarán lo mismo, y el otro monitor pasará a modo extendido.
#    Si te avisa de que alguna salida "no aparece conectada", repite
#    el paso 1 y revisa que has escrito bien los nombres.
#
# 4) (Opcional pero recomendado) Para que esto se aplique solo cada
#    vez que inicies sesión, sin tener que ejecutar nada a mano cada
#    mañana, usa el script "instalar-autoarranque-pantallas.sh" que
#    acompaña a este (debe estar en la misma carpeta):
#
#       chmod +x instalar-autoarranque-pantallas.sh
#       ./instalar-autoarranque-pantallas.sh
#
# -----------------------------------------------------------------

set -euo pipefail

# ===================================================================
# CONFIGURA AQUÍ los nombres de salida de ESTE equipo concreto.
# ===================================================================
PANTALLA_PUBLICA="DP-1"      # monitor que se ve en clase (se duplica con el proyector)
PROYECTOR="HDMI-1"           # proyector (duplica lo mismo que PANTALLA_PUBLICA)
PANTALLA_PRIVADA="DP-2"      # monitor del profesor, EXTENDIDO (la clase no lo ve)
POSICION_PRIVADA="right-of"  # right-of | left-of | above | below (respecto a PANTALLA_PUBLICA,
                              # según dónde esté físicamente colocado ese monitor en la mesa)
# ===================================================================

# Pequeña espera: si el script se lanza justo al iniciar sesión, da
# tiempo a que el sistema termine de detectar las 3 pantallas.
if [[ "${1:-}" == "--autoarranque" ]]; then
    sleep 3
fi

if [[ "${1:-}" == "--detectar" ]]; then
    echo "Salidas conectadas ahora mismo en este equipo:"
    xrandr --query | grep " connected"
    exit 0
fi

# Comprobación de seguridad: si alguna de las 3 salidas configuradas
# no está conectada de verdad, no tocamos nada (para no dejar el
# escritorio con una pantalla en negro a media clase).
for salida in "$PANTALLA_PUBLICA" "$PROYECTOR" "$PANTALLA_PRIVADA"; do
    if ! xrandr --query | grep -q "^${salida} connected"; then
        echo "Aviso: la salida '$salida' no aparece conectada ahora mismo." >&2
        echo "Revisa los cables, o ejecuta:  $0 --detectar" >&2
        echo "para ver los nombres reales y ajustar las variables del script." >&2
        exit 1
    fi
done

FLAG_POSICION="--${POSICION_PRIVADA}"

xrandr \
    --output "$PANTALLA_PUBLICA" --auto --primary \
    --output "$PROYECTOR" --auto --same-as "$PANTALLA_PUBLICA" \
    --output "$PANTALLA_PRIVADA" --auto "$FLAG_POSICION" "$PANTALLA_PUBLICA"

echo "Listo: $PANTALLA_PUBLICA + $PROYECTOR duplicados; $PANTALLA_PRIVADA extendido ($POSICION_PRIVADA)."
