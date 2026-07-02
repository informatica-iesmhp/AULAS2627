---
name: thinstation-usb-no-ventoy
description: La ISO de ThinStation-NG NO arranca bien desde Ventoy; hay que grabarla directa al USB (Rufus modo Imagen DD / balenaEtcher / dd)
metadata:
  type: reference
---

La `thinstation-efi.iso` de ThinStation-NG 7.2 **no se debe arrancar con Ventoy**. Ventoy mapea la ISO con un driver virtual en vez de exponerla como dispositivo real, y ThinStation localiza su squashfs (~300 MB, con `lightdm` y toda la pila gráfica) recorriendo dispositivos como un CD (`boot_device=cd0`). Bajo Ventoy no lo encuentra → arranca **solo con el initramfs**: kernel + red + consola, pero **sin lightdm ni entorno gráfico**. Falla igual en `normal mode` y `memdisk mode` (`grub2 mode` da «No bootfile found for UEFI!»).

**Solución (verificada, MSI físico junio 2026):** grabar la ISO **directa** al USB en modo imagen → **Rufus** (Esquema GPT, destino UEFI no-CSM, y al pulsar EMPEZAR elegir **«Escribir en modo Imagen DD»**), balenaEtcher, o `dd ... oflag=direct conv=fsync` al disco completo. Arrancar por la entrada `UEFI:` (CSM y Secure Boot off).

**Firma diagnóstica** del problema (en consola root del equipo): `command -v lightdm` vacío + `/usr/sbin/lightdm` no existe + `df -h` **sin ningún squashfs/overlay montado** (solo tmpfs). Eso significa "la capa de paquetes no cargó", NO un problema de GPU ni de RAM (en el caso MSI había 64 GB libres y `nouveau`/KMS ligó bien con `/dev/dri/card1`). Documentado en [[../ThinStation/CLAUDE.md]] (Paso 8 y §8b). Relacionado: [[thinstation-multimonitor]].
