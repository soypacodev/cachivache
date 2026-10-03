<#
.SYNOPSIS
    Vista de archivos: la capa de consulta sobre el índice de disco.

.DESCRIPTION
    Busca, ordena y recorta los archivos del índice (Indice.ps1).

    Es solo informativa: nunca propone borrar. Por eso Get-VistaArchivos
    copia cada fila a un objeto con solo los campos de mostrar; así no
    pueden llegar a la tabla propiedades como Seleccionado, Riesgo o
    Metodo. Hay una invariante que lo comprueba.

    No se usa -like porque interpreta [ y ] como clases de caracteres
    ("foto[1].jpg" no se encontraría). El patrón se traduce a expresión
    regular escapando todo salvo * y ?.
#>

function Get-OrdenesVistaArchivos {
    <#
    .SYNOPSIS
        Los criterios de orden que entiende la vista.
    .DESCRIPTION
        Fuente única de la lista. Los ValidateSet que la repiten (un
        atributo no admite llamadas a función) se comparan contra esta
        función en una invariante.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Tamano', 'Nombre')
}

function Test-CoincideComodin {
    <#
    .SYNOPSIS
        ¿Casa este nombre con este patrón de comodines?

    .DESCRIPTION
        * es "cualquier cosa" y ? es "un carácter cualquiera". Todo lo
        demás es literal, corchetes incluidos. No distingue mayúsculas.

    .PARAMETER Nombre
        Nombre de archivo. Nulo se trata como cadena vacía.
    .PARAMETER Patron
        Patrón de búsqueda. Vacío o solo espacios casa con todo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Nombre,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Patron
    )

    if ([string]::IsNullOrWhiteSpace($Patron)) { return $true }

    # Se recortan espacios: un patrón pegado con un espacio final no
    # encontraría nada, y en Windows los nombres no acaban en espacio.
    $limpio = $Patron.Trim()
    if ($limpio.Length -eq 0) { return $true }

    $constructor = [Text.StringBuilder]::new()
    [void]$constructor.Append('^')

    $asteriscoAnterior = $false
    foreach ($caracter in $limpio.ToCharArray()) {
        if ($caracter -eq [char]'*') {
            # Varios asteriscos seguidos cuentan como uno: cada .* extra
            # multiplica el retroceso del motor cuando el patrón no casa.
            if (-not $asteriscoAnterior) { [void]$constructor.Append('.*') }
            $asteriscoAnterior = $true
            continue
        }
        $asteriscoAnterior = $false

        if ($caracter -eq [char]'?') {
            [void]$constructor.Append('.')
            continue
        }

        # Regex.Escape convierte [, ], (, ., + etc. en literales.
        [void]$constructor.Append([regex]::Escape([string]$caracter))
    }

    [void]$constructor.Append('$')

    $opciones = ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                 [Text.RegularExpressions.RegexOptions]::CultureInvariant)

    # CultureInvariant: con la cultura turca, "I" no es la mayúscula de "i".
    $texto = $Nombre
    if ($null -eq $texto) { $texto = '' }

    return [regex]::IsMatch($texto, $constructor.ToString(), $opciones)
}

function Get-VistaArchivos {
    <#
    .SYNOPSIS
        Consulta sobre el índice: busca, ordena y recorta.

    .DESCRIPTION
        Devuelve filas para mostrar, nunca candidatos.

    .PARAMETER Indice
        Resultado de New-IndiceDisco. Nulo devuelve una lista vacía (la
        vista se pinta antes de que haya análisis).
    .PARAMETER Buscar
        Patrón de nombre con comodines. Vacío no filtra.
    .PARAMETER Cuantos
        Número de filas. Cero o menos no devuelve ninguna.
    .PARAMETER Orden
        Tamano (de mayor a menor) o Nombre (alfabético).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Indice,
        [AllowNull()] [AllowEmptyString()] [string] $Buscar = '',
        [int] $Cuantos = 50,
        [ValidateSet('Tamano', 'Nombre')] [string] $Orden = 'Tamano'
    )

    if ($null -eq $Indice) { return @() }
    if ($Cuantos -le 0) { return @() }

    $crudos = $Indice.Archivos
    if ($null -eq $crudos) { return @() }

    $coincidentes = [Collections.Generic.List[object]]::new()
    foreach ($fila in $crudos) {
        if ($null -eq $fila) { continue }
        if (Test-CoincideComodin -Nombre $fila.Nombre -Patron $Buscar) {
            $coincidentes.Add($fila)
        }
    }
    if ($coincidentes.Count -eq 0) { return @() }

    if ($Orden -eq 'Nombre') {
        # Desempate por tamaño para que el orden sea estable entre consultas.
        $ordenados = @($coincidentes |
            Sort-Object -Property @{ Expression = { [string]$_.Nombre } },
                                  @{ Expression = { [double]$_.Bytes }; Descending = $true })
    } else {
        # Por bytes numéricos, nunca por el texto formateado ("9,52 GB" <
        # "980 MB" alfabéticamente).
        $ordenados = @($coincidentes |
            Sort-Object -Property @{ Expression = { [double]$_.Bytes }; Descending = $true },
                                  @{ Expression = { [string]$_.Ruta } })
    }

    $recortados = @($ordenados | Select-Object -First $Cuantos)

    # Copia con solo los campos de mostrar (ver la cabecera).
    $salida = [Collections.Generic.List[object]]::new()
    foreach ($fila in $recortados) {
        $salida.Add([pscustomobject]@{
            Ruta      = [string]$fila.Ruta
            Nombre    = [string]$fila.Nombre
            Carpeta   = [string]$fila.Carpeta
            Extension = [string]$fila.Extension
            Bytes     = [double]$fila.Bytes
            Ultimo    = $fila.Ultimo
        })
    }

    return @($salida)
}

