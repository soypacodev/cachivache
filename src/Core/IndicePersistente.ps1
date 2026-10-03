<#
.SYNOPSIS
    Persistencia binaria del índice de espacio: guardado en disco y
    lectura posterior.

.DESCRIPTION
    Regla principal:

        EL ÍNDICE GUARDADO SOLO SIRVE PARA DIBUJAR EL MAPA,
        NUNCA PARA DECIDIR QUÉ SE BORRA.

    El borrado se basa siempre en lo observado en la ejecución actual (el
    recorrido de New-IndiceDisco y la revalidación de la guardia). Si este
    archivo está obsoleto o dañado, lo peor que puede pasar es un mapa mal
    dibujado. Por eso aquí no hay ninguna función que devuelva candidatos.

    -------------------------------------------------------------------
    FORMATO BINARIO Y TRES TABLAS

    Medido con índices sintéticos de hasta un millón de entradas:
      * JSON: con un millón de entradas ConvertTo-Json agota la memoria
        sin lanzar; con 100.000, guardar y cargar es más lento que
        recorrer el disco.
      * CSV: unas seis veces más lento en carga que el binario.
      * BinaryWriter/BinaryReader: un millón de entradas en ~1 s.

    Las entradas se cargan como diccionarios, no como pscustomobject:
    componer objetos de PowerShell multiplica por doce el tiempo de carga.

    Se guardan tres tablas:
      1. Archivos.
      2. Carpetas con sus totales ya sumados (recalcularlos al cargar
         costaría más que recorrer el disco).
      3. Número de referencia NTFS de cada carpeta -> ruta. El diario de
         cambios trae la referencia del padre, no su ruta.

    Coste real de esta implementación (Linux, PowerShell 7):

        10.000 entradas    guardar 0,06-0,19 s   cargar 0,05-0,13 s
        100.000 entradas   guardar 0,38 s        cargar 0,50 s
        1.000.000 entradas                       cargar 6,51 s

    Es más que la medición de referencia porque cada entrada se devuelve
    con los seis campos de New-IndiceDisco. Compensa porque New-IndiceDisco
    limita la lista a MaximoArchivos (20.000 por omisión). Si se sube ese
    tope, construir cada entrada con un literal @{...} es unas 2,3 veces
    más rápido, a cambio de depender del orden de evaluación del literal.

    -------------------------------------------------------------------
    ARCHIVOS NO FIABLES

    Un archivo truncado, con basura, de otra versión del formato, vacío o
    inexistente devuelve $null sin lanzar; quien llama vuelve a recorrer
    el disco.

    -------------------------------------------------------------------
    FORMATO

    CABECERA (se lee sin tocar el cuerpo):

        firma        8 bytes  "CACHIDX" + 0x00
        Version      int32    versión del formato
        SerieVolumen cadena   número de serie del volumen
        IdDiario     cadena   identificador del diario USN
        UsnCorte     int64    USN hasta donde se leyó
        Entradas     int32    número de entradas de archivo del cuerpo
        Suma         cadena   suma de comprobación del cuerpo
        Escrito      int64    fecha de escritura (DateTime.ToBinary)

    CUERPO (hasta el final del archivo):

        LongitudCuerpo int64  bytes del cuerpo, incluidos estos ocho
        Raices         int32 + n cadenas
        Bytes          double
        TotalArchivos  int32
        Compartidos    int32
        Inaccesibles   int32
        UmbralArchivo  double
        Carpetas       int32 + n x (Ruta, Nombre, Nivel, Bytes, Propios,
                                    Archivos, Ultimo)
        Archivos       int32 + n x (Ruta, Nombre, Carpeta, Extension,
                                    Bytes, Ultimo)
        Referencias    int32 + n x (uint64, Ruta)

    Decisiones del formato:

    1. LongitudCuerpo va dentro del cuerpo para no alterar los campos de
       la cabecera, y permite detectar un archivo truncado sin leer el
       cuerpo (lo que Get-CabeceraIndice evita hacer).
    2. Las cadenas de la cabecera llevan longitud int32 explícita y se
       valida que quepa en el archivo, porque se leen antes de cualquier
       validación; una longitud disparatada pediría un buffer enorme. Las
       del cuerpo usan Write/ReadString de .NET (más rápido), ya que solo
       se leen tras comprobar la suma.
    3. Los bucles de las tablas no llaman a funciones de PowerShell por
       entrada (unos 10 µs por llamada); el código va en línea a propósito.
