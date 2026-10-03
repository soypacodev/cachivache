<#
.SYNOPSIS
    Ejecuta todo lo que se puede comprobar sin abrir la ventana, en una
    sola pasada, y deja el informe en un archivo.

.DESCRIPTION
    Pasos:
      1. La suite de Pester completa.
      2. PSScriptAnalyzer con la configuración del proyecto.
      3. El suelo de cobertura (tools/Cobertura.ps1), salvo con -Rapido.
      4. El informe en pruebas/.

    Aunque las pruebas fallen, se ejecuta todo para dar el cuadro completo.
    El código de salida es 0 si todo está bien y 1 si no, de modo que sirve
    en la CI y en un gancho de git.

    No regenera el oráculo del XAML (tests/datos/MainWindow.montado.
    esperado.xaml): compararlo consigo mismo pasaría siempre. Si esa prueba
    falla, imprime el comando para regenerarlo.

    No ejecuta la interfaz: sin WPF, src/UI la cubren docs/PRUEBA-MANUAL.md,
    la CI en Windows y docs/BANCO-PRUEBAS.md. El informe lo recuerda al
    final.

.PARAMETER Ruta
    Qué probar. Por defecto, la carpeta tests; admite un archivo suelto.

.PARAMETER Rapido
    Sin cobertura, que multiplica por tres o cuatro la duración.

.PARAMETER SinRegistro
    No escribe el informe en disco (para cuando otro guion guarda la
    salida).

.EXAMPLE
    .\tools\Probar.ps1
    Todo, con cobertura, e informe en pruebas\.

.EXAMPLE
    .\tools\Probar.ps1 -Rapido
    Suite y analizador, sin medir cobertura.

.EXAMPLE
    .\tools\Probar.ps1 -Ruta tests\Cli.Tests.ps1 -Rapido
    Solo un archivo.
