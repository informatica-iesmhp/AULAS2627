#!/bin/bash

# Asegurar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Error: Este script debe ejecutarse como root (usa sudo)."
  exit 1
fi

MENSAJE="ATENCIÓN: El sistema se reiniciará en 10 minutos. Guarde su trabajo."
TITULO="Alerta del Administrador"

# 1. Obtener los IDs de todas las sesiones activas en el sistema
sesiones=$(loginctl list-sessions --no-legend | awk '{print $1}')

for sesion in $sesiones; do
    # Obtener el tipo de sesión (wayland, x11, tty...)
    tipo_sesion=$(loginctl show-session "$sesion" -p Type --value)
    
    # Filtrar solo sesiones gráficas (locales o RDP)
    if [ "$tipo_sesion" = "wayland" ] || [ "$tipo_sesion" = "x11" ]; then
        usuario=$(loginctl show-session "$sesion" -p Name --value)
        uid=$(loginctl show-session "$sesion" -p User --value)
        
        echo "[+] Enviando mensaje a la sesión $sesion (Usuario: $usuario, Tipo: $tipo_sesion)"

        # --- OPCIÓN A: Notificación de escritorio (Recomendada y más estable en Wayland) ---
        # Nos conectamos al bus de sesión DBus del usuario para enviar un popup flotante
        sudo -u "$usuario" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            notify-send -u critical "$TITULO" "$MENSAJE"

        # --- OPCIÓN B: Ventana Gráfica Interactiva (Zenity) ---
        # Intentamos localizar el socket específico de Wayland de ese usuario
        wayland_disp=$(ls /run/user/$uid/wayland-* 2>/dev/null | head -n 1 | xargs basename 2>/dev/null)

        if [ "$tipo_sesion" = "wayland" ] && [ -n "$wayland_disp" ]; then
            # Lanzar en la sesión Wayland (el '&' final evita que el script se bloquee esperando que cierren la ventana)
            sudo -u "$usuario" XDG_RUNTIME_DIR="/run/user/$uid" \
                WAYLAND_DISPLAY="$wayland_disp" \
                zenity --info --text="$MENSAJE" --title="$TITULO" --width=300 2>/dev/null &
        elif [ "$tipo_sesion" = "x11" ]; then
            # Fallback para sesiones X11 tradicionales o XWayland persistentes en RDP antiguo
            sudo -u "$usuario" DISPLAY=:0 \
                zenity --info --text="$MENSAJE" --title="$TITULO" --width=300 2>/dev/null &
        fi
    fi
done