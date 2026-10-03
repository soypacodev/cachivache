<#
.SYNOPSIS
    Registros y volcados del sistema operativo. Requiere administrador.
.DESCRIPTION
    Registros de mantenimiento de Windows, informes de errores y volcados de
    memoria. Ninguno hace falta para que el equipo funcione: son material de
    diagnóstico que Windows conserva indefinidamente.
#>

$BuscarLogsSistema = {
    param($Configuracion, $Sync)

    $lista = @(
        @{ N = 'Registros CBS';                 R = "$env:SystemRoot\Logs\CBS";              M = 'Contenido'; E = 'Registros del servicio de componentes. Sin efecto.' }
        @{ N = 'Registros DISM';                R = "$env:SystemRoot\Logs\DISM";             M = 'Contenido'; E = 'Registros de mantenimiento de la imagen. Sin efecto.' }
        @{ N = 'Registros de Windows Update';   R = "$env:SystemRoot\Logs\WindowsUpdate";    M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Registros de instalación';      R = "$env:SystemRoot\Panther";               M = 'Contenido'; E = 'Registros de cuando se instaló Windows. Sin efecto.' }
        @{ N = 'Volcados del kernel';           R = "$env:SystemRoot\LiveKernelReports";     M = 'Contenido'; E = 'Volcados de fallos del sistema ya ocurridos. Sin efecto.' }
        @{ N = 'Minivolcados de memoria';       R = "$env:SystemRoot\Minidump";              M = 'Contenido'; E = 'Volcados de pantallazos azules antiguos. Sin efecto.' }
        @{ N = 'Informes de error archivados';  R = "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"; M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Informes de error en cola';     R = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue";   M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Caché de Prefetch';             R = "$env:SystemRoot\Prefetch";              M = 'Contenido'; E = 'Windows lo regenera. Los primeros arranques de cada programa irán algo más lentos.' }
        # Temporales del sistema; los del usuario (%LOCALAPPDATA%\Temp) los
        # cubre el módulo de cachés.
        @{ N = 'Temporales del sistema';        R = "$env:SystemRoot\Temp";                 M = 'Contenido'; E = 'Sin efecto. Los archivos en uso se saltan solos.' }
        @{ N = 'Registros de reparación de Windows'; R = "$env:SystemRoot\Logs\waasmedic"; M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Registros de mantenimiento SIH'; R = "$env:SystemRoot\Logs\SIH";           M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Registros de instalación de actualizaciones'; R = "$env:SystemRoot\Logs\MoSetup"; M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Registros de red';              R = "$env:SystemRoot\Logs\NetSetup";       M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Registros de depuración';       R = "$env:SystemRoot\debug";                M = 'Contenido'; E = 'Sin efecto.' }
        @{ N = 'Registros de USO';              R = "$env:ProgramData\USOShared\Logs";     M = 'Contenido'; E = 'Registros del orquestador de actualizaciones. Sin efecto.' }
    )

    $raices = @($env:SystemRoot, $env:ProgramData)

    Invoke-BusquedaPorLista -ModuloId 'logs' -Categoria 'Registros del sistema' `
                            -Entradas $lista -Raices $raices -Sync $Sync `
                            -MinimoBytes 1MB -IncluirMenores

    # Volcado completo de memoria: puede ocupar tanto como la RAM instalada.
    $volcado = Join-Path $env:SystemRoot 'MEMORY.DMP'
    if (Test-Path -LiteralPath $volcado) {
        $item = Get-Item -LiteralPath $volcado -Force -ErrorAction SilentlyContinue
        if ($item -and $item.Length -ge 10MB -and (Test-RutaSegura $volcado $raices)) {
            New-Candidato -ModuloId 'logs' -Categoria 'Registros del sistema' `
                          -Nombre 'Volcado completo de memoria (MEMORY.DMP)' -Ruta $volcado -Bytes $item.Length `
                          -Info "generado el $($item.LastWriteTime.ToString('yyyy-MM-dd'))" `
                          -Efecto 'Volcado de un pantallazo azul ya pasado. Solo sirve para depurar ese fallo concreto.' `
                          -Metodo 'Ruta' -Raices $raices -Riesgo 'Bajo' -Preseleccionado $true
        }
    }
}

New-ModuloLimpieza -Id 'logs' -Orden 65 `
    -Nombre 'Registros y volcados del sistema' `
    -Descripcion 'Registros de mantenimiento, informes de errores y volcados de memoria de Windows.' `
    -Riesgo 'Bajo' -RequiereAdmin `
    -Perfiles @('conservador', 'equilibrado', 'agresivo') `
    -Buscar $BuscarLogsSistema
