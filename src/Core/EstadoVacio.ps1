<#
.SYNOPSIS
    Mensaje que se muestra cuando la tabla de resultados no tiene filas
    visibles.

.DESCRIPTION
    Distingue situaciones que, sin mensaje, se ven igual: programa recién
    abierto, análisis en marcha, análisis sin resultados y resultados
    escondidos por un filtro o por "Ocultar lo ya eliminado". Este último
    caso es el importante: una tabla en blanco tras filtrar parece un
    análisis fallido.

    La decisión está en funciones puras y no en un DataTrigger del XAML (ver
    la cabecera de grupo de Panel.Resultados.xaml): los Style con
    DataTrigger se comportaron de forma incoherente en Windows y esto se
    puede probar sin WPF. La ventana solo asigna el texto resultante.
#>

function Get-RiesgoDelFiltro {
    <#
    .SYNOPSIS
        Nivel de riesgo correspondiente a cada posición del desplegable.

    .DESCRIPTION
        Fuente única para que el filtro y el mensaje de tabla vacía no
        discrepen sobre si hay un filtro de riesgo puesto.

        El índice es la posición del ComboBox de Panel.Resultados.xaml:
        0 "Todos los riesgos", 1 bajo, 2 medio, 3 alto. Cualquier otro valor
        (incluido -1, sin selección) equivale a "todos".

    .PARAMETER Indice
        SelectedIndex del desplegable de riesgo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Indice = 0)

    switch ($Indice) {
        1 { return 'Bajo' }
        2 { return 'Medio' }
        3 { return 'Alto' }
        default { return '' }
    }
}

function Test-HayFiltroPuesto {
    <#
    .SYNOPSIS
        Indica si hay algún filtro de búsqueda que pueda esconder filas.

    .DESCRIPTION
        Usa la misma regla que el predicado de la vista (IsNullOrWhiteSpace):
        si discreparan, el mensaje ofrecería quitar un filtro inexistente y
        el botón no haría nada.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $TextoFiltro,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $RiesgoFiltro
    )

    if (-not [string]::IsNullOrWhiteSpace($TextoFiltro))  { return $true }
    if (-not [string]::IsNullOrWhiteSpace($RiesgoFiltro)) { return $true }
    return $false
}

function Get-TextoQuitarFiltros {
    <#
    .SYNOPSIS
        Rótulo del botón que quita los filtros.

    .DESCRIPTION
        El botón quita siempre los dos filtros (texto y riesgo), porque
        quitar solo uno podría dejar la tabla igual de vacía. El rótulo
        indica cuáles se van a quitar para que no sorprenda; si solo hay
        uno puesto, nombra ese.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $TextoFiltro,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $RiesgoFiltro
    )

    $hayTexto  = -not [string]::IsNullOrWhiteSpace($TextoFiltro)
    $hayRiesgo = -not [string]::IsNullOrWhiteSpace($RiesgoFiltro)

    if ($hayTexto -and $hayRiesgo) { return 'Quitar los dos filtros' }
    if ($hayTexto)                 { return 'Quitar el filtro de texto' }
    if ($hayRiesgo)                { return 'Quitar el filtro de riesgo' }
    return 'Quitar los filtros'
}

