#!/bin/bash
#"set -e" significa que el script se detendrá si ocurre un error
set -e
VERSIONSCRIPT="22.1-20260126-09:55"       #Versión del script
REPO="IAC-IESMHP"
DISTRO="Mint"
versionDISTRO=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
RAIZSCRIPTS="/opt/$REPO"
RAIZDISTRO="$RAIZSCRIPTS/$DISTRO/ISO/$versionDISTRO"
RAIZLOG="/var/log/$REPO/$DISTRO"
SCRIPT3="3-SetupPrimerInicio.sh"

# Funciones de colores
echoverde() {
    echo -e "\033[32m$1\033[0m" 
}
echorojo()  {
      echo -e "\033[31m$1\033[0m" 
}  
echoamarillo() {  
    echo -e "\033[33m$1\033[0m" 
}

echoverde "$0 (vs$VERSIONSCRIPT)"

#Idioma y teclado español
echoamarillo "Configurando el entorno gráfico en español..."
sed -i 's/# es_ES.UTF-8/es_ES.UTF-8/g' /etc/locale.gen
locale-gen es_ES.UTF-8

# Set system-wide locale defaults
echo "LANG=es_ES.UTF-8" > /etc/default/locale
echo "LC_ALL=es_ES.UTF-8" >> /etc/default/locale
echo "LANGUAGE=es_ES" >> /etc/default/locale

# Configure keyboard for Spanish layout
echo "XKBLAYOUT=es" > /etc/default/keyboard
echo "XKBMODEL=pc105" >> /etc/default/keyboard
echo "XKBVARIANT=" >> /etc/default/keyboard
echo "XKBOPTIONS=" >> /etc/default/keyboard

# Configure Cinnamon desktop environment for Spanish
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-language << EOF
[org/gnome/desktop/input-sources]
sources=[('xkb', 'es')]
xkb-options=[]

[org/gnome/system/locale]
region='es_ES.UTF-8'
EOF

# Update dconf
# dconf es un sistema de configuración basado en claves utilizado en GNOME y otras aplicaciones.
# El comando 'dconf update' actualiza la base de datos del sistema con los cambios realizados en la configuración.
# Si el comando falla durante la ejecución del script (por ejemplo, porque no hay un entorno gráfico activo),
# se muestra un mensaje indicando que los cambios de configuración se aplicarán en el primer inicio de sesión.
# Esto es común cuando se configura un sistema desde un LiveCD o en entornos de preinstalación.
dconf update 2>/dev/null || echo "dconf se aplicará en el primer inicio"

echo && echo && echoverde "....Configurado entorno en español"  

# Configure fstab

echoamarillo "Configurando /etc/fstab..."
# Detectar particiones y asignar variables
EFI=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/boot/efi" {print $1}')
SWAP=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "[SWAP]" {print $1}')
ROOT=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/" {print $1}')
HOME=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/home" {print $1}')
#HOME=$(lsblk | grep ─ | grep -v SWAP | grep -v efi | grep -v '/' | awk '{gsub(/^[^a-zA-Z0-9]*/, "", $1); print $1}')
echo "EFI= $EFI SWAP= $SWAP ROOT= $ROOT HOME= $HOME"

cat > /etc/fstab << EOF
# /etc/fstab
UUID=$(blkid -s UUID -o value "/dev/$ROOT") / ext4 defaults 0 1
UUID=$(blkid -s UUID -o value "/dev/$EFI") /boot/efi vfat umask=0077 0 1
UUID=$(blkid -s UUID -o value "/dev/$HOME") /home ext4 defaults 0 2
UUID=$(blkid -s UUID -o value "/dev/$SWAP") none swap sw 0 0
EOF
cat /etc/fstab
echo && echo && echoverde "...Configurado /etc/fstab"  

#Para si no reponde un ping a 1.1.1.1, pausar la instalación, y vuelve a comprobar en bucle
while ! ping -c 1 1.1.1.1; do
    echo "No se puede acceder a Internet. Pausando la instalación."
    read -p "Presione Enter para continuar..."
done


# Remove live-specific packages and configurations
echoamarillo "Eliminando paquetes innecesarios..."
#apt-get update
apt-get remove -y --purge casper ubiquity ubiquity-frontend-* live-boot live-boot-initramfs-tools 
echoverde "...Eliminados paquetes innecesarios..."  

echoamarillo "Averiguando MAC y autorizando equipos de gestión por SSH..."
MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
mkdir -p /root/.ssh
LOCAL_MACS="$RAIZSCRIPTS/macs.csv"
LOCAL_AUTORIZADOS="$RAIZSCRIPTS/Autorizados.txt"
cp $LOCAL_AUTORIZADOS /root/.ssh/authorized_keys
echoverde "...Leida Mac y autorizados equipos de gestión por SSH"

# Compruebo si la MAC está en el repositorio: si no está, se queda el nombre del equipo por defecto "mint"
EQUIPOENMACS="mint"
if [ ! -f $LOCAL_MACS ]; then
    echorojo "No se ha encontrado el archivo de MACs: $LOCAL_MACS"
    echo "Por favor, compruebe la conexión a Internet y que el archivo está disponible en el repositorio."