#>
[CmdletBinding()]
param(
    [string] $Ruta = 'tests',
    [switch] $Rapido,
    [switch] $SinRegistro
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Cobertura.ps1')

# Un único camino de salida: lo que se muestra es lo que se guarda.
$lineas = [Collections.Generic.List[string]]::new()
function Write-Informe {
    param([string] $Texto = '', [string] $Color = '')
    $lineas.Add($Texto)
    if ($Color) { Write-Host $Texto -ForegroundColor $Color } else { Write-Host $Texto }
}

function Test-ModuloDisponible {
    param([string] $Nombre, [string] $VersionMinima = '0.0')
    $m = @(Get-Module -ListAvailable -Name $Nombre |
           Where-Object { $_.Version -ge [version]$VersionMinima })
    return $m.Count -gt 0
}

$faltan = @()
if (-not (Test-ModuloDisponible -Nombre 'Pester' -VersionMinima '5.0')) { $faltan += 'Pester (5.0 o mas)' }
if (-not (Test-ModuloDisponible -Nombre 'PSScriptAnalyzer'))            { $faltan += 'PSScriptAnalyzer' }
if ($faltan.Count -gt 0) {
    Write-Host ''
    Write-Host ('  Falta por instalar: {0}' -f ($faltan -join ', ')) -ForegroundColor Red
    Write-Host '  Instalalos con:' -ForegroundColor DarkGray
    Write-Host '    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck'
    Write-Host '    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
    Write-Host ''
    exit 1
}

Push-Location $raiz
try {
    Import-Module Pester -MinimumVersion 5.0
    Import-Module PSScriptAnalyzer

    $arranque = Get-Date
    Write-Informe ''
    Write-Informe ('  Cachivache - pasada completa   {0}' -f $arranque.ToString('yyyy-MM-dd HH:mm:ss')) 'Cyan'
    Write-Informe ('  PowerShell {0} sobre {1}' -f $PSVersionTable.PSVersion,
                   $(if ($IsLinux) { 'Linux' } elseif ($IsMacOS) { 'macOS' } else { 'Windows' })) 'DarkGray'
    Write-Informe ''

    # ---------------------------------------------------------------
    #  1. La suite
    # ---------------------------------------------------------------
    $conf = New-PesterConfiguration
    $conf.Run.Path         = $Ruta
    $conf.Run.PassThru     = $true
    $conf.Output.Verbosity = 'None'
    if (-not $Rapido) {
        $conf.CodeCoverage.Enabled = $true
        $conf.CodeCoverage.Path    = @('src')
    }

    # 6>$null y 3>$null: el código probado escribe con Write-Host y
    # Write-Warning, y esa salida se mezclaría con el informe.
    $resultado = Invoke-Pester -Configuration $conf 6>$null 3>$null

    # Cero pruebas no es un éxito: suele ser una ruta mal escrita.
    if ($null -eq $resultado -or $resultado.TotalCount -eq 0) {
        Write-Informe ''
        Write-Informe ("  NO SE HA EJECUTADO NI UNA PRUEBA con -Ruta '{0}'." -f $Ruta) 'Red'
        Write-Informe '  Cero pruebas no es una suite en verde: es una ruta que no existe.' 'Red'
        Write-Host ''
        exit 1
    }

    # Si un .Tests.ps1 falla al cargarse (sintaxis, BeforeAll que lanza,
    # dot-source roto), Pester lo cuenta como contenedor fallido y no en
    # FailedCount: hay que comprobarlo aparte.
    $contenedoresRotos = [int] $resultado.FailedContainersCount
    if ($contenedoresRotos -gt 0) {
        Write-Informe ''
        Write-Informe ('  {0} archivo(s) de pruebas NO SE HAN PODIDO EJECUTAR.' -f $contenedoresRotos) 'Red'
        foreach ($c in $resultado.Containers) {
            if (-not $c.Passed) {
                Write-Informe ('    x {0}' -f $c.Item) 'Red'
                foreach ($e in @($c.ErrorRecord)) {
                    if ($e) { Write-Informe ('        {0}' -f $e.Exception.Message) 'DarkGray' }
                }
            }
        }
    }

    $fallaronPruebas = $resultado.FailedCount -gt 0 -or $contenedoresRotos -gt 0
    Write-Informe ('  PRUEBAS      {0} en total, {1} bien, {2} mal' -f `
                   $resultado.TotalCount, $resultado.PassedCount, $resultado.FailedCount) `
                  $(if ($fallaronPruebas) { 'Red' } else { 'Green' })

    if ($fallaronPruebas) {
        Write-Informe ''
        foreach ($f in $resultado.Failed) {
            Write-Informe ('    x {0}' -f $f.ExpandedPath) 'Red'
            $mensaje = @(($f.ErrorRecord.Exception.Message -split "`r?`n") | Select-Object -First 4)
            foreach ($m in $mensaje) { Write-Informe ('        {0}' -f $m) 'DarkGray' }
        }

        # Aviso del oráculo, solo si falla alguna prueba relacionada.
        $sonaOraculo = @($resultado.Failed | Where-Object {
            $_.ExpandedPath -match 'oraculo|montad|xaml' }).Count -gt 0
        if ($sonaOraculo) {
            Write-Informe ''
            Write-Informe '  Parece el oraculo del XAML. Si el cambio en src/UI/*.xaml es intencionado, regeneralo:' 'Yellow'
            Write-Informe '    . ./src/UI/Xaml.ps1'
            Write-Informe '    $ui = Join-Path (Get-Location) "src/UI"'
            Write-Informe '    $m = Expand-PanelesXaml -Texto ([IO.File]::ReadAllText((Join-Path $ui "MainWindow.xaml"))) -Carpeta $ui'
            Write-Informe '    [IO.File]::WriteAllText("tests/datos/MainWindow.montado.esperado.xaml", $m, [Text.UTF8Encoding]::new($true))'
            Write-Informe '  Este guion NO lo regenera solo: comparar un archivo consigo mismo pasa siempre.' 'DarkGray'
        }
    }

    # ---------------------------------------------------------------
    #  2. El analizador
    # ---------------------------------------------------------------
    $avisos = @(Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1)
    $fallaronAvisos = $avisos.Count -gt 0
    Write-Informe ('  ANALIZADOR   {0} avisos' -f $avisos.Count) `
                  $(if ($fallaronAvisos) { 'Red' } else { 'Green' })
    foreach ($a in $avisos) {
        Write-Informe ('    x {0}:{1}  {2}' -f (Split-Path $a.ScriptName -Leaf), $a.Line, $a.RuleName) 'Red'
    }

    # ---------------------------------------------------------------
    #  3. La cobertura y su suelo
    # ---------------------------------------------------------------
    $fallaronSuelos = $false
    if ($Rapido) {
        Write-Informe '  COBERTURA    sin medir (-Rapido)' 'DarkGray'
    } else {
        $medido = @{}
        $porCarpeta = @{}
        foreach ($x in $resultado.CodeCoverage.CommandsMissed) {
            $k = Split-Path (Split-Path $x.File -Parent) -Leaf
            if (-not $porCarpeta.ContainsKey($k)) { $porCarpeta[$k] = @{ Mal = 0; Bien = 0 } }
            $porCarpeta[$k].Mal++
        }
        foreach ($x in $resultado.CodeCoverage.CommandsExecuted) {
            $k = Split-Path (Split-Path $x.File -Parent) -Leaf
            if (-not $porCarpeta.ContainsKey($k)) { $porCarpeta[$k] = @{ Mal = 0; Bien = 0 } }
            $porCarpeta[$k].Bien++
        }
        foreach ($k in $porCarpeta.Keys) {
            $total = $porCarpeta[$k].Bien + $porCarpeta[$k].Mal
            if ($total -gt 0) { $medido[$k] = 100.0 * $porCarpeta[$k].Bien / $total }
        }
        $medido['total'] = [double] $resultado.CodeCoverage.CoveragePercent

        Write-Informe ('  COBERTURA    {0:N1}% del programa se ha llegado a ejecutar' -f $medido['total'])
        foreach ($k in ($medido.Keys | Where-Object { $_ -ne 'total' } | Sort-Object)) {
            $sinEjecutar = if ($porCarpeta.ContainsKey($k)) { $porCarpeta[$k].Mal } else { 0 }
            Write-Informe ('      src/{0,-10} {1,6:N1}%   {2} instrucciones sin ejecutar' -f `
                           $k, $medido[$k], $sinEjecutar) 'DarkGray'
        }

        $motivos = @(Test-CoberturaSuficiente -Medido $medido)
        $fallaronSuelos = $motivos.Count -gt 0
        if ($fallaronSuelos) {
            Write-Informe ''
            foreach ($m in $motivos) { Write-Informe ('    x SUELO  {0}' -f $m) 'Red' }
        }
    }

    # ---------------------------------------------------------------
    #  4. Veredicto
    # ---------------------------------------------------------------
    $todoBien = -not ($fallaronPruebas -or $fallaronAvisos -or $fallaronSuelos)
    Write-Informe ''
    Write-Informe ('  {0}   ({1:N0} s)' -f `
                   $(if ($todoBien) { 'TODO EN VERDE' } else { 'HAY ALGO QUE MIRAR' }),
                   ((Get-Date) - $arranque).TotalSeconds) `
                  $(if ($todoBien) { 'Green' } else { 'Red' })

    # Siempre, también en verde: la interfaz no se ejecuta aquí.
    Write-Informe ''
    Write-Informe '  Esto NO cubre la ventana: no hay WPF donde esto se ejecuta. Para eso estan' 'DarkGray'
    Write-Informe '  docs/PRUEBA-MANUAL.md, la pestaña Actions y docs/BANCO-PRUEBAS.md.' 'DarkGray'

    # ---------------------------------------------------------------
    #  El informe en disco
    # ---------------------------------------------------------------
    if (-not $SinRegistro) {
        $carpeta = Join-Path $raiz 'pruebas'
        if (-not (Test-Path -LiteralPath $carpeta)) {
            [void](New-Item -ItemType Directory -Path $carpeta -Force)
        }
        $archivo = Join-Path $carpeta ('{0}-{1}.txt' -f `
                    $arranque.ToString('yyyy-MM-dd-HHmmss'),
                    $(if ($todoBien) { 'verde' } else { 'rojo' }))
        [IO.File]::WriteAllLines($archivo, $lineas)

        # Copia con nombre fijo, además de la fechada.
        [IO.File]::WriteAllLines((Join-Path $carpeta 'ultima-pasada.txt'), $lineas)

        # Solo se conservan los veinte últimos informes.
        $viejas = @(Get-ChildItem -LiteralPath $carpeta -Filter '*-*.txt' -File |
                    Sort-Object Name -Descending | Select-Object -Skip 20)
        foreach ($v in $viejas) { Remove-Item -LiteralPath $v.FullName -Force -ErrorAction SilentlyContinue }

        Write-Host ''
        Write-Host ('  Informe: {0}' -f $archivo) -ForegroundColor DarkGray
    }
    Write-Host ''

    if (-not $todoBien) { exit 1 }
    exit 0
} finally {
    Pop-Location
}
