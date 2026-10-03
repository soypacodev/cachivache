<#
.SYNOPSIS
    Vocabulario de programas instalados, leído del registro de Windows.

.DESCRIPTION
    Solo lectura: el programa nunca escribe en el registro.

    Lo usa 30-RestosProgramas para no proponer como huérfana la carpeta de
    un programa que sigue instalado. La resolución de ejecutables y accesos
    directos está en Ejecutables.ps1 (ver docs/ESTRUCTURA.md, sección 5.3).

    Los nombres se separan en dos conjuntos según la evidencia que aportan:

      FUERTES  Indican que un programa concreto está instalado: DisplayName
               de la lista de desinstalación, carpeta de InstallLocation y
               de Archivos de programa. Valen para coincidencia exacta y
               por prefijo.

      DEBILES  Indicios genéricos: servicios, procesos, paquetes de la
               Store, accesos directos, entradas de arranque y editores.
               Solo valen para coincidencia exacta.

    Comparar todo por subcadena con un único conjunto hacía que palabras
    genéricas ("games", "power", "launcher") marcaran como conocida casi
    cualquier carpeta, y los restos de juegos no se detectaban nunca.
#>

# Longitud mínima de un token para que se considere significativo; por
# debajo se responde "conocido". Con 3 entran nombres reales como "obs",
# "vlc" o "nvda".
$script:LongitudMinimaToken = 3

# Coincidencia por prefijo: longitud mínima y proporción mínima del nombre
# más largo. Con 0.7, "Adobe Acrobat" casa con "Adobe Acrobat DC" (12/14),
# pero "Discord" no casa con "Discord Canary" (7/13), que es otro programa.
$script:LongitudMinimaPrefijo = 6
$script:RatioMinimoPrefijo    = 0.7

function New-VocabularioInstalado {
    <#
    .SYNOPSIS
        Crea el contenedor vacío de los dos conjuntos de nombres.
    .DESCRIPTION
        IndicePrefijo agrupa los tokens fuertes por sus tres primeras letras
        para no recorrer el conjunto entero por cada carpeta. Es exacto: si
        un token es prefijo de otro y ambos superan la longitud mínima,
        comparten las tres primeras letras.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo compone un objeto en memoria: no toca el sistema.')]
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Fuertes       = [Collections.Generic.HashSet[string]]::new()
        Debiles       = [Collections.Generic.HashSet[string]]::new()
        IndicePrefijo = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new()
    }
}

function Add-TokenVocabulario {
    <#
    .SYNOPSIS
        Añade un nombre al vocabulario, como fuerte o como débil.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo modifica una estructura en memoria.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Vocabulario,
        [string] $Texto,
        [switch] $Fuerte
    )

    if ([string]::IsNullOrWhiteSpace($Texto)) { return }

    # Se guardan las formas con y sin versión ("Python 3.9" y "Python").
    # La variante se deriva del token para normalizar el texto una sola vez.
    $base = ConvertTo-Token $Texto
    foreach ($token in @($base, (Remove-SufijoVersion $base))) {
        if ($token.Length -lt $script:LongitudMinimaToken) { continue }

        if ($Fuerte) {
            [void]$Vocabulario.Fuertes.Add($token)

            if ($token.Length -ge $script:LongitudMinimaPrefijo) {
                $clave = $token.Substring(0, 3)
                if (-not $Vocabulario.IndicePrefijo.ContainsKey($clave)) {
                    $Vocabulario.IndicePrefijo[$clave] = [Collections.Generic.List[string]]::new()
                }
                if (-not $Vocabulario.IndicePrefijo[$clave].Contains($token)) {
                    $Vocabulario.IndicePrefijo[$clave].Add($token)
                }
            }
        } else {
            [void]$Vocabulario.Debiles.Add($token)
        }
    }
}

