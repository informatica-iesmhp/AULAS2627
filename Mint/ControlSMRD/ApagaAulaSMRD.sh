ansible all -i equiposSMRD.ini -a "poweroff" -u root


#Trabajando en: 
#   ssh root@10.0.32.122 "R=\$(ss -Htn state established '( sport = :ssh or sport = :3389 )' | grep -v 10.0.32.119); if [ -z \"\$R\" ]; then echo 'sin conexiones'; poweroff; else echo \"\$R\"; fi"