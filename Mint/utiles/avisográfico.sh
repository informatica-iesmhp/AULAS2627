#!/bin/bash

avisar_sesiones_graficas() {
    local mensaje="$1"
    local titulo="${2:-Aviso del administrador}"
    echo "Lanzando mensaje en sesiones gráficas activas..."
    while read -r sid; do
        local user display dbus_address uid
        user=$(loginctl show-session "$sid" -p Name --value)
        display=$(loginctl show-session "$sid" -p Display --value)
        # Omitir si no hay DISPLAY
        [[ -z "$display" ]] && continue
        uid=$(id -u "$user")
        # Buscar un proceso de sesión gráfica para extraer DBUS
        pid=$(pgrep -u "$user" -n gnome-session || pgrep -u "$user" -n xfce4-session || pgrep -u "$user" -n xrdp-sesman || echo "")
        [[ -z "$pid" ]] && continue
        dbus_address=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep DBUS_SESSION_BUS_ADDRESS= | cut -d= -f2-)
        if [[ -n "$dbus_address" ]]; then
            sudo -u "$user" DISPLAY="$display" DBUS_SESSION_BUS_ADDRESS="$dbus_address" \
                zenity --info --text="$mensaje" --title="$titulo" --timeout=10 &
        else
            echo "No se pudo obtener DBUS para $user en DISPLAY=$display"
        fi
    done < <(loginctl list-sessions --no-legend | awk '{print $1}')
}
# Mostrar un mensaje
avisar_sesiones_graficas "Hola mundo!"

