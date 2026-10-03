<#
.SYNOPSIS
    Los manifiestos de winget y de Scoop de una versión. Cálculo puro, sin
    tocar el disco.

.DESCRIPTION
    Separado de Publicar-Manifiestos.ps1 (que escribe archivos) para poder
    cargarlo y probarlo sin efectos.

    Los manifiestos se generan a partir del paquete real porque cuatro
    datos cambian con cada versión y quedarían obsoletos sin avisar: la
    versión (sin la v), la URL de descarga, la carpeta dentro del zip
    (Compress-Archive anida el contenido en Cachivache-vX.Y.Z) y el hash.
    Un hash desfasado solo falla al instalar, con aspecto de paquete
    adulterado.

    Mayúsculas del hash (ver también Sumas.ps1):
      - winget: en mayúsculas, como lo escribe wingetcreate, para que un
        manifiesto regenerado solo difiera si cambia el paquete.
      - Scoop: en minúsculas, igual que SHA256SUMS.txt, del que el
        autoupdate toma el hash.
#>

# Test-SumaSha256Valida. Se carga aquí para que este archivo funcione por
# sí solo.
. (Join-Path $PSScriptRoot 'Sumas.ps1')

function Get-IdentidadPaquete {
    <#
    .SYNOPSIS
        Los datos del paquete que no dependen de la versión.

    .DESCRIPTION
        Fuente única de repositorio, identificadores y licencia para los
        tres YAML de winget y el JSON de Scoop.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        # winget exige Editor.Paquete; se usa el nombre del autor, que es lo
        # que muestra winget al instalar.
        IdentificadorWinget = 'FranciscoLopez.Cachivache'
        IdentificadorScoop  = 'cachivache'
        Repositorio         = 'https://github.com/soypacodev/cachivache'
        Editor              = 'Francisco López'
        UrlEditor           = 'https://github.com/soypacodev'
        Licencia            = 'MIT'
        Idioma              = 'es-ES'
        Resumen             = 'Limpiador de disco para Windows que enseña qué va a borrar antes de borrarlo.'

        # 1.6.0: admite NestedInstallerFiles (el instalador es un .zip con
        # una carpeta dentro) y la aceptan clientes de winget antiguos.
        VersionManifiesto   = '1.6.0'
    }
}

function Get-VersionDesdeEtiqueta {
    <#
    .SYNOPSIS
        La versión sin la 'v' inicial, a partir de la etiqueta de git.

    .DESCRIPTION
        El zip y la URL usan la etiqueta completa, pero winget y Scoop
        esperan la versión sin la v (con ella no ordena bien). Es estricta:
        una etiqueta mal formada lanza en vez de producir una URL rota.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta
    )

    if ([string]::IsNullOrWhiteSpace($Etiqueta)) {
        throw 'No hay etiqueta de la que sacar la version.'
    }
    if ($Etiqueta -cnotmatch '^v\d+(\.\d+){1,3}$') {
        throw ("La etiqueta '$Etiqueta' no tiene la forma vX.Y.Z que publica este proyecto.")
    }

    return $Etiqueta.Substring(1)
}

function Get-NombrePaqueteZip {
    <#
    .SYNOPSIS
        Nombre del .zip de una versión.

    .DESCRIPTION
        Lo comparten publicar.yml, las URL de winget y Scoop y la
        verificación de sumas. Una invariante comprueba que el flujo y esta
        función no divergen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta
    )

    # Solo para validar la etiqueta.
    [void](Get-VersionDesdeEtiqueta -Etiqueta $Etiqueta)
    return ('Cachivache-{0}.zip' -f $Etiqueta)
}

function Get-CarpetaDentroDelZip {
    <#
    .SYNOPSIS
        La carpeta que hay dentro del .zip.

    .DESCRIPTION
        Compress-Archive comprime la carpeta, no su contenido: al
        descomprimir aparece Cachivache-v2.1.0\Cachivache.exe. winget lo
        necesita en RelativeFilePath y Scoop en extract_dir.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta
    )

    return [IO.Path]::GetFileNameWithoutExtension((Get-NombrePaqueteZip -Etiqueta $Etiqueta))
}

function Get-UrlDescarga {
    <#
    .SYNOPSIS
        La URL de un archivo adjunto a la versión de GitHub.

    .DESCRIPTION
        Sirve para el .zip y para SHA256SUMS.txt (del que el autoupdate de
        Scoop toma el hash).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Archivo
    )

    if ([string]::IsNullOrWhiteSpace($Archivo)) {
        throw 'No se ha dicho de que archivo es la URL.'
    }
    [void](Get-VersionDesdeEtiqueta -Etiqueta $Etiqueta)

    $identidad = Get-IdentidadPaquete
    return ('{0}/releases/download/{1}/{2}' -f $identidad.Repositorio, $Etiqueta, $Archivo)
}

