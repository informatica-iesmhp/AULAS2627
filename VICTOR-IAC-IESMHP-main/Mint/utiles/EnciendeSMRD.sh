declare -A macs=(
    ["SMRD-00"]="bc:fc:e7:05:76:08"
    ["SMRD-01"]="08:bf:b8:40:09:82"
    ["SMRD-02"]="bc:fc:e7:05:73:d1"
    ["SMRD-03"]="bc:fc:e7:05:72:58"
    ["SMRD-04"]="bc:fc:e7:05:70:f8"
    ["SMRD-05"]="bc:fc:e7:05:71:4a"
    ["SMRD-06"]="bc:fc:e7:04:bb:57"
    ["SMRD-07"]="bc:fc:e7:05:71:60"
    ["SMRD-08"]="bc:fc:e7:05:72:e9"
    ["SMRD-09"]="bc:fc:e7:05:72:9a"
    ["SMRD-10"]="bc:fc:e7:04:bc:ed"
    ["SMRD-11"]="bc:fc:e7:05:73:47"
    ["SMRD-12"]="bc:fc:e7:05:73:cc"
    ["SMRD-13"]="bc:fc:e7:05:75:7e"
    ["SMRD-14"]="bc:fc:e7:05:73:63"
    ["SMRD-15"]="bc:fc:e7:05:73:c8"
    ["SMRD-16"]="bc:fc:e7:05:73:41"
    ["SMRD-17"]="bc:fc:e7:05:73:d0"
    ["SMRD-18"]="bc:fc:e7:05:73:d5"
)

for i in "${!macs[@]}"
do
   wakeonlan ${macs[$i]} >null
   echo "Llamando a $i -> ${macs[$i]}"
done
