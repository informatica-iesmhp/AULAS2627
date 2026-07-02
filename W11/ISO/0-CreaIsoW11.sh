#!/usr/bin/env bash
#
# 0-CreaIsoW11.sh
# Inserta un autounattend.xml en una ISO de Windows 11 desde Linux (Ubuntu)
# reconstruyendo la ISO con xorriso (modo -as mkisofs), conservando el
# arranque BIOS + UEFI. Ademas embebe 0b-GitHub.ps1 via $OEM$ para que acabe
# en "C:\Program Files\IAC-IESMHP\W11\ISO\0b-GitHub.ps1" del sistema instalado
# (lo lanza el FirstLogonCommands del autounattend.xml en el primer inicio de
# sesion). Esa es ya su ubicacion DEFINITIVA: cuando 0b clona el repo, este se
# materializa sobre esa misma carpeta y el propio 0b queda "actualizado" desde
# GitHub sin moverse de sitio.
#
# Dependencias:  sudo apt install xorriso wimtools
#
# Uso:
#   ./0-CreaIsoW11.sh -i ORIGINAL.iso -a autounattend.xml -o SALIDA.iso \
#                     [-s 0b-GitHub.ps1] [--split]
#
#   -s        Ruta al script PowerShell de bootstrap a embeber via $OEM$.
#             Por defecto 0b-GitHub.ps1 junto a este script. Si no existe se
#             avisa y se continua sin embeberlo.
#   --split   Fuerza el troceo de install.wim en .swm (<4 GB) aunque no supere
#             los 4 GiB. Por defecto solo se trocea si install.wim > 4 GiB
#             (limite de tamano de fichero de ISO 9660).
#
# Por que NO el metodo nativo ("replay"/"keep"):
#   Las ISOs de Win11 24H2/25H2 ocultan las imagenes de arranque El Torito (no
#   son ficheros del arbol). Con 'replay' xorriso falla ("not a data file in the
#   ISO filesystem"). Con 'keep' conserva el arranque, pero el modo nativo
#   -indev/-outdev hacia un fichero DISTINTO escribe solo una sesion incremental
#   (te queda una ISO de pocos KB sin los datos). Por eso este script monta la
#   ISO en solo-lectura y la RECONSTRUYE con -as mkisofs.
#
# NOTA: prueba SIEMPRE la ISO resultante en una maquina virtual antes de
#       usarla en hardware real.
#
set -euo pipefail

# Script de bootstrap por defecto: 0b-GitHub.ps1 junto a este script.
SELFDIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ORIG=""; AUTO=""; OUT=""; SPLIT=0; PS1SCRIPT="$SELFDIR/0b-GitHub.ps1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) ORIG="$2"; shift 2 ;;
    -a) AUTO="$2"; shift 2 ;;
    -o) OUT="$2";  shift 2 ;;
    -s) PS1SCRIPT="$2"; shift 2 ;;
    --split) SPLIT=1; shift ;;
    *) echo "Argumento no reconocido: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$ORIG" ]] || { echo "ERROR: no encuentro la ISO de origen: $ORIG" >&2; exit 1; }
[[ -f "$AUTO" ]] || { echo "ERROR: no encuentro el autounattend.xml: $AUTO" >&2; exit 1; }
[[ -n "$OUT"  ]] || { echo "ERROR: falta -o SALIDA.iso" >&2; exit 1; }
command -v xorriso >/dev/null || { echo "ERROR: instala xorriso (sudo apt install xorriso)" >&2; exit 1; }

# sudo solo si no somos root (mount/umount lo necesitan)
if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

ORIG="$(readlink -f "$ORIG")"
AUTO="$(readlink -f "$AUTO")"

echo ">> ISO origen : $ORIG"
echo ">> Answer file: $AUTO"
echo ">> ISO salida : $OUT"

rm -f "$OUT"

