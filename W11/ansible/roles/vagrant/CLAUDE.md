# Rol `vagrant`

## Qué hace
Instala **HashiCorp Vagrant** con Chocolatey (`vagrant`). Sin versión fija. Avisa
de que tras instalarse suele hacer falta **reiniciar** para que el `PATH` quede listo.

## Estructura
- `tasks/main.yml` — sin `defaults/`.

## Notas
- Vagrant necesita un proveedor (VirtualBox o VMware), que instalan los roles
  `virtualbox` / `vmware`. Para el proveedor VMware hace falta además el plugin
  `vagrant-vmware-desktop` y su utility (no incluido aquí).
- En Ubuntu Vagrant está pendiente (rol `hashicorp` en el "por hacer").