#>

# "CACHIDX" y un cero: permite descartar un archivo ajeno en la primera
# lectura.
$script:FirmaIndicePersistente = [byte[]] @(0x43, 0x41, 0x43, 0x48, 0x49, 0x44, 0x58, 0x00)

# Se incrementa al cambiar el formato. Un archivo con otra versión (mayor
# o menor) se descarta entero.
$script:VersionFormatoIndice = 1

function Get-VersionFormatoIndice {
    <#
    .SYNOPSIS
        Versión del formato del índice que entiende este programa.

    .NOTES
        Se expone como función (igual que Get-CaducidadIndice y
        Get-SueloCobertura) para que quien escribe y quien comprueba usen
        el mismo valor: en un archivo cargado con dot-source, $script:
        apunta al ámbito de quien llama.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$script:VersionFormatoIndice
}

# Mismo centinela que New-EntradaCarpeta para "sin fecha".
$script:FechaCeroIndice = [datetime]'1900-01-01'

function Write-CadenaIndice {
    <#
    .SYNOPSIS
        Escribe una cadena de la cabecera: longitud int32 y bytes UTF-8.

    .DESCRIPTION
        Solo para la cabecera (ver el punto 2 de las decisiones del formato).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Escritor,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Texto
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Texto)
    $Escritor.Write([int]$bytes.Length)
    if ($bytes.Length -gt 0) { $Escritor.Write($bytes) }
}

function Read-CadenaIndice {
    <#
    .SYNOPSIS
        Lee una cadena de la cabecera, comprobando que la longitud
        declarada cabe en lo que queda de archivo.

    .DESCRIPTION
        Lanza si no cabe; el try/catch de quien llama lo convierte en $null.
        Evita reservar memoria para longitudes absurdas en archivos dañados.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] $Lector)

    $flujo = $Lector.BaseStream
    $longitud = $Lector.ReadInt32()
    if ($longitud -lt 0 -or $longitud -gt ($flujo.Length - $flujo.Position)) {
        throw "Cadena imposible en la cabecera: dice $longitud bytes."
    }
    if ($longitud -eq 0) { return '' }
    return [Text.Encoding]::UTF8.GetString($Lector.ReadBytes($longitud))
}

function Read-CabeceraIndiceFlujo {
    <#
    .SYNOPSIS
        Lee la cabecera de un flujo abierto; $null si el archivo no es un
        índice o es de otra versión.

    .DESCRIPTION
        Compartida por Get-CabeceraIndice y Read-IndiceDisco para que ambos
        apliquen el mismo criterio de cabecera válida. Al volver, el flujo
        queda al principio del cuerpo.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [AllowNull()] $Lector)

    $flujo = $Lector.BaseStream
    $firma = $Lector.ReadBytes($script:FirmaIndicePersistente.Length)
    if ($null -eq $firma -or $firma.Length -ne $script:FirmaIndicePersistente.Length) {
        return $null
    }
    for ($i = 0; $i -lt $firma.Length; $i++) {
        if ($firma[$i] -ne $script:FirmaIndicePersistente[$i]) { return $null }
    }

    $version = $Lector.ReadInt32()
    # Cualquier versión distinta (mayor o menor) se rechaza.
    if ($version -ne $script:VersionFormatoIndice) { return $null }

    $serie    = Read-CadenaIndice -Lector $Lector
    $diario   = Read-CadenaIndice -Lector $Lector
    $corte    = $Lector.ReadInt64()
    $entradas = $Lector.ReadInt32()
    $suma     = Read-CadenaIndice -Lector $Lector
    $escrito  = [datetime]::FromBinary($Lector.ReadInt64())

    if ($entradas -lt 0) { return $null }

    # La longitud declarada del cuerpo, comparada con lo que queda de
    # archivo, detecta truncamientos o datos añadidos sin leer entradas.
    $declarada = $Lector.ReadInt64()
    $real = ($flujo.Length - $flujo.Position) + 8
    if ($declarada -ne $real) { return $null }

    return [pscustomobject]@{
        Version      = [int]$version
        SerieVolumen = [string]$serie
        IdDiario     = [string]$diario
        UsnCorte     = [long]$corte
        Entradas     = [int]$entradas
        Suma         = [string]$suma
        Escrito      = $escrito
    }
}

