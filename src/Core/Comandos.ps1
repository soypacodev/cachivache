<#
.SYNOPSIS
    Qué programas externos puede lanzar el programa y desde dónde.

.DESCRIPTION
    Decisión de seguridad: dado un nombre, qué ejecutable se lanzaría (o
    ninguno). Este archivo no lanza nada; solo resuelve rutas. Ver
    SECURITY.md.

    Hay dos vías, a propósito:

      Resolve-EjecutablePermitido   motor de borrado. Lista blanca cerrada;
                                    es lo único que Remove.ps1 puede lanzar
                                    con el método 'Comando'.

      Resolve-EjecutableDeSistema   consultas de solo lectura durante el
                                    análisis. Sin lista de nombres, pero
                                    anclado a System32.

    Ninguna consulta el PATH: puede contener carpetas escribibles por el
    usuario (p. ej. %LOCALAPPDATA%\Microsoft\WindowsApps), donde un
    ejecutable suplantado se lanzaría en lugar del legítimo.
#>

# Lista blanca del método 'Comando', por nombre base (sin ruta ni
# extensión). Candidato.Comando es solo texto para mostrar: se ejecuta
# Ejecutable + Argumentos por separado, sin intérprete de shell.
#
# No añadir herramientas que se resuelvan a .cmd/.bat (como npm): un .cmd
# se ejecuta siempre a través de cmd.exe y reintroduciría el intérprete.
#
# Lo que abre la ventana a petición del usuario (Explorador, informes,
# navegador) sigue sus propias reglas; ver SECURITY.md.
$script:EjecutablesPermitidos = @('dism', 'docker')

# Ubicaciones de instalación de Docker Desktop, en orden de preferencia.
# Ninguna es escribible por un usuario sin privilegios.
$script:RutasDocker = @(
    'Docker\Docker\resources\bin\docker.exe'
    'Docker\Docker\resources\docker.exe'
    'Docker\docker.exe'
)

function Resolve-EjecutablePermitido {
    <#
    .SYNOPSIS
        Resuelve un nombre de ejecutable a su ruta absoluta si está en la
        lista blanca del método 'Comando', o $null si no.
    .DESCRIPTION
        Compara por nombre base y descarta la ruta recibida: la ruta
        devuelta siempre la decide esta función. DISM se resuelve bajo
        System32 y Docker bajo Archivos de programa; nunca por PATH.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Ejecutable)

    if ([string]::IsNullOrWhiteSpace($Ejecutable)) { return $null }
    # Fuera de Windows, GetFileNameWithoutExtension no trata '\' como
    # separador: se normaliza a '/' para que funcione en cualquier sistema.
    $normalizado = $Ejecutable.Trim().Replace('\', '/')
    $nombre = [IO.Path]::GetFileNameWithoutExtension($normalizado).ToLowerInvariant()
    if ($script:EjecutablesPermitidos -notcontains $nombre) { return $null }

    switch ($nombre) {
        'dism' {
            return (Resolve-EjecutableDeSistema -Nombre 'Dism.exe')
        }
        'docker' {
            # Anclado a Archivos de programa (no escribible sin privilegios).
            foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
                if ([string]::IsNullOrWhiteSpace($base)) { continue }
                foreach ($relativa in $script:RutasDocker) {
                    # Concatenación y no Join-Path, que falla si la unidad
                    # no existe en el proceso (p. ej. en Linux).
                    $ruta = $base.TrimEnd('\') + '\' + $relativa
                    if (Test-Path -LiteralPath $ruta -PathType Leaf) { return $ruta }
                }
            }
            return $null
        }
    }
    return $null
}

function Get-RutaExplorador {
    <#
    .SYNOPSIS
        Ruta absoluta del Explorador de Windows.
    .DESCRIPTION
        Un nombre suelto se busca antes en la carpeta del programa y en el
        directorio actual (p. ej. Descargas), donde podría haber un
        explorer.exe ajeno. Vive en la raíz de Windows, no en System32,
        por eso no sirve Resolve-EjecutableDeSistema.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $null }
    $ruta = Join-Path $env:SystemRoot 'explorer.exe'
    if (Test-Path -LiteralPath $ruta -PathType Leaf) { return $ruta }
    return $null
}

function Get-RutaPowerShell {
    <#
    .SYNOPSIS
        Ruta absoluta de Windows PowerShell 5.1.
    .DESCRIPTION
        Mismo motivo que Get-RutaExplorador, con más peso: es lo que se
        lanza al reiniciar como administrador. Un powershell.exe ajeno
        resuelto por orden de búsqueda sería una escalada de privilegios.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $null }
    $ruta = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ruta -PathType Leaf) { return $ruta }
    return $null
}

function Resolve-EjecutableDeSistema {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de una herramienta de Windows bajo
        System32, o $null si no está.

    .DESCRIPTION
        Evita invocar herramientas externas por nombre suelto, que se
        resolverían por PATH (ver la cabecera del archivo); es crítico en
        las ramas que se ejecutan como administrador.

        No necesita lista blanca: anclada a System32, solo puede devolver
        lo que Windows tiene instalado. La lista blanca del motor de
        borrado es independiente.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Nombre)

    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $null }
    # Solo un nombre de archivo: nada de rutas ni de subir por el árbol.
    if ($Nombre -match '[\\/:]' -or $Nombre.Contains('..')) { return $null }

    $ruta = Join-Path (Join-Path $env:SystemRoot 'System32') $Nombre
    if (Test-Path -LiteralPath $ruta -PathType Leaf) { return $ruta }
    return $null
}
