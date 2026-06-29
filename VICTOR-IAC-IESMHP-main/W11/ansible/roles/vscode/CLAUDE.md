# Rol `vscode`

## Qué hace
Instala **Visual Studio Code** con Chocolatey (`vscode`), fijando `vscode_version`
(por defecto `1.125`). Pasa `/NoDesktopIcon` para no llenar el escritorio.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `vscode_version` (vaciar para la última).

## Notas
- Equivalente al rol `vscode` de Ubuntu (allí desde el `.deb` oficial). En Windows
  Choco ya usa el instalador oficial de Microsoft. Alternativa: winget
  `Microsoft.VisualStudioCode`.
- Las extensiones de VS Code son configuración **de usuario**: encajarían en una
  futura carpeta `rolesUsuario/` (como en Ubuntu).