function Get-SumaCuerpoIndice {
    <#
    .SYNOPSIS
        Suma de comprobación (SHA-256, hexadecimal) del cuerpo del índice.

    .DESCRIPTION
        Detecta cuerpos truncados o modificados (típicamente por un corte
        durante la escritura). SHA-256 cuesta décimas de segundo incluso
        con un millón de entradas, frente a segundos de recorrido.

        Un cuerpo nulo y uno vacío dan la misma suma: un índice sin
        entradas es un caso válido.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [byte[]] $Bytes
    )

    try {
        $datos = $Bytes
        if ($null -eq $datos) { $datos = [byte[]]::new(0) }

        $algoritmo = [Security.Cryptography.SHA256]::Create()
        try {
            $resumen = $algoritmo.ComputeHash($datos)
        } finally {
            $algoritmo.Dispose()
        }

        $texto = [Text.StringBuilder]::new(64)
        foreach ($b in $resumen) { [void]$texto.Append($b.ToString('x2')) }
        return $texto.ToString()
    } catch {
        # Sin suma, quien llama la verá como no válida y recorrerá de nuevo.
        return $null
    }
}

function Save-IndiceDisco {
    <#
    .SYNOPSIS
        Guarda el índice en disco, con su cabecera, de forma atómica.

    .PARAMETER Indice
        Lo que devuelve New-IndiceDisco. También vale lo que devuelve
        Read-IndiceDisco: la ida y vuelta se puede repetir.
    .PARAMETER Ruta
        Archivo destino.
    .PARAMETER SerieVolumen
        Número de serie del volumen, para detectar que la letra de unidad
        es hoy OTRO disco.
    .PARAMETER IdDiario
        Identificador del diario USN. Si cambia, la historia anterior ya
        no existe.
    .PARAMETER UsnCorte
        USN hasta donde se leyó el diario.
    .PARAMETER Referencias
        Tabla de referencia de carpeta a ruta. Puede ser $null.
    .PARAMETER Escrito
        Fecha de escritura. Es parámetro para poder probar la caducidad.

    .OUTPUTS
        [bool] Si se ha escrito.

    .NOTES
        Escritura atómica, como Add-EntradaHistorial: se escribe en un
        temporal junto al destino y se reemplaza con Move-Item -Force (lo
        más parecido a un reemplazo atómico en PowerShell 5.1 y 7). Así un
        corte durante la escritura no deja un índice truncado.

        El temporal lleva el PID para que dos procesos no compartan archivo
        intermedio. Si el reemplazo falla, el .tmp no se borra aquí (en
        src/Core solo Remove.ps1 borra archivos); la siguiente escritura
        del mismo proceso lo sobrescribe.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Indice,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta,
        [AllowNull()] [AllowEmptyString()] [string] $SerieVolumen = '',
        [AllowNull()] [AllowEmptyString()] [string] $IdDiario = '',
        [long] $UsnCorte = 0,
        [AllowNull()] $Referencias = $null,
        [datetime] $Escrito = (Get-Date)
    )

    if ($null -eq $Indice) { return $false }
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Guardar el índice de espacio')) { return $false }

    $memoria  = $null
    $escritor = $null
    $flujo    = $null
    $salida   = $null
    try {
        # --- El cuerpo, primero en memoria --------------------------------
        # Se necesita completo para calcular la suma de la cabecera, que va
        # delante (unos 65 MB por millón de entradas).
        $memoria  = [IO.MemoryStream]::new()
        $escritor = [IO.BinaryWriter]::new($memoria, [Text.UTF8Encoding]::new($false))

        # Hueco para la longitud del cuerpo; se rellena al final.
        $escritor.Write([long]0)

        $raices = [Collections.Generic.List[string]]::new()
        if ($null -ne $Indice.Raices) {
            foreach ($r in $Indice.Raices) {
                if ($null -ne $r) { $raices.Add([string]$r) }
            }
        }
        $escritor.Write([int]$raices.Count)
        foreach ($r in $raices) { $escritor.Write([string]$r) }

        $escritor.Write([double]$Indice.Bytes)
        $escritor.Write([int]$Indice.TotalArchivos)
        $escritor.Write([int]$Indice.Compartidos)
        $escritor.Write([int]$Indice.Inaccesibles)
        $escritor.Write([double]$Indice.UmbralArchivo)

        # --- Tabla 2: las carpetas, con los totales YA sumados ------------
        $carpetas = @()
        if ($null -ne $Indice.Carpetas) { $carpetas = @($Indice.Carpetas.Values) }
        $escritor.Write([int]$carpetas.Count)
        foreach ($c in $carpetas) {
            $escritor.Write([string]$c.Ruta)
            $escritor.Write([string]$c.Nombre)
            $escritor.Write([int]$c.Nivel)
            $escritor.Write([double]$c.Bytes)
            $escritor.Write([double]$c.Propios)
            $escritor.Write([int]$c.Archivos)
            $u = $c.Ultimo
            if ($u -isnot [datetime]) { $u = $script:FechaCeroIndice }
            $escritor.Write([long]$u.ToBinary())
        }

        # --- Tabla 1: los archivos ----------------------------------------
        $archivos = @()
        if ($null -ne $Indice.Archivos) { $archivos = @($Indice.Archivos) }
        $escritor.Write([int]$archivos.Count)
        foreach ($a in $archivos) {
            $escritor.Write([string]$a.Ruta)
            $escritor.Write([string]$a.Nombre)
            $escritor.Write([string]$a.Carpeta)
            $escritor.Write([string]$a.Extension)
            $escritor.Write([double]$a.Bytes)
            $u = $a.Ultimo
            if ($u -isnot [datetime]) { $u = $script:FechaCeroIndice }
            $escritor.Write([long]$u.ToBinary())
        }

        # --- Tabla 3: referencia de carpeta a ruta ------------------------
        $claves = @()
        if ($null -ne $Referencias -and $null -ne $Referencias.Keys) {
            $claves = @($Referencias.Keys)
        }
        $escritor.Write([int]$claves.Count)
        foreach ($k in $claves) {
            $escritor.Write([uint64]$k)
            $escritor.Write([string]$Referencias[$k])
        }

        $escritor.Flush()
        $memoria.Position = 0
        $escritor.Write([long]$memoria.Length)
        $escritor.Flush()
        $cuerpo = $memoria.ToArray()

        $suma = Get-SumaCuerpoIndice -Bytes $cuerpo
        if ([string]::IsNullOrEmpty($suma)) { return $false }

        # --- Escritura al temporal y reemplazo ----------------------------
        $temporal = "$Ruta.$PID.tmp"
        $flujo = [IO.File]::Open($temporal, [IO.FileMode]::Create, [IO.FileAccess]::Write,
                                 [IO.FileShare]::None)
        $salida = [IO.BinaryWriter]::new($flujo, [Text.UTF8Encoding]::new($false))
        $salida.Write($script:FirmaIndicePersistente)
        $salida.Write([int]$script:VersionFormatoIndice)
        Write-CadenaIndice -Escritor $salida -Texto $SerieVolumen
        Write-CadenaIndice -Escritor $salida -Texto $IdDiario
        $salida.Write([long]$UsnCorte)
        $salida.Write([int]$archivos.Count)
        Write-CadenaIndice -Escritor $salida -Texto $suma
        $salida.Write([long]$Escrito.ToBinary())
        $salida.Write($cuerpo)
        $salida.Flush()
        $salida.Dispose(); $salida = $null
        $flujo = $null

        Move-Item -LiteralPath $temporal -Destination $Ruta -Force -ErrorAction Stop
        return $true
    } catch {
        # Sin error visible: si no se guarda, la próxima vez se recorre el
        # disco.
        Write-Verbose "No se ha podido guardar el índice: $($_.Exception.Message)"
        return $false
    } finally {
        if ($null -ne $salida)   { $salida.Dispose() }
        if ($null -ne $flujo)    { $flujo.Dispose() }
        if ($null -ne $escritor) { $escritor.Dispose() }
        if ($null -ne $memoria)  { $memoria.Dispose() }
    }
}

