<#
.SYNOPSIS
    Medición de tamaños, información de unidades y recorrido de carpetas.
#>

# ---------------------------------------------------------------------
# Rutas largas
#
# Windows limita las rutas a 260 caracteres (MAX_PATH) salvo que se anteponga
# "\\?\", que desactiva la normalización y admite hasta 32.767. En Windows
# PowerShell 5.1 (.NET Framework) es la única vía, aunque el registro habilite
# rutas largas. Es habitual en este dominio: node_modules anidados, cachés de
# Gradle o .next\cache\webpack.
#
# Regla: el prefijo solo existe dentro de la llamada a la API. Nunca se guarda
# en un candidato, ni se compara, ni se registra, ni se muestra: la guardia
# compararía "\\?\C:\Windows" con "C:\Windows" y no coincidiría. Hay un
# invariante que lo comprueba.
# ---------------------------------------------------------------------

function ConvertTo-RutaLarga {
    <#
    .SYNOPSIS
        Antepone "\\?\" a una ruta de Windows para saltarse MAX_PATH.

    .DESCRIPTION
        Cálculo puro: solo transforma texto. Devuelve la ruta sin cambios si:

          - ya lleva el prefijo (duplicarlo la invalida);
          - es relativa ("\\?\" exige ruta absoluta y la API no resuelve
            nada);
          - no empieza por letra de unidad ni es UNC (rutas no Windows en las
            pruebas, o etiquetas como "docker system prune");
          - contiene "." o ".." como segmento: con el prefijo la API no
            normaliza y buscaría una carpeta llamada "..".

        Las rutas de red se convierten a "\\?\UNC\servidor\recurso", la
        forma que exige la API.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [AllowEmptyString()] [string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $Ruta }
    if ($Ruta.StartsWith('\\?\') -or $Ruta.StartsWith('\\.\')) { return $Ruta }

    $normal = $Ruta.Replace('/', '\')

    foreach ($segmento in $normal.Split('\')) {
        if ($segmento -eq '.' -or $segmento -eq '..') { return $Ruta }
    }

    if ($normal -match '^[A-Za-z]:\\') { return '\\?\' + $normal }
    if ($normal.StartsWith('\\'))      { return '\\?\UNC\' + $normal.Substring(2) }

    return $Ruta
}

function ConvertFrom-RutaLarga {
    <#
    .SYNOPSIS
        Quita el prefijo "\\?\" de una ruta.

    .DESCRIPTION
        Se aplica a todo lo que sale hacia candidatos, registro, informes y
        mensajes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [AllowEmptyString()] [string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $Ruta }
    if ($Ruta.StartsWith('\\?\UNC\')) { return '\\' + $Ruta.Substring(8) }
    if ($Ruta.StartsWith('\\?\'))     { return $Ruta.Substring(4) }
    return $Ruta
}

function Test-RutaDemasiadoLarga {
    <#
    .SYNOPSIS
        ¿Supera esta ruta el límite clásico de Windows?

    .DESCRIPTION
        MAX_PATH (260) incluye el terminador nulo, así que el límite útil son
        259 caracteres. Se mide sin prefijo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] [AllowEmptyString()] [string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $false }
    return ((ConvertFrom-RutaLarga -Ruta $Ruta).Length -ge 260)
}

# ---------------------------------------------------------------------
# Archivos que viven en la nube
#
# Con "Archivos a petición" de OneDrive el disco guarda solo un marcador: la
# entrada de directorio con su tamaño lógico, sin contenido. Enumerar o leer
# Length, Attributes y LastWriteTime no descarga nada (sale de la entrada de
# directorio), así que medir es seguro. Abrir el archivo para leerlo sí lo
# descarga: en este proyecto, Get-HuellaRapida y Get-FileHash (duplicados).
# Además, un marcador apenas ocupa espacio en disco, así que no debe
# prometerse su tamaño lógico como espacio recuperable.
#
# Se usan valores numéricos porque [IO.FileAttributes]::RecallOnDataAccess no
# existe en el .NET Framework de PowerShell 5.1 y lanzaría al ejecutarse.
$script:AtributoOffline             = 0x1000     # FILE_ATTRIBUTE_OFFLINE
$script:AtributoRecallOnOpen        = 0x40000    # FILE_ATTRIBUTE_RECALL_ON_OPEN
$script:AtributoRecallOnDataAccess  = 0x400000   # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS

function Test-EsMarcadorNube {
    <#
    .SYNOPSIS
        ¿Está este archivo solo en la nube, sin contenido en el disco?

    .DESCRIPTION
        Cálculo puro sobre los atributos. Se comprueban tres atributos porque
        los proveedores difieren: OneDrive usa RecallOnDataAccess y otros
        sistemas de almacenamiento jerárquico usan Offline.

    .PARAMETER Atributos
        Valor de FileInfo.Attributes como entero, para no depender de nombres
        de la enumeración que no existen en todas las versiones de .NET.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [int] $Atributos)

    $mascara = $script:AtributoOffline -bor
               $script:AtributoRecallOnOpen -bor
               $script:AtributoRecallOnDataAccess
    return (($Atributos -band $mascara) -ne 0)
}

function Test-ArchivoEnNube {
    <#
    .SYNOPSIS
        Igual que Test-EsMarcadorNube, a partir de un FileInfo o una ruta.

    .DESCRIPTION
        No abre el archivo (Attributes sale de la entrada de directorio), así
        que no dispara ninguna descarga.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $Archivo)

    if ($null -eq $Archivo) { return $false }
    try {
        $atributos = if ($Archivo -is [string]) {
            [int][IO.File]::GetAttributes((ConvertTo-RutaLarga -Ruta $Archivo))
        } else {
            [int]$Archivo.Attributes
        }
        return Test-EsMarcadorNube -Atributos $atributos
    } catch {
        # Si no se puede saber, se responde que no: tratarlo como marcador
        # haría saltar archivos normales en silencio.
        return $false
    }
}

function Get-CarpetaParaRecorrer {
    <#
    .SYNOPSIS
        Devuelve el DirectoryInfo con prefijo de ruta larga para que la
        enumeración no tope con MAX_PATH.

    .DESCRIPTION
        Si el prefijo no es aplicable (ruta relativa, etiqueta, sistema no
        Windows) devuelve la carpeta sin cambios.
    #>
    [CmdletBinding()]
    [OutputType([IO.DirectoryInfo])]
    param([Parameter(Mandatory)] [IO.DirectoryInfo] $Carpeta)

    $larga = ConvertTo-RutaLarga -Ruta $Carpeta.FullName
    if ($larga -eq $Carpeta.FullName) { return $Carpeta }

    try   { return [IO.DirectoryInfo]::new($larga) }
    catch { return $Carpeta }
}

function Test-EsEnlace {
    <#
    .SYNOPSIS
        Detecta junctions y enlaces simbólicos.
    .DESCRIPTION
        Nunca se sigue ni se borra un punto de reanálisis: borrar el enlace
        podría arrastrar el destino real, que puede estar en cualquier sitio.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Elemento)

    if ($null -eq $Elemento) { return $false }
    return [bool]($Elemento.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Join-RutaNativa {
    <#
    .SYNOPSIS
        Une segmentos de ruta sin pasar por el proveedor de PowerShell.
    .DESCRIPTION
        Join-Path resuelve la unidad a través del proveedor y lanza si la letra
        no existe en el proceso (por ejemplo, en las pruebas fuera de
        Windows). Usa el separador nativo, de modo que las rutas construidas a
        partir de carpetas descubiertas en disco (bibliotecas de Steam,
        partidas guardadas) funcionan igual en Windows y en las pruebas.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Base, [Parameter(ValueFromRemainingArguments)] [string[]] $Segmentos)

    $separador = [IO.Path]::DirectorySeparatorChar
    $ruta = $Base.TrimEnd([char]'\', [char]'/')
    foreach ($segmento in @($Segmentos)) {
        if ([string]::IsNullOrWhiteSpace($segmento)) { continue }
        foreach ($trozo in ($segmento -split '[\\/]')) {
            if ([string]::IsNullOrWhiteSpace($trozo)) { continue }
            $ruta = $ruta + $separador + $trozo
        }
    }
    return $ruta
}

function Test-RutaExcluida {
    <#
    .SYNOPSIS
        Indica si el usuario ha excluido una ruta.

    .DESCRIPTION
        Excluir una carpeta excluye todo lo que cuelga de ella. La comparación
        se hace sobre la ruta normalizada (minúsculas, sin barra final, un
        solo separador) y exige separador en el prefijo: excluir "C:\Datos" no
        excluye "C:\Datos Antiguos".

        Se comprueba en el embudo del análisis y otra vez en el motor de
        borrado, que corre más tarde y en otro runspace.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $Ruta,
        [string[]] $Excluidas = @()
    )

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $false }

    $lista = @($Excluidas | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lista.Count -eq 0) { return $false }

    # Ambos separadores se llevan siempre a la barra invertida, sin consultar
    # el separador nativo: la comparación no debe depender del sistema donde
    # se ejecuta (en Linux el nativo es "/").
    $normalizar = {
        param([string] $R)
        return $R.Replace('/', '\').TrimEnd([char]'\').ToLowerInvariant()
    }

    $candidata = & $normalizar $Ruta
    foreach ($excluida in $lista) {
        $base = & $normalizar $excluida
        if ([string]::IsNullOrEmpty($base)) { continue }

        if ($candidata.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { return $true }

        # El separador es obligatorio: ver la ayuda de la función.
        if ($candidata.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-EsRutaDeVerdad {
    <#
    .SYNOPSIS
        Indica si un texto es una ruta absoluta y no una etiqueta.

    .DESCRIPTION
        El campo Ruta de un candidato no siempre es una ruta: el método Comando
        lleva la orden ("docker system prune -a -f"), Papelera lleva una
        etiqueta, e Informativo puede llevar cualquiera de las dos. Por eso se
        decide por el valor y no por el método.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Texto
    )

    if ([string]::IsNullOrWhiteSpace($Texto)) { return $false }

    # Se acepta cualquier ruta anclada: letra de unidad ("C:\" o "C:/"),
    # recurso de red ("\\equipo") o raíz POSIX ("/tmp"). La última es
    # necesaria porque las pruebas se ejecutan también en Linux.
    return $Texto -match '^[A-Za-z]:[\\/]' -or $Texto.StartsWith('\\') -or $Texto.StartsWith('/')
}

function Get-ClaveExclusion {
    <#
    .SYNOPSIS
        Clave estable con la que el usuario excluye un candidato.

    .DESCRIPTION
        Dos formas de clave:

        - Con ruta real: la clave es la ruta.
        - Sin ruta (comandos, papelera): "modulo:<ModuloId>|<Nombre>". La
          barra vertical no es válida en una ruta de Windows, así que una
          clave sintética no puede confundirse con una ruta ni casar con una
          exclusión de carpeta.

        ModuloId y Nombre no dependen de la ejecución, de modo que la clave es
        estable entre análisis.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $ModuloId,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Nombre
    )

    if (Test-EsRutaDeVerdad -Texto $Ruta) { return $Ruta }

    return ('modulo:{0}|{1}' -f $ModuloId, $Nombre)
}

function Test-ClaveExcluida {
    <#
    .SYNOPSIS
        Indica si el usuario ha excluido este candidato.

    .DESCRIPTION
        - Clave de ruta: Test-RutaExcluida (por prefijo).
        - Clave sintética: solo coincidencia exacta; una etiqueta no tiene
          jerarquía.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Clave,
        [string[]] $Excluidas = @()
    )

    if ([string]::IsNullOrWhiteSpace($Clave)) { return $false }
    if (Test-EsRutaDeVerdad -Texto $Clave) {
        return (Test-RutaExcluida -Ruta $Clave -Excluidas $Excluidas)
    }

    foreach ($excluida in @($Excluidas)) {
        if ([string]::IsNullOrWhiteSpace($excluida)) { continue }
        if ($Clave.Equals($excluida.Trim(), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-IdentidadArchivo {
    <#
    .SYNOPSIS
        Identidad del contenido de un archivo, o $null si no lo comparte con
        ninguna otra entrada (enlaces duros).

    .DESCRIPTION
        Un enlace duro es otra entrada de directorio que apunta al mismo
        contenido. No lleva el atributo de punto de reanálisis, así que sin
        esta función el recorrido lo contaría dos veces (WinSxS está formado
        casi por completo por enlaces duros).

          * En Windows se usa GetFileInformationByHandle: número de enlaces,
            número de serie del volumen e índice del archivo. Funciona igual
            en PowerShell 5.1 y 7.
          * Si la API no responde, se recurre a LinkType y Target de Get-Item
            (solo útil en PowerShell 5.1, donde Target lista los enlaces).
          * Fuera de Windows se usa UnixStat (HardlinkCount e Inode).

        Recibe una ruta y no un FileInfo porque los objetos de
        EnumerateFiles no traen esta información. Cuesta una consulta al
        sistema por archivo, por lo que el llamante debe pedirlo
        expresamente y solo donde compensa.

        Ante la duda devuelve $null: el archivo se cuenta normalmente, en vez
        de arriesgarse a descontar bytes reales.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Ruta)

    # Los recorridos usan el prefijo de ruta larga y los hijos lo heredan,
    # pero el proveedor de PowerShell no lo entiende: se quita salvo que la
    # ruta sea realmente larga. Sin esto, Get-Item fallaría siempre y no se
    # detectaría ningún enlace duro.
    if (-not (Test-RutaDemasiadoLarga -Ruta $Ruta)) {
        $Ruta = ConvertFrom-RutaLarga -Ruta $Ruta
    }

    # --- Camino Windows: identidad del sistema de archivos ---------------
    # $IsWindows no existe en PowerShell 5.1 (vale $null).
    if ($IsWindows -or ($null -eq $IsWindows)) {
        $nativa = Get-IdentidadArchivoNativa -Ruta $Ruta
        if ($null -ne $nativa) {
            if ($nativa -eq '') { return $null }
            return $nativa
        }
    }

    try {
        $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction Stop

        # --- Camino Unix (pruebas, macOS, Linux) ----------------------
        $unix = $item.PSObject.Properties['UnixStat']
        if ($null -ne $unix -and $null -ne $unix.Value) {
            if ([int]$unix.Value.HardlinkCount -le 1) { return $null }
            return 'unix:{0}:{1}' -f $unix.Value.DeviceId, $unix.Value.Inode
        }

        # --- Camino Windows de reserva (PowerShell 5.1) ----------------
        $tipo = $item.PSObject.Properties['LinkType']
        if ($null -eq $tipo -or $tipo.Value -ne 'HardLink') { return $null }

        $rutas = [Collections.Generic.List[string]]::new()
        $rutas.Add($item.FullName)
        $destino = $item.PSObject.Properties['Target']
        if ($null -ne $destino -and $null -ne $destino.Value) {
            foreach ($otra in @($destino.Value)) {
                if (-not [string]::IsNullOrWhiteSpace($otra)) { $rutas.Add([string]$otra) }
            }
        }
        if ($rutas.Count -lt 2) { return $null }

        return 'win:' + (($rutas | Sort-Object -Unique) -join '|').ToLowerInvariant()
    } catch {
        return $null
    }
}

function Get-IdentidadArchivoNativa {
    <#
    .SYNOPSIS
        Identidad de un archivo según Windows (volumen e índice).
    .DESCRIPTION
        Devuelve 'vol:<serie>:<índice>' si el archivo tiene más de un enlace,
        una cadena vacía si tiene solo uno y $null si no se ha podido
        consultar (fuera de Windows, sin permiso o API no disponible).

        Abre el archivo sin pedir acceso de lectura ni de escritura, que
        basta para consultar sus atributos y funciona aunque otro proceso lo
        tenga abierto. Con FILE_FLAG_OPEN_REPARSE_POINT nunca sigue un enlace.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Ruta)

    try {
        if (-not ('Cachivache.EnlacesDuros' -as [type])) {
            Add-Type -Namespace 'Cachivache' -Name 'EnlacesDuros' -UsingNamespace 'System.Runtime.InteropServices', 'Microsoft.Win32.SafeHandles' -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct Informacion {
    public uint Atributos;
    public uint CreacionBajo;  public uint CreacionAlto;
    public uint AccesoBajo;    public uint AccesoAlto;
    public uint EscrituraBajo; public uint EscrituraAlto;
    public uint SerieVolumen;
    public uint TamanoAlto;    public uint TamanoBajo;
    public uint Enlaces;
    public uint IndiceAlto;    public uint IndiceBajo;
}

[DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out Informacion lpFileInformation);
'@ -ErrorAction Stop
        }

        # Acceso 0 (solo atributos), compartido para lectura, escritura y
        # borrado (7), OPEN_EXISTING (3), FILE_FLAG_BACKUP_SEMANTICS más
        # FILE_FLAG_OPEN_REPARSE_POINT (0x02200000).
        $manejador = [Cachivache.EnlacesDuros]::CreateFile(
            (ConvertTo-RutaLarga -Ruta $Ruta), [uint32]0, [uint32]7, [IntPtr]::Zero,
            [uint32]3, [uint32]0x02200000, [IntPtr]::Zero)
        try {
            if ($manejador.IsInvalid) { return $null }
            $info = New-Object 'Cachivache.EnlacesDuros+Informacion'
            if (-not [Cachivache.EnlacesDuros]::GetFileInformationByHandle($manejador, [ref] $info)) {
                return $null
            }
            if ($info.Enlaces -le 1) { return '' }
            $indice = ([uint64]$info.IndiceAlto -shl 32) -bor [uint64]$info.IndiceBajo
            return 'vol:{0:x8}:{1:x16}' -f $info.SerieVolumen, $indice
        } finally {
            $manejador.Dispose()
        }
    } catch {
        return $null
    }
}

function Get-HuellaRapida {
    <#
    .SYNOPSIS
        Huella barata de un archivo: tamaño más los primeros y últimos 64 KB.
    .DESCRIPTION
        Sirve para descartar parejas antes de calcular el hash completo, nunca
        para afirmar que dos archivos son iguales: huellas distintas implican
        archivos distintos; huellas iguales requieren comparación completa.
        Evita leer gigabytes enteros para descartar archivos del mismo tamaño.

        Los últimos 64 KB importan tanto como los primeros: grabaciones de la
        misma cámara, ISO o máquinas virtuales suelen compartir cabecera.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Ruta)

    # Abrir un marcador de OneDrive lo descarga. Es la única función del
    # núcleo que abre archivos del usuario, así que la comprobación vive aquí
    # y no en cada llamante. La cadena vacía equivale a "no se pudo abrir".
    if (Test-ArchivoEnNube -Archivo $Ruta) { return '' }

    $trozo = 64KB
    try {
        $flujo = [IO.File]::Open($Ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    } catch {
        return ''
    }

    try {
        $longitud = $flujo.Length
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            $bufer = New-Object byte[] $trozo

            $leidos = $flujo.Read($bufer, 0, [Math]::Min([int]$trozo, [int][Math]::Min($longitud, [long]$trozo)))
            if ($leidos -gt 0) { [void]$hash.TransformBlock($bufer, 0, $leidos, $bufer, 0) }

            if ($longitud -gt (2 * $trozo)) {
                [void]$flujo.Seek(-$trozo, [IO.SeekOrigin]::End)
                $leidos = $flujo.Read($bufer, 0, [int]$trozo)
                if ($leidos -gt 0) { [void]$hash.TransformBlock($bufer, 0, $leidos, $bufer, 0) }
            }

            [void]$hash.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            return "$longitud-" + [BitConverter]::ToString($hash.Hash).Replace('-', '')
        } finally {
            $hash.Dispose()
        }
    } catch {
        return ''
    } finally {
        $flujo.Dispose()
    }
}

function Get-ResumenArbol {
    <#
    .SYNOPSIS
        Recorre una carpeta y devuelve bytes, número de archivos y la fecha
        de modificación más reciente en una sola pasada.
    .DESCRIPTION
        Motor de Measure-Ruta y Measure-RutaDetalle. Usa EnumerateFiles en vez
        de Get-ChildItem -Recurse, que construye un objeto de PowerShell por
        archivo y es un orden de magnitud más lento.

        - Pila propia con EnumerateDirectories en vez de AllDirectories, para
          poder saltar los puntos de reanálisis (seguirlos contaría dos veces
          el destino o entraría en ciclos).
        - Length y LastWriteTime vienen de WIN32_FIND_DATA: leerlas no
          vuelve al disco ni falla si el archivo desaparece.
        - La fecha más reciente se obtiene con un máximo sobre ticks, sin
          ordenar.

        Cada enumeración tiene su propio try: un acceso denegado pierde esa
        carpeta, no el recorrido. Los fallos se cuentan en Inaccesibles y no
        se escriben en el flujo de error, porque con ErrorActionPreference =
        'Stop' (modo consola) abortarían la medición.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [IO.DirectoryInfo] $Carpeta,
        # Patrones opcionales para detectar, en el mismo recorrido, carpetas
        # y documentos que el usuario querría conservar (30-RestosProgramas).
        [string] $PatronCarpetaValiosa = '',
        [string] $PatronExtensionValiosa = '',
        # Cuenta una sola vez el contenido compartido por enlaces duros.
        # Desactivado por defecto: cuesta un Get-Item por archivo (ver
        # Get-IdentidadArchivo) y solo compensa en carpetas del sistema.
        [switch] $ContarEnlacesDuros
    )

    $bytes        = 0.0
    $archivos     = 0
    $ticksUltimo  = 0L
    $inaccesibles = 0
    $valiosas     = [Collections.Generic.List[string]]::new()
    $documentos   = 0
    $buscaCarpetas   = -not [string]::IsNullOrEmpty($PatronCarpetaValiosa)
    $buscaExtensiones = -not [string]::IsNullOrEmpty($PatronExtensionValiosa)

    # El conjunto solo se crea si se va a usar. Se asigna dentro del if y no
    # con "$vistos = if (...) { ... }": un if usado como expresión envía su
    # resultado por la canalización, que enumera el HashSet vacío y deja
    # $vistos a $null.
    $vistos      = $null
    if ($ContarEnlacesDuros) {
        $vistos = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    $compartidos = 0

    $pendientes = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()

    # El prefijo de ruta larga se aplica aquí, una sola vez en la raíz: los
    # hijos que devuelve la enumeración heredan su forma, y son los
    # descendientes los que suelen superar MAX_PATH.
    $pendientes.Push((Get-CarpetaParaRecorrer -Carpeta $Carpeta))

    while ($pendientes.Count -gt 0) {
        $actual = $pendientes.Pop()

        # Dos try independientes: con uno compartido, un acceso denegado al
        # enumerar los archivos impediría apilar las subcarpetas y se perdería
        # la rama entera sin ningún error.
        try {
            foreach ($archivo in $actual.EnumerateFiles()) {
                $ticks = $archivo.LastWriteTime.Ticks
                if ($ticks -gt $ticksUltimo) { $ticksUltimo = $ticks }

                # El archivo se cuenta siempre; sus bytes no se suman si otro
                # enlace duro al mismo contenido ya los sumó.
                $archivos++
                $sumar = $true
                if ($null -ne $vistos) {
                    $identidad = Get-IdentidadArchivo -Ruta $archivo.FullName
                    if ($null -ne $identidad -and -not $vistos.Add($identidad)) {
                        $sumar = $false
                        $compartidos++
                    }
                }
                if ($sumar) { $bytes += $archivo.Length }

                if ($buscaExtensiones -and $archivo.Extension -match $PatronExtensionValiosa) {
                    $documentos++
                }
            }
        } catch {
            $inaccesibles++
        }

        try {
            foreach ($sub in $actual.EnumerateDirectories()) {
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }

                if ($buscaCarpetas -and $sub.Name -match $PatronCarpetaValiosa) {
                    $valiosas.Add($sub.Name)
                }
                $pendientes.Push($sub)
            }
        } catch {
            $inaccesibles++
        }
    }

    return [pscustomobject]@{
        Bytes        = $bytes
        Archivos     = $archivos
        Ultimo       = if ($ticksUltimo -gt 0) { [datetime]::new($ticksUltimo) } else { $null }
        Inaccesibles = $inaccesibles
        # Solo tienen contenido si se han pedido los patrones.
        CarpetasValiosas = @($valiosas)
        ArchivosValiosos = $documentos
        # Archivos cuyos bytes no se han sumado por ser enlaces duros ya
        # contados. Cero si no se pidió.
        Compartidos      = $compartidos
    }
}

# ---------------------------------------------------------------------
# Recorrido de los módulos
#
# Get-ChildItem -Recurse en Windows PowerShell 5.1 se detiene en silencio a
# los 260 caracteres, así que los módulos no encontrarían nada al fondo de un
# node_modules anidado. Get-ElementosDelArbol aplica las mismas reglas que
# Get-ResumenArbol:
#
#   1. Pila propia con EnumerateDirectories, para saltar puntos de
#      reanálisis.
#   2. EnumerateFiles, que admite el prefijo y evita el proveedor de
#      PowerShell. La ganancia de velocidad es clara cuando se usa -Filtro
#      (lo resuelve Windows); en el resto lo que se gana es corrección.
#   3. El prefijo "\\?\" se pone una vez, en la raíz.
#   4. Cada enumeración en su propio try.
#
# Las rutas devueltas acaban en candidatos y en la guardia, así que nunca se
# leen de FullName (que llevaría el prefijo): se componen con la ruta limpia
# del padre más el nombre de la entrada.
# ---------------------------------------------------------------------

function Get-ElementosDelArbol {
    <#
    .SYNOPSIS
        Recorre una carpeta completa, sin detenerse en los 260 caracteres, y
        devuelve los elementos uno a uno.

    .DESCRIPTION
        Sustituye a Get-ChildItem -Recurse en los módulos (ver el bloque
        anterior).

        Devuelve objetos propios, no FileInfo, para que FullName no lleve el
        prefijo. Incluyen FullName, Name, BaseName, Extension, Length,
        LastWriteTime, LastAccessTime, CreationTime, DirectoryName y
        Attributes (de WIN32_FIND_DATA, sin volver al disco), además de
        EsCarpeta y TamanoEnDisco. No incluyen Directory; DirectoryName lleva
        la misma ruta.

        TamanoEnDisco vale $null salvo con -MedirEnDisco en archivos
        comprimidos con NTFS. $null significa "desconocido", nunca "no ocupa
        nada"; lo interpreta Get-EspacioRecuperable.

        Los puntos de reanálisis nunca se siguen y, por defecto, tampoco se
        devuelven. Los archivos ocultos y de sistema sí se devuelven (como con
        -Force): varios módulos dependen de ellos (Thumbs.db, desktop.ini,
        papelera) y una prueba lo fija.

    .PARAMETER Ruta
        Carpeta inicial. Si no existe no se devuelve nada y no se lanza.

    .PARAMETER Que
        'Archivos' (por defecto), 'Carpetas' o 'Todo'.

    .PARAMETER Filtro
        Patrón de nombre, como -Filter de Get-ChildItem; lo resuelve la API de
        Windows. Solo se aplica a archivos: filtrar carpetas cambiaría por
        dónde se desciende y podaría ramas enteras. Para eso está
        -NoDescender.

    .PARAMETER NoDescender
        Bloque que recibe una carpeta y devuelve $true si no hay que entrar en
        ella. Lo usa 20-Proyectos para no descender en node_modules, lo que
        evitaría proponer sus 'dist' y 'build' además del node_modules que los
        contiene.

    .PARAMETER Cancelado
        Bloque que devuelve $true cuando el usuario ha cancelado. Se consulta
        una vez por carpeta.

    .PARAMETER IncluirEnlaces
        Devuelve también los puntos de reanálisis, sin entrar en ellos.

    .PARAMETER MedirEnDisco
        Rellena TamanoEnDisco en los archivos comprimidos con NTFS.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta,
        [ValidateSet('Archivos', 'Carpetas', 'Todo')] [string] $Que = 'Archivos',
        [string] $Filtro = '*',
        [AllowNull()] [scriptblock] $NoDescender,
        [AllowNull()] [scriptblock] $Cancelado,
        [switch] $IncluirEnlaces,
        # Desactivado por defecto: cuesta una llamada al sistema por archivo.
        # Solo se consulta a los archivos con el atributo de compresión, que
        # sale gratis de la enumeración, así que en un árbol normal apenas
        # cuesta.
        [switch] $MedirEnDisco
    )

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return }

    # La barra final se quita antes de componer rutas: con ella saldrían dos
    # separadores seguidos y las rutas, que se comparan como texto en la
    # guardia y en las exclusiones, no coincidirían.
    $raizLimpia = $Ruta.TrimEnd([char]'\', [char]'/')
    if ([string]::IsNullOrEmpty($raizLimpia)) { return }

    # Mismo prefijo que Get-CarpetaParaRecorrer, pero aplicado a la cadena:
    # así funciona también si la carpeta de partida ya es larga.
    $rutaApi = ConvertTo-RutaLarga -Ruta $raizLimpia

    try {
        $raiz = [IO.DirectoryInfo]::new($rutaApi)
        if (-not $raiz.Exists) { return }
    } catch {
        # Etiqueta que no es una ruta, unidad inexistente o caracteres no
        # válidos: no se devuelve nada.
        Write-Verbose ("No se puede recorrer '{0}': {1}" -f $Ruta, $_.Exception.Message)
        return
    }

    $separador = [IO.Path]::DirectorySeparatorChar
    $emiteArchivos = ($Que -eq 'Archivos' -or $Que -eq 'Todo')
    $emiteCarpetas = ($Que -eq 'Carpetas' -or $Que -eq 'Todo')
    # El objeto de carpeta se construye si hay que devolverlo o si lo
    # necesita la poda.
    $armaCarpetas  = $emiteCarpetas -or ($null -ne $NoDescender)

    # Cada marco de la pila lleva el DirectoryInfo para la API (con prefijo)
    # y la ruta limpia con la que se componen las rutas devueltas.
    $pendientes = [Collections.Generic.Stack[object[]]]::new()
    $pendientes.Push(@($raiz, $raizLimpia))

    while ($pendientes.Count -gt 0) {
        if ($null -ne $Cancelado -and (& $Cancelado)) { break }

        $marco  = $pendientes.Pop()
        $actual = [IO.DirectoryInfo]$marco[0]
        $base   = [string]$marco[1]

        # Dos try independientes, como en Get-ResumenArbol.
        if ($emiteArchivos) {
            try {
                foreach ($archivo in $actual.EnumerateFiles($Filtro)) {
                    $nombre = $archivo.Name

                    # $null = desconocido. Solo se consulta con -MedirEnDisco
                    # y en archivos marcados como comprimidos.
                    $enDisco = $null
                    if ($MedirEnDisco -and (Test-EstaComprimido -Atributos ([int]$archivo.Attributes))) {
                        # Ruta limpia: Get-TamanoEnDisco añade el prefijo.
                        $enDisco = Get-TamanoEnDisco -Ruta ($base + $separador + $nombre)
                    }

                    [pscustomobject]@{
                        FullName       = $base + $separador + $nombre
                        Name           = $nombre
                        BaseName       = [IO.Path]::GetFileNameWithoutExtension($nombre)
                        Extension      = $archivo.Extension
                        Length         = $archivo.Length
                        LastWriteTime  = $archivo.LastWriteTime
                        LastAccessTime = $archivo.LastAccessTime
                        CreationTime   = $archivo.CreationTime
                        DirectoryName  = $base
                        Attributes     = $archivo.Attributes
                        TamanoEnDisco  = $enDisco
                        EsCarpeta      = $false
                    }
                }
            } catch {
                # No se usa Write-Error: con ErrorActionPreference = 'Stop'
                # (modo consola) abortaría el análisis por una sola carpeta.
                Write-Verbose ("No se han podido leer los archivos de '{0}': {1}" -f $base, $_.Exception.Message)
            }
        }

        try {
            foreach ($sub in $actual.EnumerateDirectories()) {
                $rutaSub = $base + $separador + $sub.Name
                $esEnlace = ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0

                $carpeta = $null
                if ($armaCarpetas) {
                    $carpeta = [pscustomobject]@{
                        FullName       = $rutaSub
                        Name           = $sub.Name
                        BaseName       = $sub.Name
                        Extension      = $sub.Extension
                        Length         = 0.0
                        LastWriteTime  = $sub.LastWriteTime
                        LastAccessTime = $sub.LastAccessTime
                        CreationTime   = $sub.CreationTime
                        DirectoryName  = $base
                        Attributes     = $sub.Attributes
                        # Siempre $null en carpetas, pero presente para que
                        # ambos tipos de elemento tengan las mismas propiedades.
                        TamanoEnDisco  = $null
                        EsCarpeta      = $true
                    }
                }

                if ($emiteCarpetas -and ($IncluirEnlaces -or -not $esEnlace)) { $carpeta }

                # Un punto de reanálisis nunca se sigue.
                if ($esEnlace) { continue }
                if ($null -ne $NoDescender -and (& $NoDescender $carpeta)) { continue }

                $pendientes.Push(@($sub, $rutaSub))
            }
        } catch {
            Write-Verbose ("No se han podido leer las subcarpetas de '{0}': {1}" -f $base, $_.Exception.Message)
        }
    }
}

function Measure-Ruta {
    <#
    .SYNOPSIS
        Devuelve el tamaño en bytes de un archivo o de una carpeta completa.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return 0.0 }

    # Get-Item y no [IO.Directory]::Exists: PowerShell resuelve rutas
    # relativas a $PWD y separadores que System.IO no entiende, y aquí llegan
    # también etiquetas que no son rutas. Si no encuentra nada, se intenta
    # como ruta larga.
    $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    if ($null -eq $item)     { return (Measure-RutaLarga -Ruta $Ruta) }
    if (Test-EsEnlace $item) { return 0.0 }
    if (-not $item.PSIsContainer) { return [double]$item.Length }

    return (Get-ResumenArbol -Carpeta $item).Bytes
}

function Measure-RutaLarga {
    <#
    .SYNOPSIS
        Mide algo cuya ruta supera los 260 caracteres sin pasar por el
        proveedor de PowerShell.

    .DESCRIPTION
        Get-Item no admite estas rutas, así que Measure-Ruta devolvería cero
        y el candidato quedaría por debajo del mínimo. Solo se llama cuando
        Get-Item ha devuelto $null; usa System.IO con el prefijo.

        Los puntos de reanálisis miden cero.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()] [AllowEmptyString()] [string] $Ruta)

    if (-not (Test-RutaDemasiadoLarga -Ruta $Ruta)) { return 0.0 }

    $larga = ConvertTo-RutaLarga -Ruta $Ruta
    if ($larga -eq $Ruta) { return 0.0 }

    try {
        if ([IO.Directory]::Exists($larga)) {
            $carpeta = [IO.DirectoryInfo]::new($larga)
            if (Test-EsEnlace $carpeta) { return 0.0 }
            return (Get-ResumenArbol -Carpeta $carpeta).Bytes
        }
        if ([IO.File]::Exists($larga)) {
            $archivo = [IO.FileInfo]::new($larga)
            if (Test-EsEnlace $archivo) { return 0.0 }
            return [double]$archivo.Length
        }
    } catch {
        # No existe, sin permiso o no es una ruta: se devuelve cero.
        Write-Verbose ("No se ha podido medir la ruta larga '{0}': {1}" -f $Ruta, $_.Exception.Message)
    }
    return 0.0
}

function Measure-RutaDetalle {
    <#
    .SYNOPSIS
        Tamaño, número de archivos y fecha del último cambio de una carpeta.
    #>
    [CmdletBinding()]
    param([string] $Ruta)

    $resultado = [pscustomobject]@{
        Bytes    = 0.0
        Archivos = 0
        Ultimo   = [datetime]'1900-01-01'
    }
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $resultado }

    $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $resultado }

    # Con un archivo suelto se devuelven sus propios datos (un archivo).
    if (-not $item.PSIsContainer) {
        $resultado.Bytes    = [double]$item.Length
        $resultado.Archivos = 1
        $resultado.Ultimo   = $item.LastWriteTime
        return $resultado
    }

    $resumen = Get-ResumenArbol -Carpeta $item
    $resultado.Bytes    = $resumen.Bytes
    $resultado.Archivos = $resumen.Archivos
    if ($null -ne $resumen.Ultimo) { $resultado.Ultimo = $resumen.Ultimo }
    else                           { $resultado.Ultimo = $item.LastWriteTime }
    return $resultado
}

function Get-UnidadesAnalizables {
    <#
    .SYNOPSIS
        Lista las unidades que el programa analiza, con su espacio, su clase
        y si se puede borrar en ellas.

    .DESCRIPTION
        Cada unidad incluye Clase y Borrable. Aparecer en esta lista significa
        que se analiza, no que se pueda borrar: una unidad extraíble entra en
        el mapa, la vista de archivos y el informe, pero nunca produce un
        candidato borrable. La regla vive en Extraibles.ps1.

        Usa System.IO.DriveInfo en vez de Win32_LogicalDisk: el dato es el
        mismo, pero la consulta CIM cuesta decenas de milisegundos (más si
        hay que arrancar WMI) y falla si el servicio WMI está dañado.

        IsReady es imprescindible: en una unidad sin formato o sin medio, leer
        VolumeLabel o TotalSize lanza IOException.
    #>
    [CmdletBinding()]
    param()

    try   { $unidades = [IO.DriveInfo]::GetDrives() }
    catch { return }

    foreach ($unidad in $unidades) {
        # La decisión de qué unidades se analizan vive en Extraibles.ps1.
        $clase = Get-ClaseDeUnidad -Tipo $unidad.DriveType
        if (-not (Test-UnidadAnalizable -Clase $clase).Analizable) { continue }
        if (-not $unidad.IsReady) { continue }

        try {
            $total = [double]$unidad.TotalSize
            # AvailableFreeSpace: espacio disponible para este usuario,
            # respetando cuotas.
            $libre = [double]$unidad.AvailableFreeSpace
            $etiqueta = $unidad.VolumeLabel
        } catch {
            continue
        }

        $usado = $total - $libre
        [pscustomobject]@{
            # Name viene como "C:\" y el programa espera "C:".
            Letra        = $unidad.Name.TrimEnd('\')
            Etiqueta     = if ([string]::IsNullOrWhiteSpace($etiqueta)) { 'Disco local' } else { $etiqueta }
            Total        = $total
            Libre        = $libre
            PorcentajeUsado = if ($total -gt 0) { [Math]::Round(100 * $usado / $total, 1) } else { 0 }
            # La clasificación viaja con la unidad para que nadie tenga que
            # volver a calcularla.
            Clase        = $clase
            Borrable     = (Test-PuedeProducirCandidatoBorrable -Clase $clase)
        }
    }
}

function Get-TipoDeUnidad {
    <#
    .SYNOPSIS
        DriveType de la unidad a la que pertenece una ruta, o $null si no se
        puede saber.

    .DESCRIPTION
        Lo usa el segundo corte de Get-MotivoNoSeBorra, que necesita la clase
        del disco sin depender de la lista de unidades de la configuración (un
        disco conectado después de arrancar no está en ella).

        Ante la duda devuelve $null, que quien llama trata como "desconocida":
        el corte no se aplica y deciden las demás comprobaciones. Inventar una
        clase sería peor en ambos sentidos.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta)

    $letra = Get-LetraUnidad -Ruta $Ruta
    if ([string]::IsNullOrWhiteSpace($letra)) { return $null }

    try {
        # DriveInfo, como en Get-UnidadesAnalizables.
        return ([IO.DriveInfo]::new($letra + '\')).DriveType
    } catch {
        # Fuera de Windows o con una letra no montada lanza: es el caso
        # "no lo sé".
        Write-Verbose "No se ha podido saber el tipo de la unidad '$letra': $($_.Exception.Message)"
        return $null
    }
}

function Get-PropiedadUnidad {
    <#
    .SYNOPSIS
        Lee una propiedad de tamaño de una unidad concreta ("C:").
    .DESCRIPTION
        Los nombres de propiedad (FreeSpace, Size) se conservan de
        Win32_LogicalDisk por compatibilidad con los llamantes; por debajo se
        usa DriveInfo (ver Get-UnidadesAnalizables). Lo llama el resumen del
        pie cada vez que el usuario marca una casilla.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [string] $Unidad,
        [ValidateSet('FreeSpace', 'Size')]
        [string] $Propiedad
    )

    if ([string]::IsNullOrWhiteSpace($Unidad)) { return 0.0 }
    try {
        $disco = [IO.DriveInfo]::new($Unidad)
        if (-not $disco.IsReady) { return 0.0 }
        if ($Propiedad -eq 'Size') { return [double]$disco.TotalSize }
        return [double]$disco.AvailableFreeSpace
    } catch {
        # Letra inexistente, unidad desconectada o cadena que no es una
        # unidad.
        return 0.0
    }
}

function Get-LetraUnidad {
    <#
    .SYNOPSIS
        Letra de unidad de una ruta ("C:"), o cadena vacía si no la tiene.
    .DESCRIPTION
        Devuelve vacío para rutas de red, rutas relativas y etiquetas que no
        son rutas (método 'Comando'). El llamante decide qué hacer en ese
        caso.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return '' }
    if ($Ruta -match '^[\\/]{2}')            { return '' }   # \\servidor\...
    if ($Ruta -notmatch '^[A-Za-z]:')        { return '' }
    return $Ruta.Substring(0, 2).ToUpperInvariant()
}

function Test-UnidadSeleccionada {
    <#
    .SYNOPSIS
        Indica si una ruta está en una unidad que el usuario quiere limpiar.
    .DESCRIPTION
        Lee $Configuracion.UnidadesSeleccionadas. Se comprueba en
        ModuleRegistry.ps1, por donde pasan todos los candidatos.

        En los casos ambiguos responde que sí: lista vacía o inexistente (modo
        consola, configuración antigua, pruebas) o ruta sin letra de unidad
        (etiqueta, recurso de red). Responder que no ocultaría candidatos
        legítimos sin explicación.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $Ruta,
        $Configuracion
    )

    if ($null -eq $Configuracion) { return $true }
    $propiedad = $Configuracion.PSObject.Properties['UnidadesSeleccionadas']
    if ($null -eq $propiedad) { return $true }

    $elegidas = @($propiedad.Value | Where-Object { $_ })
    if ($elegidas.Count -eq 0) { return $true }

    $letra = Get-LetraUnidad $Ruta
    if ([string]::IsNullOrEmpty($letra)) { return $true }

    foreach ($u in $elegidas) {
        if ((Get-LetraUnidad $u) -eq $letra) { return $true }
    }
    return $false
}

function Get-EspacioLibre {
    <#
    .SYNOPSIS
        Espacio libre en bytes de una unidad concreta ("C:").
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([string] $Unidad)

    return (Get-PropiedadUnidad -Unidad $Unidad -Propiedad 'FreeSpace')
}

function Test-ProcesoAbierto {
    <#
    .SYNOPSIS
        Comprueba si alguno de los procesos indicados está en ejecución.
    .DESCRIPTION
        Sirve para avisar de que hay que cerrar un programa antes de vaciar
        su caché; si no, los archivos en uso se saltan.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]] $Nombres)

    # Una sola enumeración de procesos y un conjunto: cada Get-Process -Name
    # recorre la tabla de procesos completa.
    if ($null -eq $Nombres -or @($Nombres).Count -eq 0) { return @() }

    $enMarcha = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($proceso in @(Get-Process -ErrorAction SilentlyContinue)) {
            [void]$enMarcha.Add($proceso.ProcessName)
        }
    } catch {
        # Sin lista de procesos no se avisa; no afecta a lo que se borra.
        return @()
    }

    $abiertos = [Collections.Generic.List[string]]::new()
    foreach ($nombre in $Nombres) {
        if ($enMarcha.Contains($nombre)) { $abiertos.Add($nombre) }
    }
    return @($abiertos)
}

