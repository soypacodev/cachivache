<#
.SYNOPSIS
    Generación de informes en HTML, CSV y JSON.
#>

function Measure-TotalBytes {
    <#
    .SYNOPSIS
        Suma una propiedad de bytes de una lista de candidatos.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        $Candidatos,
        [ValidateSet('Bytes', 'BytesLiberados')]
        [string] $Propiedad = 'Bytes'
    )

    $suma = 0.0
    foreach ($c in @($Candidatos)) { $suma += [double]$c.$Propiedad }
    return $suma
}

function ConvertTo-CsvSeguro {
    <#
    .SYNOPSIS
        Neutraliza un texto para que Excel no lo interprete como fórmula.

    .DESCRIPTION
        Excel evalúa como fórmula cualquier celda que empiece por =, +, -,
        @ o un tabulador, aunque Export-Csv la entrecomille. Un archivo
        llamado

            =cmd|'/c calc'!A1.tmp

        se ejecutaría al abrir el informe. Los nombres de archivo, servicio
        o valores del registro los controla quien los crea, así que se
        tratan como entrada no confiable.

        El apóstrofo inicial es la convención de Excel para "texto literal":
        no se ve en la celda. El informe HTML usa ConvertTo-HtmlSeguro.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Texto)

    if ([string]::IsNullOrEmpty($Texto)) { return $Texto }

    # Se mira el primer carácter no blanco: Excel ignora los espacios
    # iniciales, así que " =HYPERLINK(...)" también se evalúa.
    $recortado = $Texto.TrimStart()
    if ([string]::IsNullOrEmpty($recortado)) { return $Texto }
    if ($recortado[0] -in @('=', '+', '-', '@', "`t", "`r")) { return "'" + $Texto }
    return $Texto
}

function Export-InformeCsv {
    <#
    .SYNOPSIS
        Vuelca los candidatos a un CSV listo para abrir en Excel.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Candidatos,
        [Parameter(Mandatory)] [string] $Ruta,
        # Sustituye perfil, usuario y equipo por marcadores
        # (ConvertTo-RutaAnonima, Format.ps1).
        [switch] $Anonimo
    )

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Exportar CSV')) { return }

    # Se anonimiza antes de neutralizar fórmulas para que el apóstrofo
    # quede al principio del texto final.
    $limpiar = if ($Anonimo) {
        { param($t) ConvertTo-CsvSeguro (ConvertTo-RutaAnonima $t) }
    } else {
        { param($t) ConvertTo-CsvSeguro $t }
    }
    # Todo campo cuyo contenido venga del disco o del registro pasa por
    # ConvertTo-CsvSeguro. Modulo, Riesgo y Metodo salen de un ValidateSet,
    # y los numéricos y booleanos los genera el programa.
    @($Candidatos) |
        Select-Object @{ n = 'Modulo';        e = { $_.ModuloId } },
                      @{ n = 'Categoria';     e = { & $limpiar $_.Categoria } },
                      @{ n = 'Nombre';        e = { & $limpiar $_.Nombre } },
                      @{ n = 'Ruta';          e = { & $limpiar $_.Ruta } },
                      @{ n = 'Bytes';         e = { [long]$_.Bytes } },
                      @{ n = 'Tamano';        e = { Format-Tamano $_.Bytes } },
                      Riesgo, Metodo,
                      @{ n = 'Info';          e = { & $limpiar $_.Info } },
                      @{ n = 'Efecto';        e = { & $limpiar $_.Efecto } },
                      @{ n = 'Aviso';         e = { & $limpiar $_.Aviso } },
                      @{ n = 'Seleccionado';  e = { $_.Seleccionado } },
                      @{ n = 'Eliminado';     e = { $_.Hecho } },
                      @{ n = 'Liberado';      e = { Format-Tamano $_.BytesLiberados } },
                      @{ n = 'Error';         e = { & $limpiar $_.Error } } |
        Export-Csv -LiteralPath $Ruta -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
}

