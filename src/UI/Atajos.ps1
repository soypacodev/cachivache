<#
.SYNOPSIS
    Qué acción corresponde a cada combinación de teclas de la ventana. Cálculo puro.

.DESCRIPTION
    Está separado de Window.Eventos.ps1 porque no depende de WPF: recibe la
    tecla, si Control estaba pulsado y si el foco está en un cuadro de texto,
    y devuelve el nombre de una acción o nada. Así las pruebas pueden
    recorrer todas las combinaciones sin interfaz gráfica.

    Aquí se decide y quien llama ejecuta, levantando el evento Click del
    botón correspondiente en vez de repetir lo que hace su manejador.
#>

# Los seis paneles, en el orden en que se ven en la barra lateral: Ctrl+1 es
# la primera entrada y Ctrl+6 la última. Si se reordena la barra lateral hay
# que reordenar esta lista (una invariante compara ambas).
$script:NavegacionPorNumero = @(
    'NavInicio'      # Ctrl+1
    'NavResultados'  # Ctrl+2
    'NavRegistro'    # Ctrl+3
    'NavInformes'    # Ctrl+4
    'NavAjustes'     # Ctrl+5
    'NavAcerca'      # Ctrl+6
)

function Get-NavegacionPorNumero {
    <#
    .SYNOPSIS
        Los nombres de las seis entradas de la barra lateral, en su orden.

    .DESCRIPTION
        Se expone como función para que la ventana y las pruebas la obtengan
        de la misma forma.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:NavegacionPorNumero
}

function Get-AtajoDeTecla {
    <#
    .SYNOPSIS
        Qué acción corresponde a una tecla, o nada si esa tecla no es atajo.

    .PARAMETER Tecla
        El nombre de la tecla tal y como lo da WPF: 'F5', 'Escape', 'A',
        'D1'..'D6' para los números de la fila superior y 'NumPad1'..'NumPad6'
        para los del teclado numérico (ambos se tratan igual).

    .PARAMETER Control
        Si estaba pulsado Control.

    .PARAMETER EnCuadroDeTexto
        Si el foco está dentro de un cuadro de texto. Solo afecta a Ctrl+A,
        que dentro de un cuadro de texto (como el registro de la sesión)
        conserva su significado de "seleccionar todo".

    .OUTPUTS
        El nombre de la acción, o $null si la tecla no es ningún atajo (el
        caso normal: por aquí pasa cada tecla pulsada en la ventana).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Una tecla sin nombre no es un error, sino una tecla que no es
        # atajo: sin AllowNull, Mandatory lanzaría dentro del manejador de
        # teclado.
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Tecla,
        [switch] $Control,
        [switch] $EnCuadroDeTexto
    )

    if ([string]::IsNullOrWhiteSpace($Tecla)) { return $null }

    if (-not $Control) {
        # F5 y Escape no chocan con la edición de texto: valen escribiendo.
        switch ($Tecla) {
            'F5'     { return 'Analizar' }
            'Escape' { return 'Cancelar' }
        }
        return $null
    }

    switch ($Tecla) {
        'F' { return 'Filtrar' }
        'A' {
            # Dentro de un cuadro de texto, Ctrl+A selecciona el texto.
            if ($EnCuadroDeTexto) { return $null }
            return 'MarcarTodo'
        }
    }

    # Ctrl+1..6, con los numeros de arriba o los del teclado numerico.
    $m = [regex]::Match($Tecla, '^(?:D|NumPad)([1-6])$')
    if ($m.Success) {
        return $script:NavegacionPorNumero[[int]$m.Groups[1].Value - 1]
    }

    return $null
}
