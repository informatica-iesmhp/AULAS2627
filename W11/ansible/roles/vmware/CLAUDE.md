# Rol `vmware`

## Qué hace
Instala **VMware Workstation Pro** con Chocolatey. Gratuito para uso
personal/educativo desde 2024 (antes de pago).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `vmware_choco_name` (`vmware-workstation`), `vmware_version`.

## Notas / TODO
- **Verificar el id del paquete**: según versión, en Choco ha sido
  `vmware-workstation` o `vmwareworkstation`. Ajustar `vmware_choco_name` si falla.
- La versión de la lista es **"25 H2 U1"**; las versiones de Choco son numéricas, así
  que por defecto se instala la última del paquete. Fija `vmware_version` a un build
  concreto si lo necesitas.
- En Ubuntu el rol `vmware` está **comentado** (falla la compilación del módulo en
  el primer arranque); en Windows no hay ese problema.
