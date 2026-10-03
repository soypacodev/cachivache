<#
.SYNOPSIS
    Comunicación de progreso y cancelación entre el hilo de trabajo y la
    interfaz.

.DESCRIPTION
    Las usan todos los módulos de limpieza. Solo leen y escriben la tabla
    sincronizada que comparten el runspace de análisis y la ventana.

    Aceptan $Sync nulo (modo consola), para que los módulos no tengan que
    distinguir el modo en que se ejecutan.
#>

function Test-Cancelacion {
    <#
    .SYNOPSIS
        Indica si la interfaz ha pedido abortar el análisis en curso.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Sync)

    if ($null -eq $Sync) { return $false }
    return [bool]$Sync.Cancelar
}

function Set-Progreso {
    <#
    .SYNOPSIS
        Publica el mensaje que la interfaz muestra bajo la barra de progreso.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Escribe un mensaje en una tabla en memoria para la interfaz.')]
    [CmdletBinding()]
    param(
        $Sync,
        [string] $Mensaje
    )
    if ($null -ne $Sync) { $Sync.Mensaje = $Mensaje }
}