function Get-CabeceraIndice {
    <#
    .SYNOPSIS
        Lee solo la cabecera del índice, sin cargar el cuerpo. $null si el
        archivo no sirve.

    .DESCRIPTION
        Permite decidir si el índice es aprovechable antes de cargarlo. Lee
        la firma, los siete campos y la longitud del cuerpo.

        Devuelve $null, sin lanzar, si el archivo no existe, no es un
        índice, es de otra versión, está truncado o tiene datos añadidos.

        No verifica la suma del cuerpo (exigiría leerlo entero); eso lo
        hace Read-IndiceDisco.

    .OUTPUTS
        [pscustomobject] con exactamente siete campos: Version,
        SerieVolumen, IdDiario, UsnCorte, Entradas, Suma y Escrito.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta
    )

    $flujo  = $null
    $lector = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Ruta)) { return $null }
        if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) { return $null }

        # FileShare::ReadWrite: otro proceso puede estar reemplazando el
        # archivo; si lo leído no cuadra, se descarta por firma o longitud.
        $flujo = [IO.File]::Open($Ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                 [IO.FileShare]::ReadWrite)
        $lector = [IO.BinaryReader]::new($flujo, [Text.UTF8Encoding]::new($false))
        return (Read-CabeceraIndiceFlujo -Lector $lector)
    } catch {
        return $null
    } finally {
        if ($null -ne $lector) { $lector.Dispose() }
        if ($null -ne $flujo)  { $flujo.Dispose() }
    }
}

