#!/bin/bash
# ===========================================================================
# 5-LimpiaUsuariosDominio.sh — borra TODO el rastro de los usuarios del DOMINIO
# en ESTE equipo (rol preparaAD de IAC-IESMHP). Complemento de 4-SacaDelDominio.sh.
# ---------------------------------------------------------------------------
# Ejecutar COMO ROOT, normalmente DESPUÉS de 4-SacaDelDominio.sh (con el equipo
# YA fuera del dominio y la caché de SSSD vaciada). Operación DESTRUCTIVA e
# IRREVERSIBLE: borra carpetas personales completas.
#
# Qué identifica como "usuario de dominio a purgar": cualquier cuenta cuyo
# NOMBRE ya NO resuelve en /etc/passwd (getent) pero dejó rastro local:
#   - home en /home/<nombre> (uid >= 1000, no propiedad de un usuario local)
#   - rango en /etc/subuid / /etc/subgid (lo añade el Docker rootless del rol)
#   - lingering en /var/lib/systemd/linger/<nombre>
#   - perfil en /var/lib/AccountsService/users/<nombre>
# Los usuarios LOCALES (los que SÍ están en /etc/passwd: 'usuario', los creados
# con adduser, root...) se PRESERVAN SIEMPRE.
#
# Por cada usuario a purgar:
#   - termina su sesión y su gestor systemd --user (para el daemon rootless y
#     desmonta los overlays de sus contenedores) y mata sus procesos.
#   - borra: home, subuid/subgid, lingering, AccountsService (perfil+icono),
#     correo, cron, tickets Kerberos (/tmp/krb5cc_<uid>*) y /run/user/<uid>.
#
# OJO equipos CEIABD antiguos (pre-2026-06-12) con un dataset ZFS por usuario
# (rpool/home/<usuario>): el `rm -rf` NO destruye el dataset. En esos equipos,
# tras este script: `zfs list -r rpool/home` y `zfs destroy rpool/home/<usuario>`
# de los que queden. El esquema actual (dataset único rpool/home) no lo necesita.
#
# Uso:
#   sudo ./5-LimpiaUsuariosDominio.sh            # interactivo (pide confirmación)
#   sudo ./5-LimpiaUsuariosDominio.sh --dry-run  # solo LISTA, no borra nada
#   sudo ./5-LimpiaUsuariosDominio.sh --si       # desatendido (pase de aula)
# ===========================================================================
set -euo pipefail
shopt -s nullglob

[[ $EUID -eq 0 ]] || { echo "[ERR] Ejecutar como root (sudo $0)"; exit 1; }

DRYRUN=0; ASUME_SI=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)  DRYRUN=1 ;;
    --si|-y|--yes) ASUME_SI=1 ;;
    -h|--help)     grep -E '^# ?' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[ERR] Opción desconocida: $arg (usa --dry-run | --si)"; exit 1 ;;
  esac
done

# Aviso si el equipo SIGUE unido: entonces los usuarios del dominio aún resuelven
# en getent y NO se detectarán como rastro. Hay que sacarlo primero.
if command -v realm >/dev/null 2>&1; then
  UNIDO="$(realm list --name-only 2>/dev/null | head -n1 || true)"
  if [[ -n "$UNIDO" ]]; then
    echo "[AVISO] El equipo SIGUE unido a '$UNIDO': los usuarios del dominio aún"
    echo "        resuelven y NO se marcarán como rastro. Sácalo primero:"
    echo "        sudo $(dirname "$0")/4-SacaDelDominio.sh"
    echo
  fi
fi

# Tras 'realm leave' + vaciado de caché SSSD, solo los usuarios LOCALES resuelven.
es_local() { getent passwd "$1" >/dev/null 2>&1; }

# Escapa un nombre para usarlo como dirección BRE de sed (anclada con ^...:).
esc_sed() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }

declare -A UID_DE=()    # nombre -> uid (vacío si se desconoce: sin home)
declare -A HOME_DE=()   # nombre -> ruta del home (si existe)

marca_orfano() {        # $1 = nombre candidato (de subuid/linger/AccountsService)
  local n="$1"
  [[ -z "$n" ]] && return 0
  es_local "$n" && return 0
  [[ -n "${UID_DE[$n]+x}" ]] || UID_DE["$n"]=""
}

