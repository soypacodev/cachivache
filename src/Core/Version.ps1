<#
.SYNOPSIS
    Versión del programa y aviso de versión nueva. Es el único sitio donde
    se cambia la versión al publicar.

.DESCRIPTION
    Contiene dos partes independientes:

    1. El cálculo puro de si una etiqueta publicada es más nueva que la
       instalada. No tiene efectos externos y se prueba entero.
    2. La consulta a la red: una sola función aislada, que nunca lanza y
       devuelve cadena vacía cuando no puede saberlo.

    El programa no se conecta por su cuenta (ni al arrancar ni en segundo
    plano): la consulta solo ocurre cuando el usuario pulsa el botón del
    panel Acerca de. Ver la nota del README.
#>

$script:VersionCachivache = '2.0.1'
$script:RepositorioUrl   = 'https://github.com/soypacodev/cachivache'

function Get-VersionCachivache {
    [OutputType([string])]
    param()
    return $script:VersionCachivache
}

function ConvertTo-PartesVersion {
    <#
    .SYNOPSIS
        Convierte una etiqueta de versión en sus tres números, o $null si no
        se reconoce.

    .DESCRIPTION
        - Quita la 'v' inicial: "v2.1.0" y "2.1.0" son la misma versión.
        - Devuelve números, no texto: como cadena, "2.10.0" sería menor que
          "2.9.0".
        - Admite una, dos o tres partes y completa con ceros ("2.1" = "2.1.0").
        - Cualquier otro formato devuelve $null ("no se sabe"), incluidas las
          preversiones ("2.1.0-beta"): una etiqueta no reconocida nunca debe
          producir un aviso.
        - Como máximo nueve dígitos por parte, para que quepa en un entero
          de 32 bits y la conversión no lance.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta
    )

    if ([string]::IsNullOrWhiteSpace($Etiqueta)) { return $null }

    $texto = $Etiqueta.Trim()
    if ($texto -match '^[vV]') { $texto = $texto.Substring(1).Trim() }

    if ($texto -notmatch '^[0-9]{1,9}(\.[0-9]{1,9}){0,2}$') { return $null }

    $partes = @(0, 0, 0)
    $indice = 0
    foreach ($trozo in $texto.Split('.')) {
        $partes[$indice] = [int]$trozo
        $indice++
    }

    # La coma evita que PowerShell desenrolle el array al devolverlo.
    return ,[int[]]$partes
}

function Format-VersionNormalizada {
    <#
    .SYNOPSIS
        Normaliza una etiqueta ("v2.1" -> "2.1.0"). Cadena vacía si no se
        reconoce.

    .DESCRIPTION
        Además de unificar la presentación, sirve de filtro de seguridad: la
        etiqueta publicada viene de la red, y la ventana solo muestra los
        números reconocidos, nunca el texto recibido tal cual.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Etiqueta
    )

    $partes = ConvertTo-PartesVersion -Etiqueta $Etiqueta
    if ($null -eq $partes) { return '' }
    return ($partes -join '.')
}

function Compare-VersionCachivache {
    <#
    .SYNOPSIS
        1 si Izquierda es más nueva, -1 si es más antigua, 0 si son iguales,
        $null si alguna no se reconoce.

    .DESCRIPTION
        Compara parte a parte de izquierda a derecha.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Izquierda,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Derecha
    )

    $unas = ConvertTo-PartesVersion -Etiqueta $Izquierda
    $otras = ConvertTo-PartesVersion -Etiqueta $Derecha
    if ($null -eq $unas -or $null -eq $otras) { return $null }

    for ($i = 0; $i -lt 3; $i++) {
        if ($unas[$i] -gt $otras[$i]) { return 1 }
        if ($unas[$i] -lt $otras[$i]) { return -1 }
    }
    return 0
}

function Test-HayVersionNueva {
    <#
    .SYNOPSIS
        Indica si la versión publicada es más nueva que la instalada.

    .DESCRIPTION
        Ante cualquier duda (etiqueta no reconocida, respuesta vacía)
        devuelve $false: un aviso falso es peor que un aviso tardío.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Instalada,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Publicada
    )

    $comparacion = Compare-VersionCachivache -Izquierda $Publicada -Derecha $Instalada
    if ($null -eq $comparacion) { return $false }
    return ($comparacion -gt 0)
}