function ConvertTo-EscalarYaml {
    <#
    .SYNOPSIS
        Un valor listo para poner detrás de "clave:" en un YAML.

    .DESCRIPTION
        Entrecomilla lo que YAML interpretaría como otro tipo: números
        (una versión "2.1" sería un número y winget la rechazaría),
        booleanos y nulos (true, yes, on, null, ~...), valores con ': ',
        indicadores iniciales y espacios en los bordes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Valor
    )

    if ([string]::IsNullOrEmpty($Valor)) { return "''" }

    $pareceNumero  = $Valor -match '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$'
    $pareceBooleano = $Valor -match '^(?i:true|false|yes|no|on|off|null|~)$'
    $indicador     = $Valor -match '^[\s>|&*!%@`#\-?:{}\[\],''"]'
    $parteClave    = $Valor.Contains(': ')
    $bordeConEspacio = $Valor -ne $Valor.Trim()

    if ($pareceNumero -or $pareceBooleano -or $indicador -or $parteClave -or $bordeConEspacio) {
        # Comillas simples: el único escape es duplicar la comilla, y las
        # barras invertidas de las rutas de Windows quedan literales.
        return ("'" + $Valor.Replace("'", "''") + "'")
    }

    return $Valor
}

function Format-ManifiestoWingetVersion {
    <#
    .SYNOPSIS
        El manifiesto 'version' de winget: el que dice que existe el paquete.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta
    )

    $identidad = Get-IdentidadPaquete
    $version   = Get-VersionDesdeEtiqueta -Etiqueta $Etiqueta

    return (@(
        ('# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.{0}.schema.json' -f $identidad.VersionManifiesto)
        ''
        ('PackageIdentifier: {0}' -f (ConvertTo-EscalarYaml -Valor $identidad.IdentificadorWinget))
        ('PackageVersion: {0}'    -f (ConvertTo-EscalarYaml -Valor $version))
        ('DefaultLocale: {0}'     -f (ConvertTo-EscalarYaml -Valor $identidad.Idioma))
        'ManifestType: version'
        ('ManifestVersion: {0}'   -f (ConvertTo-EscalarYaml -Valor $identidad.VersionManifiesto))
    ) -join "`n") + "`n"
}

function Format-ManifiestoWingetInstalador {
    <#
    .SYNOPSIS
        El manifiesto 'installer' de winget: dónde está el .zip y qué hay
        dentro.

    .DESCRIPTION
        Es el único de los tres que lleva el hash.

        zip + NestedInstallerType portable permite publicar sin firmar:
        winget no ejecuta ningún instalador, solo descomprime y crea un
        alias.

        Architecture: neutral porque el programa son guiones de PowerShell y
        un lanzador AnyCPU; x64 excluiría Windows en ARM64.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Hash
    )

    if (-not (Test-SumaSha256Valida -Suma $Hash)) {
        throw ("El hash del paquete no tiene forma de SHA-256: '$Hash'")
    }

    $identidad = Get-IdentidadPaquete
    $version   = Get-VersionDesdeEtiqueta -Etiqueta $Etiqueta
    $zip       = Get-NombrePaqueteZip -Etiqueta $Etiqueta
    $carpeta   = Get-CarpetaDentroDelZip -Etiqueta $Etiqueta
    $url       = Get-UrlDescarga -Etiqueta $Etiqueta -Archivo $zip

    # Barra invertida, como en los manifiestos del repositorio de winget.
    $rutaInterior = '{0}\Cachivache.exe' -f $carpeta

    return (@(
        ('# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.{0}.schema.json' -f $identidad.VersionManifiesto)
        ''
        ('PackageIdentifier: {0}' -f (ConvertTo-EscalarYaml -Valor $identidad.IdentificadorWinget))
        ('PackageVersion: {0}'    -f (ConvertTo-EscalarYaml -Valor $version))
        'InstallerType: zip'
        'NestedInstallerType: portable'
        'NestedInstallerFiles:'
        ('  - RelativeFilePath: {0}' -f (ConvertTo-EscalarYaml -Valor $rutaInterior))
        ('    PortableCommandAlias: {0}' -f (ConvertTo-EscalarYaml -Valor $identidad.IdentificadorScoop))
        'Installers:'
        '  - Architecture: neutral'
        ('    InstallerUrl: {0}' -f (ConvertTo-EscalarYaml -Valor $url))
        # En mayúsculas, como wingetcreate. Ver la cabecera.
        ('    InstallerSha256: {0}' -f $Hash.ToUpperInvariant())
        'ManifestType: installer'
        ('ManifestVersion: {0}' -f (ConvertTo-EscalarYaml -Valor $identidad.VersionManifiesto))
    ) -join "`n") + "`n"
}

