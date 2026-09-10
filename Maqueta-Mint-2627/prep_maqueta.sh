#!/usr/bin/env bash
#
# prep_maqueta.sh
# ---------------------------------------------------------------------------
# Prepara la maqueta base (Linux Mint 22.3) instalando:
#   1) Herramientas de sistema universales (no reinstala lo que ya exista)
#   2) chrony (sincronización horaria)
#
# Quedan comentados, listos para activar más adelante si se decide usarlos:
#   3) fail2ban (protección SSH)      -> ver bloque "OPCIONAL: fail2ban"
#   4) Timeshift (snapshots)          -> ver bloque "OPCIONAL: Timeshift"
#
# El firewall (ufw) NO se toca aquí: se decidió configurarlo más adelante
# desde Ansible, aula por aula, una vez comprobado que todo el software
# (Docker, servidores que se instalen, Veyon, GLPI-Agent...) funciona sin
# restricciones. Así se evita bloquear por error algo que aún no se ha
# terminado de probar.
#
# Se asume que SSH y el usuario ansible-admin YA están creados.
# Ejecutar como root (o con sudo) UNA VEZ en el equipo que se usará como
# plantilla, antes de clonar el disco a los equipos de las aulas.
#
# Uso:
#   sudo ./prep_maqueta.sh
# ---------------------------------------------------------------------------

set -euo pipefail

# ============================ CONFIGURA AQUÍ ================================

# Red desde la que se administra el aula (PC del profesor / red del centro).
# Solo se usa si más adelante activas el bloque OPCIONAL de fail2ban (más
# abajo): esa IP/red nunca sería bloqueada por fail2ban.
# Ejemplos: "192.168.1.0/24"  (una subred)  o  "192.168.1.10/32" (solo el PC del profe)
MGMT_SUBNET="192.168.1.0/24"          # <-- CAMBIA esto por tu red real si activas fail2ban

# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "Este script debe ejecutarse como root (usa sudo)." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "Actualizando índices de paquetes..."
apt-get update -y

# ---------------------------------------------------------------------------
# 1) Herramientas de sistema universales
# ---------------------------------------------------------------------------
# apt-get install es idempotente: si un paquete ya está instalado (como tu
# "git"), simplemente lo deja como está y no hace nada con él, así que puedes
# relanzar el script sin miedo a romper nada ya instalado.
log "Instalando herramientas de sistema universales..."
apt-get install -y \
    git \
    curl \
    wget \
    vim \
    nano \
    htop \
    tmux \
    tree \
    net-tools \
    iproute2 \
    unzip \
    rsync \
    software-properties-common \
    gnupg \
    ca-certificates

# ---------------------------------------------------------------------------
# 2) chrony (sincronización horaria)
# ---------------------------------------------------------------------------
# Mint/Ubuntu traen por defecto "systemd-timesyncd", un cliente NTP muy
# básico. chrony hace lo mismo pero mejor (se recupera antes de cortes de
# red, sincroniza más rápido tras un "suspend", permite varios servidores de
# respaldo...). El problema es que si dejas los DOS activos a la vez, ambos
# intentan ajustar el reloj del sistema por su cuenta y se pisan entre sí
# (como tener dos termostatos distintos controlando la misma calefacción).
# Por eso se para y desactiva timesyncd: no lo desinstalamos, solo dejamos
# que sea chrony quien mande.
log "Instalando y configurando chrony..."
apt-get install -y chrony

if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    systemctl stop systemd-timesyncd
    systemctl disable systemd-timesyncd
fi

systemctl enable --now chrony
echo "  Estado de chrony:"
chronyc tracking 2>/dev/null || echo "  (chrony arrancará por completo tras el primer reinicio)"

# ---------------------------------------------------------------------------
# 3) OPCIONAL: fail2ban (protección de SSH contra fuerza bruta)
# ---------------------------------------------------------------------------
# Descomenta todo este bloque (quita el "#" de cada línea) si más adelante
# decidís activarlo. Recuerda antes ajustar MGMT_SUBNET arriba a vuestra red
# real: esa lista blanca es la que evita que un fallo puntual de Ansible os
# bloquee la gestión de todo el aula.
#
# log "Instalando y configurando fail2ban..."
# apt-get install -y fail2ban
#
# cat > /etc/fail2ban/jail.local <<EOF
# [DEFAULT]
# # IPs/redes que fail2ban NUNCA bloqueará (incluye siempre localhost)
# ignoreip = 127.0.0.1/8 ::1 ${MGMT_SUBNET}
#
# # Tiempo de baneo
# bantime  = 1h
# # Ventana de tiempo en la que se cuentan los intentos fallidos
# findtime = 10m
# # Nº de intentos fallidos antes de banear
# maxretry = 5
#
# [sshd]
# enabled = true
# EOF
#
# systemctl enable --now fail2ban
#
# echo "  fail2ban activo. Lista blanca: 127.0.0.1/8, ::1, ${MGMT_SUBNET}"

# ---------------------------------------------------------------------------
# 4) OPCIONAL: Timeshift (snapshots del sistema)
# ---------------------------------------------------------------------------
# Qué es: Timeshift hace "fotos" periódicas del sistema (parecido a
# "Restaurar sistema" de Windows). Si algo se rompe, arrancas desde el modo
# de recuperación de Grub y restauras una foto anterior, sin reinstalar nada.
# Por defecto NO toca /home (no es copia de seguridad de los documentos de
# los alumnos, solo para recuperar el sistema operativo).
#
# Descomenta este bloque si más adelante os interesa probarlo. Ojo: tras
# instalarlo hay que configurarlo una vez a mano (modo RSYNC, no BTRFS, ya
# que vuestro disco probablemente use ext4) ANTES de clonar la maqueta:
#
#     sudo timeshift-gtk
#     # o en modo texto:
#     sudo timeshift --setup
#
# Esa configuración queda en /etc/timeshift/timeshift.json y SÍ se clona
# junto con el resto del sistema.
#
# log "Instalando Timeshift..."
# apt-get install -y timeshift

# ---------------------------------------------------------------------------
# Resumen final
# ---------------------------------------------------------------------------
log "Resumen de servicios:"
for svc in chrony; do
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactivo")
    printf "  %-10s -> %s\n" "$svc" "$state"
done

echo
echo "Pendiente para más adelante (fuera de este script):"
echo "  - Firewall (ufw): configurar desde Ansible, aula por aula, una vez"
echo "    verificado que todo el software funciona."
echo "  - fail2ban: bloque comentado en este script, listo para activar."
echo "  - Timeshift: bloque comentado en este script, listo para activar."
