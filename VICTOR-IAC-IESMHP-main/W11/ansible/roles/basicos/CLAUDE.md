# Rol `basicos`

## Qué hace
Comprobaciones base que el resto de roles dan por hechas (equivalente Windows del
`basicos` de Ubuntu, que aseguraba python/pip/pipx/ansible):

1. Asegura el proveedor **NuGet** de PowerShell (necesario para `Install-Module`/Choco).
2. Comprueba que **winget** (App Installer) responde y **avisa** si no está (algún
   rol puntual lo usa como alternativa a Chocolatey).

## Estructura
- `tasks/main.yml` — sin `defaults/`.

## Notas
- No instala software de usuario; solo deja el equipo listo para los demás roles.
- Chocolatey se asegura en su propio rol (`chocolatey`), que va antes.
