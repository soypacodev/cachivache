<#
.SYNOPSIS
    Modo consola: analiza y limpia sin abrir ninguna ventana.

.DESCRIPTION
    Pensado para automatizar. Por defecto solo analiza: para borrar hay que
    pasar -Ejecutar, y aun así solo se tocan los elementos que el análisis
    marcó por su cuenta (riesgo bajo y sin avisos).
#>

function Write-Linea {
    param(
        [string] $Texto = '',
        [ValidateSet('normal', 'titulo', 'ok', 'aviso', 'error', 'tenue')]
        [string] $Estilo = 'normal'
    )
    switch ($Estilo) {
        'titulo' { Write-Host $Texto -ForegroundColor Cyan }
        'ok'     { Write-Host $Texto -ForegroundColor Green }
        'aviso'  { Write-Host $Texto -ForegroundColor Yellow }
        'error'  { Write-Host $Texto -ForegroundColor Red }
        'tenue'  { Write-Host $Texto -ForegroundColor DarkGray }
        default  { Write-Host $Texto }
    }
}

function Write-Cabecera {
    param([string] $Texto)
    Write-Linea ''
    Write-Linea ('  ' + $Texto) 'titulo'
    Write-Linea ('  ' + ('-' * $Texto.Length)) 'tenue'
}

# ---------------------------------------------------------------------
#  Aviso de avance del borrado
# ---------------------------------------------------------------------
# No usar .GetNewClosure(): ejecuta el bloque en un módulo dinámico que
# solo resuelve funciones del módulo y del ámbito global, y el núcleo se
# carga en el ámbito de script (Invoke-VaciarColaRegistro no se encontraría).
# Por eso las variables que necesita van en $script: y las fija
# Invoke-CachivacheCli antes del lote.
$script:CliSilencioso = $false
$script:CliSync       = $null

$script:MostrarAvanceBorrado = {
    param($candidato, $avance)
    [void](Invoke-VaciarColaRegistro -Sync $script:CliSync)
    if (-not $script:CliSilencioso) {
        $marca  = if ($candidato.Error) { '!' } else { '+' }
        $estilo = if ($candidato.Error) { 'aviso' } else { 'normal' }
        Write-Linea ('  {0} {1,-52} {2,10}' -f $marca,
                     (Get-RutaElidida $candidato.Nombre 52),
                     (Format-Tamano $candidato.BytesLiberados)) $estilo
    }
}