function Get-CarpetaConocida {
    <#
    .SYNOPSIS
        Resuelve una carpeta especial del usuario respetando redirecciones.
    .DESCRIPTION
        No se usa "$env:USERPROFILE\Documents" directamente porque con
        OneDrive o con Windows en otro idioma la carpeta real está en otro
        sitio.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads')]
        [string] $Nombre
    )

    $ruta = $null
    switch ($Nombre) {
        'Desktop'   { $ruta = [Environment]::GetFolderPath('Desktop') }
        'Documents' { $ruta = [Environment]::GetFolderPath('MyDocuments') }
        'Pictures'  { $ruta = [Environment]::GetFolderPath('MyPictures') }
        'Music'     { $ruta = [Environment]::GetFolderPath('MyMusic') }
        'Videos'    { $ruta = [Environment]::GetFolderPath('MyVideos') }
        'Downloads' {
            # Descargas no tiene entrada en Environment.SpecialFolder.
            $guid  = '{374DE290-123F-4565-9164-39C4925E467B}'
            $clave = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
            $valor = (Get-ItemProperty -Path $clave -Name $guid -ErrorAction SilentlyContinue).$guid
            if ($valor) {
                $ruta = [Environment]::ExpandEnvironmentVariables($valor)
                # ExpandEnvironmentVariables no falla con una variable
                # inexistente: deja "%VAR%" en la cadena. Una ruta así no
                # existe, así que se prefiere devolver $null.
                if ($ruta -match '%[^%]+%') { $ruta = $null }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                $ruta = Join-Path $env:USERPROFILE 'Downloads'
            }
            # Sin USERPROFILE (fuera de Windows) se devuelve $null en vez de
            # dejar que Join-Path lance.
        }
    }

    if ([string]::IsNullOrWhiteSpace($ruta)) { return $null }
    return $ruta.TrimEnd('\')
}

