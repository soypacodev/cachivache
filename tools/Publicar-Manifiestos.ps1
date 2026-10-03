<#
.SYNOPSIS
    Escribe los manifiestos de winget y de Scoop de una versión, con el
    hash del paquete recién generado.

.DESCRIPTION
    Lo ejecuta .github/workflows/publicar.yml tras calcular las sumas y
    antes de adjuntar nada, para declarar exactamente los bytes publicados.

    El hash no se acepta como parámetro: se calcula del archivo real, para
    que no pueda colarse el de una versión anterior.

    También se comprueba que el nombre del .zip coincide con
    Get-NombrePaqueteZip; si no, las URL de los manifiestos darían 404 y se
    detiene la publicación.

.PARAMETER Etiqueta
    La etiqueta de git de esta versión, con la v: v2.1.0.

.PARAMETER Paquete
    El .zip que se va a adjuntar a la versión.

.PARAMETER Destino
    Carpeta donde escribir los manifiestos. Por defecto packaging/.

.EXAMPLE
    ./tools/Publicar-Manifiestos.ps1 -Etiqueta v2.1.0 -Paquete Cachivache-v2.1.0.zip
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $Etiqueta,

    [Parameter(Mandatory)]
    [string] $Paquete,

    [string] $Destino = 'packaging'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Manifiestos.ps1')

if (-not (Test-Path -LiteralPath $Paquete -PathType Leaf)) {
    throw "No esta el paquete del que hay que declarar el hash: $Paquete"
}

$nombre   = Split-Path -Leaf $Paquete
$esperado = Get-NombrePaqueteZip -Etiqueta $Etiqueta
if ($nombre -cne $esperado) {
    throw ("El paquete se llama '$nombre' y los manifiestos van a declarar '$esperado'. " +
           'Uno de los dos esta mal, y publicarlo asi deja dos URL que devuelven 404.')
}

$hash = (Get-FileHash -LiteralPath $Paquete -Algorithm SHA256).Hash
if (-not (Test-SumaSha256Valida -Suma $hash)) {
    throw "El hash de $Paquete no tiene forma de SHA-256: '$hash'"
}

$identidad   = Get-IdentidadPaquete
$carpetaWinget = Join-Path $Destino 'winget'

$archivos = @(
    @{
        Ruta  = (Join-Path $carpetaWinget ('{0}.yaml' -f $identidad.IdentificadorWinget))
        Texto = (Format-ManifiestoWingetVersion -Etiqueta $Etiqueta)
    }
    @{
        Ruta  = (Join-Path $carpetaWinget ('{0}.installer.yaml' -f $identidad.IdentificadorWinget))
        Texto = (Format-ManifiestoWingetInstalador -Etiqueta $Etiqueta -Hash $hash)
    }
    @{
        Ruta  = (Join-Path $carpetaWinget ('{0}.locale.{1}.yaml' -f $identidad.IdentificadorWinget, $identidad.Idioma))
        Texto = (Format-ManifiestoWingetLocale -Etiqueta $Etiqueta)
    }
    @{
        Ruta  = (Join-Path $Destino ('{0}.json' -f $identidad.IdentificadorScoop))
        Texto = (Format-ManifiestoScoop -Etiqueta $Etiqueta -Hash $hash)
    }
)

if ($PSCmdlet.ShouldProcess($Destino, 'Escribir los manifiestos de winget y de Scoop')) {
    foreach ($carpeta in @($Destino, $carpetaWinget)) {
        if (-not (Test-Path -LiteralPath $carpeta -PathType Container)) {
            New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        }
    }

    foreach ($archivo in $archivos) {
        # Sin BOM a propósito (a diferencia de los .ps1): los validadores de
        # winget-pkgs rechazan YAML con BOM y ConvertFrom-Json de PowerShell
        # 5.1 lo lee mal. WriteAllText en vez de Out-File para conservar LF.
        [IO.File]::WriteAllText($archivo.Ruta, $archivo.Texto, [Text.UTF8Encoding]::new($false))
        Write-Host ("  escrito  {0}" -f $archivo.Ruta)
    }
}

Write-Host ''
Write-Host ('Manifiestos de {0} listos, declarando el SHA-256 de {1}:' -f $Etiqueta, $nombre) -ForegroundColor Cyan
Write-Host ('  {0}' -f $hash.ToLowerInvariant())
Write-Host ''
