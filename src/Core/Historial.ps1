<#
.SYNOPSIS
    Historial persistente de ejecuciones.

.DESCRIPTION
    Una entrada por ejecución, en JSON, para mostrar la evolución del
    espacio recuperado. Se conservan las cien últimas.

    No confundir con el registro de actividad (Log.ps1): una línea por
    acción, rotado por meses. El historial se reescribe entero al terminar.
#>

function Get-RutaHistorial {
    [OutputType([string])]
    param([string] $CarpetaDatos = (Get-CarpetaDatos))
    return (Join-Path $CarpetaDatos 'historial.json')
}

function Get-Historial {
    <#
    .SYNOPSIS
        Lee el historial de ejecuciones anteriores como una lista plana
        de entradas.

    .DESCRIPTION
        En Windows PowerShell 5.1, ConvertFrom-Json devuelve un array JSON
        como un único Object[] en lugar de enumerarlo (PowerShell 6+ sí lo
        enumera). Se aplana a mano para obtener el mismo resultado en
        ambas versiones. Con una sola entrada el JSON es un objeto suelto,
        no un array.
    #>
    [CmdletBinding()]
    param([string] $CarpetaDatos = (Get-CarpetaDatos))

    $lectura = Read-ArchivoHistorial -Ruta (Get-RutaHistorial -CarpetaDatos $CarpetaDatos)
    return $lectura.Entradas
}

function Read-ArchivoHistorial {
    <#
    .SYNOPSIS
        Lee historial.json y dice si se ha podido interpretar.
    .OUTPUTS
        Objeto con Entradas (array plano) e Ilegible ($true si el archivo
        existe, no está vacío y no es JSON válido).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Ruta)

    $resultado = [pscustomobject]@{ Entradas = @(); Ilegible = $false }
    if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) { return $resultado }
    try {
        $contenido = Get-Content -LiteralPath $Ruta -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($contenido)) { return $resultado }

        $datos = ConvertFrom-Json -InputObject $contenido -ErrorAction Stop
        $entradas = [Collections.Generic.List[object]]::new()
        foreach ($elemento in @($datos)) {
            if ($null -eq $elemento) { continue }
            # Una cadena es enumerable pero no se parte; las entradas
            # (PSCustomObject) van siempre al else.
            if ($elemento -is [System.Collections.IEnumerable] -and $elemento -isnot [string]) {
                foreach ($sub in $elemento) { if ($null -ne $sub) { $entradas.Add($sub) } }
            } else {
                $entradas.Add($elemento)
            }
        }
        $resultado.Entradas = $entradas.ToArray()
    } catch {
        Write-Verbose "No se ha podido leer el historial: $($_.Exception.Message)"
        $resultado.Ilegible = $true
    }
    return $resultado
}

function Add-EntradaHistorial {
    <#
    .SYNOPSIS
        Añade una ejecución al historial (se conservan las 100 últimas).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Debe incluir todos los tipos con que se llama desde la ventana y
        # la consola; un tipo rechazado se pierde en silencio porque el
        # llamante solo hace Write-Verbose. Hay una invariante que lo comprueba.
        [Parameter(Mandatory)] [ValidateSet('analisis', 'limpieza', 'limpieza-interrumpida')] [string] $Tipo,
        [Parameter(Mandatory)] [int]    $Elementos,
        [Parameter(Mandatory)] [double] $Bytes,
        [string] $Perfil        = 'equilibrado',
        [string[]] $Modulos     = @(),
        [double] $LibreAntes    = 0,
        [double] $LibreDespues  = 0,
        # Informe de esta ejecución, para poder abrirlo desde el historial.
        # Se guarda tal cual: quien la lea debe validarla con
        # Resolve-InformeAbrible, porque el .json es editable y no es de fiar.
        [string] $Informe       = '',
        # La ejecución no llegó al final: se canceló, falló algún módulo o
        # se detuvo el borrado.
        [switch] $Incompleto,
        # Por qué quedó incompleta, en una frase, para mostrarlo.
        [string] $Motivo        = '',
        [string] $CarpetaDatos  = (Get-CarpetaDatos)
    )

    $ruta = Get-RutaHistorial -CarpetaDatos $CarpetaDatos
    if (-not $PSCmdlet.ShouldProcess($ruta, 'Añadir entrada al historial')) { return }

    $entrada = [pscustomobject]@{
        Fecha        = (Get-Date).ToString('o')
        Tipo         = $Tipo
        Perfil       = $Perfil
        Modulos      = @($Modulos)
        Elementos    = $Elementos
        Bytes        = $Bytes
        LibreAntes   = $LibreAntes
        LibreDespues = $LibreDespues
        Informe      = $Informe
        Incompleto   = [bool]$Incompleto
        Motivo       = $Motivo
    }

    # Un historial ilegible se copia aparte antes de reescribirlo: si no,
    # se sustituiría por un archivo con esta única entrada.
    $lectura = Read-ArchivoHistorial -Ruta $ruta
    if ($lectura.Ilegible) {
        $copia = Save-CopiaArchivoIlegible -Ruta $ruta
        $aviso = if ($copia) {
            "El historial no se ha podido leer; se empieza uno nuevo y el anterior se ha guardado en $copia."
        } else {
            'El historial no se ha podido leer y no se ha podido guardar una copia; se empieza uno nuevo.'
        }
        Write-AvisoArchivoIlegible -Mensaje $aviso
    }

    $historial = @($lectura.Entradas) + @($entrada)
    if ($historial.Count -gt 100) {
        $historial = @($historial | Select-Object -Last 100)
    }

    # Escritura en un temporal y reemplazo atómico (Move-ArchivoReemplazando):
    # un corte a mitad no deja historial.json truncado. No protege frente a
    # dos procesos que escriben a la vez: cada uno lee, añade y reescribe,
    # y el último en escribir descarta la entrada del otro.
    #
    # El temporal lleva el PID para que dos procesos no compartan el
    # intermedio. No se borra si queda huérfano: dentro de src/Core solo
    # Remove.ps1 borra archivos (invariante comprobada por las pruebas).
    $temporal = "$ruta.$PID.tmp"
    try {
        # -ErrorAction Stop: si Set-Content falla a mitad (disco lleno), no
        # se debe mover un temporal truncado encima del historial bueno.
        $historial | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $temporal -Encoding UTF8 -ErrorAction Stop
        Move-ArchivoReemplazando -Origen $temporal -Destino $ruta -Confirm:$false
    } catch {
        Write-Verbose "No se ha podido guardar el historial: $($_.Exception.Message)"
    }
}

function Get-ResumenHistorial {
    <#
    .SYNOPSIS
        Totales acumulados para mostrar en la interfaz.
    #>
    [CmdletBinding()]
    param([string] $CarpetaDatos = (Get-CarpetaDatos))

    $historial = @(Get-Historial -CarpetaDatos $CarpetaDatos)
    # [string]: si Tipo fuera un array, -eq devolvería el subconjunto
    # coincidente (verdadero si no está vacío) y la entrada pasaría el filtro.
    $limpiezas = @($historial | Where-Object { [string]$_.Tipo -eq 'limpieza' })

    $totalBytes = 0.0
    foreach ($entrada in $limpiezas) { $totalBytes += ConvertTo-DoubleSeguro $entrada.Bytes }

    return [pscustomobject]@{
        Limpiezas    = $limpiezas.Count
        BytesTotales = $totalBytes
    }
}