function Read-IndiceDisco {
    <#
    .SYNOPSIS
        Carga el índice entero desde disco. $null si el archivo no sirve.

    .DESCRIPTION
        Devuelve la misma forma que New-IndiceDisco (Carpetas, Archivos,
        Raices, Bytes, TotalArchivos, Compartidos, Inaccesibles y
        UmbralArchivo), con dos diferencias:

          * Cada entrada es un diccionario, no un pscustomobject. Se accede
            igual ($entrada.Ruta), pero Select-Object -ExpandProperty no
            funciona, y en PowerShell 5.1 Sort-Object necesita una
            expresión ({ $_.Bytes }) en lugar del nombre de propiedad.
          * Incluye además Referencias y Cabecera.

        Devuelve $null, sin lanzar, ante cualquier archivo que no se pueda
        validar entero: truncado, alterado, de otra versión, vacío, con
        basura o inexistente.

    .OUTPUTS
        [pscustomobject] con los totales para dibujar el mapa. No contiene
        candidatos a borrado.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta,
        # Forma de la tabla de archivos. Por omisión, un array (como
        # New-IndiceDisco; lo usan el mapa, el informe y la vista de
        # archivos). Con -ComoDiccionario, una tabla ruta -> entrada para
        # las búsquedas de Update-IndiceConCambios. Se elige al leer para no
        # construir primero la forma que no se necesita.
        [switch] $ComoDiccionario
    )

    $flujo        = $null
    $lector       = $null
    $memoria      = $null
    $cuerpo       = $null
    $lectorCuerpo = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Ruta)) { return $null }
        if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) { return $null }

        $flujo = [IO.File]::Open($Ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                 [IO.FileShare]::ReadWrite)
        $lector = [IO.BinaryReader]::new($flujo, [Text.UTF8Encoding]::new($false))

        $cabecera = Read-CabeceraIndiceFlujo -Lector $lector
        if ($null -eq $cabecera) { return $null }

        # Se retrocede ocho bytes para que la suma cubra también la
        # longitud del cuerpo, ya leída por la cabecera.
        $flujo.Position = $flujo.Position - 8
        $restante = $flujo.Length - $flujo.Position
        if ($restante -lt 8 -or $restante -gt [int]::MaxValue) { return $null }

        $cuerpo = $lector.ReadBytes([int]$restante)
        if ($null -eq $cuerpo -or $cuerpo.Length -ne $restante) { return $null }

        $suma = Get-SumaCuerpoIndice -Bytes $cuerpo
        if ([string]::IsNullOrEmpty($suma)) { return $null }
        if (-not $suma.Equals([string]$cabecera.Suma, [StringComparison]::OrdinalIgnoreCase)) {
            # Truncado o alterado: se descarta entero, sin aprovechar nada.
            return $null
        }

        $memoria = [IO.MemoryStream]::new($cuerpo, $false)
        $lectorCuerpo = [IO.BinaryReader]::new($memoria, [Text.UTF8Encoding]::new($false))

        $declarada = $lectorCuerpo.ReadInt64()
        if ($declarada -ne $cuerpo.Length) { return $null }

        $nRaices = $lectorCuerpo.ReadInt32()
        if ($nRaices -lt 0 -or $nRaices -gt ($memoria.Length - $memoria.Position)) { return $null }
        $raices = [Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $nRaices; $i++) { $raices.Add($lectorCuerpo.ReadString()) }

        $bytesTotal    = $lectorCuerpo.ReadDouble()
        $totalArchivos = $lectorCuerpo.ReadInt32()
        $compartidos   = $lectorCuerpo.ReadInt32()
        $inaccesibles  = $lectorCuerpo.ReadInt32()
        $umbral        = $lectorCuerpo.ReadDouble()

        # --- Las carpetas -------------------------------------------------
        # OrdinalIgnoreCase, como New-IndiceDisco: las rutas de Windows no
        # distinguen mayúsculas.
        $nCarpetas = $lectorCuerpo.ReadInt32()
        if ($nCarpetas -lt 0 -or $nCarpetas -gt ($memoria.Length - $memoria.Position)) {
            return $null
        }
        $carpetas = [Collections.Generic.Dictionary[string, object]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
        for ($i = 0; $i -lt $nCarpetas; $i++) {
            # En línea a propósito: sin llamadas a funciones por entrada.
            $entrada = [Collections.Generic.Dictionary[string, object]]::new(
                           7, [StringComparer]::OrdinalIgnoreCase)
            $entrada['Ruta']     = $lectorCuerpo.ReadString()
            $entrada['Nombre']   = $lectorCuerpo.ReadString()
            $entrada['Nivel']    = $lectorCuerpo.ReadInt32()
            $entrada['Bytes']    = $lectorCuerpo.ReadDouble()
            $entrada['Propios']  = $lectorCuerpo.ReadDouble()
            $entrada['Archivos'] = $lectorCuerpo.ReadInt32()
            $entrada['Ultimo']   = [datetime]::FromBinary($lectorCuerpo.ReadInt64())
            $carpetas[[string]$entrada['Ruta']] = $entrada
        }

        # --- Los archivos -------------------------------------------------
        $nArchivos = $lectorCuerpo.ReadInt32()
        if ($nArchivos -lt 0 -or $nArchivos -gt ($memoria.Length - $memoria.Position)) {
            return $null
        }
        $archivos = [Collections.Generic.List[object]]::new($nArchivos)
        $porRuta  = [Collections.Generic.Dictionary[string, object]]::new(
                        [Math]::Max(1, $nArchivos), [StringComparer]::OrdinalIgnoreCase)
        for ($i = 0; $i -lt $nArchivos; $i++) {
            $entrada = [Collections.Generic.Dictionary[string, object]]::new(
                           6, [StringComparer]::OrdinalIgnoreCase)
            $entrada['Ruta']      = $lectorCuerpo.ReadString()
            $entrada['Nombre']    = $lectorCuerpo.ReadString()
            $entrada['Carpeta']   = $lectorCuerpo.ReadString()
            $entrada['Extension'] = $lectorCuerpo.ReadString()
            $entrada['Bytes']     = $lectorCuerpo.ReadDouble()
            $entrada['Ultimo']    = [datetime]::FromBinary($lectorCuerpo.ReadInt64())
            $archivos.Add($entrada)
            if ($ComoDiccionario) { $porRuta[[string]$entrada['Ruta']] = $entrada }
        }

        # El número de entradas debe coincidir con el de la cabecera.
        if ($archivos.Count -ne [int]$cabecera.Entradas) { return $null }

        # --- Referencia de carpeta a ruta ---------------------------------
        $nReferencias = $lectorCuerpo.ReadInt32()
        if ($nReferencias -lt 0 -or $nReferencias -gt ($memoria.Length - $memoria.Position)) {
            return $null
        }
        $referencias = [Collections.Generic.Dictionary[uint64, string]]::new()
        for ($i = 0; $i -lt $nReferencias; $i++) {
            $clave = $lectorCuerpo.ReadUInt64()
            $referencias[$clave] = $lectorCuerpo.ReadString()
        }

        return [pscustomobject]@{
            Carpetas      = $carpetas
            # Array, como New-IndiceDisco; conserva el orden de guardado.
            Archivos      = if ($ComoDiccionario) { $porRuta } else { $archivos.ToArray() }
            Raices        = $raices.ToArray()
            Bytes         = $bytesTotal
            TotalArchivos = $totalArchivos
            Compartidos   = $compartidos
            Inaccesibles  = $inaccesibles
            UmbralArchivo = $umbral
            Referencias   = $referencias
            Cabecera      = $cabecera
        }
    } catch {
        # Cualquier archivo dañado termina aquí como $null; quien llama
        # vuelve a recorrer el disco.
        Write-Verbose "No se ha podido leer el índice: $($_.Exception.Message)"
        return $null
    } finally {
        if ($null -ne $lectorCuerpo) { $lectorCuerpo.Dispose() }
        if ($null -ne $memoria)      { $memoria.Dispose() }
        if ($null -ne $lector)       { $lector.Dispose() }
        if ($null -ne $flujo)        { $flujo.Dispose() }
    }
}
