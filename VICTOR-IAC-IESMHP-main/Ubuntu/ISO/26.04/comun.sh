#!/bin/bash
# =============================================================================
#  comun.sh  —  Variables comunes de la cadena IAC-IESMHP (Ubuntu 26.04)
#
#  ÚNICO punto donde se definen las rutas y constantes "mágicas" del proyecto
#  (URL del repo en GitHub, /opt/IAC-IESMHP, /var/log/..., rutas de los
#  sub-scripts, ficheros de datos, redes/proxy de aula...).
#
#  Este fichero NO se ejecuta: se carga con `source` desde el resto de scripts.
#  Patrón de carga (scripts en ISO/26.04/):
#      _DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$_DIR/comun.sh"
#  Patrón de carga (scripts en ISO/26.04/utiles/):
#      _DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$_DIR/comun.sh"
#
#  EXCEPCIÓN: 0b-Github.sh corre en el Live CD ANTES de clonar el repo, por lo
#  que todavía no puede hacer `source` de este fichero (no existe en disco).
#  Mantiene un pequeño bloque de arranque con GITHUB_USER/REPO que DEBE COINCIDIR
#  con lo definido aquí. Es la ÚNICA duplicación, inevitable por el orden de
#  arranque; tras clonar, 0b-Github.sh sí carga este comun.sh.
# =============================================================================

# Guarda de doble carga: si ya se cargó en este shell, no rehacer nada.
[ -n "${IAC_COMUN_CARGADO:-}" ] && return 0
IAC_COMUN_CARGADO=1

# ── Identidad del repositorio en GitHub ──────────────────────────────────────
GITHUB_USER="victormuelacarriles"
REPO="IAC-IESMHP"
RAMA="main"
GITREPO="https://github.com/${GITHUB_USER}/${REPO}.git"
# Base para descargar ficheros sueltos del repo sin clonarlo (raw):
GITRAW="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO}/refs/heads/${RAMA}"

# ── Distribución ─────────────────────────────────────────────────────────────
DISTRO="Ubuntu"
# Versión leída de /etc/os-release (p. ej. 26.04). Fallback a 26.04 si no se
# puede leer (re-ejecución manual fuera de un Ubuntu). El `|| true` evita que
# `set -e`/`pipefail` aborten al cargar este fichero.
versionDISTRO="$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d'"' -f2 || true)"
[ -n "$versionDISTRO" ] || versionDISTRO="26.04"

# ── Rutas en el sistema de ficheros ──────────────────────────────────────────
RAIZSCRIPTS="/opt/${REPO}"                              # clon del repo (lo crea 0b-Github.sh)
RAIZDISTRO="${RAIZSCRIPTS}/${DISTRO}/ISO/${versionDISTRO}"
RAIZUTILES="${RAIZDISTRO}/utiles"
RAIZANSIBLE="${RAIZSCRIPTS}/${DISTRO}/ansible"
RAIZLOG="/var/log/${REPO}/${DISTRO}"

# ── Scripts de la cadena (rutas absolutas en el equipo instalado) ────────────
SCRIPT_LIVECD="${RAIZDISTRO}/1-SetupLiveCD.sh"
SCRIPT_CHROOT="${RAIZDISTRO}/2-SetupSOdesdeLiveCD.sh"
SCRIPT_PRIMERINICIO="${RAIZDISTRO}/3-SetupPrimerInicio.sh"
SCRIPT_COMPROBACIONES="${RAIZDISTRO}/4-Comprobaciones.sh"
SCRIPT_NOMBREIP="${RAIZUTILES}/NombreIP.sh"
SCRIPT_AUTOANSIBLE="${RAIZUTILES}/Auto-Ansible.sh"

# ── Ficheros de datos ────────────────────────────────────────────────────────
FICHERO_MACS="${RAIZSCRIPTS}/macs.csv"          # copia en el clon del repo
URL_MACS="${GITRAW}/macs.csv"                   # descarga directa (NombreIP.sh)
FICHERO_AUTORIZADOS="${RAIZSCRIPTS}/Autorizados.txt"

# ── Redes y proxy por aula ───────────────────────────────────────────────────
# Tercer octeto que identifica cada aula y proxy apt correspondiente. Se
# centralizan aquí aunque hoy sólo los usen NombreIP.sh y 3-SetupPrimerInicio.sh.
RED_IABD="10.0.72"            # aula IABD (CEIABD)
RED_SMRD="10.0.32"            # aula SMRD / SMRV
PROXY_IABD="http://10.0.72.140:3128"
PROXY_SMRD="http://10.0.32.119:3128"
