<#
.SYNOPSIS
    Las decisiones del banco de pruebas. Cálculo puro, sin tocar el disco.

.DESCRIPTION
    Separado de Banco-Pruebas.ps1 (que crea y borra archivos) para poder
    cargarlo desde las pruebas sin efectos.

    El banco monta cebos en Documentos y después borra recursivamente una
    carpeta calculada en tiempo de ejecución. Por eso las decisiones de
    dónde y si se puede montar o quitar están aquí, probadas una a una.

    También contiene el catálogo de cebos y la lógica que juzga una pasada
    del banco en la CI, para que no dependa de YAML sin pruebas.
#>

# El nombre de la carpeta que el banco crea y de la que nunca sale.
$script:NombreRaizBanco = 'Banco-Cachivache'

function Get-NombreRaizBanco {
    <#
    .SYNOPSIS
        El nombre de la carpeta raíz del banco.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:NombreRaizBanco
}

function Get-RutaRaizBanco {
    <#
    .SYNOPSIS
        Dónde va el banco, dada la carpeta Documentos. Cálculo puro.

    .DESCRIPTION
        La consulta a Windows queda fuera; aquí solo se compone la ruta. La
        usan tanto el guion que monta el banco como el comprobador de la CI,
        para que ambos miren siempre la misma carpeta.

    .PARAMETER Documentos
        Lo que devuelve [Environment]::GetFolderPath('MyDocuments').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Documentos)

    if ([string]::IsNullOrWhiteSpace($Documentos)) { return '' }
    return ($Documentos.Trim().TrimEnd('\', '/') + '\' + $script:NombreRaizBanco)
}

function Test-PareceMaquinaVirtual {
    <#
    .SYNOPSIS
        Si la descripción del equipo parece la de una máquina virtual.

    .DESCRIPTION
        No es una comprobación de seguridad (un hipervisor puede ocultarse):
        solo evita ejecutar el banco por descuido en un equipo real. Se mira
        el fabricante y el modelo que informa Windows.

    .PARAMETER Fabricante
        Win32_ComputerSystem.Manufacturer.

    .PARAMETER Modelo
        Win32_ComputerSystem.Model.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Con WMI restringido el dato puede llegar nulo: eso es "no parece
        # virtual", no una excepción.
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Fabricante,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Modelo
    )

    $senyales = @(
        'virtualbox', 'vmware', 'qemu', 'kvm', 'bochs', 'xen',
        'microsoft corporation virtual', 'virtual machine', 'hyper-v', 'parallels'
    )

    $texto = (('{0} {1}' -f $Fabricante, $Modelo)).ToLowerInvariant()
    foreach ($senyal in $senyales) {
        if ($texto.Contains($senyal)) { return $true }
    }
    return $false
}

