declare -A macs=(
    ["IABD-00"]="d8:bb:c1:35:f1:dd"
    ["IABD-01"]="d8:bb:c1:38:71:6f"
    ["IABD-02"]="d8:bb:c1:38:93:ad"
    ["IABD-03"]="d8:bb:c1:38:94:25"
    ["IABD-04"]="d8:bb:c1:38:93:a2"
    ["IABD-05"]="d8:bb:c1:38:93:b1"
    ["IABD-06"]="d8:bb:c1:38:94:69"
    ["IABD-07"]="d8:bb:c1:38:93:e8"
    ["IABD-08"]="d8:bb:c1:38:93:8a"
    ["IABD-09"]="d8:bb:c1:38:93:ae"
    ["IABD-10"]="74:56:3C:65:62:C6"
    ["IABD-11"]="74:56:3C:65:5D:51"
    ["IABD-12"]="74:56:3C:65:60:7F"
    ["IABD-13"]="74:56:3C:95:EA:3C"
    ["IABD-14"]="74:56:3C:95:ED:21"
    ["IABD-15"]="74:56:3C:95:EB:55"
    ["IABD-16"]="74:56:3C:95:EC:10"
    ["IABD-17"]="74:56:3C:95:EB:87"
    ["IABD-18"]="74:56:3C:95:EA:81"
    ["IABD-19"]="74:56:3c:95:eb:d5"
    ["IABD-20"]="74:56:3c:95:eb:57"
)

for i in "${!macs[@]}"
do
   wakeonlan ${macs[$i]} >null
   echo "Llamando a $i -> ${macs[$i]}"
done

#Explicación (bing chat):
#En el código, ${!macs[@]} se utiliza para obtener todos los índices (o claves) del array asociativo macs.
#Aquí,
#->     ! se utiliza para indicar que queremos los índices en lugar de los valores.
#->     @ se utiliza para indicar que queremos todos los índices.
#
#Por lo tant#o, ${!macs[@]} dará una lista de todos los índices en el array asociativo macs.
#Luego, en el bucle for, i toma cada uno de estos índices en cada iteración del bucle.
#Así, puedes acceder tanto a la clave (el índice, que es el nombre de la máquina en este caso)
#como al valor (la dirección MAC correspondiente) en cada iteración del bucle.

