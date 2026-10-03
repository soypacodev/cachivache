<#
.SYNOPSIS
    Decisiones para reutilizar el índice guardado (IndicePersistente.ps1)
    sin presentar datos antiguos como actuales. Cálculo puro salvo
    Get-HuellaVolumenDeZonas.

    Un índice reutilizado no se puede poner al día (leer el diario de
    cambios de NTFS resultó demasiado lento y con poca retención): describe
    el disco cuando se guardó. Es útil (segundos frente a un recorrido
    completo) siempre que se avise, y el aviso lo compone
    Get-AvisoIndiceReutilizado.

    Test-IndiceUtilizable exige un identificador de diario; sin diario se
    usa la marca fija 'sin-diario'. Si algún día se lee el diario, los
    índices con esta marca se rechazarán solos. Mientras tanto, la
    caducidad de siete días es la única protección frente a datos viejos.
#>

function Get-MarcaSinDiario {
    <#
    .SYNOPSIS
        Valor del campo de diario cuando no hay diario.

    .NOTES
        Es una función para que quien guarda y quien comprueba usen el
        mismo valor; si divergieran, el índice se rechazaría siempre sin
        error visible.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'sin-diario'
}

function Get-HuellaVolumen {
    <#
    .SYNOPSIS
        Huella del volumen, para detectar que una letra de unidad
        corresponde a otro disco. Cálculo puro.

    .DESCRIPTION
        No es el número de serie: .NET no lo expone y CIM es lento y solo
        existe en Windows. Combina sistema de archivos, tamaño total y fecha
        de creación de la raíz (formateo). No distingue dos particiones
        clonadas bit a bit; para eso queda la caducidad de siete días.

    .PARAMETER Creacion
        Fecha de creación de la raíz. Se recibe como parámetro para que la
        función sea pura.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Formato = '',
        [AllowNull()] $Bytes = 0,
        [AllowNull()] $Creacion = $null
    )

    # Las variables locales tienen nombres distintos de los parámetros:
    # PowerShell no distingue mayúsculas ($bytes y $Bytes son la misma
    # variable) y asignar la local sobrescribiría el argumento.
    $txtFormato = if ($null -eq $Formato) { '' } else { $Formato.Trim() }

    $numBytes = 0.0
    if ($null -ne $Bytes) { try { $numBytes = [double]$Bytes } catch { $numBytes = 0.0 } }
    if ($numBytes -lt 0) { $numBytes = 0.0 }

    # Formato 'o' en UTC y cultura invariable: la huella no debe cambiar
    # con el idioma de Windows.
    $txtCreacion = 'sin-fecha'
    if ($Creacion -is [datetime]) {
        $txtCreacion = $Creacion.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }

    return ('{0}|{1:F0}|{2}' -f $txtFormato, $numBytes, $txtCreacion)
}

function Get-HuellaVolumenDeZonas {
    <#
    .SYNOPSIS
        Huella de todos los volúmenes que contienen unas carpetas. Es lo
        único de este archivo que consulta el disco.

    .DESCRIPTION
        Concatena las huellas de cada unidad, ordenadas para que el orden
        de las carpetas no influya. Si cualquiera cambia, el índice deja
        de ser válido.

        No lanza nunca: una unidad que no responde deja una huella
        distinta de la guardada y se recorre el disco.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] $Zonas)

    $raices = @()
    if ($null -ne $Zonas) {
        $raices = @($Zonas |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object {
                try { [IO.Path]::GetPathRoot(([string]$_).Trim()) } catch { '' }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLowerInvariant() } |
            Sort-Object -Unique)
    }
    if ($raices.Count -eq 0) { return '' }

    $partes = @()
    foreach ($raiz in $raices) {
        $formato  = ''
        $total    = 0
        $creacion = $null
        try {
            $unidad = [IO.DriveInfo]::new($raiz)
            $formato = $unidad.DriveFormat
            $total   = $unidad.TotalSize
        } catch {
            Write-Verbose ('No se ha podido leer la unidad {0}: {1}' -f $raiz, $_.Exception.Message)
        }
        try { $creacion = [IO.Directory]::GetCreationTimeUtc($raiz) } catch { $creacion = $null }
        $partes += ('{0}={1}' -f $raiz, (Get-HuellaVolumen -Formato $formato -Bytes $total -Creacion $creacion))
    }
    return ($partes -join ';')
}

function Get-NombreIndiceEspacio {
    <#
    .SYNOPSIS
        Nombre del archivo de índice de un conjunto de carpetas. Cálculo puro.

    .DESCRIPTION
        Un índice solo vale para las carpetas que midió y el formato no las
        guarda, así que se codifican en el nombre (hash del conjunto). Así
        no hace falta cambiar el formato del archivo.

        Se normalizan orden y mayúsculas: en Windows "C:\Users\x" y
        "c:\users\X" son la misma carpeta.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] $Zonas)

    $lista = @()
    if ($null -ne $Zonas) {
        $lista = @($Zonas |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).Trim().TrimEnd([char]'\', [char]'/').ToLowerInvariant() } |
            Sort-Object -Unique)
    }
    if ($lista.Count -eq 0) { return '' }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lista -join '|')))
    } finally {
        $sha.Dispose()
    }
    # 16 caracteres hexadecimales (64 bits): suficiente para los pocos
    # conjuntos de carpetas de un usuario.
    $corto = -join (@($bytes[0..7]) | ForEach-Object { $_.ToString('x2') })
    return ('espacio-{0}.idx' -f $corto)
}

function Get-AvisoIndiceReutilizado {
    <#
    .SYNOPSIS
        Aviso al usuario cuando se muestran datos de un índice guardado.
        Cálculo puro.

    .DESCRIPTION
        Indica la antigüedad de los datos (con Format-Duracion) y cómo
        pedir una nueva medición (-Recorrer).

    .PARAMETER Escrito
        Cuándo se guardó el índice.
    .PARAMETER Ahora
        Hora actual; se recibe como parámetro para poder probarlo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Escrito,
        [Parameter(Mandatory)] [AllowNull()] $Ahora
    )

    $desde = $null
    if ($Escrito -is [datetime]) { $desde = $Escrito }
    $hasta = $null
    if ($Ahora -is [datetime]) { $hasta = $Ahora }

    # Sin fechas fiables se avisa igualmente, sin la antigüedad.
    if ($null -eq $desde -or $null -eq $hasta -or $hasta -lt $desde) {
        return 'Datos del índice guardado: no se ha vuelto a mirar el disco. Usa -Recorrer para medirlo otra vez.'
    }

    return ('Datos del índice guardado hace {0}: no se ha vuelto a mirar el disco. Usa -Recorrer para medirlo otra vez.' -f
            (Format-Duracion ($hasta - $desde)))
}
