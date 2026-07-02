declare -A macs=(
    ["IABD-00"]="d8:bb:c1:35:f1:dd"
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

echo "Esperamos 60 sg a que arranquen las máquinas..."
sleep 60
echo "Arrancamos las máquinas Windows...."
#ssh 10.0.72.120 "/ControlAula/SBD-ArrancaW11victor.sh"
