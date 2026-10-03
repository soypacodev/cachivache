<#
.SYNOPSIS
    Contrato de un candidato a limpieza y del resultado de un módulo.
#>

# Métodos de eliminación admitidos. La lista oficial es el ValidateSet del
# parámetro -Metodo de New-Candidato; aquí solo se explica cada uno (una
# invariante comprueba que ambas listas coinciden).
#   Contenido    -> vacía la carpeta pero la deja en su sitio
#   Ruta         -> borra el archivo o la carpeta entera
#   CarpetaVacia -> borra un árbol de carpetas vacías, revalidando que
#                   sigue sin un solo archivo justo antes de tocarlo
#   FirefoxCache -> vacía solo las subcarpetas cache2 de cada perfil
#   Miniaturas   -> borra únicamente thumbcache_*.db e iconcache_*.db
#   Papelera     -> vacía la papelera de reciclaje mediante la API del shell
#   Comando      -> delega en un comando externo declarado en el candidato
#   Informativo  -> no borra nada, solo informa

# =====================================================================
#  PREMARCADO
# =====================================================================
#
# Solo se marca automáticamente lo de riesgo bajo, sin avisos y que borra
# algo. La regla (Test-DebeVenirMarcado) y su explicación al usuario
# (Get-MotivoPremarcado, Get-ResumenPremarcado) se basan en la misma
# función para que no puedan divergir.

function Test-DebeVenirMarcado {
    <#
    .SYNOPSIS
        Indica si un elemento debe venir marcado por defecto.

    .DESCRIPTION
        Cálculo puro: solo se marca lo de riesgo bajo, sin avisos y que
        borra algo. Recibe los tres campos y no el candidato porque
        New-Candidato la llama mientras lo construye.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $Riesgo = 'Bajo',
        [string] $Aviso  = '',
        [string] $Metodo = 'Ruta'
    )

    if ($Metodo -eq 'Informativo') { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Aviso)) { return $false }
    return ($Riesgo -eq 'Bajo')
}

function Get-MotivoPremarcado {
    <#
    .SYNOPSIS
        Por qué este elemento viene marcado, o por qué no.

    .DESCRIPTION
        Devuelve una frase siguiendo el orden de la regla: primero los
        vetos (informativo, aviso) y después el riesgo, para mostrar el
        motivo que realmente decidió.

        Explica el estado que produce la regla, no el estado actual de la
        casilla (que el usuario puede haber cambiado).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Riesgo = 'Bajo',
        [string] $Aviso  = '',
        [string] $Metodo = 'Ruta'
    )

    if ($Metodo -eq 'Informativo') {
        return 'Sin marcar: este módulo no borra nada, solo informa.'
    }
    if (-not [string]::IsNullOrWhiteSpace($Aviso)) {
        return 'Sin marcar: lleva un aviso, y lo que lleva aviso no se marca nunca solo.'
    }
    if ($Riesgo -ne 'Bajo') {
        return ('Sin marcar: riesgo {0}. Solo se marca solo lo de riesgo bajo.' -f
                ([string]$Riesgo).ToLower())
    }
    return 'Marcado: riesgo bajo y sin avisos.'
}

function Get-ResumenPremarcado {
    <#
    .SYNOPSIS
        Frase del pie: cuántos elementos vienen marcados y por qué.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] $Candidatos)

    $todos = @($Candidatos)
    if ($todos.Count -eq 0) { return '' }

    $marcados = @($todos | Where-Object { $_.Seleccionado }).Count
    $sinMarcar = $todos.Count - $marcados

    if ($sinMarcar -eq 0) {
        return ('Los {0} vienen marcados: todos son de riesgo bajo y sin avisos.' -f $todos.Count)
    }
    if ($marcados -eq 0) {
        return ('Ninguno viene marcado: todos llevan aviso o riesgo por encima de bajo. Los marcas tú.')
    }
    return ('{0} vienen marcados por ser de riesgo bajo y sin avisos. Los otros {1} los marcas tú.' -f
            $marcados, $sinMarcar)
}