function Select-RutasNoAnidadas {
    <#
    .SYNOPSIS
        Filtra una lista de carpetas dejando solo las que no cuelgan de
        ninguna otra de la misma lista.
    .DESCRIPTION
        Con OneDrive y Known Folder Move, el Escritorio puede estar dentro de
        la carpeta "OneDrive", que también se ofrece como zona. Sin este
        filtro un mismo archivo se indexaría dos veces con el mismo FullName,
        y el módulo de duplicados podría proponer borrar el único ejemplar.

        Las entradas nulas o vacías se ignoran.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()] [AllowEmptyCollection()] [string[]] $Rutas)

    $aceptadas = [Collections.Generic.List[string]]::new()
    $validas = @($Rutas | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($ruta in @($validas | Sort-Object Length)) {
        $normalizada = $ruta.TrimEnd('\')
        $contenida = $false
        foreach ($padre in $aceptadas) {
            if ($normalizada.Equals($padre, [StringComparison]::OrdinalIgnoreCase) -or
                $normalizada.StartsWith($padre + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $contenida = $true
                break
            }
        }
        if (-not $contenida) { $aceptadas.Add($normalizada) }
    }
    return @($aceptadas)
}

function Move-ArchivoReemplazando {
    <#
    .SYNOPSIS
        Coloca un archivo recién escrito en el lugar de otro, sin dejar
        nunca el destino a medio escribir.
    .DESCRIPTION
        El origen debe estar en la misma carpeta que el destino. Si el
        destino existe se usa File.Replace (ReplaceFile en Windows, un
        reemplazo atómico); si no, File.Move. Move-Item -Force no sirve: en
        Windows PowerShell 5.1 borra el destino antes de mover y un corte
        entre los dos pasos deja sin archivo.

        Lanza si no se puede reemplazar; el origen se queda donde estaba.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Origen,
        [Parameter(Mandatory)] [string] $Destino
    )

    if (-not $PSCmdlet.ShouldProcess($Destino, 'Reemplazar con ' + $Origen)) { return }
    if ([IO.File]::Exists($Destino)) {
        # NullString: con $null, PowerShell pasaría una cadena vacía y Replace lanzaría.
        [IO.File]::Replace($Origen, $Destino, [System.Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Move($Origen, $Destino)
    }
}
