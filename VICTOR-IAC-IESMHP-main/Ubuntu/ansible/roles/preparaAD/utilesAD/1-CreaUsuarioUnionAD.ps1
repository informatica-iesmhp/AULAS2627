<#
.SYNOPSIS
    Prepara en Active Directory la cuenta delegada para unir equipos Linux
    al dominio (pareja del rol Ansible preparaAD de IAC-IESMHP).

.DESCRIPTION
    EJECUTAR EN UN CONTROLADOR DE DOMINIO (o equipo con RSAT y el modulo
    ActiveDirectory) con permisos de administrador del dominio.

    Es IDEMPOTENTE; hace tres cosas:
      1. OU "ComputersLinux": si no existe la crea en la raiz del
         dominio, protegida contra borrado accidental.
      2. Usuario "svc-union-linux": si no existe lo crea (cuenta normal, SIN
         grupos privilegiados, PasswordNeverExpires). En ambos casos
         establece/resetea su contrasena — es el UNICO dato que pide el
         script.
      3. Delegacion MINIMA sobre la OU para que la cuenta pueda
         EXCLUSIVAMENTE unir y sacar equipos del dominio dentro de esa OU:
           - Crear objetos EQUIPO (en la OU y sub-OUs)  -> unir equipos.
           - Borrar objetos EQUIPO (en la OU y sub-OUs) -> sacar equipos
             (4-SacaDelDominio.sh / realm leave). Acotado a ESTA OU: si la
             cuenta se filtrara, solo podria dar de alta/baja equipos aqui.
           - Sobre los equipos descendientes: Reset Password, escritura
             validada de dNSHostName y servicePrincipalName, y
             lectura/escritura del property set "Account Restrictions".
         Comprueba ACE a ACE y solo anade las que falten.

    Los valores por defecto (usuario de union y nombre de OU) se leen del
    UNICO punto de cambio del entorno: ..\entornoAD.yml (el mismo fichero que
    usa el rol Ansible y los scripts de utilesAD/), si esta presente junto al
    repo; si no, caen a los literales svc-union-linux / ComputersLinux. El
    DOMINIO no se lee de ahi: se autodetecta del DC con Get-ADDomain (asi el
    script vale para cualquier dominio sin tocarlo). Tras ejecutar esto,
    generar el vault con 2-CreaVault.sh (misma contrasena).

    (Sin tildes a proposito: PowerShell 5.1 lee UTF-8 sin BOM como ANSI.)

.EXAMPLE
    .\1-CreaUsuarioUnionAD.ps1
    .\1-CreaUsuarioUnionAD.ps1 -Usuario otro-svc -NombreOU OtraOU
