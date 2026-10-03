<#
.SYNOPSIS
    Montaje del XAML de la ventana a partir de sus trozos.

.DESCRIPTION
    Está separado de Window.ps1 porque no depende de WPF (es manejo de texto
    puro): así las pruebas pueden cargarlo en cualquier sistema sin cargar
    los ensamblados de WPF, que solo existen en Windows.
#>

function Expand-PanelesXaml {
    <#
    .SYNOPSIS
        Sustituye cada marca "<!--#panel Archivo.xaml-->" por el contenido de ese archivo.

    .DESCRIPTION
        MainWindow.xaml contiene el armazón (ventana, barra de título, panel
        lateral) y cada panel vive en su Panel.*.xaml.

        Los paneles se pegan como texto antes de interpretar el XAML, en vez
        de cargarse por separado, porque FindName solo busca dentro del
        ámbito de nombres del árbol donde se declaró el nombre: con árboles
        separados, $ventana.FindName('BtnAnalizar') devolvería $null. Así WPF
        interpreta un único documento con un único ámbito de nombres.

        La cabecera de comentario de cada Panel.*.xaml se descarta al pegar.

    .OUTPUTS
        [string] El XAML completo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Texto,
        [Parameter(Mandatory)] [string] $Carpeta
    )

    $resultado = $Texto
    foreach ($marca in [regex]::Matches($Texto, '(?m)^[ \t]*<!--#panel\s+([^\s>]+?)\s*-->[ \t]*\r?\n?')) {
        $archivo = $marca.Groups[1].Value
        $ruta = Join-Path $Carpeta $archivo
        if (-not (Test-Path -LiteralPath $ruta)) {
            throw "MainWindow.xaml pide el panel '$archivo' y no está en $Carpeta."
        }
        $trozo = [IO.File]::ReadAllText($ruta)
        # Se quita la cabecera de comentario y el resto se pega sin recortar
        # ni añadir saltos: la prueba de montaje exige igualdad exacta.
        $trozo = [regex]::Replace($trozo, '(?s)\A\s*<!--.*?-->\s*\r?\n', '')
        $resultado = $resultado.Replace($marca.Value, $trozo)
    }
    return $resultado
}
