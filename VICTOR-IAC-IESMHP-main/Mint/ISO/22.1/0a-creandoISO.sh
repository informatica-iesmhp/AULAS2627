#!/bin/bash

##Asegurar la última vesrión de este script mediante: git -C /opt/IAC-IESMHP pull
set -e
VERSIONSCRIPT="2.00"       #Versión del script
VERSION="22.1"             #Versión de la ISO Mint Cinnamon base
NOMBREISOFINAL="Mint-CEIABD-SMRV-v$VERSION"


# Funciones de colores
verde() { echo -e "\033[32m$1\033[0m"; }
rojo() { echo -e "\033[31m$1\033[0m"; }

verde "(vs $VERSIONSCRIPT)Iniciando creación de ISO personalizada Linux Mint $VERSION..."

# Verifica si es root
if [ "$EUID" -ne 0 ]; then
    rojo "Este script debe ejecutarse como root."
    sleep 10 && exit 1
fi

# Verifica que se pasó una ISO
if [ -z "$1" ]; then
    ISO="/tmp/linuxmint-22.1-cinnamon-64bit.iso"
    rojo "No se ha especificado una ISO. Se usará $ISO."
else
    ISO="$1"
fi
# Verifica que la ISO existe
if [ ! -f "$ISO" ]; then
    rojo "La ISO especificada no existe: $ISO"
    sleep 10 && exit 1
fi
    
# Verifica que existen utilidades necesarias
verde "Comprobando utilidades de creación de ISO..."
apt install -y xorriso isolinux syslinux-utils


#Creamos un directorio temporal para trabajar

WORKDIR=$(mktemp -d ./livecd.XXXXXX) && chmod 755 "$WORKDIR"
#Sobre el directorio de trabajo, creamos los subdirectorios necesarios
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
RAIZGIT="$WORKDIR/IAC-IESMHP"
MOUNTDIR="$WORKDIR/mount" 
EXTRACTDIR="$WORKDIR/extract"
SQUASHFS_DIR="$WORKDIR/squashfs"
NOMBRESCRIPINICIAL="0b-Github.sh"
SCRIPT_GIT="$RAIZGIT/Mint/ISO/$VERSION/$NOMBRESCRIPINICIAL"
RAIZSCRIPTS="/opt/$RAIZGIT"
RAIZLOGS="/var/log/$RAIZGIT"

verde "Descargo los scripts en /$RAIZMINT desde $RAIZSCRIPTSLIVE/Mint"
git clone $GITREPO "$RAIZGIT/"
#Directorios a crear en el sistema nuevo

# Verifica que existe el script setup.sh
if [ ! -f "$SCRIPT_GIT" ]; then
    rojo "No se encontró $SCRIPT_GIT"
    sleep 10 && exit 1
fi

verde "Montando ISO sobre la carpeta $MOUNTDIR ..."
mkdir -p "$MOUNTDIR"
mount -o loop "$ISO" "$MOUNTDIR"

verde "Copiando contenido de la ISO en $EXTRACTDIR ..."
mkdir -p "$EXTRACTDIR"
rsync -a "$MOUNTDIR/" "$EXTRACTDIR/"

verde "Extrayendo $SQUASHFS_DIR en '$MOUNTDIR/casper/filesystem.squashfs'..."
unsquashfs -d "$SQUASHFS_DIR" "$MOUNTDIR/casper/filesystem.squashfs"
        # #TODO: ejecutando sobre la / de squash, actualizar el sistema (y ponerlo en español)
        #ver código al final de este script

verde "Copio el script inicial en la raiz"
cp "$SCRIPT_GIT" "$SQUASHFS_DIR/"

#Originalmente:
    #verde "Insertando todos los script de configuración '$SCRIPT_DIR/*.sh' en '$SQUASHFS_DIR/root/'"
    #mkdir -p "$SQUASHFS_DIR$RAIZSCRIPTS"
    #rsync -ar "$SCRIPT_DIR/" "$SQUASHFS_DIR$RAIZSCRIPTS"
    #chmod +x "$SQUASHFS_DIR$RAIZSCRIPTS/"*.sh


verde "Creando servicio autostart del usuario live para ejecutar setup.sh al iniciar sesión..."
AUTOSTART_DIR="$SQUASHFS_DIR/home/mint/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
# Crear un .desktop que ejecute setup.sh en un terminal
cat <<EOF-AUTOSTART > "$AUTOSTART_DIR/setup.desktop"
[Desktop Entry]
Type=Application
Exec=x-terminal-emulator -e sudo /bin/bash /$NOMBRESCRIPINICIAL
Name=SetupLiveCD
Comment=Script de configuración personalizado para el LiveCD
X-GNOME-Autostart-enabled=true
EOF-AUTOSTART

#        #Desactivamos el servicio de display-manager, para que no se inicie al arrancar la ISO
#        verde "Desactivando el servicio de display-manager..."
#        mv "$SQUASHFS_DIR"/etc/systemd/system/display-manager.service  "$SQUASHFS_DIR"/display-manager.service.backup
#        #rm -f "$SCRIPT_DIR"/etc/systemd/system/display-manager.service

verde "Reempaquetando filesystem.squashfs..."
mksquashfs "$SQUASHFS_DIR" "$EXTRACTDIR/casper/filesystem.squashfs" -noappend


#Personalizamos GRUB de la LiveCD ISO
#UEFI-
#Hacemos copia de seguridad del grub.cfg original
cp "$EXTRACTDIR/boot/grub/grub.cfg" "$EXTRACTDIR/boot/grub/grub.cfg.$(date +%Y%m%d-%H%M)).backup"
#Creo un nuevo grub.cfg
cat <<EOF-NUEVOGRUB > "$EXTRACTDIR/boot/grub/grub.cfg"
loadfont unicode
set color_normal=white/black
set color_highlight=black/light-gray
set timeout=5
set timeout_style=menu
set default=0
menuentry "Instalación 'ON FIRE!' - by Victor Muela  [vs $VERSION $(date +%Y%m%d-%H%M)]" --class linuxmint {
    set gfxpayload=keep
    linux   /casper/vmlinuz  boot=casper username=mint hostname=mint iso-scan/filename=${iso_path} quiet splash nomodeset -- 
    initrd  /casper/initrd.lz
}
grub_platform
if [ "$grub_platform" = "efi" ]; then
menuentry 'Boot from next volume' {
    exit 1
}
menuentry 'UEFI Firmware Settings' {
    fwsetup
}
menuentry 'Memory test' {
    linux   /boot/memtest.efi
}
fi
EOF-NUEVOGRUB
#BIOS - TODO: hacer algo similar para BIOS, indicando que hay un error en placa, que se debe arrancar en UEFI
#TODO!

verde "Creando nueva ISO personalizada..."
xorriso -as mkisofs -r -V "$NOMBREISOFINAL" \
    -cache-inodes -J -l \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -isohybrid-gpt-basdat \
    -o "$NOMBREISOFINAL.iso" "$EXTRACTDIR"
verde "ISO personalizada creada con éxito: $OUTPUT"

#mv $OUTPUT /mnt/hgfs/Shared/$OUTPUT

#Hacemos otra iso igual, pero sin mostrar progreso

# Limpieza
verde "Desmonto $EXTRACTDIR ..."
umount -l "$MOUNTDIR"
rm -rf "$WORKDIR"