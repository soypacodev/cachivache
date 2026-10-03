<#
.SYNOPSIS
    Configuración del equipo: se descubre en cada arranque, no se guarda.

.DESCRIPTION
    Unidades, carpetas conocidas del usuario, permisos de administrador y
    los umbrales que aplica el perfil elegido.

    Las preferencias persistentes del usuario están en Preferencias.ps1.
#>

function Test-EsAdministrador {
    <#
    .SYNOPSIS
        Indica si el proceso actual tiene permisos de administrador.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identidad)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-CarpetaDatos {
    <#
    .SYNOPSIS
        Carpeta donde el programa guarda registros, informes e historial.
    .DESCRIPTION
        Se usa LOCALAPPDATA y no la carpeta del programa para que este
        funcione en solo lectura y no mezcle datos generados con el código.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
    # Puede no existir ninguna de las dos variables (un servicio sin
    # LOCALAPPDATA, PowerShell en Linux sin TEMP); GetTempPath() siempre
    # devuelve una ruta.
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [IO.Path]::GetTempPath() }
    $carpeta = Join-Path $base 'Cachivache'

    foreach ($sub in @('', 'informes', 'registros')) {
        $ruta = if ($sub) { Join-Path $carpeta $sub } else { $carpeta }
        if (-not (Test-Path -LiteralPath $ruta)) {
            New-Item -ItemType Directory -Path $ruta -Force | Out-Null
        }
    }
    return $carpeta
}


function New-Configuracion {
    <#
    .SYNOPSIS
        Descubre las carpetas del equipo y compone el objeto de configuración.
    .DESCRIPTION
        El resultado se pasa a todos los módulos y a la guardia. No contiene
        rutas fijas: todo se resuelve en ejecución para funcionar en
        cualquier equipo y con Windows en cualquier idioma.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Lee el entorno y devuelve un objeto: no modifica nada.')]
    [CmdletBinding()]
    param(
        [string] $Perfil = 'equilibrado'
    )

    $carpetaDatos = Get-CarpetaDatos

    $configuracion = [pscustomobject]@{
        # --- Carpetas del usuario ---------------------------------------
        Escritorio   = Get-CarpetaConocida 'Desktop'
        Documentos   = Get-CarpetaConocida 'Documents'
        Descargas    = Get-CarpetaConocida 'Downloads'
        Imagenes     = Get-CarpetaConocida 'Pictures'
        Musica       = Get-CarpetaConocida 'Music'
        Videos       = Get-CarpetaConocida 'Videos'
        CarpetaDatos = $carpetaDatos

        # --- Entorno -----------------------------------------------------
        Unidad       = $env:SystemDrive
        Admin        = Test-EsAdministrador
        Equipo       = $env:COMPUTERNAME
        # Get-DescripcionSistema guarda en caché la consulta CIM, que
        # también usa la cabecera del registro.
        Windows      = Get-DescripcionSistema

        # --- Umbrales (los sobreescribe el perfil) -----------------------
        Perfil          = $Perfil
        DiasSinUso      = 180
        MinimoMB        = 10
        IncluirMenores  = $false
        Permanente      = $false
        # Simular no se guarda en las preferencias (ver Preferencias.ps1):
        # solo dura la sesión.
        Simular         = $false
        MinimoDuplicadoMB     = 5
        MinimoGrandeMB        = 250

        # --- Rellenados justo después ------------------------------------
        ZonasUsuario    = @()
        RaicesProyecto  = @()
        Unidades        = @()
        # Letras de las unidades que el usuario quiere analizar. Vacío
        # significa "todas": ver Test-UnidadSeleccionada.
        UnidadesSeleccionadas = @()
        # Carpetas excluidas por el usuario; vienen de las preferencias.
        RutasExcluidas        = @()
    }

    # El @() exterior es imprescindible: si queda una sola ruta, sin él se
    # asignaría una cadena en vez de un array y "ZonasUsuario + @(...)"
    # concatenaría texto.
    $configuracion.ZonasUsuario = @(Select-RutasNoAnidadas (@(
        $configuracion.Escritorio, $configuracion.Documentos, $configuracion.Descargas,
        $configuracion.Imagenes, $configuracion.Musica, $configuracion.Videos,
        (Join-Path $env:USERPROFILE 'OneDrive')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique))

    $configuracion.RaicesProyecto = @(@(
        $configuracion.Escritorio, $configuracion.Documentos,
        (Join-Path $env:USERPROFILE 'source'),
        (Join-Path $env:USERPROFILE 'repos'),
        (Join-Path $env:USERPROFILE 'dev'),
        (Join-Path $env:USERPROFILE 'Proyectos'),
        (Join-Path $env:USERPROFILE 'Projects')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)

    $configuracion.Unidades = @(Get-UnidadesAnalizables)
    # Por defecto, todas las unidades. ModuleRegistry.ps1 descarta los
    # candidatos fuera de esta lista (ver Test-UnidadSeleccionada).
    $configuracion.UnidadesSeleccionadas = @($configuracion.Unidades | ForEach-Object { $_.Letra })

    return (Set-PerfilConfiguracion -Configuracion $configuracion -Perfil $Perfil)
}