function New-Candidato {
    <#
    .SYNOPSIS
        Crea un elemento propuesto para limpieza.

    .PARAMETER ModuloId
        Identificador del módulo que lo propone.
    .PARAMETER Categoria
        Grupo visible en la interfaz.
    .PARAMETER Nombre
        Título corto y legible.
    .PARAMETER Ruta
        Ruta absoluta afectada.
    .PARAMETER Bytes
        Tamaño lógico de lo propuesto. No es directamente lo que se promete
        liberar: eso lo decide Get-EspacioRecuperable junto con
        -TamanoEnDisco.
    .PARAMETER TamanoEnDisco
        Espacio real ocupado en disco, o $null si no se conoce. $null no
        equivale a 0 ("no ocupa nada"). Lo rellena
        Get-ElementosDelArbol -MedirEnDisco; los módulos que no lo conocen
        no lo pasan.
    .PARAMETER Info
        Detalle secundario (fechas, número de archivos...).
    .PARAMETER Efecto
        Qué ocurre después de borrarlo, en lenguaje llano.
    .PARAMETER Aviso
        Motivo por el que conviene revisarlo a mano. Si viene relleno, el
        elemento se muestra en rojo y nunca se marca por defecto.
    .PARAMETER Metodo
        Cómo se elimina. Valores del ValidateSet; la cabecera del archivo
        explica cada uno.
    .PARAMETER Raices
        Lista blanca de carpetas de las que debe colgar la ruta.
    .PARAMETER Riesgo
        Bajo | Medio | Alto. Determina el color de la etiqueta.
    .PARAMETER PermitirPersonales
        Levanta el veto por extensión personal. Reservado al módulo de
        duplicados, que garantiza que existe otra copia idéntica.
    .PARAMETER Preseleccionado
        Si se marca solo al aparecer. Por defecto se deriva del riesgo.
    .PARAMETER ForzarPermanente
        Solo para módulos de caché (aplicaciones y navegadores). Ignora la
        preferencia "enviar a la papelera" para este candidato: enviar
        cientos de miles de archivos de caché a la papelera es muy lento y
        no libera espacio hasta vaciarla. El resto respeta siempre la
        preferencia del usuario. Ver Invoke-EliminacionCandidato (Remove.ps1).
    .PARAMETER Comando
        Solo para -Metodo 'Comando'. Texto legible para la interfaz y el
        registro (p. ej. la ruta completa de DISM). Nunca se ejecuta tal
        cual: ver Ejecutable y Argumentos.
    .PARAMETER Ejecutable
        Solo para -Metodo 'Comando'. Nombre del ejecutable sin ruta ni
        argumentos (p. ej. 'dism' o 'docker'). Remove.ps1 lo resuelve contra
        su propia lista blanca en el momento de borrar.
    .PARAMETER Argumentos
        Solo para -Metodo 'Comando'. Array de argumentos, uno por elemento.
        Se pasan a Start-Process sin intérprete de shell, de modo que '&',
        '|' y '%VAR%' no se interpretan.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo compone un objeto en memoria: no toca el sistema.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ModuloId,
        [Parameter(Mandatory)] [string] $Categoria,
        [Parameter(Mandatory)] [string] $Nombre,
        [Parameter(Mandatory)] [string] $Ruta,
        [double]   $Bytes  = 0,
        # Sin tipo: con [double], el enlace de parámetros convertiría $null
        # en 0 y se perdería la diferencia entre "desconocido" y "nada".
        [AllowNull()] $TamanoEnDisco = $null,
        [string]   $Info   = '',
        [string]   $Efecto = '',
        [string]   $Aviso  = '',
        [ValidateSet('Contenido', 'Ruta', 'CarpetaVacia', 'FirefoxCache', 'Miniaturas', 'Papelera', 'Comando', 'Informativo')]
        [string]   $Metodo = 'Ruta',
        [string[]] $Raices = @(),
        [ValidateSet('Bajo', 'Medio', 'Alto')]
        [string]   $Riesgo = 'Bajo',
        [string]   $Comando = '',
        [string]   $Ejecutable = '',
        [string[]] $Argumentos = @(),
        [switch]   $PermitirPersonales,
        [switch]   $ForzarPermanente,
        [Nullable[bool]] $Preseleccionado = $null
    )

    # La regla está solo en Test-DebeVenirMarcado (ver la cabecera).
    $marcado = Test-DebeVenirMarcado -Riesgo $Riesgo -Aviso $Aviso -Metodo $Metodo
    if ($null -ne $Preseleccionado) { $marcado = [bool]$Preseleccionado }

    # -Preseleccionado puede desmarcar lo que la regla marcaría, pero no al
    # revés: lo que lleva aviso o es informativo nunca se marca, lo pida
    # quien lo pida. Si algo debe ir marcado, no lleva Aviso sino Info.
    if (-not [string]::IsNullOrWhiteSpace($Aviso)) { $marcado = $false }
    if ($Metodo -eq 'Informativo') { $marcado = $false }

    [pscustomobject]@{
        ModuloId       = $ModuloId
        Categoria      = $Categoria
        Nombre         = $Nombre
        Ruta           = $Ruta
        # Espacio que se promete liberar; lo decide solo
        # Get-EspacioRecuperable. En carpetas comprimidas con NTFS el tamaño
        # lógico es mayor que lo recuperable. Con TamanoEnDisco nulo se usa
        # el lógico.
        Bytes          = Get-EspacioRecuperable -TamanoLogico $Bytes -TamanoEnDisco $TamanoEnDisco
        # Dato en crudo (incluido $null) para poder mostrar ambas cifras.
        TamanoEnDisco  = $TamanoEnDisco
        Info           = $Info
        Efecto         = $Efecto
        Aviso          = $Aviso
        Metodo         = $Metodo
        Comando        = $Comando
        Ejecutable     = $Ejecutable
        Argumentos     = @($Argumentos)
        Raices         = @($Raices)
        # Solo lo usa el módulo de duplicados. Ver Test-RutaSegura.
        PermitirPersonales = [bool]$PermitirPersonales
        # Solo lo usan los módulos de caché. Ver Remove.ps1.
        ForzarPermanente = [bool]$ForzarPermanente
        Riesgo         = $Riesgo
        Seleccionado   = $marcado
        Hecho          = $false
        BytesLiberados = 0.0
        Error          = ''
        # Clave para comparar con las exclusiones del usuario. No es la ruta:
        # para un comando o la papelera, Ruta es solo una etiqueta y no debe
        # compararse por prefijo de carpeta. Ver Get-ClaveExclusion.
        ClaveExclusion = Get-ClaveExclusion -Ruta $Ruta -ModuloId $ModuloId -Nombre $Nombre
    }
}

