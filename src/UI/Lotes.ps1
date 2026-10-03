<#
.SYNOPSIS
    Cómo recorrer una lista larga de filas sin bloquear la ventana. Cálculo puro.

.DESCRIPTION
    No depende de WPF: recibe un número de filas y devuelve un plan; quien
    llama lo ejecuta.

    "Marcar todo", "Desmarcar todo" y "Solo lo seguro" asignan Seleccionado
    en cada fila desde el hilo de la interfaz, y cada asignación dispara
    PropertyChanged. Con miles de filas la ventana se congela varios
    segundos, así que por encima de un umbral se trocea el recorrido.

    Trocear hace que la ventana responda mientras marca, y por tanto que
    acepte clics: quien ejecuta debe desactivar los botones peligrosos (como
    eliminar) mientras dura y reactivarlos al final.

    Por debajo del umbral se hace de una vez: trocear añade una vuelta al
    despachador por trozo y sería más lento en el caso normal.
#>

function Get-PlanMarcadoEnLote {
    <#
    .SYNOPSIS
        Cómo trocear el marcado de N filas, o si no hay que trocearlo.

    .PARAMETER Total
        Cuántas filas hay que recorrer.

    .PARAMETER Umbral
        A partir de cuántas filas se trocea. Por debajo se hace de una vez.

    .PARAMETER Tamano
        Cuántas filas por trozo cuando se trocea.

    .NOTES
        Los trozos deben cubrir exactamente las Total filas, ni una más ni
        una menos (lo comprueba una invariante).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Total,
        [int] $Umbral = 2000,
        [int] $Tamano = 500
    )

    # Un valor no numérico se trata como "nada que hacer": se llama desde un
    # manejador de clic y no debe lanzar.
    $n = 0
    if ($null -ne $Total) {
        try { $n = [int]$Total } catch { $n = 0 }
    }
    if ($n -le 0) {
        return [pscustomobject]@{
            Total = 0; PorTrozos = $false; Tamano = 0; Trozos = 0; Umbral = $Umbral
        }
    }

    # Valores no válidos vuelven a los predeterminados para evitar bucles
    # infinitos o planes sin trozos.
    if ($Umbral -lt 1) { $Umbral = 2000 }
    if ($Tamano -lt 1) { $Tamano = 500 }

    if ($n -le $Umbral) {
        # De una sola vez, pero con un plan completo (un único trozo) para
        # que quien llama tenga un solo camino.
        return [pscustomobject]@{
            Total = $n; PorTrozos = $false; Tamano = $n; Trozos = 1; Umbral = $Umbral
        }
    }

    $trozos = [int][Math]::Ceiling($n / [double]$Tamano)
    return [pscustomobject]@{
        Total = $n; PorTrozos = $true; Tamano = $Tamano; Trozos = $trozos; Umbral = $Umbral
    }
}

function Get-RangosDeLote {
    <#
    .SYNOPSIS
        Los tramos concretos de un plan: desde dónde y cuántas filas.

    .DESCRIPTION
        Permite comprobar la cobertura sobre los tramos reales; el último
        tramo suele ser más corto que los demás.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)] [AllowNull()] $Plan)

    if ($null -eq $Plan -or [int]$Plan.Total -le 0) { return @() }

    $tramos = [Collections.Generic.List[object]]::new()
    $desde = 0
    while ($desde -lt [int]$Plan.Total) {
        $cuantas = [Math]::Min([int]$Plan.Tamano, [int]$Plan.Total - $desde)
        $tramos.Add([pscustomobject]@{ Desde = $desde; Cuantas = $cuantas })
        $desde += $cuantas
    }
    return $tramos.ToArray()
}
