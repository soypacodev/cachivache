<#
.SYNOPSIS
    Preferencias del usuario, persistidas entre sesiones.

.DESCRIPTION
    Un archivo JSON en la carpeta de datos con lo que el usuario eligió la
    última vez: tema, perfil, umbrales, módulos activos y exclusiones.

    Config.ps1 describe el equipo y se recalcula en cada arranque; esto
    describe al usuario, persiste y puede haberse editado a mano, por lo
    que se valida al leerlo.
#>

function Get-RutaPreferencias {
    [OutputType([string])]
    param()
    return (Join-Path (Get-CarpetaDatos) 'preferencias.json')
}

function Save-CopiaArchivoIlegible {
    <#
    .SYNOPSIS
        Copia un archivo de datos que no se puede interpretar junto al
        original, con la extensión .corrupto, antes de que se sobrescriba.
    .DESCRIPTION
        Si ya hay una copia anterior no se pisa: la nueva lleva la fecha.
        Devuelve la ruta de la copia, o $null si no se ha podido hacer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Ruta)

    $copia = "$Ruta.corrupto"
    if (Test-Path -LiteralPath $copia) {
        $copia = '{0}.corrupto-{1}' -f $Ruta, (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    try {
        Copy-Item -LiteralPath $Ruta -Destination $copia -ErrorAction Stop
        return $copia
    } catch {
        Write-Verbose "No se ha podido copiar $Ruta : $($_.Exception.Message)"
        return $null
    }
}

function Write-AvisoArchivoIlegible {
    <#
    .SYNOPSIS
        Anota en el registro (si está cargado) que un archivo de datos no se
        ha podido leer.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Mensaje)

    Write-Verbose $Mensaje
    if (Get-Command Write-Registro -ErrorAction SilentlyContinue) {
        try { Write-Registro -Nivel 'AVISO' -Mensaje $Mensaje } catch { Write-Verbose $_.Exception.Message }
    }
}

function Get-TemaDeWindows {
    <#
    .SYNOPSIS
        Tema de aplicaciones de Windows: 'claro' u 'oscuro'.

    .DESCRIPTION
        Solo se usa mientras no haya preferencia guardada; la elección del
        usuario tiene prioridad.

        Lee AppsUseLightTheme (tema de aplicaciones), no
        SystemUsesLightTheme (barra de tareas): 0 = oscuro, 1 = claro. Si no
        existe (Windows anterior a 1809) o no se puede leer, devuelve 'oscuro'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $clave = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $valor = (Get-ItemProperty -Path $clave -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ([int]$valor -eq 1) { return 'claro' }
        return 'oscuro'
    } catch {
        return 'oscuro'
    }
}