function Export-InformeJson {
    <#
    .SYNOPSIS
        Vuelca el análisis completo a JSON, para integrarlo con otras cosas.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Candidatos,
        [Parameter(Mandatory)] [string] $Ruta,
        $Configuracion = $null,
        [switch] $Anonimo
    )

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Exportar JSON')) { return }

    $total = Measure-TotalBytes $Candidatos

    # No se incluye el nombre del equipo: no aporta nada y el informe
    # puede adjuntarse a una incidencia pública.
    $documento = [pscustomobject]@{
        Generado   = (Get-Date).ToString('o')
        Version    = $script:VersionCachivache
        Perfil     = if ($Configuracion) { $Configuracion.Perfil } else { '' }
        Total      = $total
        Elementos  = @($Candidatos).Count
        Candidatos = @($Candidatos | Select-Object ModuloId,
            @{ n = 'Categoria'; e = { if ($Anonimo) { ConvertTo-RutaAnonima $_.Categoria } else { $_.Categoria } } },
            @{ n = 'Nombre';    e = { if ($Anonimo) { ConvertTo-RutaAnonima $_.Nombre }    else { $_.Nombre } } },
            Bytes, Riesgo, Metodo, Seleccionado, Hecho, BytesLiberados,
            @{ n = 'Ruta';   e = { if ($Anonimo) { ConvertTo-RutaAnonima $_.Ruta }   else { $_.Ruta } } },
            @{ n = 'Info';   e = { if ($Anonimo) { ConvertTo-RutaAnonima $_.Info }   else { $_.Info } } },
            @{ n = 'Efecto'; e = { if ($Anonimo) { ConvertTo-RutaAnonima $_.Efecto } else { $_.Efecto } } },
            @{ n = 'Aviso';  e = { if ($Anonimo) { ConvertTo-RutaAnonima $_.Aviso }  else { $_.Aviso } } },
            @{ n = 'Error';  e = { if ($Anonimo) { ConvertTo-RutaAnonima $_.Error }  else { $_.Error } } })
    }
    $documento | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ruta -Encoding UTF8 -ErrorAction Stop
}

function ConvertTo-HtmlSeguro {
    [OutputType([string])]
    param([string] $Texto)
    if ([string]::IsNullOrEmpty($Texto)) { return '' }
    return [Net.WebUtility]::HtmlEncode($Texto)
}

