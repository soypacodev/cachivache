<#
.SYNOPSIS
    Formato de tamaños, tiempos y rutas para mostrar al usuario.
.DESCRIPTION
    Funciones puras, sin efectos secundarios. Se cargan tanto en el hilo
    de la interfaz como en los hilos de análisis.

    La normalización de texto para comparar identidad (Remove-Tildes,
    ConvertTo-Token) está en Texto.ps1, porque de ella depende la guardia
    de seguridad. Ver docs/ESTRUCTURA.md (sección 6).
#>

function ConvertTo-DoubleSeguro {
    <#
    .SYNOPSIS
        Convierte un valor a número, o devuelve 0 si no se puede.

    .DESCRIPTION
        Para campos leídos de archivos JSON en disco, que pueden estar
        editados a mano, venir de otra versión o tener una forma inesperada.
        "[double]$entrada.Bytes" lanza ante un array; esta función devuelve
        0, de modo que un dato corrupto no impide abrir el programa.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param($Valor)

    if ($null -eq $Valor) { return 0.0 }

    # Un array devuelve 0 (no se suma ni se toma el primero). En PowerShell 7
    # [double] ya lanza con arrays, pero se comprueba explícitamente para no
    # depender de que 5.1 se comporte igual.
    if ($Valor -is [System.Collections.IEnumerable] -and $Valor -isnot [string]) { return 0.0 }

    try {
        return [double]$Valor
    } catch {
        return 0.0
    }
}

function ConvertTo-RutaAnonima {
    <#
    .SYNOPSIS
        Sustituye los datos que identifican al equipo y a su usuario por
        marcadores, dejando la ruta legible.

    .DESCRIPTION
        Permite compartir informes y registros (como pide SECURITY.md para
        reportar fallos) sin publicar el nombre de usuario de Windows ni el
        del equipo.

        Se sustituye de lo más específico a lo más general (el perfil antes
        que el nombre suelto) para que "C:\Users\ana\ana.txt" no quede como
        "C:\Users\<usuario>\<usuario>.txt". El nombre suelto solo se
        sustituye como segmento de ruta completo: con el usuario "ana", la
        carpeta "Semana" no se altera.

        No detecta otros datos identificativos (nombres de proyecto, de
        cliente o de archivo); por eso SECURITY.md pide revisar el informe
        antes de publicarlo.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Transforma una cadena: no toca el sistema.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Texto)

    if ([string]::IsNullOrEmpty($Texto)) { return $Texto }
    $resultado = $Texto

    # 1. El perfil completo (la coincidencia más larga), con y sin barra final.
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $perfil = $env:USERPROFILE.TrimEnd('\')
        $resultado = $resultado -replace [regex]::Escape($perfil), '<perfil>'
    }

    # 2. El nombre de usuario suelto, solo como segmento de ruta. (?m) y \r?$
    #    para textos de varias líneas, como el diagnóstico.
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and $env:USERNAME.Length -ge 2) {
        $resultado = $resultado -replace
            ('(?im)(?<=[\\/])' + [regex]::Escape($env:USERNAME) + '(?=[\\/]|\r?$)'), '<usuario>'
    }

    # 3. El nombre del equipo, aparezca donde aparezca.
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $env:COMPUTERNAME.Length -ge 2) {
        $resultado = $resultado -replace ('(?i)' + [regex]::Escape($env:COMPUTERNAME)), '<equipo>'
    }

    return $resultado
}

function Format-Tamano {
    <#
    .SYNOPSIS
        Convierte bytes en un texto legible (KB, MB, GB, TB).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [double] $Bytes
    )
    process {
        if ($Bytes -lt 0) { $Bytes = 0 }
        if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
        if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
        return ('{0:N0} B' -f $Bytes)
    }
}