function Format-ManifiestoWingetLocale {
    <#
    .SYNOPSIS
        El manifiesto 'defaultLocale' de winget: lo que lee una persona.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta
    )

    $identidad = Get-IdentidadPaquete
    $version   = Get-VersionDesdeEtiqueta -Etiqueta $Etiqueta

    return (@(
        ('# yaml-language-server: $schema=https://aka.ms/winget-manifest.defaultLocale.{0}.schema.json' -f $identidad.VersionManifiesto)
        ''
        ('PackageIdentifier: {0}' -f (ConvertTo-EscalarYaml -Valor $identidad.IdentificadorWinget))
        ('PackageVersion: {0}'    -f (ConvertTo-EscalarYaml -Valor $version))
        ('PackageLocale: {0}'     -f (ConvertTo-EscalarYaml -Valor $identidad.Idioma))
        ('Publisher: {0}'         -f (ConvertTo-EscalarYaml -Valor $identidad.Editor))
        ('PublisherUrl: {0}'      -f (ConvertTo-EscalarYaml -Valor $identidad.UrlEditor))
        ('PublisherSupportUrl: {0}' -f (ConvertTo-EscalarYaml -Valor ($identidad.Repositorio + '/issues')))
        ('Author: {0}'            -f (ConvertTo-EscalarYaml -Valor $identidad.Editor))
        'PackageName: Cachivache'
        ('PackageUrl: {0}'        -f (ConvertTo-EscalarYaml -Valor $identidad.Repositorio))
        ('License: {0}'           -f (ConvertTo-EscalarYaml -Valor $identidad.Licencia))
        ('LicenseUrl: {0}'        -f (ConvertTo-EscalarYaml -Valor ($identidad.Repositorio + '/blob/main/LICENSE')))
        ('ShortDescription: {0}'  -f (ConvertTo-EscalarYaml -Valor $identidad.Resumen))
        ('Moniker: {0}'           -f (ConvertTo-EscalarYaml -Valor $identidad.IdentificadorScoop))
        'Tags:'
        '  - limpieza'
        '  - disco'
        '  - espacio'
        '  - powershell'
        '  - windows'
        ('ReleaseNotesUrl: {0}'   -f (ConvertTo-EscalarYaml -Valor ('{0}/releases/tag/{1}' -f $identidad.Repositorio, $Etiqueta)))
        'ManifestType: defaultLocale'
        ('ManifestVersion: {0}'   -f (ConvertTo-EscalarYaml -Valor $identidad.VersionManifiesto))
    ) -join "`n") + "`n"
}

function Format-ManifiestoScoop {
    <#
    .SYNOPSIS
        El manifiesto de Scoop: un solo .json.

    .DESCRIPTION
        Se genera con ConvertTo-Json para escapar bien comillas y barras
        invertidas.

        checkver y autoupdate permiten que Scoop se actualice solo si el
        .json deja de regenerarse: mira las versiones de GitHub y toma el
        hash de SHA256SUMS.txt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Hash
    )

    if (-not (Test-SumaSha256Valida -Suma $Hash)) {
        throw ("El hash del paquete no tiene forma de SHA-256: '$Hash'")
    }

    $identidad = Get-IdentidadPaquete
    $version   = Get-VersionDesdeEtiqueta -Etiqueta $Etiqueta
    $zip       = Get-NombrePaqueteZip -Etiqueta $Etiqueta
    $carpeta   = Get-CarpetaDentroDelZip -Etiqueta $Etiqueta

    # Comillas simples: $version es un marcador de Scoop, no una variable de
    # PowerShell; con comillas dobles se expandiría a cadena vacía.
    $plantillaZip = 'Cachivache-v$version.zip'
    $urlAutoupdate = '{0}/releases/download/v$version/{1}' -f $identidad.Repositorio, $plantillaZip

    $manifiesto = [ordered] @{
        version     = $version
        description = $identidad.Resumen
        homepage    = $identidad.Repositorio
        license     = $identidad.Licencia
        url         = (Get-UrlDescarga -Etiqueta $Etiqueta -Archivo $zip)
        # En minúsculas, como SHA256SUMS.txt. Ver la cabecera.
        hash        = $Hash.ToLowerInvariant()
        extract_dir = $carpeta

        # bin da el modo consola desde la terminal; el acceso directo abre
        # la ventana. Un shim al .exe abriría la ventana sin salida en consola.
        bin         = @(, @('Cachivache.ps1', 'cachivache'))
        shortcuts   = @(, @('Cachivache.exe', 'Cachivache'))

        checkver    = [ordered] @{ github = $identidad.Repositorio }
        autoupdate  = [ordered] @{
            url         = $urlAutoupdate
            extract_dir = 'Cachivache-v$version'
            # $baseurl es la carpeta de adjuntos de la versión, donde está
            # SHA256SUMS.txt.
            hash        = [ordered] @{ url = '$baseurl/SHA256SUMS.txt' }
        }
    }

    $texto = $manifiesto | ConvertTo-Json -Depth 5

    # LF y salto final: ConvertTo-Json devuelve CRLF en Windows.
    return (($texto -replace "`r`n", "`n").TrimEnd("`n") + "`n")
}
