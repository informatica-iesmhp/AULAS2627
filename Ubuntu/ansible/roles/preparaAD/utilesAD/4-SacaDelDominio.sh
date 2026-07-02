#!/bin/bash
# ===========================================================================
# 4-SacaDelDominio.sh — saca ESTE equipo del dominio Active Directory
# (rol preparaAD de IAC-IESMHP). Es el INVERSO de 3-UneAlDominio.sh.
# ---------------------------------------------------------------------------
# Ejecutar COMO ROOT en el equipo a sacar. Flujo:
#   1. Comprueba si el equipo está unido (realm list). Si NO lo está → termina.
#   2. Si lo está: muestra el dominio y PIDE CONFIRMACIÓN explícita.
#   3. Pregunta el usuario del dominio con permisos para BORRAR la cuenta de
#      equipo de la OU (por defecto 'svc-union-linux'; 1-CreaUsuarioUnionAD.ps1
#      le delega también el borrado, acotado a la OU ComputersLinux) y su
#      contraseña. En blanco = se pide OTRO usuario del dominio (p. ej. admin).
#   4. realm leave -U <usuario> → borra la cuenta de equipo en AD y deshace la
#      configuración local (sssd.conf, keytab). Verifica que quedó fuera.
#   5. Limpia el snippet SSSD huérfano (/etc/sssd/conf.d/10-iac-ad.conf): sin
#      dominio, sssd no debe arrancar con él (quedaría como unidad fallida).
#   5b. Vacía la caché de SSSD (/var/lib/sss/{db,mc}) que realm leave NO borra,
#      para que una RE-UNIÓN posterior no arranque con datos del enrolamiento
#      viejo (login de dominio inestable).
#   6. Revierte lo que mete *realmd* al unir y NO quita al salir: pam_sss en
#      /etc/pam.d/common-* y el módulo 'sss' en las bases passwd/group de
#      nsswitch. Si se dejan, pam_sss apunta a un sssd ya inexistente →
#      "Request to sssd failed: Connection refused" en la fase ACCOUNT del
#      stack PAM → rompe el arranque de sesiones gráficas (greeter de GDM y,
#      en consecuencia, el handover RDP de gnome-remote-desktop = pantalla en
#      negro). Un 3-UneAlDominio.sh posterior los vuelve a poner al re-unir.
#
# Los prerequisitos del rol (krb5.conf, split-DNS, reorden mDNS de nsswitch) se
# DEJAN intactos: son inofensivos y facilitan una reunión posterior con
# 3-UneAlDominio.sh.
#
# NO borra el RASTRO de los usuarios del dominio (sus /home, subuid/subgid,
# lingering, daemon rootless, AccountsService): eso es DESTRUCTIVO y va aparte,
# en 5-LimpiaUsuariosDominio.sh (se ejecuta después, con confirmación).
# ===========================================================================
#  Util: para sacar un equipo del dominio AD (rol preparaAD de IAC-IESMHP).
#  Limpieza manual de un objeto huérfano (join a medias por reloj desfasado):
#  adcli delete-computer --domain=<dominio> --login-user=<usuario_union> [hostname]
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERR] Ejecutar como root (sudo $0)"; exit 1; }

# El script vive en roles/preparaAD/utilesAD/ → la raíz ansible está 3 niveles arriba
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# USUARIO_UNION desde el ÚNICO punto de cambio (../entornoAD.yml, el mismo que
# lee el rol). Se puede pisar por entorno:  USUARIO_UNION=admin ./4-SacaDelDominio.sh
# shellcheck source=entornoAD.sh
source "$_DIR/entornoAD.sh"

command -v realm >/dev/null || { echo "[ERR] realm no encontrado (¿está instalado realmd? Lanza antes el rol preparaAD)."; exit 1; }

# --- 1. ¿Está unido? --------------------------------------------------------
echo "=== [1/4] ¿Unido a algún dominio? ==="
UNIDO="$(realm list --name-only 2>/dev/null | head -n1 || true)"
if [[ -z "$UNIDO" ]]; then
    echo "[OK] Este equipo NO está unido a ningún dominio — nada que hacer."
    exit 0
fi
echo "Este equipo está unido a: $UNIDO"

# --- 2. Confirmación --------------------------------------------------------
echo "=== [2/4] Confirmación ==="
read -r -p "¿Seguro que quieres SACAR este equipo del dominio '$UNIDO'? [s/N] " RESP
[[ "$RESP" =~ ^[sS]$ ]] || { echo "Abortado (sin cambios)."; exit 0; }

# --- 3. Usuario con permisos de borrado en la OU ----------------------------
echo "=== [3/4] Credenciales para borrar la cuenta de equipo en AD ==="
# Contraseña en blanco = la cuenta delegada no está disponible → se ofrece
# sacar con OTRO usuario del dominio con permisos de borrado (p. ej. un admin).
read -rs -p "Contraseña de '$USUARIO_UNION' (en blanco = sacar con otro usuario): " PASS; echo
if [[ -z "$PASS" ]]; then
    read -r  -p "Usuario del dominio con permisos para sacar equipos: " USUARIO_UNION
    [[ -n "$USUARIO_UNION" ]] || { echo "[ERR] Usuario vacío."; exit 1; }
    read -rs -p "Contraseña de '$USUARIO_UNION': " PASS; echo
    [[ -n "$PASS" ]] || { echo "[ERR] Contraseña vacía."; exit 1; }