function Invoke-CachivacheCli {
    <#
    .SYNOPSIS
        Punto de entrada del modo consola.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] $Configuracion,
        [Parameter(Mandatory)] $Modulos,
        [string[]] $Ids       = @(),
        [switch]   $Ejecutar,
        [string]   $Informe   = '',
        # Sustituye perfil, usuario y equipo por marcadores en el informe.
        [switch]   $InformeAnonimo,
        # Muestra lo que se borraría sin borrarlo.
        [switch]   $Simular,
        [switch]   $Silencioso
    )

    if (-not $Silencioso) {
        Write-Linea ''
        Write-Linea "  Cachivache v$script:VersionCachivache" 'titulo'
        Write-Linea "  $($Configuracion.Equipo) - perfil $($Configuracion.Perfil) - $(if ($Configuracion.Admin) { 'administrador' } else { 'modo estándar' })" 'tenue'
    }

    # Sin -Sync: la cabecera se escribe al momento. Los módulos sí reciben
    # la tabla sincronizada y su cola se vacía después de cada uno.
    Write-CabeceraSesion -Perfil $Configuracion.Perfil -Admin $Configuracion.Admin

    # --- Selección de módulos --------------------------------------------
    $seleccionados = if ($Ids.Count -gt 0) {
        @($Modulos | Where-Object { $Ids -contains $_.Id })
    } else {
        @($Modulos | Where-Object { Test-ModuloEnPerfil -Modulo $_ -Perfil $Configuracion.Perfil })
    }
    $seleccionados = @($seleccionados | Where-Object { -not ($_.RequiereAdmin -and -not $Configuracion.Admin) })

    if ($seleccionados.Count -eq 0) {
        if (-not $Silencioso) { Write-Linea '  No hay ningún módulo que ejecutar con esta configuración.' 'aviso' }
        return 1
    }

    # --- Análisis ---------------------------------------------------------
    if (-not $Silencioso) { Write-Cabecera 'Análisis' }

    $todos = [Collections.Generic.List[object]]::new()
    $sync  = New-EstadoSincronizado
    $cronometro = [Diagnostics.Stopwatch]::StartNew()

    # Módulos que no han dado resultado. La ventana los muestra en una
    # franja; la consola debe informar de lo mismo.
    $fallidos = [Collections.Generic.List[string]]::new()

    foreach ($modulo in $seleccionados) {
        if (-not $Silencioso) { Write-Host ('  {0,-42}' -f $modulo.Nombre) -NoNewline }

        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $Configuracion -Sync $sync

        if ($resultado.Omitido) {
            if (-not $Silencioso) { Write-Linea ('omitido: ' + $resultado.Omitido) 'tenue' }
            continue
        }
        if ($resultado.Error) {
            if (-not $Silencioso) { Write-Linea ('error: ' + $resultado.Error) 'error' }
            Write-Registro -Mensaje "$($modulo.Id): $($resultado.Error)" -Nivel 'ERROR'
            $fallidos.Add([string]$modulo.Nombre)
            continue
        }

        $suma = 0.0
        foreach ($candidato in $resultado.Candidatos) {
            $suma += $candidato.Bytes
            $todos.Add($candidato)
        }
        if (-not $Silencioso) {
            if ($resultado.Candidatos.Count -eq 0) { Write-Linea 'nada' 'tenue' }
            else { Write-Linea ('{0,4} elementos   {1,10}' -f $resultado.Candidatos.Count, (Format-Tamano $suma)) 'ok' }
        }

        # Con $sync, lo que registre un módulo queda encolado. En la ventana
        # lo vacía un temporizador; en consola hay que hacerlo aquí o se pierde.
        [void](Invoke-VaciarColaRegistro -Sync $sync)
    }
    $cronometro.Stop()

    $borrables = @($todos | Where-Object { $_.Metodo -ne 'Informativo' })
    $marcados  = @($borrables | Where-Object { $_.Seleccionado })
    $bytesMarcados = 0.0
    foreach ($candidato in $marcados) { $bytesMarcados += $candidato.Bytes }
    $bytesTotales = 0.0
    foreach ($candidato in $borrables) { $bytesTotales += $candidato.Bytes }

    if (-not $Silencioso) {
        Write-Cabecera 'Resumen'
        # Se desglosan los informativos para que la cuenta cuadre con
        # "Recuperable total", que solo suma los borrables.
        $informativos = $todos.Count - $borrables.Count
        Write-Linea ('  Elementos encontrados : {0} ({1} recuperables, {2} solo informativos)' -f `
                     $todos.Count, $borrables.Count, $informativos)
        Write-Linea ('  Recuperable total     : {0}' -f (Format-Tamano $bytesTotales))
        Write-Linea ('  Marcado por defecto   : {0} elementos, {1}' -f $marcados.Count, (Format-Tamano $bytesMarcados))
        # Explica el criterio del premarcado con la misma frase que la ventana.
        $criterio = Get-ResumenPremarcado -Candidatos $borrables
        if ($criterio) { Write-Linea ('                          {0}' -f $criterio) 'tenue' }
        Write-Linea ('  Tiempo de análisis    : {0}' -f (Format-Duracion $cronometro.Elapsed))
        Write-Linea ('  Libre en {0}           : {1}' -f $Configuracion.Unidad, (Format-Tamano (Get-EspacioLibre $Configuracion.Unidad)))

        # El aviso va después de las cifras para que no quede tapado por la tabla.
        if ($fallidos.Count -gt 0) {
            Write-Linea ''
            Write-Linea ('  ATENCIÓN: esta lista está incompleta. {0} no se {1} podido completar: {2}.' -f `
                         $(if ($fallidos.Count -eq 1) { '1 módulo' } else { '{0} módulos' -f $fallidos.Count }),
                         $(if ($fallidos.Count -eq 1) { 'ha' } else { 'han' }),
                         (@($fallidos) -join ', ')) 'error'
            Write-Linea '  Puede haber basura que no aparece aquí. El detalle está en el registro.' 'error'
        }
    }

    # --- Informe ----------------------------------------------------------
    # Antes del historial, para anotar en la entrada la ruta del informe.
    $rutaInforme = ''
    if ($Informe) {
        $extension = [IO.Path]::GetExtension($Informe).TrimStart('.').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($extension)) { $extension = 'html'; $Informe = "$Informe.html" }
        try {
            switch ($extension) {
                'csv'  { Export-InformeCsv  -Candidatos $todos -Ruta $Informe -Anonimo:$InformeAnonimo -Confirm:$false }
                'json' { Export-InformeJson -Candidatos $todos -Ruta $Informe -Configuracion $Configuracion -Anonimo:$InformeAnonimo -Confirm:$false }
                default { Export-InformeHtml -Candidatos $todos -Ruta $Informe -Configuracion $Configuracion -Modulos $Modulos -Anonimo:$InformeAnonimo -Confirm:$false }
            }
            if (-not $Silencioso) { Write-Linea ('  Informe guardado en {0}' -f $Informe) 'ok' }

            # La ruta de -Informe puede estar en cualquier sitio; solo se
            # anota si cae en la carpeta de informes, la única que la
            # ventana acepta abrir después.
            $rutaInforme = [string](Resolve-InformeAbrible -Ruta $Informe -CarpetaDatos $Configuracion.CarpetaDatos)
        } catch {
            if (-not $Silencioso) { Write-Linea ('  No se ha podido guardar el informe: {0}' -f $_.Exception.Message) 'error' }
            Write-Registro -Mensaje "No se ha podido guardar el informe '$Informe': $($_.Exception.Message)" -Nivel 'ERROR'
        }
    }

    # -Modulos recoge solo los que dieron resultado, no los que fallaron.
    $idsFallidos = @($seleccionados | Where-Object { $fallidos -contains $_.Nombre } | ForEach-Object { $_.Id })
    Add-EntradaHistorial -Tipo 'analisis' -Elementos $todos.Count -Bytes $bytesTotales `
                         -Perfil $Configuracion.Perfil `
                         -Modulos @($seleccionados | Where-Object { $_.Id -notin $idsFallidos } | ForEach-Object { $_.Id }) `
                         -Informe $rutaInforme `
                         -Incompleto:($fallidos.Count -gt 0) `
                         -Motivo $(if ($fallidos.Count -gt 0) {
                                      'No se pudieron completar: {0}.' -f ((@($fallidos)) -join ', ')
                                   } else { '' }) `
                         -CarpetaDatos $Configuracion.CarpetaDatos -Confirm:$false

    # --- Eliminación ------------------------------------------------------
    if (-not $Ejecutar) {
        if (-not $Silencioso) {
            Write-Linea ''
            Write-Linea '  Esto ha sido solo un análisis: no se ha borrado nada.' 'aviso'
            Write-Linea '  Añade -Ejecutar para eliminar los elementos marcados.' 'tenue'
            Write-Linea ''
        }
        return 0
    }

    if ($marcados.Count -eq 0) {
        if (-not $Silencioso) { Write-Linea '  No hay nada marcado para eliminar.' 'aviso' }
        return 0
    }

    if (-not $PSCmdlet.ShouldProcess(
            "$($marcados.Count) elementos ($(Format-Tamano $bytesMarcados))",
            'Eliminar')) {
        return 0
    }

    if (-not $Silencioso) { Write-Cabecera 'Eliminación' }

    # Estado que lee $script:MostrarAvanceBorrado (ver arriba).
    $script:CliSilencioso = [bool]$Silencioso
    $script:CliSync       = $sync

    [void](Initialize-MotorBorrado)
    $libreAntes = Get-EspacioLibre $Configuracion.Unidad
    $liberado = 0.0
    $hechos = 0

    # El bucle de borrado (Remove.ps1) es común a consola y ventana; la
    # consola solo aporta cómo se informa de cada elemento.
    $resultadoLote = Invoke-LoteEliminacion -Candidatos $marcados `
                        -Permanente:$Configuracion.Permanente -Simular:$Simular `
                        -Configuracion $Configuracion -Sync $sync -Confirm:$false `
                        -AlProgresar $script:MostrarAvanceBorrado

    $liberado = $resultadoLote.Liberado
    $hechos   = $resultadoLote.Hechos
    $conError = $resultadoLote.ConError

    # Informe de la limpieza con lo que realmente se hizo (el de -Informe
    # se generó antes de borrar).
    $informeLimpieza = ''
    if ($Simular) {
        # No hay limpieza que documentar; el informe del análisis ya
        # recoge lo propuesto.
        if (-not $Silencioso) { Write-Linea '' }
    } else {
    try {
        $informeLimpieza = New-NombreInforme -Tipo 'limpieza' -Extension 'html' -CarpetaDatos $Configuracion.CarpetaDatos
        Export-InformeHtml -Candidatos @($marcados | Where-Object { $_.Hecho }) -Ruta $informeLimpieza `
                           -Configuracion $Configuracion -Tipo 'limpieza' -Modulos $Modulos -Confirm:$false
        if (-not $Silencioso) { Write-Linea ('  Informe de la limpieza en {0}' -f $informeLimpieza) 'ok' }
    } catch {
        Write-Registro -Nivel 'ERROR' -Mensaje "No se ha podido generar el informe de la limpieza: $($_.Exception.Message)"
        $informeLimpieza = ''
    }
    }

    $libreDespues = Get-EspacioLibre $Configuracion.Unidad

    # Una simulación no se anota en el historial: no ha ocurrido nada.
    if (-not $Simular) {
        Add-EntradaHistorial -Tipo 'limpieza' -Elementos $hechos -Bytes $liberado `
                             -Perfil $Configuracion.Perfil -LibreAntes $libreAntes -LibreDespues $libreDespues `
                             -Informe $informeLimpieza `
                             -CarpetaDatos $Configuracion.CarpetaDatos -Confirm:$false
    }

    if (-not $Silencioso) {
        if ($Simular) {
            # En simulación todos los verbos van en condicional.
            Write-Cabecera 'Resultado de la simulación'
            Write-Linea ('  Se habrían eliminado : {0} elementos' -f $resultadoLote.Simulados) 'ok'
            Write-Linea ('  Se habrían liberado  : {0}' -f (Format-Tamano $liberado)) 'ok'
            # Los bloqueados se muestran aquí, no solo en el registro: son
            # los que harían fallar la previsión.
            if ([int]$resultadoLote.Bloqueados -gt 0) {
                Write-Linea ('  NO se habrían borrado: {0} elementos (mira las líneas BLOQUEADO)' -f `
                             $resultadoLote.Bloqueados) 'error'
            }
            Write-Linea ('  Libre en {0}          : {1} -> {2} (estimado)' -f `
                         $Configuracion.Unidad, (Format-Tamano $libreAntes),
                         (Format-Tamano ($libreAntes + $liberado)))
            Write-Linea ''
            Write-Linea '  NO SE HA BORRADO NADA. Quita -Simular para hacerlo de verdad.' 'aviso'
        } else {
            Write-Cabecera 'Resultado'
            Write-Linea ('  Elementos eliminados : {0}' -f $hechos) 'ok'
            if ($conError -gt 0) {
                Write-Linea ('  No se han podido     : {0} (ver el registro)' -f $conError) 'aviso'
            }
            Write-Linea ('  Espacio liberado     : {0}' -f (Format-Tamano $liberado)) 'ok'
            Write-Linea ('  Libre en {0}          : {1} (antes {2})' -f `
                         $Configuracion.Unidad, (Format-Tamano $libreDespues), (Format-Tamano $libreAntes))
        }
        Write-Linea ''
    }
    return 0
}
