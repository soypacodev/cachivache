<#
.SYNOPSIS
    Estado de la papelera de reciclaje de cada volumen, para no llamar
    "papelera" a un borrado que en realidad es definitivo.

.DESCRIPTION
    Si un archivo no cabe en la papelera (supera la cuota, la papelera está
    desactivada o el disco no la tiene), Windows lo borra permanentemente
    sin avisar y la llamada devuelve éxito igualmente. Este archivo permite
    saberlo de antemano para informar del destino real.

    Está dividido en dos partes:

      Get-EstadoPapelera   consulta Windows y devuelve datos.
      Test-CabeEnPapelera  cálculo puro; se prueba sin Windows.

    Dónde está la configuración:

    HKCU\...\Explorer\BitBucket\Volume\{GUID}
        MaxCapacity   tamaño máximo de la papelera del volumen, en MB
        NukeOnDelete  1 = sin papelera en ese volumen, todo es definitivo

    El {GUID} es el que devuelve Win32_Volume en DeviceID. La directiva
    HKLM\...\Policies\Explorer\NoRecycleFiles = 1 desactiva la papelera en
    todos los volúmenes.
#>

# Estado por unidad. Se guarda en caché porque la cuota no cambia mientras
# el programa está abierto y una limpieza puede consultarla miles de veces.
$script:CachePapelera = @{}

function Reset-CachePapelera {
    <#
    .SYNOPSIS
        Vacía la caché de estados de papelera (pruebas o cambio de
        configuración con el programa abierto).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo vacía una tabla en memoria.')]
    [CmdletBinding()]
    param()
    $script:CachePapelera = @{}
}

function New-EstadoPapelera {
    <#
    .SYNOPSIS
        Compone el estado de una papelera.

    .PARAMETER Disponible
        Si el volumen tiene papelera utilizable.
    .PARAMETER CapacidadBytes
        Capacidad admitida. 0 si no está disponible; -1 significa
        "desconocida", que no equivale a cero (ver Test-CabeEnPapelera).
    .PARAMETER Motivo
        Frase para el usuario. Se define aquí para que consola y ventana
        digan lo mismo.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo compone un objeto en memoria.')]
    [CmdletBinding()]
    param(
        [bool]   $Disponible     = $true,
        [double] $CapacidadBytes = -1,
        [string] $Motivo         = ''
    )

    return [pscustomobject]@{
        Disponible     = $Disponible
        CapacidadBytes = $CapacidadBytes
        Motivo         = $Motivo
    }
}

function Test-CabeEnPapelera {
    <#
    .SYNOPSIS
        Decide si algo de este tamaño iría realmente a la papelera.

    .DESCRIPTION
        Cálculo puro: no toca disco ni registro.

          1. Sin papelera en el volumen          -> no cabe (seguro).
          2. Con papelera y tamaño mayor que ella -> no cabe (seguro).
          3. Cuota desconocida                   -> cabe (no seguro).

        El caso 3 responde "cabe" a propósito: tratar lo desconocido como
        "no cabe" bloquearía borrados legítimos en equipos donde no se pueda
        leer el registro y empujaría al usuario a usar el borrado permanente.
        La incertidumbre queda anotada en el registro de actividad.

    .PARAMETER Bytes
        Tamaño de lo que se quiere borrar.
    .PARAMETER Estado
        Lo que devuelve Get-EstadoPapelera.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $Bytes,
        # AllowNull es necesario para que la guarda de $null de abajo llegue
        # a ejecutarse: sin él, el enlace de parámetros rechaza el nulo antes.
        [Parameter(Mandatory)] [AllowNull()] $Estado
    )

    if ($null -eq $Estado) {
        return [pscustomobject]@{ Cabe = $true; Seguro = $false; Motivo = '' }
    }

    if (-not $Estado.Disponible) {
        return [pscustomobject]@{
            Cabe   = $false
            Seguro = $true
            Motivo = $(if ([string]::IsNullOrWhiteSpace($Estado.Motivo)) {
                          'este disco no tiene papelera de reciclaje'
                       } else { $Estado.Motivo })
        }
    }

    # Capacidad desconocida: se deja pasar, pero sin garantizarlo.
    if ([double]$Estado.CapacidadBytes -lt 0) {
        return [pscustomobject]@{ Cabe = $true; Seguro = $false; Motivo = '' }
    }

    if ($Bytes -gt [double]$Estado.CapacidadBytes) {
        return [pscustomobject]@{
            Cabe   = $false
            Seguro = $true
            Motivo = ('ocupa {0} y la papelera de este disco admite {1}' -f
                      (Format-Tamano $Bytes), (Format-Tamano $Estado.CapacidadBytes))
        }
    }

    return [pscustomobject]@{ Cabe = $true; Seguro = $true; Motivo = '' }
}

function Get-GuidVolumen {
    <#
    .SYNOPSIS
        Nombre de volumen ({GUID}) de una letra de unidad, tal como lo usa
        el registro.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Unidad)

    $letra = $Unidad.TrimEnd('\', '/')
    if ($letra.Length -eq 1) { $letra = $letra + ':' }

    try {
        $volumen = Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop |
                   Where-Object { $_.DriveLetter -eq $letra } |
                   Select-Object -First 1
        if ($null -eq $volumen) { return '' }

        # DeviceID tiene la forma \\?\Volume{guid}\; el registro usa {guid}.
        if ($volumen.DeviceID -match '(\{[0-9a-fA-F-]+\})') { return $matches[1] }
        return ''
    } catch {
        return ''
    }
}

