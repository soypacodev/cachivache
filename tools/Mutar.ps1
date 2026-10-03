<#
.SYNOPSIS
    Rompe el código a propósito para comprobar que una prueba falla por el
    motivo correcto. Herramienta de desarrollo.

.DESCRIPTION
    Las invariantes se verifican por mutación: se rompe el código, se
    comprueba que la prueba falla y se restaura.

    Dos reglas, para que una mutación fallida no pase por una prueba
    correcta:
    1. Si el texto a mutar no aparece, se lanza.
    2. Si aparece más de una vez, también se lanza: hay que elegir un
       único sitio.

.EXAMPLE
    . ./tools/Mutar.ps1
    Invoke-Mutacion -Ruta ./src/UI/Atajos.ps1 -Buscar "return 'Filtrar'" -Poner "return 'Otra'" -Prueba {
        # ... aquí se ejecuta la suite y se comprueba que falla
    }
#>

function Get-TextoMutado {
    <#
    .SYNOPSIS
        El texto con la sustitución hecha. Cálculo puro.

    .DESCRIPTION
        Decide si la mutación es válida. Separada de la escritura en disco
        para poder probarla.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Texto,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Buscar,
        # AllowEmptyString: borrar una línea es una mutación válida.
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Poner
    )

    if ([string]::IsNullOrEmpty($Texto))  { throw 'No hay texto que mutar.' }
    if ([string]::IsNullOrEmpty($Buscar)) { throw 'No se ha dicho que buscar.' }
    if ($Buscar -ceq $Poner) { throw 'La mutacion no cambia nada: buscar y poner son iguales.' }

    # Comparación literal, no regex: el código está lleno de $, [ y (.
    $veces = 0
    $desde = 0
    while ($true) {
        $i = $Texto.IndexOf($Buscar, $desde, [StringComparison]::Ordinal)
        if ($i -lt 0) { break }
        $veces++
        $desde = $i + $Buscar.Length
    }

    if ($veces -eq 0) {
        throw ("No aparece, asi que no se ha mutado nada: '{0}'" -f $Buscar)
    }
    if ($veces -gt 1) {
        throw ("Aparece {0} veces: '{1}'. Alarga el texto hasta que sea unico." -f $veces, $Buscar)
    }

    return $Texto.Replace($Buscar, $Poner)
}

function Invoke-Mutacion {
    <#
    .SYNOPSIS
        Muta un archivo, ejecuta un bloque y lo restaura siempre.

    .PARAMETER Prueba
        Bloque a ejecutar con el código mutado; normalmente, Pester, para
        comprobar que falla por el motivo correcto.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [Parameter(Mandatory)] [string] $Buscar,
        # Como en Get-TextoMutado: borrar es una mutación válida.
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Poner,
        [Parameter(Mandatory)] [scriptblock] $Prueba
    )

    if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) {
        throw "No esta el archivo que hay que mutar: $Ruta"
    }

    $original = [IO.File]::ReadAllText($Ruta)
    # Lanza antes de tocar el disco si la mutación no es válida.
    $mutado = Get-TextoMutado -Texto $original -Buscar $Buscar -Poner $Poner

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Mutar temporalmente')) { return }

    # Se conserva el BOM: sin él fallaría la invariante de codificación, no
    # la prueba que se quiere comprobar.
    $conBom = $original.Length -gt 0 -and
              [IO.File]::ReadAllBytes($Ruta)[0] -eq 239
    $codificacion = [Text.UTF8Encoding]::new($conBom)

    try {
        [IO.File]::WriteAllText($Ruta, $mutado, $codificacion)
        & $Prueba
    } finally {
        # En finally: se restaura aunque el bloque de prueba lance.
        [IO.File]::WriteAllText($Ruta, $original, $codificacion)
    }
}