function Get-EstadoVacio {
    <#
    .SYNOPSIS
        Decide qué mensaje mostrar con la tabla vacía y qué botón ofrecer.

    .DESCRIPTION
        Devuelve un objeto con seis campos:

          Vacio                si hay que mostrar el mensaje
          Caso                 identificador de la situación (para pruebas)
          Texto                texto para el usuario
          OfrecerQuitarFiltro  si procede el botón que quita los filtros
          OfrecerMostrarHechos si procede el que muestra lo ya eliminado
          TextoBoton           rótulo del botón que corresponda

        Los dos botones nunca se ofrecen a la vez, por eso comparten
        TextoBoton.

        El orden de las comprobaciones importa: primero si hay filas
        visibles, después si la colección completa tiene elementos y solo
        al final la fase. Preguntar antes por la fase haría que un análisis
        en marcha con filas filtradas dijera "la lista se irá llenando".

        Con elementos pero nada visible, la casilla "Ocultar lo ya eliminado"
        se comprueba antes que el filtro: el filtro está a la vista y la
        casilla puede llevar tiempo marcada; además el botón de filtros no
        destapa lo eliminado. Si están las dos cosas, el texto nombra ambas.

        Si hay elementos, nada visible y ningún filtro ni casilla, se informa
        sin ofrecer un botón que no arreglaría nada (no debería ocurrir).

    .PARAMETER Fase
        'terminado' si ya acabó un análisis en esta sesión, 'analizando'
        mientras corre; cualquier otro valor significa que aún no se ha
        analizado (el caso prudente).
    .PARAMETER Total
        Elementos en la colección completa, estén filtrados o no.
    .PARAMETER HayVisibles
        Si la vista muestra al menos una fila. Es booleano porque la ventana
        usa ICollectionView.IsEmpty, que no recorre la colección.
    .PARAMETER TextoFiltro
        Texto del cuadro de filtro. Puede ser nulo.
    .PARAMETER RiesgoFiltro
        Nivel elegido en el desplegable; vacío si son todos.
    .PARAMETER OcultandoHechos
        Si está marcada la casilla "Ocultar lo ya eliminado". No forma parte
        de Test-HayFiltroPuesto porque el botón de quitar filtros no la
        desmarca. Por defecto $false.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Fase,
        [Parameter(Mandatory)] [AllowNull()] [int] $Total,
        [Parameter(Mandatory)] [AllowNull()] [bool] $HayVisibles,
        [AllowNull()] [AllowEmptyString()] [string] $TextoFiltro  = '',
        [AllowNull()] [AllowEmptyString()] [string] $RiesgoFiltro = '',
        [AllowNull()] [bool] $OcultandoHechos = $false
    )

    if ($Total -lt 0) { $Total = 0 }

    if ($HayVisibles) {
        return [pscustomobject]@{
            Vacio                = $false
            Caso                 = 'con-datos'
            Texto                = ''
            OfrecerQuitarFiltro  = $false
            OfrecerMostrarHechos = $false
            TextoBoton           = ''
        }
    }

    if ($Total -gt 0) {
        $cuantos   = if ($Total -eq 1) { '1 elemento' } else { '{0} elementos' -f $Total }
        $hayFiltro = Test-HayFiltroPuesto -TextoFiltro $TextoFiltro -RiesgoFiltro $RiesgoFiltro

        # La casilla se comprueba antes que el filtro (ver la ayuda).
        if ($OcultandoHechos) {
            $texto = if ($hayFiltro) {
                ('El análisis encontró {0} y ahora mismo no se ve ninguno: tienes puesto el filtro ' +
                 'y además la casilla "Ocultar lo ya eliminado". La lista no está vacía: está escondida.') -f $cuantos
            } else {
                ('El análisis encontró {0}, y la casilla "Ocultar lo ya eliminado" los está escondiendo ' +
                 'porque ya se eliminaron. La lista no está vacía: está escondida.') -f $cuantos
            }
            return [pscustomobject]@{
                Vacio                = $true
                Caso                 = 'ocultando-hechos'
                Texto                = $texto
                OfrecerQuitarFiltro  = $false
                OfrecerMostrarHechos = $true
                # Describe la acción, sin prometer que la tabla se llene.
                TextoBoton           = 'Mostrar lo ya eliminado'
            }
        }

        if ($hayFiltro) {
            # Los paréntesis antes de -f son necesarios: -f tiene más
            # precedencia que +, y sin ellos solo se formatearía el último
            # fragmento.
            $texto = ('El análisis encontró {0}, pero el filtro que tienes puesto no deja pasar ninguno. ' +
                      'La lista no está vacía: está filtrada.') -f $cuantos
            return [pscustomobject]@{
                Vacio                = $true
                Caso                 = 'filtrado'
                Texto                = $texto
                OfrecerQuitarFiltro  = $true
                OfrecerMostrarHechos = $false
                TextoBoton           = (Get-TextoQuitarFiltros -TextoFiltro $TextoFiltro -RiesgoFiltro $RiesgoFiltro)
            }
        }

        return [pscustomobject]@{
            Vacio                = $true
            Caso                 = 'oculto'
            Texto                = ('Ninguno de los {0} que encontró el análisis se está viendo en la tabla.' -f $cuantos)
            OfrecerQuitarFiltro  = $false
            OfrecerMostrarHechos = $false
            TextoBoton           = ''
        }
    }

    if ($Fase -eq 'analizando') {
        return [pscustomobject]@{
            Vacio                = $true
            Caso                 = 'analizando'
            Texto                = 'Analizando: la lista se irá llenando sola. Todavía no ha aparecido nada.'
            OfrecerQuitarFiltro  = $false
            OfrecerMostrarHechos = $false
            TextoBoton           = ''
        }
    }

    if ($Fase -ne 'terminado') {
        return [pscustomobject]@{
            Vacio                = $true
            Caso                 = 'sin-analizar'
            Texto                = 'Todavía no se ha analizado nada. Ve a Inicio, pulsa "Analizar el equipo" y lo que se encuentre aparecerá aquí.'
            OfrecerQuitarFiltro  = $false
            OfrecerMostrarHechos = $false
            TextoBoton           = ''
        }
    }

    # Análisis terminado sin resultados: no es un fallo. El texto aclara que
    # depende de los módulos y ajustes usados en este análisis.
    return [pscustomobject]@{
        Vacio                = $true
        Caso                 = 'sin-resultados'
        Texto                = ('El análisis ha terminado y no ha encontrado nada que borrar. ' +
                                'No es un fallo, es una buena noticia: no hay basura que limpiar ' +
                                'con los módulos y los ajustes que has usado.')
        OfrecerQuitarFiltro  = $false
        OfrecerMostrarHechos = $false
        TextoBoton           = ''
    }
}
