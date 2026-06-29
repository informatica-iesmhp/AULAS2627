#!/bin/bash
# ===========================================================================
# 2-CreaVault.sh — crea el vault cifrado con las credenciales de la cuenta
# delegada de unión al dominio (rol preparaAD de IAC-IESMHP).
# ---------------------------------------------------------------------------
# Ejecutar en el EQUIPO DEL PROFESOR (Linux, con el repo clonado y ansible
# instalado). Pide:
#   1. La contraseña de la cuenta 'svc-union-linux' (la que se tecleó en
#      1-CreaUsuarioUnionAD.ps1 en el controlador de dominio).
#   2. La contraseña DEL VAULT (la pide ansible-vault, dos veces): es la que
#      protege el fichero cifrado y la que se teclea luego en cada pase con
#      --ask-vault-pass. NO confundir ambas.
#
# Resultado: Ubuntu/ansible/vault/preparaAD-vault.yml (AES256, committeable).
#
# ¿Por qué en vault/ y NO en group_vars/? Ansible auto-carga group_vars/ en
# TODOS los pases: un vault ahí obligaría a teclear --ask-vault-pass siempre
# (incluido el primer arranque desatendido, que reventaría). En vault/ solo
# se carga cuando se pide explícitamente con -e @vault/preparaAD-vault.yml.
#
# Uso posterior (unión automatizada de un aula):
#   cd /opt/IAC-IESMHP/Ubuntu/ansible
#   ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \
#     -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass
# ===========================================================================
set -euo pipefail

# El script vive en roles/preparaAD/utilesAD/ → la raíz ansible está 3 niveles arriba
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "$_DIR/../../.." && pwd)"

# USUARIO_UNION desde el ÚNICO punto de cambio (../entornoAD.yml, el mismo que
# carga el rol). El vault DEBE llevar el mismo usuario que preparaad_usuario_union.
# shellcheck source=entornoAD.sh
source "$_DIR/entornoAD.sh"
VAULT_DIR="$ANSIBLE_DIR/vault"
VAULT_FILE="$VAULT_DIR/preparaAD-vault.yml"

command -v ansible-vault >/dev/null || { echo "[ERR] ansible-vault no encontrado (sudo apt install ansible)"; exit 1; }

if [[ -f "$VAULT_FILE" ]]; then
    read -r -p "[AVISO] $VAULT_FILE ya existe. ¿Sobreescribir? [s/N] " RESP
    [[ "$RESP" =~ ^[sS]$ ]] || { echo "Abortado (vault existente intacto)."; exit 0; }
fi

# --- 1. Contraseña de la cuenta de unión -----------------------------------
echo "Contraseña de la cuenta '$USUARIO_UNION' (la del dominio, NO la del vault):"
read -rs -p "  Contraseña: " PASS1; echo
read -rs -p "  Repítela  : " PASS2; echo
[[ "$PASS1" == "$PASS2" ]] || { echo "[ERR] No coinciden."; exit 1; }
[[ -n "$PASS1" ]]          || { echo "[ERR] No puede estar vacía."; exit 1; }
# El rol interpola la contraseña en una orden shell entre comillas simples
[[ "$PASS1" != *"'"* ]]    || { echo "[ERR] No puede contener comillas simples (limitación del rol preparaAD)."; exit 1; }

# --- 2. Fichero en claro temporal → cifrado con ansible-vault ---------------
umask 077
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# Credenciales de la cuenta delegada de unión al dominio (rol preparaAD).
# Generado por utilesAD/2-CreaVault.sh — cifrado AES256, committeable al repo.
# Se carga SOLO con: -e @vault/preparaAD-vault.yml --ask-vault-pass
preparaad_usuario_union: $USUARIO_UNION
preparaad_password_union: '$PASS1'
EOF
unset PASS1 PASS2

mkdir -p "$VAULT_DIR"
echo
echo "Ahora ansible-vault pedirá la contraseña DEL VAULT (2 veces) — apúntala,"
echo "es la que se teclea en cada pase con --ask-vault-pass:"
ansible-vault encrypt --output "$VAULT_FILE" "$TMP"

echo
echo "[OK] Vault creado: $VAULT_FILE"
echo
echo "Verificar:   ansible-vault view '$VAULT_FILE'"
echo "Usar (unión de un aula, desde $ANSIBLE_DIR):"
echo "  ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \\"
echo "    -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass"
