<#
.SYNOPSIS
    Disposición del mapa de árbol: convierte tamaños en rectángulos.

.DESCRIPTION
    Cálculo puro: no dibuja ni toca el disco. Recibe elementos con un
    tamaño y un área, y devuelve la geometría de cada uno junto con el
    elemento original. Sirve igual para WPF, para un SVG o para una prueba.

    Usa el algoritmo "squarified treemap" (Bruls, Huizing y van Wijk): añade
    elementos a una fila mientras la proporción (lado largo / lado corto)
    del peor rectángulo mejore, y la cierra cuando empeora. Así se evitan
    las tiras largas y finas del reparto ingenuo.
#>

function New-Rectangulo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo compone un objeto en memoria.')]
    [CmdletBinding()]
    param([double] $X, [double] $Y, [double] $Ancho, [double] $Alto)

    return [pscustomobject]@{ X = $X; Y = $Y; Ancho = $Ancho; Alto = $Alto }
}

function Get-ProporcionPeor {
    <#
    .SYNOPSIS
        Proporción del peor rectángulo de una fila.
    .DESCRIPTION
        Decide cuándo cerrar una fila. Recibe los tamaños de la fila, su
        suma y el lado corto disponible.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [double[]] $Tamanos,
        [double]   $Suma,
        [double]   $Lado
    )

    if ($Tamanos.Count -eq 0 -or $Suma -le 0 -or $Lado -le 0) { return [double]::MaxValue }

    $minimo = [double]::MaxValue
    $maximo = 0.0
    foreach ($t in $Tamanos) {
        if ($t -lt $minimo) { $minimo = $t }
        if ($t -gt $maximo) { $maximo = $t }
    }
    if ($minimo -le 0) { return [double]::MaxValue }

    # Fórmula del artículo original: max( l^2*max/s^2 , s^2/(l^2*min) ).
    $ladoCuadrado = $Lado * $Lado
    $sumaCuadrado = $Suma * $Suma
    return [Math]::Max(($ladoCuadrado * $maximo) / $sumaCuadrado,
                       $sumaCuadrado / ($ladoCuadrado * $minimo))
}

function Get-DisposicionMapa {
    <#
    .SYNOPSIS
        Reparte un rectángulo entre una lista de elementos, en proporción
        a su tamaño.

    .PARAMETER Elementos
        Objetos con una propiedad de tamaño. Se devuelven tal cual dentro
        del resultado.
    .PARAMETER Ancho
    .PARAMETER Alto
        Tamaño del área a repartir, en cualquier unidad.
    .PARAMETER Propiedad
        Nombre de la propiedad que lleva el tamaño.
    .PARAMETER MinimoLado
        Los rectángulos con algún lado menor que esto no se devuelven.

    .NOTES
        Los elementos se ordenan de mayor a menor, que es lo que el
        algoritmo necesita para producir rectángulos cuadrados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Elementos,
        [Parameter(Mandatory)] [double] $Ancho,
        [Parameter(Mandatory)] [double] $Alto,
        [string] $Propiedad  = 'Bytes',
        [double] $MinimoLado = 3
    )

    $resultado = [Collections.Generic.List[object]]::new()
    if ($Ancho -le 0 -or $Alto -le 0) { return @($resultado) }

    # Ordenar con un bloque de script y no con "-Property $Propiedad": en
    # PowerShell 5.1 este no ordena los diccionarios de un índice leído de
    # disco, y no da error.
    $lista = @(@($Elementos) |
               Where-Object { $null -ne $_ -and [double]$_.$Propiedad -gt 0 } |
               Sort-Object -Property { [double]$_.$Propiedad } -Descending)
    if ($lista.Count -eq 0) { return @($resultado) }

    $total = 0.0
    foreach ($e in $lista) { $total += [double]$e.$Propiedad }
    if ($total -le 0) { return @($resultado) }

    # Se trabaja en área: cada elemento recibe una porción proporcional a
    # su tamaño, independiente de la escala.
    $areaTotal = $Ancho * $Alto
    $escala    = $areaTotal / $total

    $x = 0.0; $y = 0.0
    $anchoLibre = $Ancho; $altoLibre = $Alto

    $indice = 0
    while ($indice -lt $lista.Count -and $anchoLibre -gt 0 -and $altoLibre -gt 0) {

        # Las filas se apoyan en el lado corto para salir lo más cuadradas posible.
        $lado = [Math]::Min($anchoLibre, $altoLibre)

        $fila      = [Collections.Generic.List[object]]::new()
        $areasFila = [Collections.Generic.List[double]]::new()
        $sumaFila  = 0.0

        while ($indice -lt $lista.Count) {
            $area = [double]$lista[$indice].$Propiedad * $escala
            if ($area -le 0) { $indice++; continue }

            if ($fila.Count -eq 0) {
                $fila.Add($lista[$indice]); $areasFila.Add($area)
                $sumaFila += $area; $indice++
                continue
            }

            # Si añadir el elemento empeora el peor rectángulo, la fila se cierra.
            $actual = Get-ProporcionPeor -Tamanos $areasFila.ToArray() -Suma $sumaFila -Lado $lado
            $conNuevo = [Collections.Generic.List[double]]::new($areasFila)
            $conNuevo.Add($area)
            $siguiente = Get-ProporcionPeor -Tamanos $conNuevo.ToArray() -Suma ($sumaFila + $area) -Lado $lado

            if ($siguiente -gt $actual) { break }

            $fila.Add($lista[$indice]); $areasFila.Add($area)
            $sumaFila += $area; $indice++
        }

        if ($fila.Count -eq 0) { break }

        # La fila ocupa una banda de grosor "suma / lado".
        $grosor = $sumaFila / $lado
        $avance = 0.0

        for ($i = 0; $i -lt $fila.Count; $i++) {
            $trozo = $areasFila[$i] / $grosor

            if ($anchoLibre -ge $altoLibre) {
                # Banda vertical a la izquierda del área libre.
                $rect = New-Rectangulo -X $x -Y ($y + $avance) -Ancho $grosor -Alto $trozo
            } else {
                # Banda horizontal en la parte de arriba.
                $rect = New-Rectangulo -X ($x + $avance) -Y $y -Ancho $trozo -Alto $grosor
            }
            $avance += $trozo

            if ($rect.Ancho -ge $MinimoLado -and $rect.Alto -ge $MinimoLado) {
                $resultado.Add([pscustomobject]@{
                    Elemento = $fila[$i]
                    X        = $rect.X
                    Y        = $rect.Y
                    Ancho    = $rect.Ancho
                    Alto     = $rect.Alto
                })
            }
        }

        # Se recorta el área libre por donde se ha colocado la banda.
        if ($anchoLibre -ge $altoLibre) {
            $x          += $grosor
            $anchoLibre -= $grosor
        } else {
            $y          += $grosor
            $altoLibre  -= $grosor
        }
    }

    return @($resultado)
}
