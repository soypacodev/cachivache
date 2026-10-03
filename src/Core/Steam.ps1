<#
.SYNOPSIS
    Lectura de los metadatos que Steam deja en disco.

.DESCRIPTION
    Solo lectura, como Registry.ps1: nunca se escribe en la configuración
    de Steam.

    Vive en el núcleo y no en 33-Juegos.ps1 porque los módulos se cargan
    con dot-sourcing dentro de Get-ModulosLimpieza: las funciones
    declaradas en un módulo desaparecen al terminar esa función.
#>

function Get-ValorVdf {
    <#
    .SYNOPSIS
        Extrae los valores de una clave de un archivo VDF de Valve.
    .DESCRIPTION
        El formato VDF es "clave" "valor", una pareja por línea, con
        bloques anidados entre llaves. Basta una expresión regular para
        leer claves sueltas como "path" o "installdir".

        Las barras invertidas vienen escapadas ("D:\\Juegos") y se
        desescapan al leerlas.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [Parameter(Mandatory)] [string] $Clave
    )

    if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) { return @() }
    try   { $texto = [IO.File]::ReadAllText($Ruta) }
    catch { return @() }

    $patron = '"' + [regex]::Escape($Clave) + '"\s+"([^"]*)"'
    return @([regex]::Matches($texto, $patron, 'IgnoreCase') |
             ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } |
             Where-Object { $_ })
}

function Get-BibliotecasSteam {
    <#
    .SYNOPSIS
        Carpetas "steamapps" de todas las bibliotecas de Steam del equipo.
    .DESCRIPTION
        Incluye la carpeta de instalación y las bibliotecas declaradas en
        libraryfolders.vdf. Solo devuelve carpetas que existen: una
        biblioteca en un disco desconectado sigue figurando en el archivo.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $raices = [Collections.Generic.List[string]]::new()

    # 1. Dónde está instalado Steam.
    $instalacion = $null
    $clave = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Valve\Steam' -ErrorAction SilentlyContinue
    if ($clave -and $clave.SteamPath) { $instalacion = $clave.SteamPath -replace '/', '\' }

    if ([string]::IsNullOrWhiteSpace($instalacion)) {
        foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if ([string]::IsNullOrWhiteSpace($base)) { continue }
            $candidata = Join-RutaNativa $base 'Steam'
            if (Test-Path -LiteralPath $candidata) { $instalacion = $candidata; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($instalacion)) { return @() }

    $principal = Join-RutaNativa $instalacion 'steamapps'
    if (Test-Path -LiteralPath $principal) { $raices.Add($principal) }

    # 2. Bibliotecas declaradas en el VDF, en sus dos ubicaciones históricas.
    foreach ($vdf in @((Join-RutaNativa $instalacion 'steamapps' 'libraryfolders.vdf'),
                       (Join-RutaNativa $instalacion 'config' 'libraryfolders.vdf'))) {
        foreach ($ruta in (Get-ValorVdf -Ruta $vdf -Clave 'path')) {
            $steamapps = Join-RutaNativa $ruta 'steamapps'
            if ((Test-Path -LiteralPath $steamapps) -and ($raices -notcontains $steamapps)) {
                $raices.Add($steamapps)
            }
        }
    }

    return @($raices)
}