function Get-EstadoPapelera {
    <#
    .SYNOPSIS
        Devuelve si la unidad tiene papelera y cuánto admite.

    .DESCRIPTION
        Consulta la directiva de grupo, Win32_LogicalDisk, Win32_Volume y el
        registro. Lo que no se puede averiguar se devuelve como -1, nunca
        como 0 (que bloquearía todos los borrados). Fuera de Windows
        devuelve siempre "desconocido".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Unidad)

    $letra = $Unidad.TrimEnd('\', '/')
    if ($letra.Length -eq 1) { $letra = $letra + ':' }
    $clave = $letra.ToUpperInvariant()

    if ($script:CachePapelera.ContainsKey($clave)) { return $script:CachePapelera[$clave] }

    $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes -1

    try {
        # 1. La directiva tiene prioridad sobre todo lo demás.
        $politica = Get-ItemProperty -ErrorAction SilentlyContinue `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
        if ($politica -and [int]$politica.NoRecycleFiles -eq 1) {
            $estado = New-EstadoPapelera -Disponible $false -CapacidadBytes 0 `
                        -Motivo 'la papelera está desactivada por directiva del sistema'
            $script:CachePapelera[$clave] = $estado
            return $estado
        }

        # 2. Solo los discos fijos (DriveType 3) tienen papelera; en red o
        #    USB, enviar a la papelera equivale a borrar.
        $unidadInfo = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
                      Where-Object { $_.DeviceID -eq $clave } | Select-Object -First 1
        if ($unidadInfo -and [int]$unidadInfo.DriveType -ne 3) {
            $estado = New-EstadoPapelera -Disponible $false -CapacidadBytes 0 `
                        -Motivo 'este disco no es fijo, y solo los discos fijos tienen papelera'
            $script:CachePapelera[$clave] = $estado
            return $estado
        }

        # 3. Cuota del volumen.
        $guid = Get-GuidVolumen -Unidad $clave
        if (-not [string]::IsNullOrWhiteSpace($guid)) {
            $ruta = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\' + $guid
            $cfg  = Get-ItemProperty -Path $ruta -ErrorAction SilentlyContinue
            if ($cfg) {
                if ([int]$cfg.NukeOnDelete -eq 1) {
                    $estado = New-EstadoPapelera -Disponible $false -CapacidadBytes 0 `
                                -Motivo ('la papelera está desactivada en {0}' -f $clave)
                } elseif ($null -ne $cfg.MaxCapacity) {
                    # MaxCapacity está en MB.
                    $estado = New-EstadoPapelera -Disponible $true `
                                -CapacidadBytes ([double]$cfg.MaxCapacity * 1MB)
                }
            }
        }
    } catch {
        # Desconocido a propósito (ver Test-CabeEnPapelera).
        $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes -1
    }

    $script:CachePapelera[$clave] = $estado
    return $estado
}

function Test-IraAPapelera {
    <#
    .SYNOPSIS
        Indica si un elemento acabaría en la papelera o se borraría de forma
        permanente.

    .DESCRIPTION
        Combina Get-EstadoPapelera y Test-CabeEnPapelera en la consulta que
        necesita Remove.ps1.

    .PARAMETER Ruta
        Ruta del elemento; de ella se obtiene la unidad.
    .PARAMETER Bytes
        Tamaño ya medido, para no volver a recorrer árboles grandes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [Parameter(Mandatory)] [double] $Bytes
    )

    $unidad = ''
    if ($Ruta -match '^([A-Za-z]):') { $unidad = $matches[1] + ':' }
    if ([string]::IsNullOrWhiteSpace($unidad)) {
        # Las rutas UNC no tienen papelera.
        if ($Ruta.StartsWith('\\')) {
            return [pscustomobject]@{
                Cabe = $false; Seguro = $true
                Motivo = 'está en una carpeta de red, y la red no tiene papelera'
            }
        }
        return [pscustomobject]@{ Cabe = $true; Seguro = $false; Motivo = '' }
    }

    return Test-CabeEnPapelera -Bytes $Bytes -Estado (Get-EstadoPapelera -Unidad $unidad)
}

function Get-TextosDestinoBorrado {
    <#
    .SYNOPSIS
        Devuelve el nombre del destino de un borrado y el rótulo del botón
        que lo lanza.

    .DESCRIPTION
        Ambos textos salen de aquí para que el diálogo de confirmación no
        pueda mostrar "Papelera de reciclaje" junto a un botón "Eliminar
        definitivamente" (o al revés). Mismo patrón que Get-MotivoNoSeBorra
        y Test-DebeVenirMarcado.

        El subtítulo del diálogo ("Esta acción no la puede deshacer el
        programa") es correcto en ambos casos: desde la papelera la
        restaura el usuario, no el programa.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch] $Permanente)

    if ($Permanente) {
        return [pscustomobject]@{
            Destino = 'Borrado permanente'
            Boton   = 'Eliminar definitivamente'
            Palabra = 'ELIMINAR'
        }
    }
    return [pscustomobject]@{
        Destino = 'Papelera de reciclaje'
        Boton   = 'Enviar a la papelera'
        Palabra = 'SI'
    }
}
