#!/bin/bash
#
# instalar-autoarranque-pantallas.sh
#
# Instala config-pantallas-profesor.sh para que se aplique solo cada
# vez que el profesor inicia sesión, sin tener que ejecutarlo a mano.
#
# -----------------------------------------------------------------
# INSTRUCCIONES DE USO
# -----------------------------------------------------------------
# Requisito previo: "config-pantallas-profesor.sh" debe estar en la
# MISMA carpeta que este instalador, ya editado (variables correctas)
# y ya probado a mano con éxito (ver sus propios comentarios de uso).
#
# En una terminal, dentro de esa carpeta:
#
#       chmod +x instalar-autoarranque-pantallas.sh
#       ./instalar-autoarranque-pantallas.sh
#
# Esto copia el script a ~/bin/ y crea la entrada de arranque
# automático de Cinnamon. Se aplicará solo:
#   - la próxima vez que ese profesor inicie sesión en ese equipo.
#
# Para comprobarlo sin tener que reiniciar sesión, ejecuta directamente:
#
#       ~/bin/config-pantallas-profesor.sh
#
# Si algún día cambias el cableado o los monitores de ese equipo,
# vuelve a editar ~/bin/config-pantallas-profesor.sh directamente
# (ya no hace falta repetir este instalador).
# -----------------------------------------------------------------

set -euo pipefail

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-pantallas-profesor.sh"
DESTINO_DIR="$HOME/bin"
DESTINO="$DESTINO_DIR/config-pantallas-profesor.sh"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/config-pantallas-profesor.desktop"

if [[ ! -f "$ORIGEN" ]]; then
    echo "No encuentro config-pantallas-profesor.sh junto a este instalador." >&2
    exit 1
fi

mkdir -p "$DESTINO_DIR" "$AUTOSTART_DIR"
cp "$ORIGEN" "$DESTINO"
chmod +x "$DESTINO"

cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Configuración pantallas profesor
Comment=Duplica monitor+proyector y deja el otro monitor extendido (privado)
Exec=$DESTINO --autoarranque
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF

echo "Instalado:"
echo "  Script:    $DESTINO"
echo "  Autoarranque: $AUTOSTART_FILE"
echo
echo "Se aplicará solo la próxima vez que inicies sesión."
echo "Para probarlo ahora mismo sin reiniciar sesión:"
echo "  $DESTINO"
