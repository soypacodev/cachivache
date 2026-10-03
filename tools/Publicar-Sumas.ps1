<#
.SYNOPSIS
    Calcula las sumas SHA-256 de los archivos de una versión y escribe
    SHA256SUMS.txt.

.DESCRIPTION
    Lo ejecuta .github/workflows/publicar.yml después de generar el paquete
    y antes de adjuntarlo, para medir exactamente los bytes que se suben.

    Las sumas corresponden a los archivos adjuntos a la versión, no a los
    artefactos de la CI: actions/upload-artifact los envuelve en otro zip y
    su suma no coincide.

.PARAMETER Archivos
    Los archivos que se van a publicar.

.PARAMETER Destino
    Dónde escribir el archivo de sumas. Por defecto, SHA256SUMS.txt en la
    carpeta actual.

.EXAMPLE
    ./tools/Publicar-Sumas.ps1 -Archivos Cachivache-v2.1.0.zip, Cachivache.exe
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]] $Archivos,

    [string] $Destino = 'SHA256SUMS.txt'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sumas.ps1')

$entradas = foreach ($ruta in $Archivos) {
    if (-not (Test-Path -LiteralPath $ruta -PathType Leaf)) {
        throw "No esta el archivo que hay que firmar: $ruta"
    }

    $hash = (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash

    # Una suma errónea es peor que ninguna: se detiene la publicación.
    if (-not (Test-SumaSha256Valida -Suma $hash)) {
        throw "El hash de $ruta no tiene forma de SHA-256: '$hash'"
    }

    @{ Nombre = (Split-Path -Leaf $ruta); Hash = $hash }
}

$contenido = Format-SumasSha256 -Entradas @($entradas)

if ($PSCmdlet.ShouldProcess($Destino, 'Escribir las sumas SHA-256')) {
    # Sin BOM a propósito: con BOM, sha256sum -c no valida la primera línea
    # (ver Sumas.ps1). WriteAllText y no Out-File, que convertiría a CRLF y
    # el \r acabaría en el nombre del archivo.
    [IO.File]::WriteAllText($Destino, $contenido, [Text.UTF8Encoding]::new($false))
}

Write-Host ''
Write-Host 'SHA-256 de esta version:' -ForegroundColor Cyan
Write-Host ($contenido.TrimEnd())
Write-Host ''

# La tabla se devuelve para incluirla en el cuerpo de la versión, un lugar
# distinto de los adjuntos: alterar paquete y sumas a la vez no basta.
return (Format-TablaSumas -Entradas @($entradas))
