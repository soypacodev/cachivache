<#
.SYNOPSIS
    Análisis: los guiones que corren en el runspace, el lanzador de trabajos
    y el temporizador que sondea el progreso.

.DESCRIPTION
    Lo que se ejecuta en el runspace no puede tocar controles de WPF: solo
    escribe en la tabla sincronizada.

    Este archivo no se ejecuta solo: Show-VentanaPrincipal (Window.ps1) lo
    carga con dot-source dentro de la función, por lo que usa $c, $estado,
    $ventana y los cierres de Window.Ayudantes.ps1 sin declararlos. Ver
    docs/ESTRUCTURA.md (sección 3).
#>

    # =================================================================
    #  ANÁLISIS
    # =================================================================
    $temporizador = New-Object Windows.Threading.DispatcherTimer
    $temporizador.Interval = [TimeSpan]::FromMilliseconds(200)

    # 'Continue' y no 'SilentlyContinue': así los errores no terminantes de
    # un módulo (acceso denegado, ruta demasiado larga...) quedan en
    # $ps.Streams.Error y $limpiarTrabajo puede registrarlos.
    $codigoAnalisis = @'
$ErrorActionPreference = 'Continue'
try {
    # El núcleo y la guardia ya los ha cargado $abrirRunspace. Se carga
    # solo el archivo del módulo actual.
    $modulo = . $archivoModulo
    if ($null -ne $modulo) {
        $sync.Resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $cfg -Sync $sync
    }
} catch {
    $sync.Error = $_.Exception.Message
}
$sync.Terminado = $true
'@

    $codigoBorrado = @'
$ErrorActionPreference = 'Continue'
try {
    # Núcleo y guardia ya cargados por $abrirRunspace.
    [void](Initialize-MotorBorrado)

    # El mismo bucle de borrado que usa la consola (Remove.ps1). El verbo se
    # resuelve aquí y no dentro del bloque de progreso, que se invoca desde
    # el ámbito de Invoke-LoteEliminacion: no se depende del alcance
    # dinámico de $simular.
    $verbo = if ($simular) { 'Midiendo' } else { 'Eliminando' }

    $resultado = Invoke-LoteEliminacion -Candidatos $lote -Permanente:$permanente -Simular:$simular `
                    -Configuracion $cfg -Sync $sync -Confirm:$false `
                    -AlProgresar {
                        param($candidato, $avance)
                        $sync.Mensaje   = '{0}: {1}' -f $verbo, $candidato.Nombre
                        $sync.Resultado = [pscustomobject]@{
                            Hechos = $avance.Hechos; Liberado = $avance.Liberado
                        }
                    }.GetNewClosure()
    $sync.Resultado = [pscustomobject]@{
        Hechos    = $resultado.Hechos
        Liberado  = $resultado.Liberado
        Simulados = $resultado.Simulados
        Bloqueados = $resultado.Bloqueados
        Simulado  = $resultado.Simulado
    }
} catch {
    $sync.Error = $_.Exception.Message
}
$sync.Terminado = $true
'@

    # El núcleo (Bootstrap.ps1) y la guardia se cargan una vez por runspace,
    # no una por módulo.
    $codigoArranqueRunspace = @'