function New-ModuloLimpieza {
    <#
    .SYNOPSIS
        Declara un módulo de limpieza.
    .DESCRIPTION
        Cada archivo de src/Modules termina llamando a esta función. El
        objeto resultante es lo único que el resto del programa conoce del
        módulo, de modo que añadir uno nuevo no obliga a tocar nada más.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo compone un objeto en memoria: no toca el sistema.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Nombre,
        [Parameter(Mandatory)] [string] $Descripcion,
        [Parameter(Mandatory)] [int]    $Orden,
        [Parameter(Mandatory)] [scriptblock] $Buscar,
        [ValidateSet('Bajo', 'Medio', 'Alto')]
        [string]   $Riesgo        = 'Bajo',
        [switch]   $RequiereAdmin,
        [switch]   $SoloInforma,
        [string[]] $Perfiles      = @('equilibrado', 'agresivo')
    )

    [pscustomobject]@{
        Id            = $Id
        Nombre        = $Nombre
        Descripcion   = $Descripcion
        Orden         = $Orden
        Riesgo        = $Riesgo
        RequiereAdmin = [bool]$RequiereAdmin
        SoloInforma   = [bool]$SoloInforma
        Perfiles      = @($Perfiles)
        Buscar        = $Buscar
    }
}

function Invoke-BusquedaPorLista {
    <#
    .SYNOPSIS
        Recorre una lista de rutas conocidas y propone las que valen.

    .DESCRIPTION
        Bucle común de los módulos caches, logs y windowsupdate: para cada
        entrada comprueba que la ruta existe, la pasa por la guardia, la
        mide, descarta lo que no llega al umbral y emite el candidato.

        Quedan fuera a propósito 80-ArchivosSistema (archivos sueltos e
        informativos), MEMORY.DMP de logs y Windows.old de windowsupdate.
        Cada módulo conserva su umbral (1 MB en caches y logs, 10 MB en
        windowsupdate) y su categoría.

    .PARAMETER Entradas
        Lista de tablas con: N (nombre), R (ruta), E (efecto) y,
        opcionalmente, M (método, por defecto 'Contenido'), A (aviso) y
        Menor (si solo sale con -IncluirMenores).

    .NOTES
        No hay parámetro para forzar el marcado a propósito: la regla está
        únicamente en New-Candidato.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ModuloId,
        [Parameter(Mandatory)] [string] $Categoria,
        [Parameter(Mandatory)] $Entradas,
        [Parameter(Mandatory)] [string[]] $Raices,
        $Sync = $null,
        [double] $MinimoBytes = 1MB,
        [string] $Info = 'se vacía el contenido, la carpeta se queda',
        [switch] $ForzarPermanente,
        [switch] $IncluirMenores,
        # Scriptblock opcional que recibe la entrada y devuelve texto para
        # añadir a Info. Lo usa caches para avisar de que el programa está
        # abierto.
        [scriptblock] $NotaExtra = $null
    )

    foreach ($entrada in @($Entradas)) {
        if (Test-Cancelacion $Sync) { break }
        if (-not $IncluirMenores -and $entrada.Menor) { continue }
        # En PowerShell 5.1 un -LiteralPath nulo lanza una excepción de
        # enlace de parámetros (en 7 es un error no terminante) que abortaría
        # todo el recorrido; por eso se comprueba antes de Test-Path.
        if ([string]::IsNullOrWhiteSpace($entrada.R)) { continue }
        if (-not (Test-Path -LiteralPath $entrada.R)) { continue }

        # La guardia va antes de medir: el resultado es el mismo, pero medir
        # es mucho más caro.
        if (-not (Test-RutaSegura $entrada.R $Raices)) { continue }

        Set-Progreso $Sync "Midiendo: $($entrada.N)"
        $bytes = Measure-Ruta $entrada.R
        if ($bytes -lt $MinimoBytes) { continue }

        $metodo = if ($entrada.M) { $entrada.M } else { 'Contenido' }
        $aviso  = if ($entrada.A) { $entrada.A } else { '' }
        $nota   = if ($NotaExtra) { [string](& $NotaExtra $entrada) } else { '' }

        $parametros = @{
            ModuloId  = $ModuloId
            Categoria = $Categoria
            Nombre    = $entrada.N
            Ruta      = $entrada.R
            Bytes     = $bytes
            Info      = $Info + $nota
            Efecto    = $entrada.E
            Aviso     = $aviso
            Metodo    = $metodo
            Raices    = $Raices
            Riesgo    = 'Bajo'
        }
        if ($ForzarPermanente) { $parametros['ForzarPermanente'] = $true }

        New-Candidato @parametros
    }
}
