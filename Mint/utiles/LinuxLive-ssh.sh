#Teclado español
setxkbmap es
#Actualizamos (borro source list para que no tire del cd)
rm /etc/apt/sources.list
#mv /etc/apt/sources.list /sources.list.bak
apt-get update
#Instalamos ssh y vmware-tools
apt-get install -y ssh open-vm-tools open-vm-tools-desktop
#creamusuario
echo "mint:mint" | chpasswd
#Nos quedamos con la IP de la máquina
ip a|grep inet|grep brd