#>
#Requires -Modules ActiveDirectory
[CmdletBinding()]
param(
    [string]$Usuario,
    [string]$NombreOU
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory   # crea tambien la unidad AD: para Get/Set-Acl

# ---------------------------------------------------------------------------
# Defaults desde el UNICO punto de cambio (..\entornoAD.yml), si no se pasaron
# por parametro. Si el fichero no esta (script copiado suelto al DC), caen a
# los literales. El dominio NO sale de aqui: se autodetecta abajo con Get-ADDomain.
# ---------------------------------------------------------------------------
$entornoYml = Join-Path (Split-Path $PSScriptRoot -Parent) 'entornoAD.yml'
function Get-EntornoValor {
    param([string]$Clave, [string]$PorDefecto)
    if (Test-Path $entornoYml) {
        foreach ($linea in Get-Content -LiteralPath $entornoYml) {
            if ($linea -match "^\s*$Clave\s*:\s*[`"']?([^`"'#]+?)[`"']?\s*(#.*)?$") {
                return $Matches[1].Trim()
            }
        }
    }
    return $PorDefecto
}
if (-not $PSBoundParameters.ContainsKey('Usuario'))  { $Usuario  = Get-EntornoValor 'preparaad_usuario_union' 'svc-union-linux' }
if (-not $PSBoundParameters.ContainsKey('NombreOU')) { $NombreOU = Get-EntornoValor 'preparaad_nombre_ou'     'ComputersLinux' }

function ConvertFrom-SecureStringPlain {
    param([securestring]$Seguro)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Seguro)
    try     { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$dominio   = Get-ADDomain
$dnDominio = $dominio.DistinguishedName
$dnOU      = "OU=$NombreOU,$dnDominio"

Write-Host "Dominio : $($dominio.DNSRoot)  ($dnDominio)"
Write-Host "OU      : $dnOU"
Write-Host "Usuario : $Usuario"
Write-Host ""

# ---------------------------------------------------------------------------
# 0. Contrasena a establecer (UNICA pregunta del script)
# ---------------------------------------------------------------------------
$pwd1 = Read-Host -Prompt "Contrasena a establecer a '$Usuario'" -AsSecureString
$pwd2 = Read-Host -Prompt "Repite la contrasena" -AsSecureString
$plano = ConvertFrom-SecureStringPlain $pwd1
if ($plano -ne (ConvertFrom-SecureStringPlain $pwd2)) { throw "Las contrasenas no coinciden." }
if ($plano.Length -eq 0) { throw "La contrasena no puede estar vacia." }
# El rol preparaAD interpola la contrasena en una orden shell entre comillas
# simples: una comilla simple la romperia.
if ($plano.Contains("'")) { throw "La contrasena no puede contener comillas simples (limitacion del rol preparaAD)." }
$plano = $null

# ---------------------------------------------------------------------------
# 1. OU (crearla si no existe)
# ---------------------------------------------------------------------------
try {
    $null = Get-ADOrganizationalUnit -Identity $dnOU
    Write-Host "[OK ] La OU ya existe: $dnOU"
}
catch {
    New-ADOrganizationalUnit -Name $NombreOU -Path $dnDominio `
        -ProtectedFromAccidentalDeletion $true `
        -Description "Cuentas de equipo Linux unidas automaticamente (IAC-IESMHP, rol preparaAD)"
    Write-Host "[OK ] OU creada: $dnOU"
}

# ---------------------------------------------------------------------------
# 2. Usuario (crearlo si no existe) + contrasena
# ---------------------------------------------------------------------------
$cuenta = Get-ADUser -LDAPFilter "(sAMAccountName=$Usuario)"
if (-not $cuenta) {
    $cuenta = New-ADUser -Name $Usuario -SamAccountName $Usuario `
        -UserPrincipalName "$Usuario@$($dominio.DNSRoot)" `
        -AccountPassword $pwd1 -Enabled $true `
        -PasswordNeverExpires $true -CannotChangePassword $true `
        -KerberosEncryptionType AES128,AES256 `
        -Description "Cuenta delegada SOLO para unir equipos Linux a la OU $NombreOU (IAC-IESMHP, rol preparaAD)" `
        -PassThru
    Write-Host "[OK ] Usuario '$Usuario' creado (sin grupos privilegiados) y contrasena establecida."
}
else {
    Set-ADAccountPassword -Identity $cuenta -Reset -NewPassword $pwd1
    if (-not $cuenta.Enabled) { Enable-ADAccount -Identity $cuenta }
    Set-ADUser -Identity $cuenta -PasswordNeverExpires $true
    Write-Host "[OK ] El usuario '$Usuario' ya existia: contrasena reseteada (y cuenta habilitada)."
}

# ---------------------------------------------------------------------------
# 3. Delegacion minima de union sobre la OU (solo las ACE que falten)
# ---------------------------------------------------------------------------
# GUIDs bien conocidos del esquema de AD:
$guidEquipo   = [Guid]'bf967a86-0de6-11d0-a285-00aa003049e2'  # clase: computer
$guidResetPwd = [Guid]'00299570-246d-11d0-a768-00aa006e0529'  # extended right: Reset Password
$guidDnsHost  = [Guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd'  # validated write: dNSHostName
$guidSpn      = [Guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'  # validated write: servicePrincipalName
$guidAcctRest = [Guid]'4c164200-20c0-11d0-a768-00aa006e0529'  # property set: Account Restrictions

$sid = $cuenta.SID
$nt  = $sid.Translate([System.Security.Principal.NTAccount]).Value

$tipo  = [System.Security.AccessControl.AccessControlType]::Allow
$herAll  = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
$herDesc = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents

$reglas = @(
    # Crear objetos EQUIPO en la OU (y sub-OUs) — unir equipos (3-UneAlDominio.sh).
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::CreateChild, $tipo, $guidEquipo, $herAll)),
    # Borrar objetos EQUIPO de la OU (y sub-OUs) — sacar equipos del dominio
    # (4-SacaDelDominio.sh / realm leave). Mismo patron que CreateChild: el
    # permiso de borrado queda ACOTADO a los equipos de ESTA OU (delegacion
    # estandar "crear/borrar cuentas de equipo"). No alcanza a otras OUs.
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild, $tipo, $guidEquipo, $herAll)),
    # Sobre los objetos EQUIPO descendientes de la OU:
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight, $tipo, $guidResetPwd, $herDesc, $guidEquipo)),
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::Self, $tipo, $guidDnsHost, $herDesc, $guidEquipo)),
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::Self, $tipo, $guidSpn, $herDesc, $guidEquipo)),
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, ([System.DirectoryServices.ActiveDirectoryRights]::ReadProperty -bor
               [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty), $tipo, $guidAcctRest, $herDesc, $guidEquipo))
)

function Test-ReglaPresente {
    param($Acl, $Regla, $Cuenta)
    foreach ($ace in $Acl.Access) {
        if ($ace.IdentityReference.Value   -ne $Cuenta)                     { continue }
        if ($ace.AccessControlType         -ne $Regla.AccessControlType)    { continue }
        if ($ace.ActiveDirectoryRights     -ne $Regla.ActiveDirectoryRights){ continue }
        if ($ace.ObjectType                -ne $Regla.ObjectType)           { continue }
        if ($ace.InheritedObjectType       -ne $Regla.InheritedObjectType)  { continue }
        return $true
    }
    return $false
}

$rutaAcl = "AD:\$dnOU"
$acl = Get-Acl -Path $rutaAcl
$nuevas = 0
foreach ($regla in $reglas) {
    if (-not (Test-ReglaPresente -Acl $acl -Regla $regla -Cuenta $nt)) {
        $acl.AddAccessRule($regla)
        $nuevas++
    }
}
if ($nuevas -gt 0) {
    Set-Acl -Path $rutaAcl -AclObject $acl
    Write-Host "[OK ] Delegacion aplicada sobre la OU ($nuevas ACE nuevas de $($reglas.Count))."
}
else {
    Write-Host "[OK ] La delegacion ya estaba completa (0 cambios)."
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================"
Write-Host " Listo. '$nt' SOLO puede unir y sacar equipos del dominio en:"
Write-Host "   $dnOU"
Write-Host " (crear/borrar equipos + reset password/validated writes;"
Write-Host "  sin grupos privilegiados, sin permisos fuera de la OU)."
Write-Host ""
Write-Host " Siguiente paso (en el equipo del profesor, Linux):"
Write-Host "   utilesAD/2-CreaVault.sh   (misma contrasena que acabas de teclear)"
Write-Host ""
Write-Host " Auditoria manual de la delegacion:  dsacls `"$dnOU`""
Write-Host "================================================================"