function Get-AvisoActualizacion {
    <#
    .SYNOPSIS
        Devuelve el texto del panel Acerca de y si hay que ofrecer la
        descarga.

    .DESCRIPTION
        Toda la decisión está en esta función pura, no en el manejador del
        botón ni en el XAML, para poder probarla sin la ventana.

        Los tres estados son excluyentes: no se ha podido saber, hay una
        versión nueva, o está al día.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Instalada,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Publicada
    )

    $laInstalada = Format-VersionNormalizada -Etiqueta $Instalada
    $laPublicada = Format-VersionNormalizada -Etiqueta $Publicada

    if ($laInstalada -eq '' -or $laPublicada -eq '') {
        return [pscustomobject]@{
            Hay     = $false
            Version = ''
            Texto   = 'No se ha podido comprobar si hay una versión nueva. Vuelve a intentarlo más tarde o mira la página del proyecto.'
        }
    }

    if (Test-HayVersionNueva -Instalada $Instalada -Publicada $Publicada) {
        return [pscustomobject]@{
            Hay     = $true
            Version = $laPublicada
            Texto   = ('Hay una versión nueva: la {0}. La tuya es la {1}.' -f $laPublicada, $laInstalada)
        }
    }

    return [pscustomobject]@{
        Hay     = $false
        Version = $laPublicada
        Texto   = ('Estás al día: no hay publicada ninguna versión más nueva que la {0}.' -f $laInstalada)
    }
}

function Get-UrlUltimaVersion {
    <#
    .SYNOPSIS
        Página de la última publicación, la que se abre en el navegador.

    .DESCRIPTION
        El programa no se actualiza a sí mismo: se distribuye como .zip
        descomprimido donde el usuario quiera y no puede sustituir sus
        propios archivos mientras se ejecuta desde ellos.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Repositorio = $script:RepositorioUrl)

    if ([string]::IsNullOrWhiteSpace($Repositorio)) { return '' }
    return ($Repositorio.Trim().TrimEnd('/') + '/releases/latest')
}

function Get-UrlApiUltimaVersion {
    <#
    .SYNOPSIS
        Dirección de la API que informa de la última publicación.

    .DESCRIPTION
        Se deriva de $script:RepositorioUrl para no mantener dos direcciones
        que puedan divergir. Si el repositorio no tiene la forma esperada
        devuelve cadena vacía y no se consulta nada.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Repositorio = $script:RepositorioUrl)

    if ([string]::IsNullOrWhiteSpace($Repositorio)) { return '' }

    $base = $Repositorio.Trim().TrimEnd('/')
    if ($base.EndsWith('.git')) { $base = $base.Substring(0, $base.Length - 4) }

    $coincidencia = [regex]::Match($base, '^https://github\.com/([^/]+)/([^/]+)$')
    if (-not $coincidencia.Success) { return '' }

    return ('https://api.github.com/repos/{0}/{1}/releases/latest' -f
            $coincidencia.Groups[1].Value, $coincidencia.Groups[2].Value)
}

function Get-UltimaVersionPublicada {
    <#
    .SYNOPSIS
        Etiqueta de la última publicación, o cadena vacía si no se ha podido
        averiguar. Nunca lanza.

    .DESCRIPTION
        Único punto del programa que abre una conexión; solo se llama cuando
        el usuario pulsa el botón del panel Acerca de.

        - Nunca lanza: sin red, con proxy, con límite de peticiones o con una
          respuesta inesperada devuelve cadena vacía.
        - Usa un tiempo de espera corto para no quedarse colgada ante una
          red que acepta la conexión y no responde.
        - Usa Write-Verbose y no Write-Registro porque se ejecuta en un
          runspace aparte que solo tiene cargado este archivo.
        - Envía User-Agent: sin él la API de GitHub responde 403.
        - Añade TLS 1.2 al valor actual (es un ajuste de todo el proceso):
          PowerShell 5.1 en equipos sin actualizar puede no incluirlo y
          GitHub no acepta versiones inferiores.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Url = (Get-UrlApiUltimaVersion),
        [int] $TiempoEspera = 6
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "No se ha podido pedir TLS 1.2: $($_.Exception.Message)"
    }

    try {
        $cabeceras = @{
            'User-Agent' = 'Cachivache'
            'Accept'     = 'application/vnd.github+json'
        }
        $respuesta = Invoke-RestMethod -Uri $Url -Method Get -Headers $cabeceras `
                                       -TimeoutSec $TiempoEspera -ErrorAction Stop
        if ($null -eq $respuesta) { return '' }
        return [string]$respuesta.tag_name
    } catch {
        Write-Verbose "No se ha podido consultar la última versión: $($_.Exception.Message)"
        return ''
    }
}
