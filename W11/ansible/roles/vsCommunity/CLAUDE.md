# Rol `vsCommunity`

## Qué hace
Instala **Visual Studio Community** con Chocolatey. Por defecto el IDE base, sin
cargas de trabajo (workloads).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `vscommunity_choco_name`, `vscommunity_params` (workloads).

## Notas / TODO
- La lista dice **"Community 26"**. El paquete estable hoy es
  `visualstudio2022community`; cuando salga el de 2026 cambiar
  `vscommunity_choco_name` a `visualstudio2026community`.
- Para instalar cargas de trabajo (p.ej. desarrollo .NET de escritorio, C++…),
  rellenar `vscommunity_params` con los `--add Microsoft.VisualStudio.Workload.*`.
- Es una instalación grande (varios GB): la primera pasada tarda. Alternativa:
  winget `Microsoft.VisualStudio.2022.Community`.
