
# Fichero de HOSTS por defecto /etc/ansible/hosts.
#Usaremos un fichero de inventorio propio.  equiposSMRD.ini

#Ejemplos de comandos ansible
#Usando módulos propios

ansible all -i equiposSMRD.ini -m ping -u root  #Ping (comprueba conectividad)
ansible all -i equiposSMRD.ini -m ping -u root --limit=SMRD-00,SMRD-01  #Ping (comprueba conectividad) a equipos en concreto
ansible all -i equiposSMRD.ini -m reboot -u root  --forks=50                               #Reinicia equipos de alumnos
ansible all -i equiposSMRD.ini -m community.general.shutdown -u root  #Apaga equipos de alumnos
ansible all -i equiposSMRD.ini -m copy -a "src=[rutaorigen] dest=[rutadestino]" --forks=2  #Para copiar un fichero a to>
#Ejecutando un comando linux
ansible all -i equiposSMRD.ini -a "df -a" -u root  #Comprueba la memoria de todos
ansible all -i equiposSMRD.ini -a "timedatectl set-timezone Europe/Madrid && timedatectl set-ntp true" -u root  #Compru>
#Ejemplo de instalación a todos de (por comandos: lo lógico sería hacer un playbook)
sudo ansible all -a "add-apt-repository ppa:serge-rider/dbeaver-ce" -u root  --forks=50
sudo ansible all -a "apt-get update" -u root  --forks=50
sudo ansible all -a "apt-get install dbeaver-ce -y" -u root  --forks=50




