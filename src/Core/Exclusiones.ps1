<#
.SYNOPSIS
    Presentación de la lista de exclusiones del usuario.

.DESCRIPTION
    La lista mezcla dos formas de clave:

      - La ruta, cuando el candidato tiene una.
      - "modulo:<Id>|<Nombre>" cuando no la tiene (un comando, la papelera),
        con una barra vertical que Windows no admite en una ruta.

    Las funciones devuelven por separado el texto que se muestra y la clave
    real, que es la que se quita de la lista y la que compara el motor.

    La lógica vive en funciones puras y no en el XAML para poder probarla
    sin WPF.
#>

function Get-ExclusionVista {
    <#
    .SYNOPSIS
        Cómo se presenta una clave de la lista de exclusiones.

    .DESCRIPTION
        Devuelve cuatro campos:

          Clave    la cadena exacta guardada, sin normalizar: es la que se
                   quita de la lista y la que compara el motor.
          Titulo   lo que el usuario lee en grande.
          Detalle  qué clase de exclusión es y hasta dónde llega.
          Tipo     'carpeta', 'modulo' o 'texto'.

        Carpeta: se muestra la ruta completa para distinguir carpetas con
        el mismo nombre.

        Módulo: se muestra el nombre del elemento y el detalle nombra el
        Id del módulo, que distingue elementos homónimos de módulos distintos.

        Texto: ni ruta ni clave del programa (edición manual o -Excluir).
        Test-ClaveExcluida la compara por igualdad exacta, y el detalle lo
        indica.

    .PARAMETER Clave
        Una entrada de RutasExcluidas. Si es nula o está en blanco se
        devuelve $null para que la lista la omita.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Clave
    )

    if ([string]::IsNullOrWhiteSpace($Clave)) { return $null }

    if (Test-EsRutaDeVerdad -Texto $Clave) {
        return [pscustomobject]@{
            Clave   = $Clave
            Titulo  = $Clave
            Detalle = 'Ruta del disco. Si es una carpeta, queda fuera también todo lo que haya dentro.'
            Tipo    = 'carpeta'
        }
    }

    # Formato de Get-ClaveExclusion. El Id no lleva barra vertical; el
    # nombre se queda con el resto, aunque contenga más barras.
    $partes = [regex]::Match($Clave, '^modulo:([^|]*)\|(.*)$')
    if ($partes.Success) {
        $modulo = $partes.Groups[1].Value
        $nombre = $partes.Groups[2].Value

        # Sin nombre se muestra la clave, para que la fila sea visible y se
        # pueda quitar.
        $titulo = if ([string]::IsNullOrWhiteSpace($nombre)) { $Clave } else { $nombre }
        $deQuien = if ([string]::IsNullOrWhiteSpace($modulo)) { '(sin nombre)' } else { $modulo }

        return [pscustomobject]@{
            Clave   = $Clave
            Titulo  = $titulo
            Detalle = ('Elemento del módulo «{0}»: no es una carpeta del disco, así que la exclusión vale solo para él.' -f $deQuien)
            Tipo    = 'modulo'
        }
    }

    return [pscustomobject]@{
        Clave   = $Clave
        Titulo  = $Clave
        Detalle = ('Escrito a mano: ni es una ruta ni tiene la forma de las claves que genera el programa, ' +
                   'así que solo excluye lo que se llame exactamente así.')
        Tipo    = 'texto'
    }
}

function Get-TextoListaExclusiones {
    <#
    .SYNOPSIS
        Texto de la tarjeta que encabeza la lista de exclusiones.

    .DESCRIPTION
        Con la lista vacía indica cómo añadir una exclusión, con el nombre
        exacto de la orden del menú. Los textos dejan claro que quitar una
        exclusión no borra nada, por eso el botón no pide confirmación.
        Cero, uno y varios se tratan por separado para concordar en número.

    .PARAMETER Cuantas
        Número de exclusiones. Un negativo se trata como cero.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Cuantas = 0)

    if ($Cuantas -le 0) {
        return ('Todavía no has excluido nada. Para excluir algo: en Resultados, pulsa con el botón derecho ' +
                'sobre su fila y elige «Excluir siempre esto». Aparecerá aquí, y aquí lo podrás quitar.')
    }

    if ($Cuantas -eq 1) {
        return ('Hay 1 elemento excluido. No se propone en ningún análisis y el motor de borrado lo rechaza ' +
                'aunque llegue a estar marcado. Quitarlo de la lista no borra nada: solo hace que vuelva a proponerse.')
    }

    # Paréntesis alrededor de la concatenación: -f tiene más precedencia que
    # +, y sin ellos el {0} del primer trozo quedaría sin sustituir.
    return (('Hay {0} elementos excluidos. No se proponen en ningún análisis y el motor de borrado los rechaza ' +
             'aunque lleguen a estar marcados. Quitar uno de la lista no borra nada: solo hace que vuelva a proponerse.') -f $Cuantas)
}