else
    # Compruebo si la MAC está en el repositorio
    if ! grep -q -i "$MAC" "$LOCAL_MACS"; then
        echorojo "La MAC $MAC no se encuentra en el repositorio."
        echo            "Por favor, compruebe la conexión a Internet y que la MAC está registrada en el repositorio."
    else
        INFO_MACS=$(cat $LOCAL_MACS | grep -i $MAC )
        #Sustituyo el contenido de $LOCAL_MACS por la información de la MAC
        echo "Información de la MAC: $INFO_MACS"
        echo "$INFO_MACS" > $LOCAL_MACS
        #Si se encuentra la MAC, extraigo el nombre del equipo
        EQUIPOENMACS=$(echo $INFO_MACS | cut -d',' -f2 | xargs)
    fi
fi

EQUIPOACTUAL=$(hostname)
if [ "$EQUIPOACTUAL" != "$EQUIPOENMACS" ]; then
    echo "Equipo identificado: '$EQUIPOENMACS'  Nombre actual del equipo: '$EQUIPOACTUAL'"    
    #Cambio el nombre del equipo a $EQUIPOENMACS
    echo "Renombrando el equipo a: $EQUIPOENMACS"
    echo "$EQUIPOENMACS" > /etc/hostname
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "127.0.1.1 $EQUIPOENMACS" >> /etc/hosts
    hostnamectl set-hostname "$EQUIPOENMACS"
else
    echo "El nombre del equipo ya es correcto: '$EQUIPOENMACS'" 
fi


# Set up users
echoverde "Configurando usuarios..."
echo "root:root" | chpasswd
useradd -m -s /bin/bash usuario
echo "usuario:usuario" | chpasswd
adduser usuario sudo
# si existe /root/.ssh/authorized_keys, lo copio a /home/usuario/.ssh/authorized_keys
if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p /home/usuario/.ssh
    cp /root/.ssh/authorized_keys /home/usuario/.ssh/
    chown usuario:usuario /home/usuario/.ssh/authorized_keys
    chmod 600 /home/usuario/.ssh/authorized_keys
fi
echo && echo && echoverde "...Configurado nombre de host y usuarios" 

# Install and configure bootloader
echoverde "Instalando y configurando el gestor de arranque..."
################################################################apt-get install -y grub-efi-amd64
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=MINT

#17/06/2025:  al actualizar linux mint 22.1, se quedaba la pantalla negra al arrancar.
# Por eso añadí la opción "nomodeset" al grub, para que arranque sin problemas gráficos.
    # nomodeset: Esta opción del kernel desactiva el sistema de gestión de modo de vídeo durante el arranque.
    # Es útil cuando hay problemas gráficos al iniciar el sistema, como pantallas negras o congeladas.
    # Al usar nomodeset, el kernel utiliza el modo BIOS básico en lugar de controladores de gráficos modernos,
    # lo que puede permitir el arranque en sistemas con tarjetas gráficas problemáticas o drivers incompatibles.
    # Comúnmente utilizada como solución temporal hasta instalar los controladores gráficos adecuados.
    # IMPORTANTE: Una vez instalados los controladores gráficos correctos, se recomienda quitar esta opción 
    # editando /etc/default/grub y eliminando "nomodeset" del parámetro GRUB_CMDLINE_LINUX_DEFAULT, 
    # seguido de ejecutar 'sudo update-grub' para aplicar los cambios.
#con full-upgrade parece que funciona sin problemas, así que quito nomodeset, pero lo dejo comentado
#sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nomodeset"/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash "/' /etc/default/grub
grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub || echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub

update-grub
echo && echo && echoverde "...Instalado y configurado el gestor de arranque ( sin nomodeset! si hubiera problemas gráficos, añadirlo manualmente en /etc/default/grub)" 

# Generate new machine-id
echo "Generando nuevo machine-id..."
rm -f /etc/machine-id
dbus-uuidgen > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
echo && echo && echo "..Generada  machine-id" 

# Update initramfs
echoverde "Actualizando initramfs (lo que hace que el sistema arranque)..."
update-initramfs -u -k all
echo && echo && echoverde "...Actualizado initramfs" 

#Paso 3 : servicio de actualización en primer arranque
#Compruebo que existe el script de actualización en primer arranque
if [ ! -f "$RAIZDISTRO/$SCRIPT3" ]; then
    echorojo "No se encontró el script de actualización en primer arranque: $RAIZDISTRO/$SCRIPT3"
    sleep 10 && exit 1
fi  
#------------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------------
# Creo un servicio para actualizar el sistema en el primer arranque
echo "Configurando servicio de actualización en primer arranque..."
chmod +x "$RAIZDISTRO/$SCRIPT3"
#------------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------------


# Creo una variable con el contenido del servicio
CONTENIDOSERVICIO="[Unit]
Description=3-SetupPrimerInicio
DefaultDependencies=no
Wants=network-online.target
After=network-online.target graphical.target
Conflicts=shutdown.target

[Service]
Type=always
Environment=LC_ALL=es_ES.UTF-8
ExecStart=sudo /bin/bash $RAIZDISTRO/$SCRIPT3 
StandardOutput=append: $RAIZLOG/$SCRIPT3.log
StandardError=append: $RAIZLOG/$SCRIPT3.log
TimeoutSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

#Vuelco la variable $CONTENIDOSERVICIO en el fichero /etc/systemd/system/3-SetupPrimerInicio.service
echo "$CONTENIDOSERVICIO" > /etc/systemd/system/3-SetupPrimerInicio.service
# Habilito el servicio
systemctl enable 3-SetupPrimerInicio.service
echo && echo && echoverde "...Servicio de actualización en primer arranque configurado." 
echo $CONTENIDOSERVICIO
echo && echo "Correcto"
