<#
.SYNOPSIS
    Registro de actividad: una línea por acción, para auditar qué hizo el
    programa. Se rota por meses.

.DESCRIPTION
    El historial de ejecuciones (.json) está en Historial.ps1. Ver
    docs/ESTRUCTURA.md (sección 5.1).
#>

$script:RutaRegistro = $null

# Caché de la descripción del sistema operativo. Se declara aquí para que
# exista antes de leerse: bajo Set-StrictMode, leer una variable no
# asignada lanza.
$script:DescripcionSistema = $null

# Id corto de esta sesión de PowerShell (proceso principal o runspace de
# análisis/borrado). Va en cada línea para distinguir qué escribió cada uno
# cuando comparten archivo de registro.
$script:IdSesion = -join ((1..6) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })

function Get-DescripcionSistema {
    <#
    .SYNOPSIS
        Caption de Win32_OperatingSystem, o '(desconocido)' si el host no
        tiene CIM/WMI (por ejemplo, al ejecutar las pruebas en Linux).
    .DESCRIPTION
        Usa try/catch porque, si Get-CimInstance no existe en el host, el
        error es de resolución de comando y -ErrorAction no lo captura.

        El resultado se guarda en caché: no cambia durante la sesión y la
        consulta CIM tarda decenas de milisegundos.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrEmpty($script:DescripcionSistema)) {
        return $script:DescripcionSistema
    }
    try {
        $script:DescripcionSistema = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
    } catch {
        $script:DescripcionSistema = '(desconocido)'
    }
    if ([string]::IsNullOrWhiteSpace($script:DescripcionSistema)) {
        $script:DescripcionSistema = '(desconocido)'
    }
    return $script:DescripcionSistema
}