function Test-DentroDeRaiz {
    <#
    .SYNOPSIS
        Si una ruta está dentro de la raíz del banco. Impide que el banco
        borre algo que no haya creado.

    .DESCRIPTION
        Antes de comparar se normalizan el prefijo \\?\ (rutas largas), las
        barras finales y las mayúsculas. Se exige separador tras la raíz,
        para que "...\Banco-Cachivache-2" no cuente como dentro de
        "...\Banco-Cachivache".

        No resuelve enlaces ni "..": la ruta debe llegar ya resuelta con
        GetFullPath.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Raiz
    )

    if ([string]::IsNullOrWhiteSpace($Ruta) -or [string]::IsNullOrWhiteSpace($Raiz)) { return $false }

    $limpiar = {
        param([string] $Valor)
        $v = $Valor.Trim()
        if ($v.StartsWith('\\?\')) { $v = $v.Substring(4) }
        return $v.TrimEnd('\', '/')
    }

    $r = (& $limpiar $Ruta)
    $z = (& $limpiar $Raiz)

    if ([string]::IsNullOrWhiteSpace($z)) { return $false }
    if ($r.Equals($z, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    # El separador es obligatorio: si no, "...\Banco-Cachivache-2" entraría.
    return $r.StartsWith(($z + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Get-MotivoNoMontarBanco {
    <#
    .SYNOPSIS
        Por qué no se puede montar el banco aquí, o nada si se puede.

    .DESCRIPTION
        Devuelve el texto para el usuario. Como Get-MotivoNoSeBorra, una sola
        función decide y explica, para que ambas cosas coincidan.

    .PARAMETER PareceVirtual
        Lo que dijo Test-PareceMaquinaVirtual.

    .PARAMETER Forzado
        Si el usuario pasó -AunqueNoSeaVirtual.

    .PARAMETER RaizOcupada
        Si ya existe la carpeta del banco con algo dentro.

    .OUTPUTS
        El motivo, o $null si se puede seguir.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch] $PareceVirtual,
        [switch] $Forzado,
        [switch] $RaizOcupada
    )

    if (-not $PareceVirtual -and -not $Forzado) {
        return ('Esto no parece una maquina virtual. El banco crea archivos dentro de ' +
                'tus carpetas personales y despues los borra: hazlo en la VM con su ' +
                'instantanea, no aqui. Si de verdad quieres, pasa -AunqueNoSeaVirtual.')
    }

    # Va después a propósito: si no es una VM, ese es el motivo prioritario.
    if ($RaizOcupada) {
        return ('Ya hay un banco montado. Quitalo primero con -Quitar: montar encima ' +
                'dejaria cebos de dos tandas mezclados y no sabrias cual es cual.')
    }

    return $null
}

function Get-MotivoNoQuitarBanco {
    <#
    .SYNOPSIS
        Por qué no se puede borrar esta carpeta, o nada si se puede.

    .DESCRIPTION
        -Quitar borra recursivamente una ruta calculada; si el cálculo falla
        (Documentos no encontrado, variable de entorno vacía, GetFullPath que
        devuelve la unidad), se borraría lo que haya debajo. Se exige:

        1. Que la ruta termine exactamente en el nombre del banco.
        2. Profundidad suficiente: una raíz de unidad o una ruta de dos
           segmentos nunca es el banco.
        3. Que exista, para no informar de una limpieza que no ha ocurrido.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Raiz,
        [switch] $Existe
    )

    if ([string]::IsNullOrWhiteSpace($Raiz)) {
        return 'No se ha podido calcular donde esta el banco.'
    }

    $limpia = $Raiz.Trim()
    if ($limpia.StartsWith('\\?\')) { $limpia = $limpia.Substring(4) }
    $limpia = $limpia.TrimEnd('\', '/')

    $hojas = @($limpia -split '[\\/]' | Where-Object { $_ })

    if ($hojas.Count -lt 3) {
        return ("'$Raiz' esta demasiado arriba para ser el banco. No se borra nada.")
    }

    if ($hojas[-1] -ne $script:NombreRaizBanco) {
        return ("'$Raiz' no termina en '$($script:NombreRaizBanco)'. No se borra nada.")
    }

    if (-not $Existe) {
        return ("No hay ningun banco montado en '$Raiz'.")
    }

    return $null
}

# =====================================================================
#  CATÁLOGO DE CEBOS
# =====================================================================
# Una sola lista con los nombres, tamaños y el resultado esperado de cada
# cebo, usada para montar el banco y para juzgarlo. Los nombres no deben
# empezar por palabras de Test-ArchivoPersonal ("copia", "documento"...):
# la guardia los protegería y ningún módulo los propondría.
# tests/Banco.Tests.ps1 comprueba con la guardia real que cada nombre es
# visible.

function Get-CebosBanco {
    <#
    .SYNOPSIS
        Qué monta el banco y qué debe hacer el programa con cada cebo.
        Cálculo puro: no toca el disco.

    .DESCRIPTION
        Cada entrada describe una familia de cebos (uno o varios archivos con
        el mismo patrón de nombre):

          Id                Identificador único; aparece en los mensajes de la CI.
          Carpeta           Subcarpeta del banco.
          Patron            Nombre del archivo; con Cuantos > 1 lleva "{0}".
          Cuantos           Número de archivos de la familia.
          KiloBytes         Tamaño de cada uno.
          Relleno           Texto de relleno; mismo relleno y tamaño dan
                            archivos idénticos (para duplicados).
          EsCarpeta         La familia son carpetas vacías.
          EnlaceA           Si no está vacío, el archivo es un enlace duro a
                            ese nombre en la misma carpeta.
          SubCarpetas       Niveles anidados hasta el archivo (ruta larga).
          PatronSubCarpeta  Nombre de cada nivel.
          Premarcado        Si el análisis debe traerlo marcado. Es lo que
                            borra "-Consola -Ejecutar"; una invariante lo
                            compara con Test-DebeVenirMarcado.
          EnAnalisis        Si el análisis debe encontrarlo.
          EnLimpieza        Si la limpieza real debe borrarlo. Es independiente
                            de EnAnalisis: la papelera no admite rutas de más
                            de 260 caracteres.
          MotivoFuera       Obligatorio si EnAnalisis o EnLimpieza es $false.
          Para              Qué comprueba el cebo.

    .PARAMETER ArchivosDeSobra
        Archivos de relleno de 07-muchas-filas. A mano se montan 3.000 para
        probar el desplazamiento; en la CI bastan unos cientos.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [ValidateRange(0, 50000)]
        [int] $ArchivosDeSobra = 3000
    )

    # Valores por defecto: cada entrada solo escribe lo que la distingue, y
    # ningún campo queda ausente (leer una propiedad inexistente no lanza).
    $plantilla = @{
        Id = ''; Carpeta = ''; Patron = ''; Cuantos = 1; KiloBytes = 4
        Relleno = 'cebo'; EsCarpeta = $false; EnlaceA = ''
        SubCarpetas = 0; PatronSubCarpeta = ''
        Premarcado = $false; EnAnalisis = $true; EnLimpieza = $true
        MotivoFuera = ''; Para = ''
    }

    $entradas = @(
        @{
            Id = 'temporales-bak'; Carpeta = '01-temporales'
            Patron = 'salida-{0}.bak'; Cuantos = 8; KiloBytes = 64
            Premarcado = $false
            Para = 'El camino normal: proponer, marcarlo a mano y borrarlo a la papelera'
        }
        @{
            Id = 'temporales-old'; Carpeta = '01-temporales'
            Patron = 'version-{0}.old'; Cuantos = 8; KiloBytes = 32
            Premarcado = $false
            Para = 'Lo mismo que el anterior, con la otra extension de copia antigua'
        }
        @{
            Id = 'ruta-larga'; Carpeta = '02-ruta-larga'
            SubCarpetas = 12
            PatronSubCarpeta = 'carpeta-anidada-con-nombre-largo-numero-{0:00}'
            Patron = 'volcado-antiguo.dmp'; Cuantos = 1; KiloBytes = 28
            Premarcado = $true
            # 50-Temporales debe encontrar el .dmp del fondo: si el recorrido
            # vuelve a detenerse en 260 caracteres, este paso falla.
            EnAnalisis = $true
            # No desaparece en la limpieza real: la fase 'windows' ya lo borra
            # con -Permanente, y la papelera no admite rutas tan largas.
            EnLimpieza = $false
            MotivoFuera = ('La fase windows ya lo borra con -Permanente, asi que no esta en el ' +
                           'inventario previo; y la limpieza real va a la papelera, que no ' +
                           'admite rutas de mas de 260 caracteres. Que se NIEGUE con el motivo ' +
                           'correcto es justo lo que comprueba la fase windows.')
            Para = 'Que el recorrido lo encuentre, y medirlo y borrarlo pese a pasar de 260 caracteres'
        }
        @{
            Id = 'mas-grande'; Carpeta = '03-mas-grande-que-la-papelera'
            Patron = 'volcado-enorme.dmp'; Cuantos = 1; KiloBytes = 204800
            Premarcado = $true
            Para = 'Con la cuota de la papelera bajada a 100 MB, esto no cabe'
        }
        @{
            Id = 'enlace-original'; Carpeta = '04-enlaces-duros'
            Patron = 'original.bak'; Cuantos = 1; KiloBytes = 20480
            Premarcado = $false
            Para = 'Enlaces duros: el contenido real, 20 MB'
        }
        @{
            Id = 'enlace-duro'; Carpeta = '04-enlaces-duros'
            Patron = 'mismo-contenido-otro-nombre.bak'; Cuantos = 1
            EnlaceA = 'original.bak'
            Premarcado = $false
            Para = 'Enlaces duros: el segundo nombre. Medir la carpeta tiene que dar 20 MB, no 40'
        }
        @{
            Id = 'duplicados'; Carpeta = '05-duplicados'
            Patron = 'informe-copia-{0}.bak'; Cuantos = 2; KiloBytes = 512
            Relleno = 'contenido-identico-'
            Premarcado = $false
            Para = 'Duplicados de verdad, y el contraste con los enlaces duros de al lado'
        }
        @{
            Id = 'carpetas-vacias'; Carpeta = '06-carpetas-vacias'
            Patron = 'vacia-{0}'; Cuantos = 5; EsCarpeta = $true
            Premarcado = $false
            EnAnalisis = $false
            MotivoFuera = ('40-CarpetasVacias propone solo la cima de una cadena de carpetas ' +
                           'vacías, así que lo que sale en el análisis es 06-carpetas-vacias, ' +
                           'no cada una de las cinco hojas. Es lo correcto: proponer las cinco ' +
                           'obligaría a ejecutar el programa cinco veces.')
            Para = 'El modulo de carpetas vacias'
        }
        @{
            Id = 'relleno'; Carpeta = '07-muchas-filas'
            Patron = 'sobra-{0:00000}.tmp'; Cuantos = $ArchivosDeSobra; KiloBytes = 0
            Premarcado = $true
            Para = 'Miles de filas: desplazamiento, marcado en lote y borrado real en lote'
        }
        @{
            Id = 'comprimido'; Carpeta = '08-comprimido'
            Patron = 'volcado-comprimible.dmp'; Cuantos = 1; KiloBytes = 102400
            Premarcado = $true
            # Único cebo que no queda listo al montarlo: hay que comprimirlo
            # a mano con "compact /C" (solo Windows/NTFS), como indica
            # docs/BANCO-PRUEBAS.md. Sin comprimir, la CI lo trata como un
            # .dmp normal; comprimido, comprueba que lo prometido es el
            # tamaño en disco.
            Para = ('Compresión: 100 MB que, comprimidos con NTFS, ocupan mucho menos. Lo prometido ' +
                    'tiene que ser lo que ocupan, no lo que miden. Hay que comprimirlo a mano ' +
                    'con "compact /C": ver docs/BANCO-PRUEBAS.md, apartado 8.')
        }
    )

    $cebos = [Collections.Generic.List[object]]::new()
    foreach ($entrada in $entradas) {
        $campos = $plantilla.Clone()
        foreach ($clave in $entrada.Keys) { $campos[$clave] = $entrada[$clave] }
        $cebos.Add([pscustomobject]$campos)
    }
    return @($cebos)
}

function Get-RutaCebo {
    <#
    .SYNOPSIS
        Ruta exacta de un cebo. Cálculo puro.

    .DESCRIPTION
        La comparten el montaje, el comprobador de la CI y las pruebas.
        Se compone con barra invertida y no con Join-Path, que en Linux
        usaría "/": las rutas se comparan como texto con las de Windows.

    .PARAMETER Indice
        Número de orden dentro de la familia, desde 1. Se ignora en las
        familias de un solo elemento.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Cebo,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Raiz,
        [int] $Indice = 1
    )

    if ($null -eq $Cebo) { return '' }
    if ([string]::IsNullOrWhiteSpace($Raiz)) { return '' }

    $ruta = $Raiz.Trim().TrimEnd('\', '/') + '\' + $Cebo.Carpeta
    for ($nivel = 1; $nivel -le [int]$Cebo.SubCarpetas; $nivel++) {
        $ruta = $ruta + '\' + ($Cebo.PatronSubCarpeta -f $nivel)
    }

    $nombre = if ([int]$Cebo.Cuantos -gt 1) { $Cebo.Patron -f $Indice } else { [string]$Cebo.Patron }
    return $ruta + '\' + $nombre
}

function Test-PerfilAjeno {
    <#
    .SYNOPSIS
        Si una ruta está dentro del perfil de otro usuario. Cálculo puro.

    .DESCRIPTION
        Parte de la comprobación crítica del banco: el análisis no debe
        proponer nada de perfiles ajenos. Las rutas llegan resueltas, sin
        leer variables de entorno, para poder probarlo en Linux.

    .PARAMETER CarpetaUsuarios
        C:\Users, resuelta por quien llama.

    .PARAMETER PerfilPropio
        Perfil del usuario que ejecuta el programa; lo que cuelga de él no
        es ajeno.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Ruta,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $CarpetaUsuarios,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $PerfilPropio
    )

    # Sin carpeta de perfiles no se puede afirmar nada: se responde $false y
    # quien llama avisa de que no se ha podido comprobar.
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $false }
    if ([string]::IsNullOrWhiteSpace($CarpetaUsuarios)) { return $false }

    if (-not (Test-DentroDeRaiz -Ruta $Ruta -Raiz $CarpetaUsuarios)) { return $false }
    # C:\Users en sí no es de otro usuario (Test-DentroDeRaiz la considera
    # dentro de sí misma).
    if (Test-DentroDeRaiz -Ruta $CarpetaUsuarios -Raiz $Ruta) { return $false }

    if ([string]::IsNullOrWhiteSpace($PerfilPropio)) { return $true }
    return (-not (Test-DentroDeRaiz -Ruta $Ruta -Raiz $PerfilPropio))
}

function Get-RutasFueraDelBanco {
    <#
    .SYNOPSIS
        De una lista de rutas, las que no están dentro del banco. Cálculo
        puro.

    .DESCRIPTION
        Se usa tras la limpieza real de la CI para verificar que todo lo
        borrado eran cebos. Revisa la lista entera para que el registro
        muestre todas las rutas, y las devuelve únicas y ordenadas.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [string[]] $Rutas,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Raiz
    )

    $fuera = [Collections.Generic.List[string]]::new()
    foreach ($ruta in @($Rutas)) {
        if ([string]::IsNullOrWhiteSpace($ruta)) { continue }
        if (Test-DentroDeRaiz -Ruta $ruta -Raiz $Raiz) { continue }
        $fuera.Add($ruta)
    }
    return @($fuera | Sort-Object -Unique)
}

function Get-ResumenCebos {
    <#
    .SYNOPSIS
        Cuántos cebos de cada familia ha encontrado el análisis y cuáles
        faltan. Cálculo puro.

    .DESCRIPTION
        Devuelve una fila por familia. El comprobador de la CI falla si una
        familia con EnAnalisis = $true está incompleta. Las familias con
        EnAnalisis = $false también se miden, solo a título informativo.

    .PARAMETER Propuestas
        Las rutas que propuso el análisis.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] $Cebos,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Raiz,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [string[]] $Propuestas
    )

    # HashSet y no -contains: con miles de cebos, -contains es cuadrático.
    $vistas = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($ruta in @($Propuestas)) {
        if ([string]::IsNullOrWhiteSpace($ruta)) { continue }
        [void]$vistas.Add($ruta.Trim().TrimEnd('\', '/'))
    }

    $filas = [Collections.Generic.List[object]]::new()
    foreach ($cebo in @($Cebos)) {
        if ($null -eq $cebo) { continue }

        $encontrados = 0
        $faltan = [Collections.Generic.List[string]]::new()
        for ($n = 1; $n -le [int]$cebo.Cuantos; $n++) {
            $ruta = Get-RutaCebo -Cebo $cebo -Raiz $Raiz -Indice $n
            if ($vistas.Contains($ruta)) {
                $encontrados++
            } elseif ($faltan.Count -lt 5) {
                # Solo las cinco primeras, para no inundar el registro.
                $faltan.Add($ruta)
            }
        }

        $filas.Add([pscustomobject]@{
            Id          = [string]$cebo.Id
            Esperados   = [int]$cebo.Cuantos
            Encontrados = $encontrados
            Falta       = ([int]$cebo.Cuantos - $encontrados)
            EnAnalisis  = [bool]$cebo.EnAnalisis
            MotivoFuera = [string]$cebo.MotivoFuera
            Ejemplos    = @($faltan)
        })
    }
    return @($filas)
}
