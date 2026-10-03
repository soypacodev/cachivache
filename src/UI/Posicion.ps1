<#
.SYNOPSIS
    Cálculos puros de geometría de la ventana: qué desplazamiento y qué
    selección se recuperan al reenganchar la tabla, y hasta dónde puede
    crecer un diálogo sin salirse de la pantalla.

.DESCRIPTION
    No depende de WPF: así las pruebas cubren los casos límite (desplazamiento
    que ya no cabe, desplazador que aún no ha medido y devuelve NaN) sin
    interfaz gráfica. Aquí se decide y quien llama ejecuta.

    La tabla de resultados se desengancha y se vuelve a enganchar
    (ItemsSource a $null y de nuevo a la colección) al terminar cada módulo
    del análisis, para no repintar por cada fila, y al cambiar de tema, para
    reevaluar los colores. En ambos casos WPF regenera la lista y se pierden
    el desplazamiento y la selección; estas funciones deciden cómo
    recuperarlos.

    Deliberadamente no se desplaza la tabla hasta la fila seleccionada: el
    usuario puede estar leyendo lejos de ella. Una invariante prohíbe
    ScrollIntoView en el camino de restauración.
#>

function Get-DesplazamientoRestaurado {
    <#
    .SYNOPSIS
        A qué altura volver, dado lo que había antes y lo que cabe ahora.

    .DESCRIPTION
        Recorta el desplazamiento guardado al máximo actual: la lista puede
        haberse acortado (por ejemplo, por un filtro) desde que se guardó.

    .PARAMETER Guardado
        El desplazamiento vertical antes de desenganchar.

    .PARAMETER Maximo
        El desplazamiento máximo actual. Cero significa que la lista cabe
        entera en pantalla.

    .OUTPUTS
        El desplazamiento a aplicar. Cero ("arriba del todo") también es la
        respuesta ante datos no válidos.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double] $Guardado,
        [Parameter(Mandatory)] [double] $Maximo
    )

    # Un desplazador que aún no se ha medido devuelve NaN o infinito. Se
    # filtran antes de comparar: "NaN -gt 0" y "NaN -le 0" son ambas falsas
    # y el valor llegaría intacto a ScrollToVerticalOffset.
    foreach ($n in @($Guardado, $Maximo)) {
        if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return 0.0 }
    }

    # Los negativos se recortan aquí (WPF lo haría en silencio) para que la
    # decisión sea comprobable.
    if ($Guardado -le 0 -or $Maximo -le 0) { return 0.0 }
    if ($Guardado -ge $Maximo) { return [double] $Maximo }
    return [double] $Guardado
}

function Get-PlanRestauracionTabla {
    <#
    .SYNOPSIS
        Qué hay que restaurar tras reenganchar la tabla: desplazamiento,
        selección, ambos o nada.

    .DESCRIPTION
        Devuelve siempre un plan, nunca $null; "nada que hacer" se expresa
        con HayQueHacerAlgo = $false.

    .PARAMETER Guardado
        El desplazamiento vertical de antes de desenganchar.

    .PARAMETER Maximo
        Lo que se puede desplazar ahora, ya con las filas nuevas dentro.

    .PARAMETER HabiaSeleccion
        Si había una fila seleccionada cuando se guardó.

    .PARAMETER SeleccionVisible
        Si esa fila sigue pasando el filtro actual. Una selección oculta por
        el filtro no se restaura: "Abrir la ubicación", el menú contextual e
        Intro actuarían sobre una fila que el usuario no ve.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [double] $Guardado,
        [Parameter(Mandatory)] [double] $Maximo,
        [switch] $HabiaSeleccion,
        [switch] $SeleccionVisible
    )

    $desplazamiento = Get-DesplazamientoRestaurado -Guardado $Guardado -Maximo $Maximo
    $restaurarSeleccion = [bool] ($HabiaSeleccion -and $SeleccionVisible)

    return [pscustomobject] @{
        Desplazamiento     = $desplazamiento
        RestaurarSeleccion = $restaurarSeleccion
        # Permite no tocar nada en el caso normal (sin desplazamiento ni
        # selección que restaurar).
        HayQueHacerAlgo    = ($desplazamiento -gt 0) -or $restaurarSeleccion
    }
}

function Get-AlturaMaximaDialogo {
    <#
    .SYNOPSIS
        Hasta dónde puede crecer un diálogo sin salirse de la pantalla.

    .DESCRIPTION
        Un MaxHeight fijo en el XAML no sirve: WPF trabaja en puntos, y una
        pantalla de 1366x768 al 150 % mide 512 puntos de alto. El tope se
        calcula a partir del área de trabajo real, menos un margen para los
        bordes y la sombra de la ventana.

    .PARAMETER AltoAreaUtil
        Alto del área de trabajo del escritorio, en puntos
        ([System.Windows.SystemParameters]::WorkArea.Height).

    .PARAMETER Margen
        Espacio total que se deja libre entre arriba y abajo.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double] $AltoAreaUtil,
        [double] $Margen = 48
    )

    # Ante un dato no válido se devuelve el mínimo y no se lanza: se llama
    # justo antes de mostrar el diálogo de confirmación de borrado.
    if ([double]::IsNaN($AltoAreaUtil) -or [double]::IsInfinity($AltoAreaUtil) -or
        $AltoAreaUtil -le 0) {
        return 320.0
    }

    $alto = $AltoAreaUtil - $Margen

    # Mínimo: por debajo no caben el resumen y los botones.
    if ($alto -lt 320) { return 320.0 }

    # Máximo: en pantallas grandes la lista interior ya se desplaza sola.
    if ($alto -gt 760) { return 760.0 }

    return [double] $alto
}
