<#
.SYNOPSIS
    Cachivache - analiza y libera espacio en Windows sin romper nada.

.DESCRIPTION
    Punto de entrada único. Sin parámetros abre la ventana; con -Consola
    trabaja en la terminal. Todo el código real vive en src/.

    El análisis nunca borra nada. Para eliminar hace falta una confirmación
    escrita en la ventana o el modificador -Ejecutar en modo consola.

.PARAMETER Consola
    Trabaja en la terminal en lugar de abrir la ventana.

.PARAMETER Perfil
    conservador | equilibrado | agresivo | personalizado.

.PARAMETER Modulos
    Identificadores de módulo concretos. Sustituye a la selección del
    perfil. Usa -Listar para ver los disponibles.

.PARAMETER Ejecutar
    Solo en modo consola: elimina los elementos que el análisis haya
    marcado por su cuenta (riesgo bajo y sin avisos).

.PARAMETER Permanente
    Borra sin pasar por la papelera. Irreversible.

.PARAMETER Simular
    Con -Ejecutar, muestra qué se borraría y cuánto espacio se liberaría
    sin tocar ningún archivo.

        .\Cachivache.ps1 -Consola -Ejecutar -Simular

.PARAMETER Excluir
    Carpetas que no se tocan ni se proponen, incluido todo lo que cuelga de
    ellas. Se suman a las guardadas en las preferencias.

        .\Cachivache.ps1 -Consola -Excluir 'D:\Trabajo','C:\Proyectos\activo'

.PARAMETER Espacio
    Muestra dónde se ha ido el espacio: árbol de carpetas ordenado por
    tamaño y archivos más grandes. Es un informe: no propone ni borra nada.
    Acepta rutas; sin ellas usa las carpetas del usuario.

.PARAMETER Profundidad
    Niveles de carpeta que muestra -Espacio. Por defecto 2.

.PARAMETER Buscar
    Filtra los archivos de -Espacio por nombre. Admite comodines.

.PARAMETER Recorrer
    Obliga a -Espacio a medir de nuevo el disco aunque haya un índice
    reciente reutilizable. Cuando se reutiliza un índice, el programa lo
    avisa: describe el disco en el momento en que se guardó.

.PARAMETER InformeAnonimo
    Sustituye en el informe la carpeta de perfil, el nombre de usuario y el
    nombre del equipo por marcadores genéricos. Útil para compartirlo o
    adjuntarlo a una incidencia.

.PARAMETER Informe
    Ruta del informe a generar. La extensión decide el formato:
    .html, .csv o .json.

.PARAMETER Listar
    Muestra los módulos disponibles y termina.

.PARAMETER Silencioso
    No escribe nada por pantalla. Útil en tareas programadas.

.PARAMETER Diagnostico
    Vuelca versión, entorno, unidades y el final del registro, listo para
    pegar en una incidencia, y termina sin analizar ni abrir la ventana.

.EXAMPLE
    .\Cachivache.ps1
    Abre la ventana.

.EXAMPLE
    .\Cachivache.ps1 -Consola -Perfil conservador -Informe .\informe.html
    Analiza sin borrar nada y guarda un informe.

.EXAMPLE
    .\Cachivache.ps1 -Consola -Modulos caches,navegadores -Ejecutar
    Vacía las cachés de aplicaciones y de navegadores.

.EXAMPLE
    .\Cachivache.ps1 -Diagnostico
    Vuelca el entorno y el final del registro, listo para pegar en una
    incidencia.

.LINK
    https://github.com/soypacodev/cachivache
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $Consola,

    [ValidateSet('conservador', 'equilibrado', 'agresivo', 'personalizado')]
    [string] $Perfil = '',

    [string[]] $Modulos = @(),

    [switch] $Ejecutar,
    [switch] $Permanente,
    [string] $Informe = '',
    [switch] $InformeAnonimo,
    [switch] $Simular,
    [string[]] $Excluir = @(),
    [switch] $Espacio,
    [int]    $Profundidad = 2,
    [string] $Buscar = '',
    [switch] $Recorrer,
    [switch] $Listar,
    [switch] $Silencioso,
    [switch] $Diagnostico
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------
#  Comprobaciones previas
# ---------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error 'Cachivache necesita PowerShell 5.1 o superior.'
    exit 1
}
if ($env:OS -ne 'Windows_NT') {
    Write-Error 'Cachivache solo funciona en Windows.'
    exit 1
}