fi

# --- 4. realm leave ---------------------------------------------------------
echo "=== [4/4] Saliendo del dominio '$UNIDO' ==="
# realm leave -U lee la contraseña por stdin con --unattended (sin tty); borra
# la cuenta de equipo de la OU en AD y deshace la config local (sssd, keytab).
if ! printf '%s\n' "$PASS" | realm leave --unattended --user="$USUARIO_UNION" "$UNIDO"; then
    unset PASS
    echo "[ERR] realm leave ha fallado. Causas típicas: contraseña incorrecta,"
    echo "      el usuario sin permiso de borrado en la OU (re-ejecuta en el DC"
    echo "      1-CreaUsuarioUnionAD.ps1 para delegarlo), o problema de DNS/reloj."
    echo "      Para deshacer SOLO la configuración local (dejando la cuenta en"
    echo "      AD): realm leave"
    exit 1
fi
unset PASS

# Verificación: realm list debe quedar vacío.
RESTO="$(realm list --name-only 2>/dev/null | head -n1 || true)"
[[ -z "$RESTO" ]] || { echo "[ERR] realm leave terminó pero 'realm list' sigue mostrando: $RESTO"; exit 1; }
echo "[OK] Equipo fuera del dominio."

# --- 5. Snippet SSSD huérfano ----------------------------------------------
# Tras realm leave ya no existe /etc/sssd/sssd.conf; si dejáramos el snippet,
# sssd intentaría arrancar con un dominio sin sección [sssd] → unidad fallida.
SNIPPET="/etc/sssd/conf.d/10-iac-ad.conf"
if [[ -f "$SNIPPET" ]]; then
    rm -f "$SNIPPET"
    echo "[OK] Eliminado snippet SSSD huérfano: $SNIPPET"
fi

# --- 5b. Caché de SSSD del enrolamiento deshecho ----------------------------
# realm leave deshace sssd.conf y el keytab, pero NO vacía la caché de SSSD
# (/var/lib/sss/db = base ldb por dominio; /var/lib/sss/mc = caché en memoria
# de NSS). Si se deja, una RE-UNIÓN posterior (3-UneAlDominio.sh) arrancaría
# sssd con datos del enrolamiento VIEJO (la cuenta de equipo se borró y se
# recreará con otra contraseña/keytab) → resolución/login de dominio inestables.
# Vaciarla deja la próxima unión limpia. Tras realm leave sssd ya suele estar
# parado; el stop es por si acaso (no hay config con la que arrancarlo aquí).
if [[ -d /var/lib/sss ]]; then
    systemctl stop sssd 2>/dev/null || true
    rm -f /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
    echo "[OK] Caché de SSSD vaciada (/var/lib/sss/{db,mc})."
fi

# --- 6. Revertir pam_sss y nss 'sss' (realmd los deja al unir y NO al salir) -
# Sin esto, pam_sss queda en /etc/pam.d/common-* apuntando a un sssd que ya no
# arranca → "Request to sssd failed: Connection refused" en el stack ACCOUNT →
# rompe el greeter de GDM y el handover RDP de gnome-remote-desktop (negro).
echo "=== [6] Limpiar pam_sss / nss 'sss' (los puso realmd al unir) ==="
if command -v pam-auth-update >/dev/null 2>&1 && grep -q pam_sss /etc/pam.d/common-account 2>/dev/null; then
    DEBIAN_FRONTEND=noninteractive pam-auth-update --disable sss --force >/dev/null 2>&1 \
        || DEBIAN_FRONTEND=noninteractive pam-auth-update --remove sss >/dev/null 2>&1 \
        || true
    if grep -q pam_sss /etc/pam.d/common-account 2>/dev/null; then
        echo "[AVISO] pam_sss sigue en /etc/pam.d/common-account. Quítalo a mano:"
        echo "        sudo pam-auth-update   (desmarca «SSS authentication»)"
    else
        echo "[OK] pam_sss retirado del stack PAM."
    fi
fi
if grep -qE '^(passwd|group|shadow|gshadow|netgroup):.*[[:space:]]sss\b' /etc/nsswitch.conf 2>/dev/null; then
    sed -i -E '/^(passwd|group|shadow|gshadow|netgroup):/ s/[[:space:]]+sss\b//g' /etc/nsswitch.conf
    echo "[OK] Eliminado 'sss' de /etc/nsswitch.conf (passwd/group/…)."
fi
# Si el servidor RDP está activo, reiniciarlo para que la próxima sesión de
# handover no arrastre el PAM viejo (si no, seguiría el negro hasta el reboot).
if systemctl is-active --quiet gnome-remote-desktop 2>/dev/null; then
    systemctl restart gnome-remote-desktop 2>/dev/null || true
    echo "[OK] gnome-remote-desktop reiniciado (RDP)."
fi

echo
echo "================================================================"
echo " Correcto: $(hostname) ya NO está unido a $UNIDO."
echo " (La cuenta de equipo se ha borrado de la OU en AD.)"
echo
echo " Los HOMES y el rastro de los usuarios del dominio SIGUEN aquí."
echo " Para borrarlos (DESTRUCTIVO):  sudo $_DIR/5-LimpiaUsuariosDominio.sh"
echo "                  ver primero:  sudo $_DIR/5-LimpiaUsuariosDominio.sh --dry-run"
echo " Para volver a unirlo:          sudo $_DIR/3-UneAlDominio.sh"
echo "================================================================"