function ConvertFrom-NumeroLocal {
    <#
    .SYNOPSIS
        Interpreta un número de texto sin asumir el idioma de Windows.
    .DESCRIPTION
        Herramientas como vssadmin o DISM usan el separador decimal del
        idioma del sistema (coma en español, punto en inglés), así que
        "15.5 GB" no puede interpretarse con una regla fija.

        Regla: si aparecen los dos separadores, el último es el decimal.
        Si solo aparece uno, se mira el grupo final: 1-2 dígitos es
        decimal; exactamente 3 (o más de un grupo) es separador de miles.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([string] $Texto)

    $limpio = if ($null -ne $Texto) { $Texto.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($limpio)) { return 0.0 }

    $tienePunto = $limpio.Contains('.')
    $tieneComa  = $limpio.Contains(',')
    $normalizado = $limpio

    if ($tienePunto -and $tieneComa) {
        # El separador que aparece más a la derecha es el decimal.
        if ($limpio.LastIndexOf('.') -gt $limpio.LastIndexOf(',')) {
            $normalizado = $limpio.Replace(',', '')
        } else {
            $normalizado = $limpio.Replace('.', '').Replace(',', '.')
        }
    } elseif ($tienePunto -or $tieneComa) {
        $separador = if ($tienePunto) { '.' } else { ',' }
        $partes = $limpio.Split($separador)
        $esDecimal = $partes.Count -eq 2 -and $partes[-1].Length -le 2
        $normalizado = if ($esDecimal) {
            $limpio.Replace($separador, '.')
        } else {
            $limpio.Replace($separador, '')
        }
    }

    $resultado = 0.0
    [void][double]::TryParse(
        $normalizado,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref] $resultado)
    return $resultado
}

function ConvertTo-BytesConUnidad {
    <#
    .SYNOPSIS
        Convierte un número y una unidad de texto (KB/MB/GB/TB) a bytes.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [double] $Numero,
        [string] $Unidad
    )
    switch ($Unidad.ToUpperInvariant()) {
        'KB' { return $Numero * 1KB }
        'MB' { return $Numero * 1MB }
        'GB' { return $Numero * 1GB }
        'TB' { return $Numero * 1TB }
        default { return 0.0 }
    }
}


function Get-RutaCorta {
    <#
    .SYNOPSIS
        Acorta una ruta sustituyendo el perfil del usuario por "~".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return '' }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $Ruta }
    return ($Ruta -replace [regex]::Escape($env:USERPROFILE), '~')
}

function Get-RutaElidida {
    <#
    .SYNOPSIS
        Recorta una ruta por el centro para que quepa en la interfaz.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Ruta,
        [int]    $Maximo = 70
    )

    $corta = Get-RutaCorta $Ruta
    if ($corta.Length -le $Maximo) { return $corta }

    $mitad = [Math]::Floor(($Maximo - 3) / 2)
    return $corta.Substring(0, $mitad) + '...' + $corta.Substring($corta.Length - $mitad)
}

function Format-Duracion {
    <#
    .SYNOPSIS
        Convierte un TimeSpan en un texto breve en castellano.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([TimeSpan] $Duracion)

    if ($Duracion.TotalSeconds -lt 1)  { return 'menos de 1 s' }
    if ($Duracion.TotalSeconds -lt 60) { return ('{0:N0} s' -f $Duracion.TotalSeconds) }
    if ($Duracion.TotalMinutes -lt 60) {
        return ('{0:N0} min {1:N0} s' -f [Math]::Floor($Duracion.TotalMinutes), $Duracion.Seconds)
    }
    return ('{0:N0} h {1:N0} min' -f [Math]::Floor($Duracion.TotalHours), $Duracion.Minutes)
}

