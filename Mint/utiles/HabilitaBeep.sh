lsmod | grep pcspkr || sudo modprobe pcspkr

#Comprobamos que el speaker existe
ls -l /dev/input/by-path/ | grep spkr
cat /proc/bus/input/devices | grep -A 5 -i pcspkr

#Añadimos el usuarios al grupo audio
sudo usermod -aG audio $USER

sudo apt-get install -y beep

beep -f440 -l 1000

#sudo modprobe pcspkr   

