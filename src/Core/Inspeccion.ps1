<#
.SYNOPSIS
    Qué hay dentro de una carpeta, para poder decidir sin borrarla antes.

.DESCRIPTION
    Responde a lo que el usuario necesita antes de una decisión
    irreversible: cuántos archivos hay, de cuándo es lo más reciente y qué
    es lo que más ocupa.

    - No abre ningún archivo: todo sale de la entrada de directorio (abrir
      un marcador de OneDrive lo descargaría).
    - No sigue puntos de reanálisis, que apuntan fuera del árbol o forman
      ciclos.
    - Usa el prefijo de ruta larga para recorrer, pero lo quita de las
      rutas devueltas.
    - Tiene un tope de archivos. Si se alcanza, Truncado vale $true y
      quien muestre "los mayores" debe indicarlo.
#>

# Tope de archivos recorridos. Holgado: solo salta en árboles enormes.
$script:MaximoArchivosDetalle = 300000

function New-DetalleCarpeta {
    <#
    .SYNOPSIS
        Detalle vacío, para que todos los caminos devuelvan la misma forma.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo compone un objeto en memoria.')]
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Archivos     = 0
        Carpetas     = 0
        Bytes        = 0.0
        Ultimo       = $null
        Mayores      = @()
        EnNube       = 0
        Inaccesibles = 0
        Truncado     = $false
    }
}

function Get-DetalleCarpeta {
    <#
    .SYNOPSIS
        Recorre una carpeta y devuelve de qué está hecha.

    .PARAMETER Cuantos
        Cuántos de los mayores se devuelven.

    .OUTPUTS
        Archivos, Carpetas, Bytes, Ultimo, Mayores, EnNube, Inaccesibles,
        Truncado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta,
        [int] $Cuantos = 10
    )

    $detalle = New-DetalleCarpeta
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $detalle }

    $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $detalle }

    # Un archivo suelto es su propio detalle: un archivo y él mismo como el mayor.
    if (-not $item.PSIsContainer) {
        $detalle.Archivos = 1
        $detalle.Bytes    = [double]$item.Length
        $detalle.Ultimo   = $item.LastWriteTime
        $detalle.Mayores  = @([pscustomobject]@{
            Nombre = $item.Name
            Ruta   = ConvertFrom-RutaLarga -Ruta $item.FullName
            Bytes  = [double]$item.Length
            EnNube = (Test-ArchivoEnNube -Archivo $item)
        })
        return $detalle
    }

    if (Test-EsEnlace $item) { return $detalle }

    # Se guardan todos y se ordena una vez al final; es más barato que
    # mantener una lista ordenada en cada paso.
    $todos = [Collections.Generic.List[object]]::new()
    $ticksUltimo = 0L
    $bytes = 0.0

    $pendientes = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pendientes.Push((Get-CarpetaParaRecorrer -Carpeta $item))

    while ($pendientes.Count -gt 0) {
        $actual = $pendientes.Pop()

        # Un try por bucle: un acceso denegado al enumerar archivos no debe
        # impedir recorrer las subcarpetas. La carpeta cuenta una sola vez
        # como inaccesible aunque fallen los dos.
        $inaccesible = $false
        try {
            foreach ($archivo in $actual.EnumerateFiles()) {
                if ($todos.Count -ge $script:MaximoArchivosDetalle) {
                    $detalle.Truncado = $true
                    break
                }
                $ticks = $archivo.LastWriteTime.Ticks
                if ($ticks -gt $ticksUltimo) { $ticksUltimo = $ticks }

                $enNube = Test-ArchivoEnNube -Archivo $archivo
                # Un marcador de nube apenas ocupa disco: se cuenta y se
                # marca, pero su tamaño lógico no se suma.
                if (-not $enNube) { $bytes += [double]$archivo.Length }

                $todos.Add([pscustomobject]@{
                    Nombre = $archivo.Name
                    Ruta   = ConvertFrom-RutaLarga -Ruta $archivo.FullName
                    Bytes  = [double]$archivo.Length
                    EnNube = $enNube
                })
            }
        } catch {
            $inaccesible = $true
        }

        if ($detalle.Truncado) {
            if ($inaccesible) { $detalle.Inaccesibles++ }
            break
        }

        try {
            foreach ($sub in $actual.EnumerateDirectories()) {
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $detalle.Carpetas++
                $pendientes.Push($sub)
            }
        } catch {
            $inaccesible = $true
        }
        if ($inaccesible) { $detalle.Inaccesibles++ }
    }

    $detalle.Archivos = $todos.Count
    $detalle.Bytes    = $bytes
    $detalle.EnNube   = @($todos | Where-Object { $_.EnNube }).Count
    $detalle.Ultimo   = if ($ticksUltimo -gt 0) { [datetime]::new($ticksUltimo) } else { $null }
    $detalle.Mayores  = @($todos | Sort-Object Bytes -Descending | Select-Object -First $Cuantos)

    return $detalle
}

