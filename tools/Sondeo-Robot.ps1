<#
.SYNOPSIS
    Sondeo: comprueba si la ventana de Cachivache se puede manejar desde un
    guion con UI Automation. Solo Windows; no requiere administrador.

.DESCRIPTION
    Comprueba los requisitos de un futuro robot de interfaz (src/UI apenas
    tiene cobertura porque ninguna prueba abre la ventana). Usa UI
    Automation, la API de los lectores de pantalla, apoyándose en los
    AutomationProperties.Name de los controles:

        1. La ventana arranca y se localiza.
        2. Se enumeran los controles por su nombre accesible.
        3. Se puede pulsar uno y el programa reacciona.
        4. Se puede leer lo que muestra la ventana.
        5. Se cierra sin dejar procesos colgados.

    Solo cambia de panel y vuelve: no pulsa Analizar ni nada que elimine,
    y no toca archivos del usuario. La CI lo ejecuta para comprobar si el
    runner puede manejar la ventana.

.PARAMETER Segundos
    Cuánto esperar a que aparezca la ventana.

.PARAMETER DejarAbierta
    No cerrar la ventana al terminar.

.EXAMPLE
    # Desde la raíz del repositorio, sin administrador:
    .\tools\Sondeo-Robot.ps1
#>
[CmdletBinding()]
param(
    [int]    $Segundos = 40,
    [switch] $DejarAbierta
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent

function Write-Paso {
    param([string] $Numero, [string] $Texto, [string] $Estado = '', [string] $Detalle = '')
    $color = switch ($Estado) { 'BIEN' { 'Green' } 'FALLA' { 'Yellow' } default { 'Gray' } }
    Write-Host ('  {0,-3} {1,-46} {2}' -f $Numero, $Texto, $Estado) -ForegroundColor $color
    if ($Detalle) { Write-Host ('       {0}' -f $Detalle) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host '=== Sondeo: ¿se puede manejar la ventana? ===========================' -ForegroundColor Cyan
Write-Host ("  PowerShell {0} · {1}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
Write-Host ''

# --- 0. ¿Existe UI Automation en esta máquina? -----------------------
# Viene con .NET Framework en Windows de escritorio, pero no en ediciones
# sin escritorio (Server Core, contenedores), posibles en un runner.
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
    Write-Paso '0.' 'UI Automation esta disponible' 'BIEN'
} catch {
    Write-Paso '0.' 'UI Automation esta disponible' 'FALLA' $_.Exception.Message
    Write-Host ''
    Write-Host '  Sin UI Automation no se puede manejar la ventana: el sondeo termina aquí.' -ForegroundColor Yellow
    return
}

$proceso = $null
try {
    # --- 1. Arrancar la ventana --------------------------------------
    # El guion de entrada y no el .exe, para no tener que compilar.
    $guion = Join-Path $raiz 'Cachivache.ps1'
    # Ruta completa: por nombre se podría resolver a un powershell.exe ajeno.
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $proceso = Start-Process -FilePath $powershell `
                             -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $guion + '"')) `
                             -PassThru
    $reloj = [Diagnostics.Stopwatch]::StartNew()
    $ventana = $null
    while ($reloj.Elapsed.TotalSeconds -lt $Segundos) {
        Start-Sleep -Milliseconds 400
        if ($proceso.HasExited) { break }
        # Por identificador de proceso y no por título, que puede cambiar o
        # coincidir con otra ventana.
        $cond = [Windows.Automation.PropertyCondition]::new(
                    [Windows.Automation.AutomationElement]::ProcessIdProperty, $proceso.Id)
        $ventana = [Windows.Automation.AutomationElement]::RootElement.FindFirst(
                    [Windows.Automation.TreeScope]::Children, $cond)
        if ($null -ne $ventana) { break }
    }
    $reloj.Stop()

    if ($null -eq $ventana) {
        $motivo = if ($proceso.HasExited) { ('el proceso ha terminado con codigo {0}' -f $proceso.ExitCode) }
                  else { ('no ha aparecido en {0:N1} s' -f $reloj.Elapsed.TotalSeconds) }
        Write-Paso '1.' 'La ventana arranca y se localiza' 'FALLA' $motivo
        return
    }
    Write-Paso '1.' 'La ventana arranca y se localiza' 'BIEN' (
        'titulo "{0}", en {1:N1} s' -f $ventana.Current.Name, $reloj.Elapsed.TotalSeconds)

    # --- 2. Enumerar controles por su nombre accesible ---------------
    $todos = $ventana.FindAll([Windows.Automation.TreeScope]::Descendants,
                              [Windows.Automation.Condition]::TrueCondition)
    $conNombre = @()
    foreach ($e in $todos) {
        $n = $e.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($n)) { $conNombre += $n }
    }
    Write-Paso '2.' 'Se enumeran los controles' 'BIEN' (
        '{0} elementos, {1} con nombre accesible' -f $todos.Count, $conNombre.Count)

    # Se buscan los botones de navegación filtrando también por tipo de
    # control: el botón NavAjustes y el panel Ajustes comparten nombre
    # accesible. Además, WPF no construye un panel hasta que se muestra, así
    # que para UI Automation no existe hasta navegar a él.
    $buscados = @('Inicio', 'Resultados', 'Registro', 'Informes', 'Ajustes', 'Acerca de')

    function Get-PorNombre {
        param([string] $Nombre)
        $c = [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::NameProperty, $Nombre)
        return $ventana.FindFirst([Windows.Automation.TreeScope]::Descendants, $c)
    }

    function Get-Navegacion {
        param([string] $Nombre)
        $porNombre = [Windows.Automation.PropertyCondition]::new(
                        [Windows.Automation.AutomationElement]::NameProperty, $Nombre)
        # El tipo de control desempata entre elementos con el mismo nombre.
        $porTipo = [Windows.Automation.PropertyCondition]::new(
                        [Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [Windows.Automation.ControlType]::RadioButton)
        $ambas = [Windows.Automation.AndCondition]::new($porNombre, $porTipo)
        return $ventana.FindFirst([Windows.Automation.TreeScope]::Descendants, $ambas)
    }

    $faltan = @($buscados | Where-Object { $null -eq (Get-Navegacion $_) })
    if ($faltan.Count -eq 0) {
        Write-Paso '2b.' 'Los seis botones de navegacion se encuentran' 'BIEN'
    } else {
        Write-Paso '2b.' 'Los seis botones de navegacion se encuentran' 'FALLA' ('no aparecen: ' + ($faltan -join ', '))
    }

    # --- 3. Pulsar un botón -----------------------------------------
    # Se consultan los patrones admitidos: un RadioButton de WPF no admite
    # InvokePattern, se selecciona con SelectionItemPattern.
    $acerca = Get-Navegacion 'Acerca de'
    $pulsado = $false
    if ($null -eq $acerca) {
        Write-Paso '3.' 'Se puede pulsar un boton' 'FALLA' 'no se encuentra el boton "Acerca de"'
    } else {
        $patrones = @($acerca.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName })
        try {
            if ($acerca.GetSupportedPatterns() -contains [Windows.Automation.SelectionItemPattern]::Pattern) {
                $acerca.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
                $pulsado = $true
            } elseif ($acerca.GetSupportedPatterns() -contains [Windows.Automation.InvokePattern]::Pattern) {
                $acerca.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                $pulsado = $true
            }
            if ($pulsado) {
                Start-Sleep -Milliseconds 900
                Write-Paso '3.' 'Se puede pulsar un boton' 'BIEN' (
                    'pulsado "Acerca de". Patrones: {0}' -f ($patrones -join ', '))
            } else {
                Write-Paso '3.' 'Se puede pulsar un boton' 'FALLA' (
                    'no admite ni seleccionar ni invocar. Patrones: {0}' -f ($patrones -join ', '))
            }
        } catch {
            Write-Paso '3.' 'Se puede pulsar un boton' 'FALLA' $_.Exception.Message
        }
    }

    # --- 3b. ¿Ha reaccionado el programa? ----------------------------
    # La comprobación decisiva: el panel "Acerca de Cachivache" no existe en
    # el árbol hasta que se navega a él, así que si aparece, el clic llegó.
    if ($pulsado) {
        $panel = Get-PorNombre 'Acerca de Cachivache'
        if ($null -ne $panel) {
            Write-Paso '3b.' 'El programa reacciona al clic' 'BIEN' (
                'el panel "Acerca de Cachivache" no estaba en el arbol y ahora si')
        } else {
            Write-Paso '3b.' 'El programa reacciona al clic' 'FALLA' 'el panel sigue sin aparecer'
        }
    }

    # --- 4. Leer lo que la ventana dice ------------------------------
    # Se lee después de navegar: lo que no se ha mostrado no está en el árbol.
    $textos = @()
    $despues = $ventana.FindAll([Windows.Automation.TreeScope]::Descendants,
                                [Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $despues) {
        if ($e.Current.ControlType.ProgrammaticName -match 'Text|Edit') {
            $n = $e.Current.Name
            if (-not [string]::IsNullOrWhiteSpace($n)) { $textos += $n }
        }
    }
    if ($textos.Count -gt 0) {
        $muestra = @($textos | Select-Object -First 4) -join ' / '
        Write-Paso '4.' 'Se lee lo que la ventana dice' 'BIEN' (
            '{0} textos. Muestra: {1}' -f $textos.Count, $muestra)
    } else {
        Write-Paso '4.' 'Se lee lo que la ventana dice' 'FALLA' 'no se ha podido leer ni un texto'
    }

    # Volver al inicio (no se mide), con SelectionItemPattern como arriba.
    $volver = Get-Navegacion 'Inicio'
    if ($null -ne $volver) {
        try {
            $volver.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        } catch {
            Write-Verbose ('No se ha podido volver al panel de inicio: {0}' -f $_.Exception.Message)
        }
    }

} finally {
    # --- 5. Cerrar sin dejar nada colgado ----------------------------
    if ($null -ne $proceso -and -not $proceso.HasExited) {
        if ($DejarAbierta) {
            Write-Paso '5.' 'La ventana se cierra' '' ('se queda abierta a peticion, PID {0}' -f $proceso.Id)
        } else {
            try {
                $null = $proceso.CloseMainWindow()
                if (-not $proceso.WaitForExit(6000)) { $proceso.Kill() }
                Write-Paso '5.' 'La ventana se cierra' 'BIEN'
            } catch {
                Write-Paso '5.' 'La ventana se cierra' 'FALLA' $_.Exception.Message
            }
        }
    }
}

Write-Host ''
Write-Host '=== Fin del sondeo ==================================================' -ForegroundColor Cyan
Write-Host '  Si todos los pasos dicen BIEN, la ventana se puede manejar desde una prueba.'
Write-Host '  El paso decisivo es el 3b: pulsar sin poder comprobar el efecto daría'
Write-Host '  una prueba que hace clic sin mirar el resultado.'
Write-Host ''
Write-Host '  La integración continua ejecuta este sondeo antes de nada para saber si'
Write-Host '  la máquina puede manejar la ventana.'