function Format-ProgresoAnalisis {
    <#
    .SYNOPSIS
        Línea de estado durante el análisis: qué se está haciendo, cuánto
        tiempo lleva y cuánto se ha encontrado.

    .DESCRIPTION
        La barra de progreso solo avanza al terminar cada módulo, y un
        módulo largo puede parecer un cuelgue. Por eso la línea incluye dos
        datos que cambian: el tiempo transcurrido (siempre) y el número de
        elementos encontrados.

        Es una función pura para poder probarla sin el temporizador de WPF.

    .PARAMETER Modulo
        Nombre del módulo en curso. Su contador va pegado ("Duplicados
        (8 de 21)") y separado del mensaje, que puede traer su propia cuenta.
    .PARAMETER Mensaje
        Lo que el módulo indica que está haciendo.
    .PARAMETER Indice
        Número del módulo en curso, empezando en 1.
    .PARAMETER Transcurrido
        Tiempo desde el inicio del análisis completo, no del módulo.
    .PARAMETER Elementos
        Encontrados hasta ahora, sumando todos los módulos.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]   $Modulo  = '',
        [string]   $Mensaje = '',
        [int]      $Indice  = 0,
        [int]      $Total   = 0,
        [TimeSpan] $Transcurrido = [TimeSpan]::Zero,
        [int]      $Elementos = 0
    )

    $partes = [Collections.Generic.List[string]]::new()

    $cabeza = if ([string]::IsNullOrWhiteSpace($Modulo)) { 'Analizando' } else { $Modulo }
    if ($Total -gt 0) { $cabeza = '{0} ({1} de {2})' -f $cabeza, $Indice, $Total }
    $partes.Add($cabeza)

    # El mensaje se omite si coincide con el nombre del módulo (ocurre al
    # arrancar cada uno).
    if (-not [string]::IsNullOrWhiteSpace($Mensaje) -and $Mensaje -ne $Modulo) {
        $partes.Add($Mensaje)
    }

    # El tiempo se muestra a partir del primer segundo para evitar parpadeo.
    if ($Transcurrido.TotalSeconds -ge 1) { $partes.Add((Format-Duracion $Transcurrido)) }

    if ($Elementos -gt 0) {
        $partes.Add(('{0} {1}' -f $Elementos, $(if ($Elementos -eq 1) { 'elemento' } else { 'elementos' })))
    }

    return ($partes -join '  ·  ')
}

function Format-Antiguedad {
    <#
    .SYNOPSIS
        Describe cuánto hace que se modificó algo por última vez.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([datetime] $Fecha)

    if ($Fecha -le [datetime]'1900-01-02') { return 'fecha desconocida' }
    $dias = [int]((Get-Date) - $Fecha).TotalDays
    if ($dias -le 0)   { return 'hoy' }
    if ($dias -eq 1)   { return 'ayer' }
    if ($dias -lt 30)  { return "hace $dias días" }
    if ($dias -lt 365) {
        # Singular explícito para evitar "hace 1 meses".
        $meses = [int][Math]::Floor($dias / 30)
        if ($meses -eq 1) { return 'hace un mes' }
        return ('hace {0} meses' -f $meses)
    }
    $anios = [Math]::Floor($dias / 365)
    if ($anios -eq 1) { return 'hace más de 1 año' }
    return "hace más de $anios años"
}

function Format-ResumenSimulacion {
    <#
    .SYNOPSIS
        Resumen de la simulación que se muestra en el panel de Resultados.

    .DESCRIPTION
        Sin este resumen, la simulación solo dejaba constancia en el panel
        de Registro y desde Resultados parecía que el botón no hacía nada.

        El texto indica que era una simulación, cuánto se habría liberado,
        qué hacer a continuación y, si los hay, cuántos elementos no se
        habrían podido borrar (para no prometer un espacio que no se
        liberaría).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int]    $Simulados,
        [Parameter(Mandatory)] [double] $Liberado,
        [int] $Bloqueados = 0
    )

    if ($Simulados -le 0) {
        return ('Simulación terminada: no había nada que borrar. ' +
                'No se ha borrado nada, porque no se ha tocado nada.')
    }

    $elementos = if ($Simulados -eq 1) { '1 elemento' } else { '{0} elementos' -f $Simulados }

    # ::new() y no New-Object: con New-Object, @() no recorre bien la lista
    # resultante. Hay una invariante que lo comprueba.
    $lineas = [System.Collections.Generic.List[string]]::new()

    # Se compone en una variable antes de .Add(): dentro de los paréntesis
    # del método, la coma de '-f' se interpreta como separador de argumentos.
    $primera = ('Esto era una simulación: NO se ha borrado nada. ' +
                'Se habrían eliminado {0} y liberado {1}.') -f $elementos, (Format-Tamano $Liberado)
    [void]$lineas.Add($primera)

    if ($Bloqueados -gt 0) {
        $cuantos = if ($Bloqueados -eq 1) { '1 no se habría borrado' } else { '{0} no se habrían borrado' -f $Bloqueados }
        $aviso = 'De esos, {0}: el detalle está en Registro, en las líneas [BLOQUEADO].' -f $cuantos
        [void]$lineas.Add($aviso)
    }

    [void]$lineas.Add('Lo marcado sigue marcado. Para hacerlo de verdad, quita "Solo simular" y vuelve a pulsar.')

    return ($lineas -join ' ')
}
