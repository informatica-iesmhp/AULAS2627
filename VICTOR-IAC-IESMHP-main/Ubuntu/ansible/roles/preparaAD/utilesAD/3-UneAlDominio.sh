#!/bin/bash
# ===========================================================================
# 3-UneAlDominio.sh — prepara y une ESTE equipo al dominio Active Directory
# (rol preparaAD de IAC-IESMHP).
# ---------------------------------------------------------------------------
# Ejecutar COMO ROOT en el equipo a unir. Flujo:
#   1. Lanza el rol preparaAD en local (--tags preparaad): instala los
#      prerequisitos (realmd, SSSD, adcli, Kerberos, pam_mkhomedir...).
#   2. Si el equipo YA está unido (realm list) → termina sin tocar nada.
#   3. Si no: comprueba que el dominio se ve por DNS (realm discover),
#      pregunta la contraseña de 'svc-union-linux' (se SUPONE que la cuenta
#      existe — la crea 1-CreaUsuarioUnionAD.ps1 en el DC) y une el equipo
#      con realm join en la OU delegada. Si la contraseña se deja EN BLANCO,
#      pregunta OTRO usuario del dominio con permisos de unión (y su
#      contraseña) e intenta la unión con él.
#   4. Verifica la unión y relanza el rol para que despliegue el snippet
#      SSSD del IES (/etc/sssd/conf.d/10-iac-ad.conf) — solo se aplica con
#      el equipo ya unido.
#
# Para unir un AULA entera mejor usar el vault (2-CreaVault.sh) y:
#   ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \
#     -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass
# ===========================================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERR] Ejecutar como root (sudo $0)"; exit 1; }

# El script vive en roles/preparaAD/utilesAD/ → la raíz ansible está 3 niveles arriba
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "$_DIR/../../.." && pwd)"

# DOMINIO / OU / USUARIO_UNION desde el ÚNICO punto de cambio (../entornoAD.yml,
# el mismo que carga el rol). Se pueden pisar por entorno antes de invocar:
#   DOMINIO=otro.local OU="OU=...,DC=..." ./3-UneAlDominio.sh
# shellcheck source=entornoAD.sh
source "$_DIR/entornoAD.sh"
command -v ansible-playbook >/dev/null || { echo "[ERR] ansible-playbook no encontrado (sudo apt install ansible)"; exit 1; }

# --- 1. Prerequisitos (rol preparaAD en modo local) -------------------------
echo "=== [1/4] Prerequisitos AD (rol preparaAD) ==="
cd "$ANSIBLE_DIR"
ansible-playbook -i localhost, --connection=local roles.yaml --tags preparaad

# --- 2. ¿Ya está unido? -----------------------------------------------------
echo "=== [2/4] ¿Unido ya a un dominio? ==="
UNIDO="$(realm list --name-only 2>/dev/null || true)"
if [[ -n "$UNIDO" ]]; then
    echo "[OK] Este equipo YA está unido a: $UNIDO — nada que hacer."
    exit 0
fi
echo "No unido. Se intentará la unión a '$DOMINIO'."

# --- 3. Unión ----------------------------------------------------------------
echo "=== [3/4] Unión al dominio ==="
if ! realm discover "$DOMINIO" >/dev/null 2>&1; then
    echo "[ERR] El dominio '$DOMINIO' NO se resuelve desde este equipo."
    echo "      El rol ya intentó el split-DNS hacia los DC (preparaad_dominio_dnss),"
    echo "      así que lo probable es que NO haya conectividad con ellos"
    echo "      (routing/firewall del aula). Diagnóstico:"
    echo "        resolvectl status"
    echo "        dig -t SRV _ldap._tcp.$DOMINIO"
    echo "        dig -t SRV _ldap._tcp.$DOMINIO @<IP_de_un_DC>"
    exit 1
fi
echo "[OK] Dominio visible por DNS."