function Get-ResumenVistaArchivos {
    <#
    .SYNOPSIS
        Texto que describe lo que muestra la vista de archivos.

    .DESCRIPTION
        Distingue situaciones que en pantalla parecen iguales:

          (a) Ningún archivo supera el umbral; el análisis fue bien.
          (b) Hay archivos, pero ninguno coincide con la búsqueda.
          (c) Hay más coincidencias de las que se muestran.

        Cero, uno y varios se redactan por separado.

    .PARAMETER Indice
        Resultado de New-IndiceDisco. Nulo se trata como vacío.
    .PARAMETER Buscar
        El mismo patrón pasado a Get-VistaArchivos.
    .PARAMETER Cuantos
        El mismo número de filas pedido a Get-VistaArchivos.
    .PARAMETER Orden
        El mismo orden; decide si se puede hablar de "los mayores".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Indice,
        [AllowNull()] [AllowEmptyString()] [string] $Buscar = '',
        [int] $Cuantos = 50,
        [ValidateSet('Tamano', 'Nombre')] [string] $Orden = 'Tamano'
    )

    $crudos = $null
    if ($null -ne $Indice) { $crudos = $Indice.Archivos }

    $total = 0
    $coinciden = 0
    foreach ($fila in @($crudos)) {
        if ($null -eq $fila) { continue }
        $total++
        if (Test-CoincideComodin -Nombre $fila.Nombre -Patron $Buscar) { $coinciden++ }
    }

    # Umbral final del índice, que puede superar el pedido si se alcanzó
    # el tope de archivos.
    $umbral = 0.0
    if ($null -ne $Indice -and $null -ne $Indice.UmbralArchivo) {
        $umbral = [double]$Indice.UmbralArchivo
    }

    # --- (a) No hay nada por encima del umbral -----------------------
    if ($total -eq 0) {
        if ($umbral -gt 0) {
            return ('Ningún archivo llega a {0}: aquí el espacio está repartido en muchos archivos pequeños. ' +
                    'El análisis ha ido bien.') -f (Format-Tamano $umbral)
        }
        return 'Todavía no hay ningún archivo que enseñar: no se ha analizado nada.'
    }

    $desdeUmbral = ''
    if ($umbral -gt 0) { $desdeUmbral = ' de más de {0}' -f (Format-Tamano $umbral) }

    # --- (b) Hay archivos, pero ninguno casa con la búsqueda ---------
    if ($coinciden -eq 0) {
        if ($total -eq 1) {
            return ('El único archivo{0} que hay no coincide con «{1}». Prueba con * al principio, ' +
                    'como en *{1}*.') -f $desdeUmbral, $Buscar
        }
        return ('Ninguno de los {0} archivos{1} coincide con «{2}». Prueba con * al principio, ' +
                'como en *{2}*.') -f $total, $desdeUmbral, $Buscar
    }

    # Cero o menos es ninguna fila, igual que en Get-VistaArchivos.
    $mostrados = $coinciden
    if ($Cuantos -le 0) { $mostrados = 0 }
    if ($Cuantos -gt 0 -and $Cuantos -lt $coinciden) { $mostrados = $Cuantos }

    $mayores = 'mayores'
    if ($Orden -eq 'Nombre') { $mayores = 'primeros por orden alfabético' }

    # --- (c) Hay más de los que se muestran ---------------------------
    if ($mostrados -lt $coinciden) {
        $restantes = $coinciden - $mostrados
        if ($mostrados -le 0) {
            if ($coinciden -eq 1) {
                return ('Hay 1 archivo{0} que coincide, pero no se está mostrando.' -f $desdeUmbral)
            }
            return ('Hay {0} archivos{1} que coinciden, pero no se está mostrando ninguno.' -f
                    $coinciden, $desdeUmbral)
        }
        $cola = 'y quedan {0} más sin mostrar' -f $restantes
        if ($restantes -eq 1) { $cola = 'y queda 1 más sin mostrar' }
        if ($mostrados -eq 1) {
            $elMayor = 'el mayor'
            if ($Orden -eq 'Nombre') { $elMayor = 'el primero por orden alfabético' }
            return ('Se muestra {0} de {1} archivos{2} que coinciden, {3}. Es un informe: ' +
                    'no se propone borrar nada.') -f $elMayor, $coinciden, $desdeUmbral, $cola
        }
        return ('Se muestran los {0} {1} de {2} archivos{3} que coinciden, {4}. Es un informe: ' +
                'no se propone borrar nada.') -f $mostrados, $mayores, $coinciden, $desdeUmbral, $cola
    }

    # --- Caso normal: se muestra todo lo que hay ---------------------
    if ($coinciden -eq 1) {
        return ('Se muestra el único archivo{0} que hay. Es un informe: no se propone borrar nada.' -f
                $desdeUmbral)
    }
    return ('Se muestran los {0} archivos{1} que hay, todos. Es un informe: no se propone borrar nada.' -f
            $coinciden, $desdeUmbral)
}
