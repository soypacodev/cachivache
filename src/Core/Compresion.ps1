<#
.SYNOPSIS
    Compresión NTFS: lo que un archivo ocupa realmente en el disco.

.DESCRIPTION
    FileInfo.Length es el tamaño lógico. En un archivo comprimido por NTFS
    lo que se libera al borrarlo es el tamaño en disco, que puede ser mucho
    menor; prometer el lógico sería prometer de más.

    Test-EstaComprimido y Get-EspacioRecuperable son cálculo puro y se
    prueban sin NTFS. Get-TamanoEnDisco es la única parte que depende del
    sistema operativo.
#>

# Valor numérico y no [IO.FileAttributes]::Compressed, igual que en
# Test-EsMarcadorNube: un nombre de enumeración inexistente en la versión
# de .NET lanza en ejecución; un número no.
$script:AtributoComprimido = 0x800    # FILE_ATTRIBUTE_COMPRESSED

function Test-EstaComprimido {
    <#
    .SYNOPSIS
        Indica si los atributos llevan la marca de comprimido de NTFS.

    .DESCRIPTION
        Cálculo puro. Se comprueba el bit, no la igualdad: los atributos
        son una máscara y suelen llevar otros bits (Archive, System...).

    .PARAMETER Atributos
        FileInfo.Attributes como entero. Se acepta nulo (atributos no
        leídos) y se responde que no está comprimido.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [AllowNull()] [int] $Atributos)

    return (($Atributos -band $script:AtributoComprimido) -ne 0)
}

function Get-TamanoEnDisco {
    <#
    .SYNOPSIS
        Bytes que ocupa realmente un archivo en disco, o $null si no se sabe.

    .DESCRIPTION
        Usa GetCompressedFileSize de kernel32, que tiene en cuenta
        compresión NTFS y archivos dispersos, y no abre el archivo (no
        provoca descargas de OneDrive).

        Devuelve $null, nunca 0, cuando no se puede medir (fuera de Windows
        o si la llamada falla): 0 significaría "no libera nada", y $null
        hace que Get-EspacioRecuperable use el tamaño lógico.

        No lanza nunca: se llama una vez por archivo en recorridos grandes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $null }

    # $IsWindows no existe en PowerShell 5.1 (vale $null): "-not $IsWindows"
    # sería verdadero precisamente en Windows.
    if (-not ($IsWindows -or ($null -eq $IsWindows))) { return $null }

    try {
        if (-not ('Cachivache.Kernel32' -as [type])) {
            Add-Type -Namespace 'Cachivache' -Name 'Kernel32' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", EntryPoint = "GetCompressedFileSizeW", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSize(string lpFileName, out uint lpFileSizeHigh);
'@ -ErrorAction Stop
        }

        # Prefijo de ruta larga: node_modules y cachés anidadas superan
        # a menudo MAX_PATH.
        $rutaApi = ConvertTo-RutaLarga -Ruta $Ruta

        $alto = [uint32]0
        $bajo = [Cachivache.Kernel32]::GetCompressedFileSize($rutaApi, [ref] $alto)

        # INVALID_FILE_SIZE como [uint32]::MaxValue y no 0xFFFFFFFF: el
        # literal hexadecimal no tiene el mismo tipo en todas las versiones
        # de PowerShell. Ese valor también puede ser una parte baja válida;
        # la API distingue el error con GetLastError.
        if ($bajo -eq [uint32]::MaxValue) {
            if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) { return $null }
        }

        return [double](([uint64]$alto -shl 32) -bor [uint64]$bajo)
    } catch {
        # Archivo bloqueado, unidad desaparecida o API no disponible: "no se sabe".
        return $null
    }
}

function Get-EspacioRecuperable {
    <#
    .SYNOPSIS
        Bytes que se liberan al borrar un archivo. Cálculo puro.

    .DESCRIPTION
        Única fuente de esta cifra para la vista, el informe y el motor.

          - Si se conoce el tamaño en disco, se devuelve ese.
          - Si es $null (desconocido), se devuelve el tamaño lógico.

        Nunca devuelve un negativo: los valores negativos se tratan como cero.

    .PARAMETER TamanoLogico
        Lo que mide el archivo al leerlo (FileInfo.Length).

    .PARAMETER TamanoEnDisco
        Lo que devuelve Get-TamanoEnDisco, con su $null incluido.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $TamanoLogico,
        [Parameter(Mandatory)] [AllowNull()] $TamanoEnDisco
    )

    $logico = ConvertTo-DoubleSeguro -Valor $TamanoLogico
    if ($logico -lt 0) { $logico = 0.0 }

    # Comprobar $null antes de convertir: ConvertTo-DoubleSeguro lo
    # traduce a 0.0 y se perdería la diferencia entre "no se sabe" y "cero".
    if ($null -eq $TamanoEnDisco) { return $logico }

    $disco = ConvertTo-DoubleSeguro -Valor $TamanoEnDisco
    if ($disco -lt 0) { $disco = 0.0 }
    return $disco
}

function Format-DetalleCompresion {
    <#
    .SYNOPSIS
        Texto para el usuario cuando algo está comprimido con NTFS.

    .DESCRIPTION
        Muestra las dos cifras (tamaño real y en disco) para que se
        entienda de dónde sale lo que se libera. Si no se conoce el tamaño
        en disco, lo indica.

    .PARAMETER Archivos
        Número de archivos comprimidos que se resumen. Con 0 (por
        defecto) el texto habla de uno solo, sin cifra.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $TamanoLogico,
        [Parameter(Mandatory)] [AllowNull()] $TamanoEnDisco,
        [int] $Archivos = 0
    )

    $logico = ConvertTo-DoubleSeguro -Valor $TamanoLogico
    if ($logico -lt 0) { $logico = 0.0 }
    $textoLogico = Format-Tamano -Bytes $logico

    # Concordancia de número.
    $etiqueta = if ($Archivos -le 0) {
        'Comprimido con NTFS'
    } elseif ($Archivos -eq 1) {
        '1 archivo comprimido con NTFS'
    } else {
        ('{0} archivos comprimidos con NTFS' -f $Archivos)
    }

    if ($null -eq $TamanoEnDisco) {
        # Paréntesis alrededor de la cadena: -f tiene más precedencia que +.
        return (('{0}: {1} de tamaño real. No se ha podido leer cuánto ocupa en disco, así que se cuenta entero.') -f
                $etiqueta, $textoLogico)
    }

    $disco = Get-EspacioRecuperable -TamanoLogico $logico -TamanoEnDisco $TamanoEnDisco
    $textoDisco = Format-Tamano -Bytes $disco

    if ($disco -ge $logico) {
        # Sin ganancia (contenido ya comprimido o archivos diminutos que
        # ocupan un clúster entero): no se añade la comparación.
        return (('{0}: {1} de tamaño real que ocupan {2} en disco.') -f
                $etiqueta, $textoLogico, $textoDisco)
    }

    return (('{0}: {1} de tamaño real que ocupan {2} en disco. Se liberan {2}, no {1}.') -f
            $etiqueta, $textoLogico, $textoDisco)
}
