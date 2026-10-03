<#
.SYNOPSIS
    El formato de las sumas SHA-256 que se publican con cada versión.
    Cálculo puro, sin tocar el disco.

.DESCRIPTION
    Separado de Publicar-Sumas.ps1 (que escribe archivos) para poder
    probarlo sin efectos.

    `sha256sum -c`, winget y Scoop esperan un formato exacto:
    - Hash en minúsculas (Get-FileHash lo devuelve en mayúsculas).
    - Dos espacios exactos entre hash y nombre.
    - Saltos LF: un \r sobrante acaba en el nombre del archivo.
    - Sin BOM (al contrario que los .ps1): con BOM, la primera línea no
      valida.
#>

function Format-SumasSha256 {
    <#
    .SYNOPSIS
        El contenido de SHA256SUMS.txt a partir de los pares nombre/hash.

    .PARAMETER Entradas
        Tabla ordenada o lista de hashtables con Nombre y Hash.

    .OUTPUTS
        El texto completo, con saltos LF y salto final. Debe escribirse sin
        BOM.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()]
        [object[]] $Entradas
    )

    if (-not $Entradas) { return '' }

    $lineas = foreach ($e in $Entradas) {
        $nombre = [string]$e.Nombre
        $hash   = [string]$e.Hash

        if ([string]::IsNullOrWhiteSpace($nombre) -or [string]::IsNullOrWhiteSpace($hash)) {
            throw 'Una entrada de sumas no tiene nombre o no tiene hash.'
        }
        # Solo nombres: se verifica desde la carpeta de descarga, donde una
        # ruta del runner de la CI no existe.
        if ($nombre -match '[\\/]') {
            throw ("El nombre '$nombre' lleva ruta, y el archivo de sumas solo admite nombres.")
        }

        # Dos espacios y en minúsculas. Ver la cabecera.
        '{0}  {1}' -f $hash.ToLowerInvariant(), $nombre
    }

    # Con salto final: no todas las herramientas aceptan una última línea
    # sin terminar.
    return (($lineas -join "`n") + "`n")
}

function Format-TablaSumas {
    <#
    .SYNOPSIS
        Las mismas sumas, en tabla de Markdown para el cuerpo de la versión.

    .DESCRIPTION
        El archivo sirve para verificar con herramientas; la tabla, para
        verificar a simple vista. Además, en el cuerpo de la versión las
        sumas quedan fuera de los adjuntos, así que alterar el paquete y su
        archivo de sumas a la vez no basta.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()]
        [object[]] $Entradas
    )

    if (-not $Entradas) { return '' }

    $filas = foreach ($e in $Entradas) {
        '| `{0}` | `{1}` |' -f ([string]$e.Nombre), ([string]$e.Hash).ToLowerInvariant()
    }

    return (@(
        '| Archivo | SHA-256 |'
        '|---|---|'
        $filas
    ) -join "`n")
}

function Test-SumaSha256Valida {
    <#
    .SYNOPSIS
        Si una cadena tiene forma de suma SHA-256.

    .DESCRIPTION
        Sesenta y cuatro dígitos hexadecimales. Impide publicar un hash
        vacío, truncado o con espacios.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Suma
    )

    if ([string]::IsNullOrWhiteSpace($Suma)) { return $false }
    return $Suma -match '\A[0-9a-fA-F]{64}\z'
}
