# Rol `obs`

## Qué hace
Instala **OBS Studio** con Chocolatey (`obs-studio`), fijando `obs_version`
(por defecto `32.1.2`).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `obs_version` (vaciar para la última).

## Notas
- Equivalente al rol `obs` de Ubuntu (allí desde apt). Alternativa: winget
  `OBSProject.OBSStudio`.