$Raiz = $PSScriptRoot

# ---------------------------------------------------------------------
#  Carga del núcleo
# ---------------------------------------------------------------------
try {
    . (Join-Path (Join-Path (Join-Path $Raiz 'src') 'Core') 'Bootstrap.ps1')
} catch {
    Write-Error "No se ha podido cargar el nucleo del programa: $($_.Exception.Message)"
    exit 1
}

[void](Initialize-Registro)

# ---------------------------------------------------------------------
#  -Diagnóstico
# ---------------------------------------------------------------------
# Va antes de cargar los módulos: debe funcionar aunque src/Modules esté
# vacío o roto, que es uno de los fallos que sirve para diagnosticar.
if ($Diagnostico) {
    Write-Host (Get-InformeDiagnostico)
    exit 0
}

$modulosDisponibles = @(Get-ModulosLimpieza -Raiz $Raiz)

if ($modulosDisponibles.Count -eq 0) {
    Write-Error 'No se ha encontrado ningun modulo de limpieza en src/Modules.'
    exit 1
}

# ---------------------------------------------------------------------
#  -Listar
# ---------------------------------------------------------------------
if ($Listar) {
    Write-Host ''
    Write-Host "  Cachivache v$script:VersionCachivache - modulos disponibles" -ForegroundColor Cyan
    Write-Host ''
    foreach ($modulo in $modulosDisponibles) {
        $etiquetas = @()
        if ($modulo.RequiereAdmin) { $etiquetas += 'admin' }
        if ($modulo.SoloInforma)   { $etiquetas += 'solo informa' }
        $sufijo = if ($etiquetas.Count -gt 0) { '  [' + ($etiquetas -join ', ') + ']' } else { '' }

        Write-Host ('  {0,-16}' -f $modulo.Id) -ForegroundColor Green -NoNewline
        Write-Host ('{0}{1}' -f $modulo.Nombre, $sufijo)
        Write-Host ('                  {0}' -f $modulo.Descripcion) -ForegroundColor DarkGray
        Write-Host ('                  riesgo {0} - perfiles: {1}' -f `
                    $modulo.Riesgo.ToLower(), ($modulo.Perfiles -join ', ')) -ForegroundColor DarkGray
        Write-Host ''
    }
    exit 0
}

# ---------------------------------------------------------------------
#  Configuración
# ---------------------------------------------------------------------
$preferencias = Import-Preferencias
if ([string]::IsNullOrWhiteSpace($Perfil)) { $Perfil = [string]$preferencias.Perfil }
if ([string]::IsNullOrWhiteSpace($Perfil)) { $Perfil = 'equilibrado' }

$configuracion = New-Configuracion -Perfil $Perfil
if ($Perfil -eq 'personalizado') {
    $configuracion.MinimoMB       = [int]$preferencias.MinimoMB
    $configuracion.DiasSinUso     = [int]$preferencias.DiasSinUso
    $configuracion.IncluirMenores = [bool]$preferencias.IncluirMenores
}
# Las exclusiones de -Excluir se suman a las guardadas, no las sustituyen:
# añaden protección para esta ejecución sin retirar la ya configurada.
$configuracion.RutasExcluidas = @(
    @($preferencias.RutasExcluidas) + @($Excluir) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
)

if ($Permanente) { $configuracion.Permanente = $true }

Initialize-Guardia -Configuracion $configuracion

# Sin guardia activa cualquier ruta sería borrable: en ese caso no se arranca.
if (-not (Test-RutaIntocable 'C:\Windows\System32')) {
    Write-Error 'La guardia de seguridad no se ha inicializado correctamente. El programa no va a continuar.'
    exit 1
}

# Un identificador de módulo inválido es un error: mejor que analizar de menos.
if ($Modulos.Count -gt 0) {
    $conocidos = @($modulosDisponibles | ForEach-Object { $_.Id })
    $desconocidos = @($Modulos | Where-Object { $conocidos -notcontains $_ })
    if ($desconocidos.Count -gt 0) {
        Write-Error ("Modulos desconocidos: {0}. Usa -Listar para ver los disponibles." -f ($desconocidos -join ', '))
        exit 1
    }
}

# ---------------------------------------------------------------------
#  Modo espacio
# ---------------------------------------------------------------------
# Es una consulta (no analiza ni borra); usa el núcleo y la guardia ya
# inicializados.
if ($Espacio) {
    . (Join-Path (Join-Path (Join-Path $Raiz 'src') 'Cli') 'Cli.ps1')
    . (Join-Path (Join-Path (Join-Path $Raiz 'src') 'Cli') 'Espacio.ps1')

    Show-InformeEspacio -Rutas $Modulos -Profundidad $Profundidad -Buscar $Buscar `
                        -Recorrer:$Recorrer `
                        -Anonimo:$InformeAnonimo -Informe $Informe -Configuracion $configuracion
    exit 0
}

# ---------------------------------------------------------------------
#  Modo consola
# ---------------------------------------------------------------------
if ($Consola) {
    . (Join-Path (Join-Path (Join-Path $Raiz 'src') 'Cli') 'Cli.ps1')
    $codigo = Invoke-CachivacheCli -Configuracion $configuracion -Modulos $modulosDisponibles `
                                  -Ids $Modulos -Ejecutar:$Ejecutar -Informe $Informe `
                                  -InformeAnonimo:$InformeAnonimo -Simular:$Simular `
                                  -Silencioso:$Silencioso -Confirm:$false
    exit $codigo
}

# ---------------------------------------------------------------------
#  Modo ventana
# ---------------------------------------------------------------------
try {
    . (Join-Path (Join-Path (Join-Path $Raiz 'src') 'UI') 'Types.ps1')
    . (Join-Path (Join-Path (Join-Path $Raiz 'src') 'UI') 'Window.ps1')
    . (Join-Path (Join-Path (Join-Path $Raiz 'src') 'UI') 'Dialogs.ps1')
} catch {
    Write-Error "No se ha podido cargar la interfaz: $($_.Exception.Message)"
    exit 1
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning 'PowerShell no esta en modo STA. Abre el programa con Cachivache.bat o añade -STA.'
}

$preferencias.Perfil = $Perfil
try {
    Show-VentanaPrincipal -Configuracion $configuracion -Modulos $modulosDisponibles `
                          -Preferencias $preferencias -Raiz $Raiz
} catch {
    # El mensaje de la excepción solo apunta a esta llamada; la pila de
    # PowerShell y las excepciones internas indican el archivo y la línea
    # reales del fallo.
    Write-Host ''
    Write-Host '  La ventana ha fallado al arrancar.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Mensaje:' -ForegroundColor Yellow
    Write-Host "    $($_.Exception.Message)"
    $interna = $_.Exception.InnerException
    while ($interna) {
        Write-Host "    causado por: $($interna.Message)"
        $interna = $interna.InnerException
    }
    Write-Host ''
    Write-Host '  Donde (lo de arriba del todo es el sitio exacto):' -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace
    Write-Host ''
    try {
        Write-Registro -Nivel 'ERROR' -Mensaje "Fallo al abrir la ventana: $($_.Exception.Message)"
        Write-Registro -Nivel 'ERROR' -Mensaje $_.ScriptStackTrace
    } catch {
        Write-Verbose "Tampoco se ha podido anotar el fallo en el registro: $($_.Exception.Message)"
    }
    exit 1
}
exit 0