function Import-Preferencias {
    <#
    .SYNOPSIS
        Lee las preferencias guardadas de la sesión anterior.
    .DESCRIPTION
        Sin archivo (primer arranque) devuelve los valores por defecto, con
        el tema de Windows. Los valores inválidos se sustituyen por el
        valor por defecto.
    #>
    [CmdletBinding()]
    param()

    $ruta = Get-RutaPreferencias
    $valoresPorDefecto = @{
        Tema            = (Get-TemaDeWindows)
        Perfil          = 'equilibrado'
        DiasSinUso      = 180
        MinimoMB        = 10
        IncluirMenores  = $false
        Permanente      = $false
        ModulosActivos  = @()
        # Se guardan las unidades desmarcadas, no las marcadas: un disco
        # nuevo entra marcado por defecto.
        UnidadesExcluidas = @()
        # Elementos que el usuario ha excluido para siempre. Además de rutas
        # contiene claves "modulo:<Id>|<Nombre>" para elementos sin ruta.
        # No renombrar sin migración: con otro nombre, los archivos
        # existentes perderían todas sus exclusiones sin aviso.
        RutasExcluidas    = @()

        # "Simular" no se guarda a propósito: es una comprobación previa a
        # un acto concreto, no una preferencia. Recordada entre sesiones,
        # el usuario podría creer que ha limpiado cuando solo ha simulado.
    }

    if (-not (Test-Path -LiteralPath $ruta)) { return $valoresPorDefecto }

    # Forma y límites de cada preferencia. El archivo es editable a mano:
    # un valor que no encaja se sustituye por el de por defecto (con
    # Write-Verbose) en lugar de impedir el arranque.
    $reglas = @{
        Tema              = @{ Tipo = 'opcion'; Opciones = @('claro', 'oscuro') }
        Perfil            = @{ Tipo = 'opcion'; Opciones = @('conservador', 'equilibrado', 'agresivo', 'personalizado') }
        # Mismos rangos que los deslizadores de MainWindow.xaml; si
        # divergen, WPF recorta el valor y deja de coincidir con lo guardado.
        DiasSinUso        = @{ Tipo = 'entero'; Minimo = 30; Maximo = 730 }
        MinimoMB          = @{ Tipo = 'entero'; Minimo = 1;  Maximo = 500 }
        IncluirMenores    = @{ Tipo = 'bool' }
        Permanente        = @{ Tipo = 'bool' }
        ModulosActivos    = @{ Tipo = 'textos' }
        UnidadesExcluidas = @{ Tipo = 'textos' }
        RutasExcluidas    = @{ Tipo = 'textos' }
    }

    # Un archivo que no se puede interpretar se copia aparte antes de
    # devolver los valores por defecto: al cerrar se guardarían encima y
    # se perderían las exclusiones sin aviso.
    $guardado = $null
    try {
        $texto = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($texto)) { return $valoresPorDefecto }
        $guardado = ConvertFrom-Json -InputObject $texto -ErrorAction Stop
        # [pscustomobject] es PSObject y casaría también con un número envuelto.
        if ($guardado -isnot [System.Management.Automation.PSCustomObject]) { throw 'El contenido no es un objeto JSON.' }
    } catch {
        $motivo = $_.Exception.Message
        if (Test-Path -LiteralPath $ruta -PathType Leaf) {
            $copia = Save-CopiaArchivoIlegible -Ruta $ruta
            $aviso = if ($copia) {
                "Las preferencias no se han podido leer ($motivo). Se usan los valores por defecto; el archivo original se ha guardado en $copia."
            } else {
                "Las preferencias no se han podido leer ($motivo). Se usan los valores por defecto y no se ha podido guardar una copia del archivo."
            }
            Write-AvisoArchivoIlegible -Mensaje $aviso
        } else {
            Write-Verbose "No se han podido leer las preferencias: $motivo"
        }
        return $valoresPorDefecto
    }

    try {
        foreach ($clave in @($valoresPorDefecto.Keys)) {
            $propiedad = $guardado.PSObject.Properties[$clave]
            if ($null -eq $propiedad) { continue }

            $bruto = $propiedad.Value
            $regla = $reglas[$clave]
            $valido = $true

            switch ($regla.Tipo) {
                'opcion' {
                    $texto = [string]$bruto
                    if ($regla.Opciones -contains $texto) { $valoresPorDefecto[$clave] = $texto }
                    else { $valido = $false }
                }
                'entero' {
                    $numero = ConvertTo-DoubleSeguro $bruto
                    # ConvertTo-DoubleSeguro devuelve 0 si no puede convertir;
                    # ningún rango admite el cero.
                    if ($numero -ge $regla.Minimo -and $numero -le $regla.Maximo) {
                        $valoresPorDefecto[$clave] = [int]$numero
                    } else { $valido = $false }
                }
                'bool' {
                    if ($bruto -is [bool]) { $valoresPorDefecto[$clave] = [bool]$bruto }
                    else { $valido = $false }
                }
                'textos' {
                    # Solo se aceptan cadenas no vacías, elemento a elemento.
                    $valoresPorDefecto[$clave] = @(@($bruto) |
                        Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { [string]$_ })
                }
            }

            if (-not $valido) {
                Write-Verbose ("La preferencia '{0}' del archivo no es valida; se usa el valor por defecto." -f $clave)
            }
        }
    } catch {
        Write-Verbose "No se han podido leer las preferencias: $($_.Exception.Message)"
    }
    return $valoresPorDefecto
}

function Export-Preferencias {
    <#
    .SYNOPSIS
        Guarda las preferencias para la próxima sesión.
    .DESCRIPTION
        Devuelve $true solo si las preferencias se han escrito en disco;
        el llamante debe comprobarlo.

        -ErrorAction Stop es necesario: Set-Content falla de forma no
        terminante (carpeta inexistente, permisos, disco lleno) y sin él
        el catch no se ejecutaría. Una invariante lo exige en todo src/.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [hashtable] $Preferencias)

    $ruta = Get-RutaPreferencias
    if (-not $PSCmdlet.ShouldProcess($ruta, 'Guardar preferencias')) { return $false }
    # Temporal en la misma carpeta y reemplazo atómico: un corte a mitad no
    # deja un JSON truncado, que al leerlo perdería todas las exclusiones.
    # El PID evita que dos procesos compartan el temporal; si queda
    # huérfano no se borra aquí (en src/Core solo Remove.ps1 borra).
    $temporal = "$ruta.$PID.tmp"
    try {
        $Preferencias | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $temporal -Encoding UTF8 -ErrorAction Stop
        Move-ArchivoReemplazando -Origen $temporal -Destino $ruta -Confirm:$false
        return $true
    } catch {
        Write-Verbose "No se han podido guardar las preferencias: $($_.Exception.Message)"
        return $false
    }
}
