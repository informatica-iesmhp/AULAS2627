#!/bin/bash
###############################################################################
# Parche "paso 2" IESMHP para ThinStation-NG 7.2
# -----------------------------------------------------------------------------
# QUE HACE:
#   Mete el arbol COMPLETO de modulos del kernel (/lib/modules/$KV) + TODO el
#   firmware (/lib/firmware, ~402 MB) dentro de lib.squash, NO en el initrd.
#
# POR QUE:
#   Por defecto ThinStation deja modulos+firmware en el initrd (lista
#   fastboot/lib-boot). Con --allmodules + allfirmware true el initrd llegaba a
#   433 MB y GRUB-BIOS corrompe la mitad alta al leerlo del CD ("Initramfs
#   unpacking failed: XZ-compressed data is corrupt") -> no arranca en BIOS.
#   Con este parche el initrd queda ~45 MB (solo lo justo para montar lib.squash:
#   isofs/squashfs/loop/overlay) y arranca en BIOS *y* UEFI; la cobertura HW
#   (drivers+firmware de cualquier GPU/red) viaja en lib.squash, que con
#   'param fastboot lotsofmem' se vuelca a RAM y carga lo necesario de forma
#   perezosa tras el arranque.
#
# COMO USARLO (en el chroot Fedora, tras ./setup-chroot):
#   1) build.conf  ->  param allfirmware false   (NO true)
#   2) bash /ruta/a/parche-fastboot-mangle-paso2.sh     (aplica el parche)
#   3) cd /build && ./build --license ACCEPT --autodl   (SIN --allmodules)
#
#   Reaplicar el parche si setup-chroot regenera /build/fastboot/fastboot-mangle.
#   Idempotente: si ya esta aplicado, no duplica (marcador "IESMHP paso 2").
#
# Verificado en VM (BIOS+UEFI) 2026-06-04: initrd ~45 MB, lib.squash ~900 MB,
# 4807 modulos + firmware NVIDIA/Intel/AMD presentes tras arrancar.
###############################################################################
set -e

MANGLE=/build/fastboot/fastboot-mangle

if grep -q 'IESMHP paso 2' "$MANGLE"; then
    echo "El parche ya esta aplicado en $MANGLE (marcador IESMHP paso 2). Nada que hacer."
    exit 0
fi

# Bloque a insertar (here-doc literal: no expande $KV ni $(...))
cat > /tmp/iesmhp_block.sh <<'BLOCK'
	# --- IESMHP paso 2: modulos + firmware COMPLETOS en lib.squash (initrd minimo) ---
	KV=$(ls --color=never lib64/modules 2>/dev/null | head -n1)
	if [ -n "$KV" ] && [ -d /lib/modules/$KV ]; then
		rm -rf ../fastboot-tmp/lib64/modules; mkdir -p ../fastboot-tmp/lib64/modules
		cp -al /lib/modules/$KV ../fastboot-tmp/lib64/modules/
		rm -f ../fastboot-tmp/lib64/modules/$KV/build ../fastboot-tmp/lib64/modules/$KV/source
	fi
	if [ -d /lib/firmware ]; then
		rm -rf ../fastboot-tmp/lib64/firmware; mkdir -p ../fastboot-tmp/lib64/firmware
		cp -al /lib/firmware/. ../fastboot-tmp/lib64/firmware/
	fi
	[ -d lib64/firmware ] && rm -rf lib64/firmware
	# --- fin IESMHP paso 2 ---
BLOCK

cp "$MANGLE" "$MANGLE.bak"

# Insertar el bloque JUSTO antes del 'mksquashfs ../fastboot-tmp/.' (rama lotsofmem)
awk 'FNR==NR{blk=blk $0 ORS; next} /mksquashfs \.\.\/fastboot-tmp\/\./ && !ins{printf "%s",blk; ins=1} {print}' \
    /tmp/iesmhp_block.sh "$MANGLE.bak" > "$MANGLE"

echo "===== Parche aplicado. Bloque insertado: ====="
sed -n '/IESMHP paso 2/,/mksquashfs ..\/fastboot-tmp/p' "$MANGLE"
echo "===== (copia de seguridad en $MANGLE.bak) ====="
