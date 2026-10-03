<#
.SYNOPSIS
    Resolución y comprobación de ejecutables, entradas de arranque y
    accesos directos.

.DESCRIPTION
    Solo lectura: el programa nunca escribe en el registro. Lo usan los
    módulos 90-Arranque y 45-AccesosRotos.
#>

function Get-EjecutableDeComando {
    <#
    .SYNOPSIS
        Extrae la ruta del ejecutable de una línea de comandos.

    .DESCRIPTION
        Tres estrategias, en este orden:
          1. Ruta entre comillas -> se toma tal cual.
          2. Todo hasta el primer ".exe" de forma no ávida, lo que permite
             rutas con espacios sin comillas ("C:\Program Files\...").
          3. Sin extensión: se corta en el primer argumento con - o /.
        Siempre se expanden las variables de entorno.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Comando)

    if ([string]::IsNullOrWhiteSpace($Comando)) { return '' }
    $c = $Comando.Trim()

    # Rutas NT de servicios y controladores: "\??\C:\..." (prefijo del
    # gestor de objetos, no es ruta Win32) y "\SystemRoot\..." (raíz
    # simbólica de %SystemRoot%). Sin normalizarlas parecerían rotas.
    if ($c.StartsWith('\??\', [StringComparison]::Ordinal)) {
        $c = $c.Substring(4)
    } elseif ($c.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        # Concatenación y no Join-Path: Join-Path resuelve la unidad con el
        # proveedor de PowerShell y falla si "C:" no existe (p. ej. en Linux).
        $c = $env:SystemRoot.TrimEnd('\') + '\' + $c.Substring(12)
    }

    if ($c -match '^"([^"]+)"') {
        return [Environment]::ExpandEnvironmentVariables($Matches[1])
    }
    if ($c -match '^(.+?\.exe)') {
        return [Environment]::ExpandEnvironmentVariables($Matches[1])
    }
    $recortado = ($c -split '\s+[-/]')[0]
    return [Environment]::ExpandEnvironmentVariables($recortado.Trim())
}

function Test-EjecutableExiste {
    <#
    .SYNOPSIS
        Comprueba de tres maneras si un ejecutable existe.
    .DESCRIPTION
        Prueba la ruta tal cual, con .exe añadido y, si es un nombre suelto,
        por PATH. Muchos servicios se registran sin extensión y otros se
        resuelven por PATH.

        La búsqueda por PATH se limita a -CommandType Application: sin ese
        filtro, alias como "where", "sc" o "start" harían pasar por válida
        una entrada rota.

        Ante la duda responde que existe: es preferible no señalar una
        entrada rota a acusar de rota una legítima.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Ejecutable)

    # -PathType Leaf: una entrada que apunta a una carpeta no es un ejecutable.
    if ([string]::IsNullOrWhiteSpace($Ejecutable)) { return $true }
    if (Test-Path -LiteralPath $Ejecutable -PathType Leaf -ErrorAction SilentlyContinue)       { return $true }
    if (Test-Path -LiteralPath "$Ejecutable.exe" -PathType Leaf -ErrorAction SilentlyContinue) { return $true }

    # Solo se busca por PATH un nombre suelto: una ruta con carpeta que no
    # existe está rota.
    if ($Ejecutable -notmatch '[\\/]') {
        if (Get-Command $Ejecutable -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Get-EstadoArranque {
    <#
    .SYNOPSIS
        Lee si una entrada de arranque está activada según el Administrador
        de tareas.
    .DESCRIPTION
        Windows guarda el estado en StartupApproved como un byte[]: el bit 0
        del primer byte a cero significa activado.
    #>
    [CmdletBinding()]
    param()

    $resultado = @{}
    $claves = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    )

    foreach ($clave in $claves) {
        $valores = Get-ItemProperty -Path $clave -ErrorAction SilentlyContinue
        if ($null -eq $valores) { continue }
        $valores.PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' -and $_.Value -is [byte[]] } |
            ForEach-Object {
                $bytes = [byte[]]$_.Value
                if ($bytes.Length -gt 0) {
                    $resultado[$_.Name] = (($bytes[0] -band 1) -eq 0)
                }
            }
    }
    return $resultado
}

function Get-DestinoAccesoDirecto {
    <#
    .SYNOPSIS
        Resuelve el destino de un archivo .lnk.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        $Shell = $null
    )

    try {
        if ($null -eq $Shell) { $Shell = New-Object -ComObject WScript.Shell }
        return $Shell.CreateShortcut($Ruta).TargetPath
    } catch {
        return ''
    }
}
