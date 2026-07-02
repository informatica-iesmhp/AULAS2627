#!/bin/bash
# ===========================================================================
# entornoAD.sh — lee el ÚNICO punto de cambio del entorno AD (entornoAD.yml)
# y deja listas las variables que usan los scripts de utilesAD/.
# ---------------------------------------------------------------------------
# Se hace `source` desde 2-CreaVault.sh y 3-UneAlDominio.sh. NO ejecutar solo.
# Fuente de verdad: ../entornoAD.yml (la misma que carga el rol Ansible). Aquí
# solo se PARSEA; para cambiar el dominio editar ese .yml, NO este fichero.
#
# Exporta: DOMINIO, NOMBRE_OU, OU (derivada), USUARIO_UNION, DOMINIO_DNSS, NTP,
#          MEMBERSHIP_SOFTWARE (motor de unión: ""=adcli / "samba"=net ads join).
# Respeta valores ya puestos por entorno (p. ej. DOMINIO=otro.local ./3-...sh).
# ===========================================================================

# El helper vive en utilesAD/; entornoAD.yml está un nivel arriba (raíz del rol).
_ENTORNO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTORNO_AD="${ENTORNO_AD:-$_ENTORNO_DIR/entornoAD.yml}"

[[ -f "$ENTORNO_AD" ]] || { echo "[ERR] No encuentro el entorno AD: $ENTORNO_AD" >&2; exit 1; }

# Lee un escalar simple  clave: "valor" | 'valor' | valor  (primera aparición),
# quitando comillas y comentario en línea. NO sirve para claves con Jinja
# (preparaad_ou); esa se deriva abajo igual que en el rol.
_entorno_get() {
    local v
    v="$(sed -n -E "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*(.*)$/\1/p" "$ENTORNO_AD" | head -n1)"
    v="${v%%#*}"                                   # quita comentario en línea
    v="${v#"${v%%[![:space:]]*}"}"                 # ltrim
    v="${v%"${v##*[![:space:]]}"}"                 # rtrim
    v="${v#[\"\']}"; v="${v%[\"\']}"               # quita un par de comillas exteriores
    printf '%s' "$v"
}

# dominio.tld  ->  DC=dominio,DC=tld   (mhpies.local -> DC=mhpies,DC=local)
_entorno_dn() { printf 'DC=%s' "${1//./,DC=}"; }

DOMINIO="${DOMINIO:-$(_entorno_get preparaad_dominio)}"
NOMBRE_OU="${NOMBRE_OU:-$(_entorno_get preparaad_nombre_ou)}"
USUARIO_UNION="${USUARIO_UNION:-$(_entorno_get preparaad_usuario_union)}"
DOMINIO_DNSS="${DOMINIO_DNSS:-$(_entorno_get preparaad_dominio_dnss)}"
NTP="${NTP:-$(_entorno_get preparaad_ntp)}"   # NTP del dominio (pista de diagnóstico)
MEMBERSHIP_SOFTWARE="${MEMBERSHIP_SOFTWARE:-$(_entorno_get preparaad_membership_software)}"   # ""=adcli / "samba"=net ads join

[[ -n "$DOMINIO"   ]] || { echo "[ERR] preparaad_dominio vacío en $ENTORNO_AD" >&2; exit 1; }
[[ -n "$NOMBRE_OU" ]] || NOMBRE_OU="ComputersLinux"
[[ -n "$USUARIO_UNION" ]] || USUARIO_UNION="svc-union-linux"

# OU completa, DERIVADA del dominio (idéntica a la que calcula el rol Ansible).
OU="${OU:-OU=${NOMBRE_OU},$(_entorno_dn "$DOMINIO")}"
