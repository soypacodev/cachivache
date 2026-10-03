<#
.SYNOPSIS
    Caché de descargas de Windows Update y optimización de entrega.
.DESCRIPTION
    Requiere administrador. Son paquetes de actualización ya instalados o a
    medio descargar: Windows los vuelve a bajar si los necesita. En equipos
    con años de uso suele ser lo que más espacio recupera.
#>

$BuscarWindowsUpdate = {
    param($Configuracion, $Sync)

    $raices = @($env:SystemRoot)

    $lista = @(
        @{
            N = 'Descargas de Windows Update'
            R = "$env:SystemRoot\SoftwareDistribution\Download"
            E = 'Paquetes de actualización ya aplicados. Windows los vuelve a descargar si hacen falta.'
            A = ''
        }
        @{
            N = 'Base de datos de Windows Update'
            R = "$env:SystemRoot\SoftwareDistribution\DataStore"
            E = 'Se reconstruye sola. El historial de actualizaciones instaladas se pierde.'
            A = 'Se borra el historial de actualizaciones que muestra Windows.'
        }
        @{
            N = 'Caché de optimización de entrega'
            R = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization"
            E = 'Trozos de actualizaciones que Windows comparte en la red local. Se regeneran.'
            A = ''
        }
    )

    # Umbral de 10 MB: aquí una carpeta de pocos megas no merece una fila.
    Invoke-BusquedaPorLista -ModuloId 'windowsupdate' -Categoria 'Windows Update' `
                            -Entradas $lista -Raices $raices -Sync $Sync `
                            -MinimoBytes 10MB -IncluirMenores

    # Restos de una actualización mayor de Windows. Se informa, no se borra:
    # eliminarlo impide volver a la versión anterior y Windows ya lo hace
    # solo a los diez días.
    $windowsOld = Join-Path ($env:SystemDrive + '\') 'Windows.old'
    if (Test-Path -LiteralPath $windowsOld) {
        $bytes = Measure-Ruta $windowsOld
        if ($bytes -ge 100MB) {
            New-Candidato -ModuloId 'windowsupdate' -Categoria 'Windows Update' `
                          -Nombre 'Windows.old (versión anterior de Windows)' -Ruta $windowsOld -Bytes $bytes `
                          -Info 'copia completa de la instalación anterior' `
                          -Efecto 'Usa Configuración > Sistema > Almacenamiento > Archivos temporales para quitarlo con seguridad. Windows lo borra solo a los 10 días.' `
                          -Aviso 'Este programa NO lo toca: borrarlo a mano puede dejar restos y te impide volver a la versión anterior.' `
                          -Metodo 'Informativo' -Raices @() -Riesgo 'Alto' -Preseleccionado $false
        }
    }
}

New-ModuloLimpieza -Id 'windowsupdate' -Orden 70 `
    -Nombre 'Caché de Windows Update' `
    -Descripcion 'Paquetes de actualización descargados que ya se aplicaron. Suele ser lo que más espacio recupera.' `
    -Riesgo 'Bajo' -RequiereAdmin `
    -Perfiles @('conservador', 'equilibrado', 'agresivo') `
    -Buscar $BuscarWindowsUpdate