# --- 3b. Reloj sincronizado (Kerberos exige <5 min de desfase con el DC) ------
# El rol ya apuntó el cliente NTP (chrony/timesyncd) al DC y esperó a que
# sincronizara, pero esto es una RED DE SEGURIDAD: si el reloj sigue desfasado,
# `realm join` crea la cuenta de equipo (fase LDAP) pero falla al finalizar
# (keytab/auth como máquina), dejando un objeto HUÉRFANO en AD y un mensaje
# confuso ("posible fallo de sincronización"). Mejor abortar ANTES, sin pedir
# credenciales ni ensuciar el dominio.
clock_ok() { [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; }
if ! clock_ok; then
    echo "[AVISO] El reloj NO está sincronizado por NTP. Forzando ajuste${NTP:+ (NTP=$NTP)}..."
    if command -v chronyc >/dev/null; then
        chronyc makestep 0.1 3      >/dev/null 2>&1 || true
        chronyc waitsync 30 0.05 0 1 >/dev/null 2>&1 || true
    else
        systemctl restart systemd-timesyncd 2>/dev/null || true
        for _ in $(seq 1 10); do clock_ok && break; sleep 3; done
    fi
fi
if ! clock_ok; then
    echo "[ERR] El reloj sigue SIN sincronizar (timedatectl: NTPSynchronized=no)."
    echo "      Kerberos exige <5 min de desfase con el DC; 'realm join' fallaría"
    echo "      tras crear la cuenta de equipo (objeto huérfano en la OU)."
    echo "      Revisa NTP/conectividad con el DC${NTP:+ ($NTP)}:"
    echo "        timedatectl status"
    echo "        chronyc tracking        # (o: systemctl status systemd-timesyncd)"
    echo "        chronyc sources -v      # ¿se alcanza el NTP del dominio?"
    exit 1
fi
echo "[OK] Reloj sincronizado por NTP."

# Contraseña en blanco = la cuenta delegada no está disponible → se ofrece
# unir con OTRO usuario del dominio con permisos de unión (p. ej. un admin).
# OJO: la cuenta de equipo se crea igualmente en $OU (debe existir).
read -rs -p "Contraseña de '$USUARIO_UNION' (en blanco = unir con otro usuario): " PASS; echo
if [[ -z "$PASS" ]]; then
    read -r  -p "Usuario del dominio con permisos de unión: " USUARIO_UNION
    [[ -n "$USUARIO_UNION" ]] || { echo "[ERR] Usuario vacío."; exit 1; }
    read -rs -p "Contraseña de '$USUARIO_UNION': " PASS; echo
    [[ -n "$PASS" ]] || { echo "[ERR] Contraseña vacía."; exit 1; }
fi

# realm join lee la contraseña por stdin con --unattended (sin tty).
# Crea la cuenta de equipo en la OU delegada, escribe /etc/sssd/sssd.conf,
# genera /etc/krb5.keytab y habilita+arranca sssd.
#
# MEMBERSHIP_SOFTWARE (de entornoAD.yml): vacío = adcli (default, Windows AD);
# "samba" = realmd delega en `net ads join`, que fija la contraseña de máquina
# por netlogon en vez de por kpasswd (NECESARIO contra DC Samba, donde adcli
# falla con "Message stream modified"). Con samba se fuerza el cliente SSSD.
MEMB_ARGS=()
if [[ -n "${MEMBERSHIP_SOFTWARE:-}" ]]; then
    MEMB_ARGS=(--membership-software="$MEMBERSHIP_SOFTWARE" --client-software=sssd)
    echo "[INFO] Motor de unión: $MEMBERSHIP_SOFTWARE (cliente de identidad: sssd)."
fi
if ! printf '%s\n' "$PASS" | realm join --unattended \
        --user="$USUARIO_UNION" "${MEMB_ARGS[@]}" --computer-ou="$OU" "$DOMINIO"; then
    unset PASS
    echo "[ERR] realm join ha fallado. Causas típicas: contraseña incorrecta,"
    echo "      reloj desfasado >5 min con el DC (timedatectl), cuenta sin"
    echo "      delegación en la OU, u OU inexistente ($OU)."
    echo "      Si el DC es Samba y el log dice 'Message stream modified' al fijar"
    echo "      la contraseña de máquina, pon preparaad_membership_software: \"samba\""
    echo "      en entornoAD.yml (une por net ads join en vez de kpasswd)."
    exit 1
fi
unset PASS

UNIDO="$(realm list --name-only 2>/dev/null || true)"
[[ -n "$UNIDO" ]] || { echo "[ERR] realm join terminó pero 'realm list' sigue vacío."; exit 1; }
echo "[OK] Equipo unido a: $UNIDO"

# --- 4. Snippet SSSD del IES (re-pase del rol, ya unido) ---------------------
echo "=== [4/4] Configuración SSSD del IES (re-pase del rol) ==="
ansible-playbook -i localhost, --connection=local roles.yaml --tags preparaad

echo
echo "================================================================"
echo " Correcto: $(hostname) unido a $UNIDO (OU: $OU)"
echo " Pruebas sugeridas:"
echo "   realm list"
echo "   ping -c1 $DOMINIO            (resolución vía nsswitch, la de kinit/adcli)"
echo "   getent passwd <usuario_del_dominio>"
echo "   su - <usuario_del_dominio>   (crea el home vía pam_mkhomedir)"
echo "================================================================"