function Format-DetalleCarpeta {
    <#
    .SYNOPSIS
        El detalle en texto, listo para mostrar.

    .DESCRIPTION
        Separado de la interfaz para poder probar en texto lo que se le
        cuenta al usuario antes de borrar.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Detalle,
        [string] $Ruta = ''
    )

    if ($null -eq $Detalle) { return 'No se ha podido mirar dentro.' }

    $lineas = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Ruta)) { $lineas.Add($Ruta); $lineas.Add('') }

    if ($Detalle.Archivos -eq 0) {
        $lineas.Add('No hay ni un archivo aquí dentro.')
        if ($Detalle.Inaccesibles -gt 0) {
            $lineas.Add('')
            $lineas.Add(('Aunque {0} {1} no se {2} podido leer: puede que haya algo ahí.' -f
                         $Detalle.Inaccesibles,
                         $(if ($Detalle.Inaccesibles -eq 1) { 'carpeta' } else { 'carpetas' }),
                         $(if ($Detalle.Inaccesibles -eq 1) { 'haya' } else { 'hayan' })))
        }
        return ($lineas -join [Environment]::NewLine)
    }

    $lineas.Add(('{0} {1} en {2} {3}, {4} en total.' -f
                 $Detalle.Archivos, $(if ($Detalle.Archivos -eq 1) { 'archivo' } else { 'archivos' }),
                 $Detalle.Carpetas, $(if ($Detalle.Carpetas -eq 1) { 'subcarpeta' } else { 'subcarpetas' }),
                 (Format-Tamano $Detalle.Bytes)))

    if ($null -ne $Detalle.Ultimo) {
        $lineas.Add(('Lo más reciente es de {0} ({1}).' -f
                     $Detalle.Ultimo.ToString('yyyy-MM-dd'), (Format-Antiguedad $Detalle.Ultimo)))
    }

    if ($Detalle.EnNube -gt 0) {
        $lineas.Add(('{0} {1} solo en la nube: no ocupan ese espacio en el disco.' -f
                     $Detalle.EnNube,
                     $(if ($Detalle.EnNube -eq 1) { 'archivo está' } else { 'archivos están' })))
    }

    if ($Detalle.Inaccesibles -gt 0) {
        $lineas.Add(('{0} {1} no se {2} podido leer: lo de dentro no está contado.' -f
                     $Detalle.Inaccesibles,
                     $(if ($Detalle.Inaccesibles -eq 1) { 'carpeta' } else { 'carpetas' }),
                     $(if ($Detalle.Inaccesibles -eq 1) { 'ha' } else { 'han' })))
    }

    $lineas.Add('')
    if ($Detalle.Truncado) {
        # El mayor real puede estar en la parte no recorrida.
        $lineas.Add(('Los mayores de los primeros {0} archivos (hay más y no se han mirado todos):' -f
                     $Detalle.Archivos))
    } else {
        $lineas.Add('Lo que más ocupa:')
    }

    foreach ($mayor in @($Detalle.Mayores)) {
        $lineas.Add(('   {0}   {1}{2}' -f
                     (Format-Tamano $mayor.Bytes).PadLeft(10),
                     $mayor.Nombre,
                     $(if ($mayor.EnNube) { '   (en la nube)' } else { '' })))
    }

    return ($lineas -join [Environment]::NewLine)
}