$ErrorActionPreference = 'Continue'
. (Join-Path (Join-Path (Join-Path $raiz 'src') 'Core') 'Bootstrap.ps1')
Initialize-Guardia -Configuracion $cfg
'@

    $abrirRunspace = {
        # Si ya hay uno abierto y sano, se reutiliza.
        if ($estado.Runspace -and $estado.Runspace.RunspaceStateInfo.State -eq 'Opened') { return }

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions  = 'ReuseThread'
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('sync', $estado.Sync)
        $runspace.SessionStateProxy.SetVariable('raiz', $estado.Raiz)
        $runspace.SessionStateProxy.SetVariable('cfg',  $estado.Configuracion)

        # Arranque síncrono: al volver, el núcleo y la guardia están listos.
        $arranque = [powershell]::Create()
        try {
            $arranque.Runspace = $runspace
            [void]$arranque.AddScript($codigoArranqueRunspace)
            [void]$arranque.Invoke()
        } finally {
            $arranque.Dispose()
        }

        $estado.Runspace = $runspace
    }

    $cerrarRunspace = {
        # El runspace dura toda la operación, no un módulo. Lo cierran
        # $terminarAnalisis, $terminarBorrado, la cancelación y el cierre de la
        # ventana; $limpiarTrabajo solo libera el trabajo.
        try { if ($estado.Runspace) { $estado.Runspace.Close(); $estado.Runspace.Dispose() } }
        catch { Write-Verbose "Cierre del runspace: $($_.Exception.Message)" }
        $estado.Runspace = $null
    }

    $lanzarTrabajo = {
        param([string] $Codigo, [hashtable] $Variables)

        $estado.Sync.Terminado = $false
        $estado.Sync.Cancelar  = $false
        $estado.Sync.Error     = ''
        $estado.Sync.Resultado = $null
        $estado.Sync.Mensaje   = 'Empezando...'

        # Todo el montaje va dentro del try: si falla al abrir el runspace o
        # al lanzar, no se llega a $temporizador.Start() y la ventana quedaría
        # ocupada para siempre. El catch libera recursos y la devuelve a reposo.
        try {
            & $abrirRunspace

            foreach ($clave in $Variables.Keys) {
                $estado.Runspace.SessionStateProxy.SetVariable($clave, $Variables[$clave])
            }

            $ps = [powershell]::Create()
            $ps.Runspace = $estado.Runspace
            [void]$ps.AddScript($Codigo)

            $estado.PowerShell = $ps
            $estado.Handle     = $ps.BeginInvoke()
            $temporizador.Start()
        } catch {
            $mensaje = $_.Exception.Message
            & $escribir ('No se ha podido lanzar el trabajo: {0}' -f $mensaje) 'ERROR'

            & $limpiarTrabajo
            & $cerrarRunspace

            $estado.Sync.Terminado = $true
            $estado.Sync.Error     = $mensaje

            if ($estado.Fase -eq 'analisis') { & $terminarAnalisis }
            else                             { & $terminarBorrado }
        }
    }

    $limpiarTrabajo = {
        $temporizador.Stop()
        # Stop() corta el trabajo en curso: la bandera de cancelación solo se
        # consulta entre iteraciones y un recorrido largo bloquearía el cierre.
        try { if ($estado.PowerShell) { $estado.PowerShell.Stop() } }
        catch { Write-Verbose "Stop del runspace: $($_.Exception.Message)" }

        # Al cancelar, EndInvoke lanza porque el trabajo no terminó.
        try { if ($estado.PowerShell) { [void]$estado.PowerShell.EndInvoke($estado.Handle) } }
        catch { Write-Verbose "EndInvoke: $($_.Exception.Message)" }

        # Errores no terminantes del módulo, agrupados por categoría para no
        # llenar el registro con un "acceso denegado" por ruta.
        try {
            if ($estado.PowerShell -and $estado.PowerShell.HadErrors) {
                $maximoGrupos = 5
                $grupos = @($estado.PowerShell.Streams.Error |
                    Group-Object { $_.CategoryInfo.Category } |
                    Sort-Object Count -Descending)

                foreach ($grupo in @($grupos | Select-Object -First $maximoGrupos)) {
                    Write-Registro -Sync $estado.Sync -Nivel 'AVISO' -Mensaje (
                        '{0}: {1} rutas ({2})' -f $grupo.Name, $grupo.Count,
                        $grupo.Group[0].Exception.Message)
                }
                if ($grupos.Count -gt $maximoGrupos) {
                    Write-Registro -Sync $estado.Sync -Nivel 'AVISO' -Mensaje (
                        '... y {0} categorías de error más durante el análisis.' -f
                        ($grupos.Count - $maximoGrupos))
                }
            }
        } catch {
            Write-Verbose "No se han podido volcar los errores del módulo: $($_.Exception.Message)"
        }

        try { if ($estado.PowerShell) { $estado.PowerShell.Dispose() } }
        catch { Write-Verbose "Dispose del trabajo: $($_.Exception.Message)" }

        # El runspace no se cierra aquí: lo comparten todos los módulos y lo
        # cierra $cerrarRunspace.
        $estado.PowerShell = $null
        $estado.Handle     = $null
    }

    $siguienteModulo = {
        if ($estado.Indice -ge $estado.Cola.Count) {
            & $terminarAnalisis
            return
        }
        $modulo = $estado.Cola[$estado.Indice]
        # La misma función que usa el temporizador, para que el formato del
        # texto no cambie entre el inicio del módulo y el primer tick.
        $c.TxtEstadoInicio.Text = Format-ProgresoAnalisis `
            -Modulo $modulo.Nombre `
            -Indice ($estado.Indice + 1) -Total $estado.Total `
            -Transcurrido $estado.Cronometro.Elapsed -Elementos $estado.Items.Count
        & $lanzarTrabajo $codigoAnalisis @{ archivoModulo = $modulo.Archivo }
    }

    $terminarAnalisis = {
        $estado.Ocupado = $false
        $estado.Fase    = 'reposo'
        $estado.Cronometro.Stop()

        # Se cierra el runspace compartido por todos los módulos.
        & $cerrarRunspace

        $c.BtnAnalizar.IsEnabled  = $true
        $c.BtnCancelar.Visibility = 'Collapsed'
        $c.BarraInicio.Value      = 100
        $c.BarraInicio.Visibility = 'Collapsed'

        $bytes = 0.0
        foreach ($item in $estado.Items) { $bytes += $item.Bytes }
        $borrables = @($estado.Items | Where-Object { $_.Borrable })
        $bytesBorrables = 0.0
        foreach ($item in $borrables) { $bytesBorrables += $item.Bytes }

        # ---- Completo, cancelado o con módulos fallidos ----
        # Un análisis incompleto debe indicarse como tal.
        $fallidos   = @($estado.ModulosFallidos)
        $incompleto = [bool]$estado.AnalisisCancelado -or $fallidos.Count -gt 0
        $revisados  = [Math]::Min($estado.Indice, $estado.Total)

        $c.TxtEstadoInicio.Text = $(if ($estado.AnalisisCancelado) {
            'Análisis detenido a los {0}. Se revisaron {1} de {2} módulos.' -f `
                (Format-Duracion $estado.Cronometro.Elapsed), $revisados, $estado.Total
        } else {
            'Análisis terminado en {0}. No se ha borrado nada.' -f (Format-Duracion $estado.Cronometro.Elapsed)
        })

        $encontrados = if ($estado.Items.Count -eq 1) { '1 elemento encontrado' }
                       else { '{0} elementos encontrados' -f $estado.Items.Count }
        # El criterio de premarcado se muestra junto a la lista.
        $criterio = Get-ResumenPremarcado -Candidatos $estado.Candidatos
        $c.TxtResumenAnalisis.Text = '{0} - {1} recuperables - {2} solo informativos. Nada se ha borrado.{3}' -f `
            $encontrados, (Format-Tamano $bytesBorrables), ($estado.Items.Count - $borrables.Count),
            $(if ($criterio) { ' ' + $criterio } else { '' })

        # La franja de aviso permanece mientras dure la lista.
        if ($incompleto) {
            $avisos = @()
            if ($estado.AnalisisCancelado) {
                $avisos += ('Lo detuviste en el módulo {0} de {1}: no se ha mirado el resto.' -f $revisados, $estado.Total)
            }
            if ($fallidos.Count -gt 0) {
                $avisos += ('{0} no se {1} podido completar: {2}.' -f `
                            $(if ($fallidos.Count -eq 1) { '1 módulo' } else { '{0} módulos' -f $fallidos.Count }),
                            $(if ($fallidos.Count -eq 1) { 'ha' } else { 'han' }),
                            ($fallidos -join ', '))
            }
            $c.TxtAvisoIncompleto.Text = ('Esta lista está incompleta. {0} Puede haber basura que no aparece aquí; mira el Registro para el detalle.' -f ($avisos -join ' '))
            $c.AvisoIncompleto.Visibility = 'Visible'
        } else {
            $c.AvisoIncompleto.Visibility = 'Collapsed'
            $c.TxtAvisoIncompleto.Text    = ''
        }

        & $escribir ''
        if ($incompleto) {
            & $escribir ('ANÁLISIS INCOMPLETO: {0} elementos, {1} recuperables, en {2}. {3}' -f `
                         $estado.Items.Count, (Format-Tamano $bytesBorrables),
                         (Format-Duracion $estado.Cronometro.Elapsed),
                         $c.TxtAvisoIncompleto.Text) 'AVISO'
        } else {
            & $escribir ('ANÁLISIS TERMINADO: {0} elementos, {1} recuperables, en {2}.' -f `
                         $estado.Items.Count, (Format-Tamano $bytesBorrables), (Format-Duracion $estado.Cronometro.Elapsed))
        }

        # El informe se genera antes de la entrada del historial para guardar
        # en ella su ruta. Si falla, la entrada se anota sin informe.
        $rutaInforme = ''
        if ($estado.Candidatos.Count -gt 0) {
            try {
                $rutaInforme = New-NombreInforme -Tipo 'analisis' -Extension 'html' `
                                                 -CarpetaDatos $estado.Configuracion.CarpetaDatos
                Export-InformeHtml -Candidatos $estado.Candidatos -Ruta $rutaInforme `
                                   -Configuracion $estado.Configuracion -Modulos $estado.Modulos -Confirm:$false
                & $escribir ('Informe guardado en: {0}' -f $rutaInforme)
            } catch {
                & $escribir ('No se ha podido generar el informe: {0}' -f
                             (Get-DetalleExcepcion -ErrorRecord $_ -ConPila)) 'AVISO'
                $rutaInforme = ''
            }
        }

        # -Bytes es lo recuperable (sin informativos), igual que en la consola.
        # -Modulos son los revisados, no todos los de la cola.
        $revisadosIds = @($estado.Cola | Select-Object -First $revisados | ForEach-Object { $_.Id })

        # Comparación con el análisis anterior. Debe ir antes de
        # Add-EntradaHistorial: después, el "anterior" sería este mismo. Sin
        # nada con que comparar, Sufijo es una cadena vacía.
        $c.TxtResumenAnalisis.Text += (Get-ComparacionAnalisis `
                                          -Historial (Get-Historial -CarpetaDatos $estado.Configuracion.CarpetaDatos) `
                                          -Perfil $estado.Configuracion.Perfil `
                                          -Modulos $revisadosIds).Sufijo

        Add-EntradaHistorial -Tipo 'analisis' -Elementos $estado.Items.Count -Bytes $bytesBorrables `
                             -Perfil $estado.Configuracion.Perfil `
                             -Modulos $revisadosIds `
                             -Informe $rutaInforme `
                             -Incompleto:$incompleto `
                             -Motivo $(if ($incompleto) { $c.TxtAvisoIncompleto.Text } else { '' }) `
                             -CarpetaDatos $estado.Configuracion.CarpetaDatos -Confirm:$false
        & $refrescarHistorial
        & $actualizarResumenSeleccion

        # ---- Lo más grande primero ----
        # Se ordena al terminar y no al crear la vista, para que la lista no
        # se reordene con cada fila que llega. Los grupos por categoría se
        # mantienen y quedan ordenados por su elemento más grande.
        try {
            $estado.Vista.SortDescriptions.Clear()
            $estado.Vista.SortDescriptions.Add(
                (New-Object ComponentModel.SortDescription 'Bytes', ([ComponentModel.ListSortDirection]::Descending)))
        } catch {
            # Ordenar no es imprescindible: si falla, se muestran sin ordenar.
            Write-Verbose "No se ha podido ordenar la lista: $($_.Exception.Message)"
        }

        if ($estado.Items.Count -gt 0) {
            $c.NavResultados.IsChecked = $true
        }
    }

    $appendResult = {
        param($Resultado)
        if ($null -eq $Resultado) { return }
        $modulo = $estado.Modulos | Where-Object { $_.Id -eq $Resultado.ModuloId } | Select-Object -First 1
        $nombreModulo = if ($modulo) { $modulo.Nombre } else { $Resultado.ModuloId }

        if ($Resultado.Omitido) {
            & $escribir ("  {0}: omitido - {1}" -f $nombreModulo, $Resultado.Omitido) 'OMITIDO'
            return
        }
        if ($Resultado.Error) {
            & $escribir ("  {0}: ERROR - {1}" -f $nombreModulo, $Resultado.Error) 'ERROR'
            return
        }

        $candidatos = @($Resultado.Candidatos)
        if ($candidatos.Count -eq 0) {
            & $escribir ("  {0}: nada que limpiar." -f $nombreModulo)
            return
        }

        # Se desengancha la tabla mientras se añaden filas para que el
        # DataGrid no reagrupe ni repinte por cada una. No sirve
        # DeferRefresh(): WPF prohíbe modificar la colección con un refresco
        # aplazado. La vista (agrupación y filtro) se conserva porque
        # GetDefaultView devuelve siempre la misma instancia; el
        # desplazamiento y la selección se guardan y se restauran (ver
        # Get-PlanRestauracionTabla en Posicion.ps1).
        $posicionTabla = & $guardarPosicionTabla
        $c.TablaResultados.ItemsSource = $null
        try {

            $suma = 0.0
            foreach ($candidato in $candidatos) {
                $suma += $candidato.Bytes
                $estado.Candidatos.Add($candidato)

                $item = New-Object Cachivache.ItemVista
                $item.Categoria = $candidato.Categoria
                $item.Nombre    = $candidato.Nombre
                $item.Ruta      = $candidato.Ruta
                $item.Info      = $candidato.Info
                $item.Efecto    = $candidato.Efecto
                $item.Aviso     = $candidato.Aviso
                $item.Metodo    = $candidato.Metodo
                $item.Comando   = $candidato.Comando
                $item.Riesgo    = $candidato.Riesgo
                $item.Bytes     = $candidato.Bytes
                $item.Tamano    = if ($candidato.Bytes -gt 0) { Format-Tamano $candidato.Bytes } else { '-' }
                $item.Borrable  = $candidato.Metodo -ne 'Informativo'
                $item.Origen    = $candidato
                $item.ColorRiesgo = Get-ColorRiesgo -Riesgo $candidato.Riesgo -Tema $estado.Tema
                $item.Seleccionado = $candidato.Seleccionado -and $item.Borrable
                # Motivo del premarcado, de la misma función que lo decide.
                $item.MotivoMarcado = Get-MotivoPremarcado -Riesgo $candidato.Riesgo `
                                        -Aviso $candidato.Aviso -Metodo $candidato.Metodo
                # La clave de exclusión se copia del candidato, no se recalcula:
                # de ella dependen "Excluir siempre esto" y "Copiar ruta".
                $item.ClaveExclusion = $candidato.ClaveExclusion

                $item.add_PropertyChanged($manejadorSeleccionGlobal)
                $estado.Items.Add($item)
            }

        } finally {
            $c.TablaResultados.ItemsSource = $estado.Items
            & $restaurarPosicionTabla $posicionTabla
        }

        & $escribir ("  {0}: {1} elementos, {2}." -f $nombreModulo, $candidatos.Count, (Format-Tamano $suma))
        if ($Resultado.Descartados -gt 0) {
            & $escribir ("     {0} descartados por la guardia de seguridad." -f $Resultado.Descartados) 'BLOQUEADO'
        }
    }

    $temporizador.Add_Tick({
        # El registro se vuelca primero, siempre: el runspace puede haber
        # encolado líneas justo cuando Ocupado pasa a $false, y esta es la
        # última pasada antes de parar el temporizador.
        & $volcarRegistro

        if (-not $estado.Ocupado) { $temporizador.Stop(); return }

        $mensaje = $estado.Sync.Mensaje
        if ($estado.Fase -eq 'analisis') {
            # El tiempo y el contador de elementos avanzan aunque el módulo
            # lleve minutos en la misma operación, para que no parezca colgado.
            $nombreModulo = if ($estado.Indice -lt $estado.Cola.Count) {
                [string]$estado.Cola[$estado.Indice].Nombre
            } else { '' }
            $c.TxtEstadoInicio.Text = Format-ProgresoAnalisis `
                -Modulo $nombreModulo -Mensaje $mensaje `
                -Indice ($estado.Indice + 1) -Total $estado.Total `
                -Transcurrido $estado.Cronometro.Elapsed -Elementos $estado.Items.Count
        } else {
            $c.TxtSeleccion.Text = $mensaje
            $avance = $estado.Sync.Resultado
            if ($null -ne $avance -and $estado.Total -gt 0) {
                $c.BarraBorrado.Value = 100 * $avance.Hechos / $estado.Total
            }
        }

        if (-not $estado.Sync.Terminado) { return }
        & $limpiarTrabajo

        if ($estado.Sync.Error) {
            & $escribir ('ERROR: {0}' -f $estado.Sync.Error) 'ERROR'

            # Se anota qué módulo ha fallado para avisar de que la lista está
            # incompleta.
            if ($estado.Fase -eq 'analisis' -and $estado.Indice -lt $estado.Cola.Count) {
                $estado.ModulosFallidos.Add([string]$estado.Cola[$estado.Indice].Nombre)
            }
        }

        if ($estado.Fase -eq 'analisis') {
            & $appendResult $estado.Sync.Resultado
            $estado.Indice++
            $c.BarraInicio.Value = 100 * $estado.Indice / [Math]::Max(1, $estado.Total)
            & $actualizarResumenSeleccion
            if ($estado.Sync.Cancelar) {
                $estado.AnalisisCancelado = $true
                & $escribir 'Análisis cancelado por el usuario.' 'AVISO'
                & $terminarAnalisis
            } else {
                & $siguienteModulo
            }
        } else {
            & $terminarBorrado
        }
    })