# --- Fuente 1: homes huérfanos en /home ------------------------------------
for d in /home/*/; do
  d="${d%/}"
  name="$(basename "$d")"
  [[ "$name" == "lost+found" ]] && continue
  ouid="$(stat -c %u "$d" 2>/dev/null || echo 0)"
  [[ "$ouid" -ge 1000 ]] || continue     # saltar root y cuentas de sistema
  es_local "$name" && continue           # usuario local -> preservar
  UID_DE["$name"]="$ouid"; HOME_DE["$name"]="$d"
done

# --- Fuentes 2-4: subuid/subgid, lingering, AccountsService ----------------
for f in /etc/subuid /etc/subgid; do
  [[ -f "$f" ]] || continue
  while IFS=: read -r n _; do marca_orfano "$n"; done < "$f"
done
for l in /var/lib/systemd/linger/*;          do marca_orfano "$(basename "$l")"; done
for a in /var/lib/AccountsService/users/*;    do marca_orfano "$(basename "$a")"; done

# --- ¿Hay algo que limpiar? -------------------------------------------------
if [[ ${#UID_DE[@]} -eq 0 ]]; then
  echo "[OK] No se ha encontrado rastro de usuarios de dominio. Nada que limpiar."
  exit 0
fi

IFS=$'\n' NOMBRES=($(printf '%s\n' "${!UID_DE[@]}" | sort)); unset IFS

echo "=== Usuarios de dominio detectados (rastro local en $(hostname)) ==="
printf '  %-24s %-10s %s\n' "NOMBRE" "UID" "HOME"
for n in "${NOMBRES[@]}"; do
  h="${HOME_DE[$n]:-(sin home)}"; sz=""
  [[ -n "${HOME_DE[$n]:-}" && -d "${HOME_DE[$n]}" ]] && sz="$(du -sh "${HOME_DE[$n]}" 2>/dev/null | cut -f1)"
  printf '  %-24s %-10s %s%s\n' "$n" "${UID_DE[$n]:-?}" "$h" "${sz:+  ($sz)}"
done
echo

if [[ $DRYRUN -eq 1 ]]; then
  echo "[dry-run] No se ha borrado nada. Quita --dry-run para purgar."
  exit 0
fi

if [[ $ASUME_SI -ne 1 ]]; then
  echo "Se BORRARÁN sus carpetas personales y TODO su rastro. IRREVERSIBLE."
  read -r -p "Escribe 'BORRAR' (en mayúsculas) para confirmar: " RESP
  [[ "$RESP" == "BORRAR" ]] || { echo "Abortado (sin cambios)."; exit 0; }
fi

purga_uno() {
  local n="$1" u="${UID_DE[$1]:-}" f esc
  echo "--- Purgando '$n' (uid ${u:-?}) ---"
  # 1. Terminar sesión + gestor systemd --user (para el daemon rootless y
  #    desmontar los overlays de sus contenedores) y matar sus procesos.
  if [[ -n "$u" ]]; then
    loginctl terminate-user "$u"      2>/dev/null || true
    systemctl stop "user@$u.service"  2>/dev/null || true
    pkill -KILL -u "$u"               2>/dev/null || true
    rm -rf "/run/user/$u"             2>/dev/null || true
    rm -f  /tmp/krb5cc_"$u"*          2>/dev/null || true
  fi
  # 2. Lingering.
  rm -f "/var/lib/systemd/linger/$n" 2>/dev/null || true
  # 3. subuid/subgid (línea anclada al nombre, escapado para sed).
  esc="$(esc_sed "$n")"
  for f in /etc/subuid /etc/subgid; do
    [[ -f "$f" ]] && sed -i "/^$esc:/d" "$f" 2>/dev/null || true
  done
  # 4. AccountsService (perfil + avatar).
  rm -f "/var/lib/AccountsService/users/$n" "/var/lib/AccountsService/icons/$n" 2>/dev/null || true
  # 5. Correo y cron.
  rm -f "/var/mail/$n" "/var/spool/mail/$n" "/var/spool/cron/crontabs/$n" 2>/dev/null || true
  # 6. Home (--one-file-system: no cruza puntos de montaje por seguridad).
  if [[ -n "${HOME_DE[$n]:-}" && -d "${HOME_DE[$n]}" ]]; then
    rm -rf --one-file-system "${HOME_DE[$n]}" && echo "   home borrado: ${HOME_DE[$n]}"
  fi
}

echo "=== Purga ==="
for n in "${NOMBRES[@]}"; do purga_uno "$n"; done

echo
echo "================================================================"
echo " Correcto: purgado el rastro de ${#NOMBRES[@]} usuario(s) de dominio."
echo " (Homes, subuid/subgid, lingering, AccountsService, correo/cron, krb)."
echo "================================================================"