function Get-TokensProgramasInstalados {
    <#
    .SYNOPSIS
        Construye el vocabulario de lo instalado o en ejecución en el equipo.

    .DESCRIPTION
        Recoge nombres de varias fuentes, cada una como fuerte o débil según
        la evidencia que aporta (ver la cabecera del archivo).

        Cada fuente va en su propio try: todas son opcionales y algunas no
        existen en ciertos equipos (Get-AppxPackage en Server Core,
        Get-Service fuera de Windows). Un comando inexistente lanza
        CommandNotFoundException, que -ErrorAction SilentlyContinue no
        captura. Perder una fuente solo reduce el vocabulario; perderlas
        todas dejaría el módulo de restos sin funcionar.
    #>
    [CmdletBinding()]
    param($Sync = $null)

    $vocabulario = New-VocabularioInstalado

    # Ejecuta una fuente y anota el fallo sin propagarlo.
    $recolectar = {
        param([string] $Nombre, [scriptblock] $Accion)
        try { & $Accion } catch {
            Write-Verbose "No se ha podido leer la fuente '$Nombre': $($_.Exception.Message)"
        }
    }

    # 1. Programas desinstalables (32 y 64 bits, por máquina y por usuario).
    #    La clave WOW6432Node de HKCU es necesaria para los programas de 32
    #    bits instalados sin permisos de administrador.
    Set-Progreso $Sync 'Leyendo la lista de programas instalados...'
    & $recolectar 'programas instalados' {
        $clavesDesinstalacion = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($clave in $clavesDesinstalacion) {
            Get-ItemProperty -Path $clave -ErrorAction SilentlyContinue | ForEach-Object {
                Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.DisplayName -Fuerte
                if ($_.InstallLocation) {
                    Add-TokenVocabulario -Vocabulario $vocabulario `
                                         -Texto (Split-Path $_.InstallLocation -Leaf) -Fuerte
                }
                # El editor es débil: no dice nada de una carpeta suelta
                # con su nombre.
                Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.Publisher
            }
        }
    }

    # 2. Carpetas de Archivos de programa
    Set-Progreso $Sync 'Revisando Archivos de programa...'
    & $recolectar 'Archivos de programa' {
        foreach ($carpeta in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $carpeta) { continue }
            Get-ChildItem -LiteralPath $carpeta -Directory -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.Name -Fuerte }
        }
    }

    # 3. Procesos en ejecución
    & $recolectar 'procesos en ejecución' {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            # Dentro del catch, $_ es el error: se guarda antes el proceso.
            $proceso = $_
            Add-TokenVocabulario -Vocabulario $vocabulario -Texto $proceso.ProcessName
            # Company lee el FileVersionInfo del ejecutable y lanza en los
            # procesos protegidos del sistema.
            try {
                if ($proceso.Company) { Add-TokenVocabulario -Vocabulario $vocabulario -Texto $proceso.Company }
            } catch {
                Write-Verbose "Sin editor para el proceso $($proceso.ProcessName)."
            }
        }
    }

    # 4. Aplicaciones de la Store
    Set-Progreso $Sync 'Revisando aplicaciones de la Store...'
    & $recolectar 'aplicaciones de la Store' {
        Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object {
            Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.Name -Fuerte
            Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.Publisher
        }
    }

    # 5. Accesos directos del menú Inicio
    & $recolectar 'menu Inicio' {
        foreach ($menu in @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'))) {
            # Get-ElementosDelArbol admite rutas de más de 260 caracteres. Un
            # acceso directo sin leer haría que una carpeta legítima pareciera
            # desconocida y se propusiera para borrar.
            Get-ElementosDelArbol -Ruta $menu -Filtro '*.lnk' |
                ForEach-Object { Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.BaseName }
        }
    }

    # 6. Servicios
    & $recolectar 'servicios' {
        Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
            Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.DisplayName
            Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.Name
        }
    }

    # 7. Entradas de arranque
    & $recolectar 'entradas de arranque' {
        foreach ($clave in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
            $valores = Get-ItemProperty -Path $clave -ErrorAction SilentlyContinue
            if ($null -eq $valores) { continue }
            $valores.PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' } |
                ForEach-Object { Add-TokenVocabulario -Vocabulario $vocabulario -Texto $_.Name }
        }
    }

    return $vocabulario
}

function Test-TokenConocido {
    <#
    .SYNOPSIS
        Comprueba si un nombre de carpeta corresponde a algo instalado.

    .DESCRIPTION
        Tres reglas, en orden de coste creciente:

          1. Token demasiado corto -> conocido (ante la duda, no se propone).
          2. Coincidencia exacta en cualquiera de los dos conjuntos (O(1)).
          3. Coincidencia por prefijo, en ambas direcciones, solo contra los
             tokens fuertes con las mismas tres primeras letras, exigiendo
             que la parte común sea al menos el 70% del nombre más largo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Nombre,
        [Parameter(Mandatory)] $Vocabulario
    )

    $token = ConvertTo-Token $Nombre
    if ($token.Length -lt $script:LongitudMinimaToken) { return $true }

    # La variante sin versión se deriva del token ya normalizado.
    $variantes = @($token)
    $sinVersion = Remove-SufijoVersion $token
    if ($sinVersion -ne $token -and $sinVersion.Length -ge $script:LongitudMinimaToken) {
        $variantes += $sinVersion
    }

    # --- Regla 2: coincidencia exacta ---------------------------------
    foreach ($variante in $variantes) {
        if ($Vocabulario.Fuertes.Contains($variante)) { return $true }
        if ($Vocabulario.Debiles.Contains($variante)) { return $true }
    }

    # --- Regla 3: prefijo, solo contra tokens fuertes -----------------
    foreach ($variante in $variantes) {
        if ($variante.Length -lt $script:LongitudMinimaPrefijo) { continue }

        $clave = $variante.Substring(0, 3)
        if (-not $Vocabulario.IndicePrefijo.ContainsKey($clave)) { continue }

        foreach ($conocido in $Vocabulario.IndicePrefijo[$clave]) {
            $largo = if ($variante.Length -ge $conocido.Length) { $variante } else { $conocido }
            $corto = if ($variante.Length -ge $conocido.Length) { $conocido } else { $variante }

            if (-not $largo.StartsWith($corto, [StringComparison]::Ordinal)) { continue }
            if (($corto.Length / $largo.Length) -ge $script:RatioMinimoPrefijo) { return $true }
        }
    }

    return $false
}