function Get-InformeEstiloCss {
    <#
    .SYNOPSIS
        Hoja de estilos del informe HTML.
    .DESCRIPTION
        Separada de Export-InformeHtml para no mezclar aspecto y contenido.
        Va incrustada: el informe es un único archivo sin dependencias
        externas.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
<style>
:root{--bg:#0f1115;--surface:#161a21;--surface2:#1d222b;--border:#262c37;
--text:#e6eaf2;--muted:#8a93a6;--accent:#4c8dff;--ok:#3dd68c;--warn:#f5a524;--danger:#ff5d5d}
*{box-sizing:border-box}
body{margin:0;padding:32px;background:var(--bg);color:var(--text);
font-family:"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;font-size:14px;line-height:1.55}
.wrap{max-width:1180px;margin:0 auto}
h1{font-size:28px;font-weight:600;margin:0 0 4px}
h2{font-size:17px;font-weight:600;margin:36px 0 12px;display:flex;align-items:center;gap:10px}
.sub{color:var(--muted);margin:0 0 28px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-bottom:32px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:18px}
.card .k{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
.card .v{font-size:26px;font-weight:600;margin-top:6px}
.card.acc .v{color:var(--accent)} .card.ok .v{color:var(--ok)}
/* table-layout:fixed y anchos explicitos.
   Sin esto el navegador reparte el ancho segun el contenido, y como la
   ruta se podia partir por cualquier letra (word-break:break-all) la
   consideraba infinitamente estrechable: le daba cuatro caracteres y
   dejaba las rutas en una tira vertical ilegible. Con anchos fijos, cada
   columna tiene lo suyo pase lo que pase con el contenido. */
table{width:100%;table-layout:fixed;border-collapse:collapse;background:var(--surface);
border:1px solid var(--border);border-radius:12px;overflow:hidden}
col.c-elem{width:26%} col.c-ruta{width:34%} col.c-tam{width:10%}
col.c-riesgo{width:9%} col.c-efecto{width:21%}
th{background:var(--surface2);text-align:left;padding:11px 14px;font-weight:600;
font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
td{padding:11px 14px;border-top:1px solid var(--border);vertical-align:top;
overflow-wrap:anywhere}
tr:hover td{background:rgba(255,255,255,.02)}
/* overflow-wrap:anywhere en vez de word-break:break-all: parte solo
   cuando de verdad no cabe, en lugar de cortar cada linea a mitad de
   palabra aunque quedara sitio. */
.path{font-family:"Cascadia Mono",Consolas,monospace;font-size:12px;color:var(--muted);
overflow-wrap:anywhere}
.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
.chip{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11px;font-weight:600}
.chip.bajo{background:rgba(61,214,140,.14);color:var(--ok)}
.chip.medio{background:rgba(245,165,36,.14);color:var(--warn)}
.chip.alto{background:rgba(255,93,93,.14);color:var(--danger)}
.aviso{color:var(--danger);font-size:12px;display:block;margin-top:4px}
.count{color:var(--muted);font-weight:400;font-size:13px}
footer{margin-top:48px;color:var(--muted);font-size:12px;border-top:1px solid var(--border);padding-top:18px}
@media print{body{background:#fff;color:#111}.card,table{border-color:#ddd;background:#fff}}
</style>
'@
}

function Export-InformeHtml {
    <#
    .SYNOPSIS
        Genera un informe HTML autocontenido, sin dependencias externas.
    .DESCRIPTION
        Un único archivo con estilos incrustados que se puede archivar,
        enviar por correo o abrir sin conexión. Agrupa por módulo y marca
        con color los elementos que llevan aviso.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Candidatos,
        [Parameter(Mandatory)] [string] $Ruta,
        [Parameter(Mandatory)] $Configuracion,
        [ValidateSet('analisis', 'limpieza')] [string] $Tipo = 'analisis',
        $Modulos = @(),
        [switch] $Anonimo
    )

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Exportar informe HTML')) { return }

    $lista         = @($Candidatos)
    $totalBytes    = Measure-TotalBytes $lista 'Bytes'
    $totalLiberado = Measure-TotalBytes $lista 'BytesLiberados'

    $nombresModulo = @{}
    foreach ($m in @($Modulos)) { $nombresModulo[$m.Id] = $m.Nombre }

    $titulo = if ($Tipo -eq 'limpieza') { 'Informe de limpieza' } else { 'Informe de análisis' }

    # Con -Anonimo, todo texto que pueda contener rutas o nombres del equipo
    # pasa por ConvertTo-RutaAnonima, igual que en el CSV y el JSON.
    $anonimizar = if ($Anonimo) { { param($t) ConvertTo-RutaAnonima $t } } else { { param($t) $t } }
    $equipo = if ($Anonimo) { '<equipo>' } else { $Configuracion.Equipo }

    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="es"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine("<title>$titulo - Cachivache</title>")
    [void]$sb.AppendLine((Get-InformeEstiloCss))
    [void]$sb.AppendLine('</head><body><div class="wrap">')

    [void]$sb.AppendLine("<h1>$titulo</h1>")
    [void]$sb.AppendLine(('<p class="sub">{0} &middot; {1} &middot; perfil {2} &middot; {3}</p>' -f
        (ConvertTo-HtmlSeguro $equipo),
        (ConvertTo-HtmlSeguro $Configuracion.Windows),
        (ConvertTo-HtmlSeguro $Configuracion.Perfil),
        (Get-Date -Format 'dd/MM/yyyy HH:mm')))

    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine(('<div class="card"><div class="k">Elementos</div><div class="v">{0}</div></div>' -f $lista.Count))
    [void]$sb.AppendLine(('<div class="card acc"><div class="k">Espacio detectado</div><div class="v">{0}</div></div>' -f (Format-Tamano $totalBytes)))
    if ($Tipo -eq 'limpieza') {
        [void]$sb.AppendLine(('<div class="card ok"><div class="k">Espacio liberado</div><div class="v">{0}</div></div>' -f (Format-Tamano $totalLiberado)))
    }
    foreach ($unidad in @($Configuracion.Unidades)) {
        [void]$sb.AppendLine(('<div class="card"><div class="k">Libre en {0}</div><div class="v">{1}</div></div>' -f
            (ConvertTo-HtmlSeguro $unidad.Letra), (Format-Tamano $unidad.Libre)))
    }
    [void]$sb.AppendLine('</div>')

    foreach ($grupo in ($lista | Group-Object ModuloId | Sort-Object { -(Measure-TotalBytes $_.Group) })) {
        $nombre = if ($nombresModulo.ContainsKey($grupo.Name)) { $nombresModulo[$grupo.Name] } else { $grupo.Name }
        $suma   = Measure-TotalBytes $grupo.Group
        [void]$sb.AppendLine(('<h2>{0} <span class="count">{1} elementos &middot; {2}</span></h2>' -f
            (ConvertTo-HtmlSeguro $nombre), $grupo.Count, (Format-Tamano $suma)))
        [void]$sb.AppendLine('<table><colgroup><col class="c-elem"><col class="c-ruta"><col class="c-tam"><col class="c-riesgo"><col class="c-efecto"></colgroup>')
        [void]$sb.AppendLine('<thead><tr><th>Elemento</th><th>Ruta</th><th class="num">Tamaño</th><th>Riesgo</th><th>Efecto</th></tr></thead><tbody>')

        foreach ($c in ($grupo.Group | Sort-Object Bytes -Descending)) {
            $aviso = ''
            if (-not [string]::IsNullOrWhiteSpace($c.Aviso)) {
                $aviso = '<span class="aviso">Atención: ' + (ConvertTo-HtmlSeguro (& $anonimizar $c.Aviso)) + '</span>'
            }
            $tam = if ($c.Bytes -gt 0) { Format-Tamano $c.Bytes } else { '&mdash;' }
            [void]$sb.AppendLine(('<tr><td><strong>{0}</strong><br><span class="count">{1}</span>{2}</td><td class="path">{3}</td><td class="num">{4}</td><td><span class="chip {5}">{6}</span></td><td>{7}</td></tr>' -f
                (ConvertTo-HtmlSeguro (& $anonimizar $c.Nombre)),
                (ConvertTo-HtmlSeguro (& $anonimizar $c.Info)),
                $aviso,
                (ConvertTo-HtmlSeguro (& $anonimizar $c.Ruta)),
                $tam,
                $c.Riesgo.ToLowerInvariant(),
                (ConvertTo-HtmlSeguro $c.Riesgo),
                (ConvertTo-HtmlSeguro (& $anonimizar $c.Efecto))))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    if ($lista.Count -eq 0) {
        [void]$sb.AppendLine('<p class="sub">No se ha encontrado nada que limpiar con estos umbrales.</p>')
    }

    [void]$sb.AppendLine(('<footer>Generado por Cachivache v{0}. Este informe describe lo que el programa PROPONE; no implica que se haya borrado nada salvo que se indique lo contrario.</footer>' -f $script:VersionCachivache))
    [void]$sb.AppendLine('</div></body></html>')

    # -ErrorAction Stop es necesario: si la carpeta no existe o no hay
    # permiso, Set-Content solo emite un error no terminante, el try/catch
    # del llamante no se dispara y el informe se daría por guardado. Una
    # invariante lo exige en los cuatro exportadores.
    Set-Content -LiteralPath $Ruta -Value $sb.ToString() -Encoding UTF8 -ErrorAction Stop
}

function New-NombreInforme {
    <#
    .SYNOPSIS
        Compone una ruta de informe con marca de tiempo.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Compone una ruta; la carpeta se crea con New-Item, que ya avisa.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Tipo,
        [Parameter(Mandatory)] [string] $Extension,
        [string] $CarpetaDatos = (Get-CarpetaDatos)
    )

    $carpeta = Join-Path $CarpetaDatos 'informes'
    if (-not (Test-Path -LiteralPath $carpeta)) {
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
    }
    $marca = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    return (Join-Path $carpeta "$Tipo`_$marca.$Extension")
}

function Get-CarpetaInformes {
    <#
    .SYNOPSIS
        Carpeta donde viven los informes generados.
    .DESCRIPTION
        Fuente única de la ubicación, para quien escribe y quien lee
        informes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $CarpetaDatos = (Get-CarpetaDatos))

    return (Join-Path $CarpetaDatos 'informes')
}

function Get-InformesGuardados {
    <#
    .SYNOPSIS
        Enumera los informes ya generados, del más reciente al más antiguo.

    .DESCRIPTION
        Devuelve nombre, tipo, formato, fecha y tamaño de cada informe. La
        fecha sale del nombre del archivo si sigue el patrón de
        New-NombreInforme y, si no, de la fecha de escritura, de modo que un
        informe renombrado sigue apareciendo con fecha.

        Si la carpeta no existe devuelve una lista vacía.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('html', 'csv', 'json')]
        [string] $Formato = '',
        [string] $CarpetaDatos = (Get-CarpetaDatos)
    )

    $carpeta = Get-CarpetaInformes -CarpetaDatos $CarpetaDatos
    if (-not (Test-Path -LiteralPath $carpeta)) { return @() }

    $extensiones = if ($Formato) { @($Formato) } else { @('html', 'csv', 'json') }
    $encontrados = @()

    foreach ($archivo in @(Get-ChildItem -LiteralPath $carpeta -File -ErrorAction SilentlyContinue)) {
        $ext = $archivo.Extension.TrimStart('.').ToLowerInvariant()
        if ($extensiones -notcontains $ext) { continue }

        # analisis_2026-08-19_143005.html -> tipo 'análisis', fecha exacta.
        $tipo  = 'informe'
        $fecha = $archivo.LastWriteTime
        if ($archivo.BaseName -match '^(?<tipo>[a-z]+)_(?<f>\d{4}-\d{2}-\d{2})_(?<h>\d{2})(?<m>\d{2})(?<s>\d{2})$') {
            $tipo = $Matches['tipo']
            # InvariantCulture: el formato es fijo, no depende del idioma.
            $texto = '{0} {1}:{2}:{3}' -f $Matches['f'], $Matches['h'], $Matches['m'], $Matches['s']
            try {
                $fecha = [datetime]::ParseExact($texto, 'yyyy-MM-dd HH:mm:ss',
                                                [Globalization.CultureInfo]::InvariantCulture)
            } catch {
                $fecha = $archivo.LastWriteTime
            }
        }

        $encontrados += [pscustomobject]@{
            Nombre  = $archivo.Name
            Ruta    = $archivo.FullName
            Formato = $ext
            Tipo    = $tipo
            Fecha   = $fecha
            Bytes   = [double]$archivo.Length
        }
    }

    return @($encontrados | Sort-Object -Property Fecha -Descending)
}

function Resolve-InformeAbrible {
    <#
    .SYNOPSIS
        Devuelve la ruta de un informe que se puede abrir, o $null.

    .DESCRIPTION
        Guardia de seguridad. La interfaz abre informes con el programa
        predeterminado, y la ruta puede venir del historial (.json editable
        por el usuario o por cualquier proceso con sus permisos). Abrir un
        .lnk, .ps1 o ejecutable manipulado equivaldría a ejecutarlo.

        Se exigen las cuatro condiciones:
          1. La extensión es html, csv o json.
          2. La ruta canónica (absoluta, sin '..') está dentro de la carpeta
             de informes.
          3. Es un archivo que existe.
          4. No es un enlace ni un punto de reanálisis.

        Ante cualquier duda devuelve $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Ruta,
        [string] $CarpetaDatos = (Get-CarpetaDatos)
    )

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $null }

    $extension = [IO.Path]::GetExtension($Ruta)
    if ([string]::IsNullOrWhiteSpace($extension)) { return $null }
    if (@('.html', '.csv', '.json') -notcontains $extension.ToLowerInvariant()) { return $null }

    $carpeta = Get-CarpetaInformes -CarpetaDatos $CarpetaDatos

    try {
        $completa  = [IO.Path]::GetFullPath($Ruta)
        $baseLimpia = [IO.Path]::GetFullPath($carpeta).TrimEnd([IO.Path]::DirectorySeparatorChar)
    } catch {
        return $null
    }

    # El separador final evita que "...\informesFalsa" pase por estar
    # dentro de "...\informes".
    $prefijo = $baseLimpia + [IO.Path]::DirectorySeparatorChar
    if (-not $completa.StartsWith($prefijo, [StringComparison]::OrdinalIgnoreCase)) { return $null }

    $elemento = Get-Item -LiteralPath $completa -Force -ErrorAction SilentlyContinue
    if ($null -eq $elemento) { return $null }
    if ($elemento.PSIsContainer) { return $null }
    if (($elemento.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }

    return $completa
}