function Initialize-Registro {
    <#
    .SYNOPSIS
        Abre el archivo de registro del mes en curso.
    #>
    [CmdletBinding()]
    param([string] $CarpetaDatos = (Get-CarpetaDatos))

    $carpeta = Join-Path $CarpetaDatos 'registros'
    if (-not (Test-Path -LiteralPath $carpeta)) {
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
    }
    $script:RutaRegistro = Join-Path $carpeta ('cachivache-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
    return $script:RutaRegistro
}

function Write-CabeceraSesion {
    <#
    .SYNOPSIS
        Anota en el registro la versión, el entorno y los permisos con que
        arranca la sesión.
    .DESCRIPTION
        CONTRIBUTING.md y SECURITY.md piden adjuntar el registro al
        reportar un problema; esta cabecera da el contexto necesario.
    #>
    [CmdletBinding()]
    param(
        [string] $Perfil       = '',
        [Nullable[bool]] $Admin = $null,
        $Sync = $null
    )

    $admin   = if ($null -ne $Admin) { $Admin } else { Test-EsAdministrador }
    $sistema = Get-DescripcionSistema
    Write-Registro -Sync $Sync -Nivel 'INFO' -Mensaje ('=' * 70)
    Write-Registro -Sync $Sync -Nivel 'INFO' -Mensaje (
        'Sesión {0}  -  Cachivache v{1}  -  PowerShell {2}  -  {3}' -f
        $script:IdSesion, (Get-VersionCachivache), $PSVersionTable.PSVersion, $sistema)
    # No se incluye el nombre del equipo: el registro puede adjuntarse a una
    # incidencia pública y ese dato identifica sin ayudar a diagnosticar.
    Write-Registro -Sync $Sync -Nivel 'INFO' -Mensaje (
        '  Administrador: {0}  -  Perfil: {1}' -f
        $admin, $(if ($Perfil) { $Perfil } else { '(sin especificar)' }))
}

function Get-InformeDiagnostico {
    <#
    .SYNOPSIS
        Vuelca el entorno completo, listo para pegar en una incidencia.
    .DESCRIPTION
        Reúne en un bloque de texto lo que pide CONTRIBUTING.md: versiones
        de Windows y PowerShell, permisos, unidades y las últimas líneas del
        registro. Lo usan -Diagnostico y el botón de la ventana.

        Incluye letras, etiquetas y espacio de las unidades (necesarios para
        reproducir fallos de detección de espacio) y la carpeta de datos.
        Todo el texto, líneas del registro incluidas, pasa por
        ConvertTo-RutaAnonima: el perfil, el usuario y el equipo se
        sustituyen por marcadores. Otros nombres (proyectos, archivos)
        pueden quedar; por eso se pide revisarlo antes de publicarlo.
    .PARAMETER LineasRegistro
        Número de líneas finales del registro del mes que se incluyen. 0
        para omitirlas (p. ej. si contienen rutas que no se quieren publicar).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Nullable[bool]] $Admin = $null,
        [string] $CarpetaDatos  = (Get-CarpetaDatos),
        [int] $LineasRegistro   = 40
    )

    $admin = if ($null -ne $Admin) { $Admin } else { Test-EsAdministrador }
    $lineas = [Collections.Generic.List[string]]::new()

    $lineas.Add('=== Diagnostico de Cachivache ===')
    $lineas.Add('Versión del programa : {0}' -f (Get-VersionCachivache))
    # Paréntesis extra: dentro de .Add(...) la coma separaría argumentos del
    # método en lugar de los del operador -f.
    $lineas.Add(('PowerShell           : {0}  ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition))
    $lineas.Add('Sistema operativo    : {0}' -f (Get-DescripcionSistema))
    $lineas.Add('Arquitectura         : {0}' -f $env:PROCESSOR_ARCHITECTURE)
    $lineas.Add('Administrador        : {0}' -f $admin)
    $lineas.Add('Estado de subprocesos: {0}' -f [Threading.Thread]::CurrentThread.GetApartmentState())
    try {
        $lineas.Add('Politica de ejecución: {0}' -f (Get-ExecutionPolicy))
    } catch {
        $lineas.Add('Política de ejecución: (no disponible)')
    }
    $lineas.Add('Carpeta de datos     : {0}' -f $CarpetaDatos)
    # Cachivache evita MAX_PATH con el prefijo "\\?\" en cualquier caso. El
    # dato explica el entorno: sin LongPathsEnabled, el Explorador de
    # Windows no puede abrir ni borrar esas rutas.
    try {
        $largo = Get-ItemProperty -ErrorAction SilentlyContinue `
                    -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        $lineas.Add('Rutas largas Windows : {0}' -f $(
            if ($null -eq $largo)                     { '(no se ha podido leer)' }
            elseif ([int]$largo.LongPathsEnabled -eq 1) { 'activadas' }
            else                                      { 'desactivadas (Cachivache las maneja igual)' }))
    } catch {
        $lineas.Add('Rutas largas Windows : (no se ha podido leer)')
    }
    $lineas.Add('')

    $lineas.Add('--- Unidades ---')
    try {
        foreach ($unidad in @(Get-UnidadesAnalizables)) {
            $lineas.Add(('  {0}  {1}  -  {2} libres de {3} ({4}% usado)' -f
                $unidad.Letra, $unidad.Etiqueta, (Format-Tamano $unidad.Libre),
                (Format-Tamano $unidad.Total), $unidad.PorcentajeUsado))
        }
    } catch {
        $lineas.Add('  (no se han podido enumerar: {0})' -f $_.Exception.Message)
    }
    $lineas.Add('')

    if ($LineasRegistro -gt 0) {
        $lineas.Add('--- Ultimas {0} lineas del registro de este mes ---' -f $LineasRegistro)
        $ruta = if ([string]::IsNullOrWhiteSpace($script:RutaRegistro)) {
            Join-Path (Join-Path $CarpetaDatos 'registros') ('cachivache-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
        } else {
            $script:RutaRegistro
        }
        if (Test-Path -LiteralPath $ruta) {
            @(Get-Content -LiteralPath $ruta -Tail $LineasRegistro) | ForEach-Object { $lineas.Add("  $_") }
        } else {
            $lineas.Add('  (todavía no existe registro para este mes)')
        }
    }

    # Se publica en incidencias: se anonimiza el texto entero.
    return (ConvertTo-RutaAnonima ($lineas -join [Environment]::NewLine))
}

function Get-DetalleExcepcion {
    <#
    .SYNOPSIS
        Convierte un error capturado en una línea que indica dónde ocurrió.

    .DESCRIPTION
        Devuelve el mensaje, el tipo de excepción y el archivo y la línea
        de origen; muchos mensajes ("El índice estaba fuera de los
        límites") no sirven por sí solos para diagnosticar. La pila
        completa es opcional y está pensada para el registro, no para los
        cuadros de diálogo.

    .PARAMETER ErrorRecord
        El ErrorRecord tal cual llega a un catch: $_.

    .PARAMETER ConPila
        Añade la pila de llamadas (para el registro, no para la pantalla).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # AllowNull: la llaman manejadores de error y no debe lanzar. Sin
        # él, el enlace de parámetros rechazaría $null antes de la guarda.
        [Parameter(Mandatory)] [AllowNull()] $ErrorRecord,
        [switch] $ConPila
    )

    if ($null -eq $ErrorRecord) { return '(error desconocido)' }

    $mensaje = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    $tipo    = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.GetType().Name } else { 'Error' }

    # El origen sale de InvocationInfo. ScriptName puede venir vacío en
    # scriptblocks creados al vuelo (los cierres de la ventana); entonces se
    # omite, porque un número de línea sin archivo confunde.
    $sitio = ''
    if ($ErrorRecord.InvocationInfo -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.InvocationInfo.ScriptName)) {
        $sitio = ' [{0}:{1}]' -f (Split-Path -Leaf $ErrorRecord.InvocationInfo.ScriptName),
                                 $ErrorRecord.InvocationInfo.ScriptLineNumber
    }

    $detalle = '{0} ({1}){2}' -f $mensaje, $tipo, $sitio

    if ($ConPila -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
        $pila = ($ErrorRecord.ScriptStackTrace -split "`r?`n" | ForEach-Object { '    ' + $_ }) -join [Environment]::NewLine
        $detalle = $detalle + [Environment]::NewLine + $pila
    }

    return $detalle
}

function Write-Registro {
    <#
    .SYNOPSIS
        Escribe una línea con marca de tiempo en el registro.
    .PARAMETER Nivel
        INFO | AVISO | ERROR | BORRADO | PAPELERA | BLOQUEADO | OMITIDO
    .PARAMETER Sync
        Tabla sincronizada de New-EstadoSincronizado. Si se pasa, la línea
        se encola en $Sync.ColaRegistro y la escribe después
        Invoke-VaciarColaRegistro desde el temporizador de la interfaz, de
        modo que varios hilos pueden registrar sin acceder al archivo a la
        vez. Sin $Sync (modo consola, un solo hilo) se escribe al momento.
    #>
    [CmdletBinding()]
    param(
        # Se admite la cadena vacía a propósito: la interfaz escribe líneas
        # en blanco para separar bloques del registro.
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Mensaje,
        [ValidateSet('INFO', 'AVISO', 'ERROR', 'BORRADO', 'PAPELERA', 'BLOQUEADO', 'OMITIDO', 'SIMULACION')]
        [string] $Nivel = 'INFO',
        $Sync = $null
    )

    $idParte = if ([string]::IsNullOrWhiteSpace($Mensaje)) { '' } else { "[$script:IdSesion] " }
    $linea = '{0}  [{1,-9}]  {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $idParte, $Mensaje

    $cola = $null
    if ($null -ne $Sync -and $Sync -is [Collections.IDictionary] -and $Sync.ContainsKey('ColaRegistro')) {
        $cola = $Sync['ColaRegistro']
    }
    if ($cola -is [Collections.Concurrent.ConcurrentQueue[string]]) {
        $cola.Enqueue($linea)
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:RutaRegistro)) { [void](Initialize-Registro) }
    try {
        Add-Content -LiteralPath $script:RutaRegistro -Value $linea -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Verbose "No se ha podido escribir en el registro: $($_.Exception.Message)"
    }
}

function Invoke-VaciarColaRegistro {
    <#
    .SYNOPSIS
        Escribe a disco, de una vez, todas las líneas que se hayan
        encolado desde la última llamada.
    .DESCRIPTION
        Se llama desde el temporizador de la interfaz (cada 200 ms) y una
        última vez al terminar un trabajo, para no perder las líneas
        finales. Es el único punto que escribe el registro mientras hay un
        runspace de análisis o borrado en marcha.

        Devuelve las líneas escritas para que el panel de Registro muestre
        exactamente lo mismo que el archivo, sin tener que releerlo.
    .OUTPUTS
        [string[]] con las líneas escritas, o una lista vacía si no había
        nada encolado.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Sync)

    if ($Sync -isnot [Collections.IDictionary] -or -not $Sync.ContainsKey('ColaRegistro')) { return @() }
    $cola = $Sync['ColaRegistro']
    if ($cola -isnot [Collections.Concurrent.ConcurrentQueue[string]]) { return @() }
    if ($cola.IsEmpty) { return @() }

    $lineas = [Collections.Generic.List[string]]::new()
    $linea = $null
    while ($cola.TryDequeue([ref] $linea)) { $lineas.Add($linea) }
    if ($lineas.Count -eq 0) { return @() }

    if ([string]::IsNullOrWhiteSpace($script:RutaRegistro)) { [void](Initialize-Registro) }
    try {
        [IO.File]::AppendAllLines($script:RutaRegistro, $lineas, [Text.Encoding]::UTF8)
    } catch {
        Write-Verbose "No se ha podido vaciar la cola del registro: $($_.Exception.Message)"
    }

    # Se devuelven aunque la escritura falle, para que sigan viéndose en
    # pantalla.
    return $lineas.ToArray()
}

# ---------------------------------------------------------------------------
# Avisos repetidos
# ---------------------------------------------------------------------------
# Un fallo en un manejador de WPF puede repetirse en cada tick del
# temporizador o en cada elemento de una lista. Para no bloquear la ventana
# con cuadros de diálogo modales idénticos, en pantalla solo se muestra la
# primera aparición de cada fallo; en el registro se anotan todas.

$script:FallosAvisados = @{}
$script:MaximoAvisosDeFallo = 3

function Reset-AvisosDeFallo {
    <#
    .SYNOPSIS
        Olvida los fallos ya avisados (pruebas e inicio de sesión).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo vacía una tabla en memoria.')]
    [CmdletBinding()]
    param()
    $script:FallosAvisados = @{}
}

function Get-VecesQueFallo {
    <#
    .SYNOPSIS
        Cuántas veces se ha visto cada fallo, para el resumen al cerrar.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:FallosAvisados.Clone()
}

function Get-FirmaDeFallo {
    <#
    .SYNOPSIS
        Calcula una firma que identifica las repeticiones de un mismo fallo.

    .DESCRIPTION
        La firma es tipo + mensaje + primera línea de la pila: el mensaje o
        el tipo por sí solos coinciden en fallos sin relación.

        Ante cualquier duda devuelve cadena vacía, y una firma vacía siempre
        se avisa: es preferible repetir un aviso que ocultar un fallo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Excepcion
    )

    if ($null -eq $Excepcion) { return '' }

    $tipo = ''
    $mensaje = ''
    $donde = ''
    try { $tipo = $Excepcion.GetType().FullName } catch { $tipo = '' }
    try { $mensaje = [string]$Excepcion.Message } catch { $mensaje = '' }
    try {
        $pila = [string]$Excepcion.StackTrace
        if (-not [string]::IsNullOrWhiteSpace($pila)) {
            # Primera línea con contenido: el marco donde se produjo.
            foreach ($linea in ($pila -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($linea)) { $donde = $linea.Trim(); break }
            }
        }
    } catch { $donde = '' }

    $firma = ('{0}|{1}|{2}' -f $tipo, $mensaje, $donde).Trim('|')
    if ([string]::IsNullOrWhiteSpace($firma)) { return '' }
    return $firma
}

function Test-DebeAvisarDelFallo {
    <#
    .SYNOPSIS
        Decide si un fallo se muestra en pantalla o solo se anota.

    .DESCRIPTION
        Se avisa la primera vez de cada fallo distinto, hasta un máximo de
        $script:MaximoAvisosDeFallo fallos distintos por sesión. El resto
        solo va al registro, para que el usuario pueda seguir usando (o
        cerrar) el programa.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Firma
    )

    if ([string]::IsNullOrWhiteSpace($Firma)) { return $true }

    if ($script:FallosAvisados.ContainsKey($Firma)) {
        $script:FallosAvisados[$Firma] = $script:FallosAvisados[$Firma] + 1
        return $false
    }

    if ($script:FallosAvisados.Count -ge $script:MaximoAvisosDeFallo) {
        return $false
    }

    $script:FallosAvisados[$Firma] = 1
    return $true
}
