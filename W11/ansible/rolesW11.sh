#!/usr/bin/env bash
###############################################################################
# rolesW11.sh — Aplica roles.yaml sobre los equipos Windows 11 del inventario.
#
# Se ejecuta en el equipo de control (Linux / WSL). El inventario y las opciones
# de conexion ya estan en ansible.cfg (inventory = ./equiposW11.ini), por eso NO
# hace falta pasar -i ni --connection: Ansible conecta por SSH -> PowerShell a
# cada equipo del grupo [W11].
#
# Uso:
#   ./rolesW11.sh                      # aplica TODO a todos los equipos
#   ./rolesW11.sh -l W11-PRUEBA        # solo un equipo
#   ./rolesW11.sh --tags chrome,vscode # solo unos programas
#   ./rolesW11.sh --check              # simulacro (dry-run)
#   (cualquier argumento se pasa tal cual a ansible-playbook)
###############################################################################
set -euo pipefail

# Situarse en la carpeta de este script (donde viven ansible.cfg y roles.yaml),
# sin codificar /opt/... a fuego.
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Instalar las colecciones necesarias (idempotente).
ansible-galaxy collection install -r requirements.yml

# Comprobar conectividad antes de aplicar (no aborta si falla algun equipo).
echo "== Comprobando conectividad (win_ping) =="
ansible all -m ansible.windows.win_ping || true

# Aplicar el playbook. "$@" reenvia los argumentos extra (-l, --tags, --check...).
# El playbook NO aborta si un rol falla (block/rescue en aplicar_rol.yml): anota el
# rol fallido y sigue con el resto, y al final muestra un resumen de roles fallidos.
echo "== Aplicando roles.yaml =="
ansible-playbook roles.yaml "$@"