# Directorios de trabajo. El de 'add' (autounattend + .swm) va en el mismo disco
# que la salida, que es donde hay espacio para los .swm (~6 GB) y la ISO (~8 GB).
OUTDIR="$(dirname "$OUT")"; [[ -d "$OUTDIR" ]] || OUTDIR="."
MNT="$(mktemp -d)"
WORK="$(mktemp -d "$OUTDIR/.win11build.XXXXXX")"
cleanup() {
  if mountpoint -q "$MNT" 2>/dev/null; then $SUDO umount "$MNT" 2>/dev/null || true; fi
  rmdir "$MNT" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# Montar la ISO en solo-lectura. UDF preferido para leer install.wim >4 GB
# completo (la capa ISO 9660 podria truncarlo).
$SUDO mount -o loop,ro -t udf "$ORIG" "$MNT" 2>/dev/null \
  || $SUDO mount -o loop,ro "$ORIG" "$MNT"

# Volume ID original (Windows lo usa para detectar el medio igual que el original)
# OJO: con 'set -euo pipefail' este pipeline puede ABORTAR el script en silencio:
#  - xorriso emite el TOC por stderr en varias versiones -> con '2>/dev/null'
#    grep se queda sin entrada y devuelve 1; y/o 'grep -m1' cierra la tuberia
#    pronto y xorriso recibe SIGPIPE. En ambos casos pipefail propaga el fallo
#    y, al estar en la asignacion VOLID="$(...)", set -e mata el script ANTES
#    de poder aplicar el valor por defecto de la linea siguiente.
# El '|| true' neutraliza ese fallo no critico (si no se detecta, hay fallback).
VOLID="$(xorriso -indev "$ORIG" -toc 2>/dev/null | grep -m1 'Volume id' | sed "s/.*: *'//; s/'.*//" || true)"
[[ -n "$VOLID" ]] || VOLID="CCCOMA_X64FRE_ES-ES_DV9"
echo ">> Volume ID  : $VOLID"

# autounattend.xml en la raiz de la ISO
mkdir -p "$WORK/add"
cp "$AUTO" "$WORK/add/autounattend.xml"

# 0b-GitHub.ps1 embebido via $OEM$. En la jerarquia $OEM$, "$1" mapea a la raiz
# del disco de sistema (C:\); por eso sources/$OEM$/$1/Program Files/... acaba en
# "C:\Program Files\IAC-IESMHP\W11\ISO\0b-GitHub.ps1" del sistema instalado, que
# es la ruta DEFINITIVA del script (la misma que luego materializa el git clone)
# y la que invoca el FirstLogonCommands del autounattend.xml.
if [[ -f "$PS1SCRIPT" ]]; then
  OEM_SCRIPTS="$WORK/add/sources/\$OEM\$/\$1/Program Files/IAC-IESMHP/W11/ISO"
  mkdir -p "$OEM_SCRIPTS"
  cp "$PS1SCRIPT" "$OEM_SCRIPTS/0b-GitHub.ps1"
  echo ">> Bootstrap   : $PS1SCRIPT"
  echo ">>               -> /sources/\$OEM\$/\$1/Program Files/IAC-IESMHP/W11/ISO/0b-GitHub.ps1"
  echo ">>               (en el sistema instalado: C:\\Program Files\\IAC-IESMHP\\W11\\ISO\\0b-GitHub.ps1)"
else
  echo ">> AVISO: no encuentro el script de bootstrap ($PS1SCRIPT)." >&2
  echo ">>        La ISO se generara SIN 0b-GitHub.ps1; el FirstLogonCommands fallara." >&2
fi

# Imagen de arranque UEFI: preferimos la version sin "Press any key to boot..."
EFIIMG="efi/microsoft/boot/efisys_noprompt.bin"
[[ -f "$MNT/$EFIIMG" ]] || EFIIMG="efi/microsoft/boot/efisys.bin"
[[ -f "$MNT/$EFIIMG" ]] || { echo "ERROR: no encuentro la imagen EFI en la ISO" >&2; exit 1; }

# ¿Hay que trocear install.wim? (limite de 4 GiB por fichero en ISO 9660)
EXCL=()
WIM="$MNT/sources/install.wim"
if [[ -f "$WIM" ]]; then
  WIM_BYTES="$(stat -c%s "$WIM")"
  echo ">> install.wim: $((WIM_BYTES/1024/1024)) MB"
  if [[ "$SPLIT" -eq 1 || "$WIM_BYTES" -gt 4294967295 ]]; then
    command -v wimlib-imagex >/dev/null || { echo "ERROR: instala wimtools (sudo apt install wimtools)" >&2; exit 1; }
    echo ">> Troceando install.wim en .swm (<3800 MB)..."
    mkdir -p "$WORK/add/sources"
    wimlib-imagex split "$WIM" "$WORK/add/sources/install.swm" 3800
    EXCL=(-m "install.wim")
  fi
fi

echo ">> Reconstruyendo la ISO (xorriso -as mkisofs)..."
xorriso -as mkisofs \
  -iso-level 4 -rock -disable-deep-relocation -untranslated-filenames \
  -V "$VOLID" -volset "$VOLID" \
  -publisher "MICROSOFT CORPORATION" \
  -A "CDIMAGE 2.56 (01/01/2005 TM)" \
  "${EXCL[@]}" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
  -eltorito-alt-boot -eltorito-platform efi \
  -b "$EFIIMG" \
  -o "$OUT" "$MNT" "$WORK/add"

# --- Verificacion -----------------------------------------------------------
echo
echo "=== Verificacion ==="
echo "- Tamano de la ISO:"
ls -lh "$OUT" | awk '{print "  " $5 "  " $NF}'
echo "- Arranque El Torito (BIOS + UEFI):"
xorriso -indev "$OUT" -report_el_torito plain 2>/dev/null | grep -E "El Torito boot img" || echo "  (sin El Torito!)"
echo "- autounattend.xml en la raiz:"
xorriso -indev "$OUT" -find /autounattend.xml 2>/dev/null || echo "  (NO encontrado!)"
if [[ -f "$PS1SCRIPT" ]]; then
  echo "- 0b-GitHub.ps1 embebido (\$OEM\$ -> C:\\Program Files\\IAC-IESMHP\\W11\\ISO):"
  xorriso -indev "$OUT" -find '/sources/$OEM$/$1/Program Files/IAC-IESMHP/W11/ISO/0b-GitHub.ps1' 2>/dev/null \
    || echo "  (NO encontrado!)"
fi
echo
echo ">> Listo: $OUT"
echo ">> Pruebalo en una VM (UEFI + TPM) antes de usarlo en hardware real."
