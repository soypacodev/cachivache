<#
.SYNOPSIS
    Conexión de los eventos de la ventana: un manejador por control.

.DESCRIPTION
    Código de enlace: cada manejador debería limitarse a llamar a un cierre
    de Window.Ayudantes.ps1 o a lanzar un trabajo.

    Este archivo no se ejecuta solo: Show-VentanaPrincipal (Window.ps1) lo
    carga con dot-source dentro de la función, por lo que usa $c, $estado,
    $ventana y los cierres de Window.Ayudantes.ps1 sin declararlos. Ver
    docs/ESTRUCTURA.md (sección 3).
#>

    # =================================================================
    #  EVENTOS
    # =================================================================

    # Guardado de preferencias (cierre de la ventana, restablecer, reinicio
    # como administrador, exclusiones). El resultado de Export-Preferencias
    # se recoge siempre: para avisar si falla y para que el booleano no se
    # filtre a la salida del cierre.
    $guardarPreferencias = {
        $estado.Preferencias.ModulosActivos =
            @($estado.ModulosVista | Where-Object { $_.Seleccionado } | ForEach-Object { $_.Id })
        $guardadas = Export-Preferencias -Preferencias $estado.Preferencias -Confirm:$false
        if (-not $guardadas) {
            Write-Registro -Sync $estado.Sync -Nivel 'AVISO' -Mensaje (
                'No se han podido guardar las preferencias en "{0}". Los ajustes de esta sesión no se conservarán.' -f (Get-RutaPreferencias))
        }
    }

    # ---- Barra de título ----
    $c.BtnMinimizar.Add_Click({ $ventana.WindowState = 'Minimized' })
    $c.BtnMaximizar.Add_Click({
        $ventana.WindowState = if ($ventana.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    })
    $c.BtnCerrar.Add_Click({ $ventana.Close() })
    $c.BtnTema.Add_Click({
        & $aplicarTema $(if ($estado.Tema -eq 'oscuro') { 'claro' } else { 'oscuro' })
    })

    # ---- Navegación ----
    $c.NavInicio.Add_Checked({     & $mostrarPanel 'PanelInicio' })
    $c.NavResultados.Add_Checked({ & $mostrarPanel 'PanelResultados' })
    $c.NavRegistro.Add_Checked({   & $mostrarPanel 'PanelRegistro' })
    $c.NavInformes.Add_Checked({   & $refrescarHistorial; & $mostrarPanel 'PanelInformes' })
    # Ajustes reconstruye la lista de exclusiones al abrirse, como Informes
    # el historial: puede haber cambiado desde la tabla o desde fuera.
    $c.NavAjustes.Add_Checked({    & $refrescarExclusiones; & $mostrarPanel 'PanelAjustes' })
    $c.NavAcerca.Add_Checked({     & $mostrarPanel 'PanelAcerca' })

    # ---- Teclado ----
    # Qué hace cada tecla lo decide Get-AtajoDeTecla (Atajos.ps1). Aquí se
    # ejecuta levantando el Click del botón, no repitiendo su manejador: así
    # el atajo hereda sus guardas (un botón deshabilitado no atiende).
    #
    # PreviewKeyDown y no KeyDown: hay que ver la tecla antes que el control
    # con el foco, que podría consumirla. Por eso se respeta a mano lo que
    # necesita un cuadro de texto (EnCuadroDeTexto).
    $ventana.Add_PreviewKeyDown({
        param($origen, $e)

        $control = ([System.Windows.Input.Keyboard]::Modifiers -band
                    [System.Windows.Input.ModifierKeys]::Control) -eq
                   [System.Windows.Input.ModifierKeys]::Control

        $foco = [System.Windows.Input.Keyboard]::FocusedElement
        $enTexto = $foco -is [System.Windows.Controls.TextBox]

        $accion = Get-AtajoDeTecla -Tecla ([string]$e.Key) -Control:$control -EnCuadroDeTexto:$enTexto
        if (-not $accion) { return }

        # Solo se marca como atendida si era un atajo.
        $e.Handled = $true

        $clic = { param($boton) $boton.RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }

        switch ($accion) {
            'Analizar'   { & $clic $c.BtnAnalizar }
            'MarcarTodo' { & $clic $c.BtnMarcarTodo }

            'Filtrar' {
                # Primero se muestra Resultados: desde otro panel el cuadro
                # de filtro no sería visible.
                $c.NavResultados.IsChecked = $true
                [void] $c.CampoFiltro.Focus()
            }

            'Cancelar' {
                # Se elige según qué botón se puede pulsar ahora, no según
                # una bandera interna, para que atajo y ratón coincidan.
                if ($c.BtnCancelar.Visibility -eq 'Visible' -and $c.BtnCancelar.IsEnabled) {
                    & $clic $c.BtnCancelar
                } elseif ($c.BtnCancelarBorrado.Visibility -eq 'Visible' -and $c.BtnCancelarBorrado.IsEnabled) {
                    & $clic $c.BtnCancelarBorrado
                }
            }

            default {
                # Entradas de la barra lateral: su Checked muestra el panel y
                # le da el foco.
                $c[$accion].IsChecked = $true
            }
        }
    })

    # ---- Módulos ----
    $c.BtnModulosTodos.Add_Click({
        foreach ($vista in $estado.ModulosVista) { if ($vista.Disponible) { $vista.Seleccionado = $true } }
    })
    $c.BtnModulosNinguno.Add_Click({
        foreach ($vista in $estado.ModulosVista) { $vista.Seleccionado = $false }
    })

    # ---- Analizar ----
    $c.BtnAnalizar.Add_Click({
        if ($estado.Ocupado) { return }

        $seleccionados = @($estado.ModulosVista | Where-Object { $_.Seleccionado })
        if ($seleccionados.Count -eq 0) {
            [Windows.MessageBox]::Show('Marca al menos un módulo para analizar.', 'Nada que analizar',
                'OK', 'Information') | Out-Null
            return
        }

        # Sin unidades marcadas el análisis descartaría todo tras recorrer el
        # disco: se avisa antes de empezar.
        if (@($estado.DiscosVista | Where-Object { $_.Seleccionado }).Count -eq 0) {
            [Windows.MessageBox]::Show(
                'No hay ninguna unidad marcada en el panel de la izquierda, así que el análisis no encontraria nada. Marca al menos una.',
                'Ninguna unidad marcada', 'OK', 'Information') | Out-Null
            return
        }

        $estado.Items.Clear()
        $estado.Candidatos.Clear()
        $c.TxtResumenAnalisis.Text = 'Analizando...'
        # El registro de la sesión no se vacía entre análisis; su tamaño lo
        # limita $volcarRegistro.

        # Se aplican siempre los valores de Ajustes: lo que muestran los
        # controles es lo que se usa.
        $estado.Configuracion.MinimoMB       = [int]$c.SliderMinimoMB.Value
        $estado.Configuracion.DiasSinUso     = [int]$c.SliderDias.Value
        $estado.Configuracion.IncluirMenores = [bool]$c.ChkMenores.IsChecked
        $estado.Configuracion.Permanente     = [bool]$c.ChkPermanente.IsChecked

        $ids = @($seleccionados | ForEach-Object { $_.Id })
        $estado.Cola   = @($estado.Modulos | Where-Object { $ids -contains $_.Id } | Sort-Object Orden)
        $estado.Indice = 0
        $estado.Total  = $estado.Cola.Count
        $estado.Ocupado = $true
        $estado.Fase    = 'analisis'
        $estado.LibreInicial = Get-EspacioLibre $estado.Configuracion.Unidad
        $estado.Cronometro = [Diagnostics.Stopwatch]::StartNew()

        # Se reinicia el estado de "incompleto" del análisis anterior.
        $estado.AnalisisCancelado = $false
        $estado.ModulosFallidos.Clear()
        $c.AvisoIncompleto.Visibility = 'Collapsed'
        $c.TxtAvisoIncompleto.Text    = ''

        # La lista se acaba de vaciar: se actualiza ya el cartel de tabla vacía.
        & $actualizarEstadoVacio

        $c.BtnAnalizar.IsEnabled  = $false
        # Eliminar se desactiva ya, sin esperar al primer módulo.
        $c.BtnEliminar.IsEnabled  = $false
        $c.TxtSeleccion.Text      = 'Nada marcado.'
        $c.TxtProyeccion.Text     = 'Analizando: la lista se irá llenando sola.'
        $c.BtnCancelar.Visibility = 'Visible'
        # Se reactiva por si quedó deshabilitado de una cancelación anterior.
        $c.BtnCancelar.IsEnabled  = $true
        $c.BarraInicio.Visibility = 'Visible'
        $c.BarraInicio.Value = 0

        & $escribir ('ANALISIS - perfil {0}, {1} modulos. No se va a borrar nada.' -f `
                     $estado.Configuracion.Perfil, $estado.Total)
        & $escribir ('Umbrales: mínimo {0} MB, {1} días sin usar, elementos pequeños: {2}.' -f `
                     $estado.Configuracion.MinimoMB, $estado.Configuracion.DiasSinUso,
                     $(if ($estado.Configuracion.IncluirMenores) { 'si' } else { 'no' }))
        & $siguienteModulo
    })

    $c.BtnCancelar.Add_Click({
        if (-not $estado.Ocupado) { return }

        # La bandera no basta: los módulos solo la consultan entre
        # iteraciones. Se detiene el runspace y, como "$sync.Terminado = $true"
        # puede no llegar a ejecutarse, el análisis se cierra aquí en vez de
        # esperar al temporizador.
        $estado.Sync.Cancelar    = $true
        $c.BtnCancelar.IsEnabled = $false
        $c.TxtEstadoInicio.Text  = 'Cancelando el análisis...'

        & $limpiarTrabajo
        & $escribir 'Análisis cancelado por el usuario.' 'AVISO'
        & $terminarAnalisis
    })

    $c.BtnCancelarBorrado.Add_Click({
        if (-not $estado.Ocupado) { return }

        # Lo ya borrado sigue borrado. Como al cancelar el análisis, se
        # detiene el runspace porque la bandera sola no basta.
        $estado.Sync.Cancelar           = $true
        $c.BtnCancelarBorrado.IsEnabled = $false
        $c.TxtSeleccion.Text            = 'Deteniendo la eliminación...'

        & $limpiarTrabajo
        & $escribir 'Eliminación detenida por el usuario.' 'AVISO'
        & $terminarBorrado
    })

    # ---- Filtros y selección ----
    # El cuadro de texto filtra con retardo (ver $solicitarFiltro); el
    # desplegable de riesgo filtra al momento.
    $c.CampoFiltro.Add_TextChanged({ & $solicitarFiltro })
    $c.FiltroRiesgo.Add_SelectionChanged({ & $aplicarFiltro })

    # Botón del cartel de tabla vacía.
    if ($null -ne $c.BtnQuitarFiltros) {
        $c.BtnQuitarFiltros.Add_Click({ & $quitarFiltros })
    }

    # Marcado en lote: suprime el recálculo del resumen mientras dura y lo
    # hace una vez al final. No se desengancha el manejador porque
    # remove_PropertyChanged no funciona con scriptblocks (cada conversión
    # crea un delegado nuevo).
    #
    # Se recorre la vista y no $estado.Items: con un filtro activo solo deben
    # marcarse las filas visibles, nunca las ocultas.
    $marcarEnLote = {
        param([scriptblock] $Criterio)
        if ($null -eq $estado.Vista) { return }

        # Se materializa con @() para no modificar elementos mientras se
        # enumera una CollectionView filtrada.
        $filas = @($estado.Vista)
        $plan = Get-PlanMarcadoEnLote -Total $filas.Count
        if ($plan.Total -le 0) { return }

        $estado.SuprimirResumen = $true
        try {
            if (-not $plan.PorTrozos) {
                # Por debajo del umbral: de una vez.
                foreach ($item in $filas) { $item.Seleccionado = [bool](& $Criterio $item) }
            }
            else {
                # Por trozos, cediendo a la ventana entre ellos para que
                # repinte. Como la ventana atiende clics mientras tanto, se
                # desactivan los botones peligrosos y se restauran siempre.
                $botones = @($c.BtnEliminar, $c.BtnMarcarTodo, $c.BtnDesmarcarTodo, $c.BtnSoloSeguros)
                $antes = @($botones | ForEach-Object { $_.IsEnabled })
                foreach ($b in $botones) { $b.IsEnabled = $false }
                $cursorPrevio = $ventana.Cursor
                $ventana.Cursor = [Windows.Input.Cursors]::Wait
                try {
                    foreach ($tramo in @(Get-RangosDeLote -Plan $plan)) {
                        for ($i = 0; $i -lt $tramo.Cuantas; $i++) {
                            $item = $filas[$tramo.Desde + $i]
                            $item.Seleccionado = [bool](& $Criterio $item)
                        }
                        # Cede al despachador en prioridad de fondo para que
                        # WPF repinte.
                        $ventana.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
                    }
                } finally {
                    for ($i = 0; $i -lt $botones.Count; $i++) { $botones[$i].IsEnabled = $antes[$i] }
                    $ventana.Cursor = $cursorPrevio
                }
            }
        } finally {
            $estado.SuprimirResumen = $false
        }
        & $actualizarResumenSeleccion
    }

    $c.BtnMarcarTodo.Add_Click({
        & $marcarEnLote { param($i) $i.Borrable -and -not $i.Hecho }
    })
    $c.BtnDesmarcarTodo.Add_Click({
        & $marcarEnLote { param($i) $false }
    })
    $c.BtnSoloSeguros.Add_Click({
        & $marcarEnLote {
            param($i)
            $i.Borrable -and -not $i.Hecho -and $i.Riesgo -eq 'Bajo' -and
            [string]::IsNullOrWhiteSpace($i.Aviso)
        }
    })

    # ---- Ver qué hay dentro ----
    $c.BtnVerContenido.Add_Click({
        $item = $c.TablaResultados.SelectedItem
        if ($null -eq $item) {
            Show-Aviso -Mensaje 'Elige antes una fila de la lista: es su contenido el que se mira.' -Tipo 'Information'
            return
        }
        if ($item.Metodo -eq 'Comando') {
            Show-Aviso -Tipo 'Information' -Mensaje (
                "Este elemento no es una carpeta: es un comando del sistema ({0}), asi que no hay nada dentro que mirar." -f $item.Comando)
            return
        }

        # El recorrido puede tardar unos segundos y bloquea la ventana: se
        # indica con el cursor de espera. No se usa el runspace, que
        # pertenece al análisis.
        $ventana.Cursor = [Windows.Input.Cursors]::Wait
        try {
            $detalle = Get-DetalleCarpeta -Ruta $item.Ruta
            $texto   = Format-DetalleCarpeta -Detalle $detalle -Ruta $item.Ruta
        } catch {
            & $escribir ('No se ha podido mirar dentro de {0}: {1}' -f
                         $item.Ruta, (Get-DetalleExcepcion -ErrorRecord $_ -ConPila)) 'AVISO'
            $texto = 'No se ha podido mirar dentro: ' + (Get-DetalleExcepcion -ErrorRecord $_)
        } finally {
            $ventana.Cursor = $null
        }

        Show-Aviso -Titulo ('Contenido de {0}' -f $item.Nombre) -Mensaje $texto -Tipo 'Information'
    })

    # Compartido con el menú contextual y el doble clic ($abrirUbicacion).
    $c.BtnAbrirCarpeta.Add_Click({ & $abrirUbicacion $c.TablaResultados.SelectedItem })

    # ---- Doble clic sobre una fila ----
    # Muestra el elemento en su carpeta; nunca lo abre (sería ejecutar algo
    # propuesto para borrar). Sin fila no avisa: el doble clic también cae
    # sobre la cabecera y el hueco bajo la última fila.
    $c.TablaResultados.Add_MouseDoubleClick({
        $item = $c.TablaResultados.SelectedItem
        if ($null -eq $item) { return }
        & $abrirUbicacion $item
    })

    # ---- Ocultar lo ya eliminado ----
    # Add_Checked/Add_Unchecked y no Add_Click: Click solo salta cuando
    # pulsa el usuario, no cuando el código cambia la casilla.
    $sincronizarOcultarHechos = { & $aplicarFiltro }
    $c.ChkOcultarHechos.Add_Checked($sincronizarOcultarHechos)
    $c.ChkOcultarHechos.Add_Unchecked($sincronizarOcultarHechos)

    # El botón del cartel solo desmarca la casilla; Add_Unchecked hace el
    # resto, para que haya un único camino.
    $c.BtnMostrarHechos.Add_Click({ $c.ChkOcultarHechos.IsChecked = $false })

    # ---- Eliminar ----
    $c.BtnEliminar.Add_Click({
        if ($estado.Ocupado) { return }
        $marcados = @($estado.Items | Where-Object { $_.Seleccionado -and $_.Borrable -and -not $_.Hecho })
        if ($marcados.Count -eq 0) { return }

        $bytes = 0.0
        foreach ($item in $marcados) { $bytes += $item.Bytes }
        # Un comando externo entra siempre en la lista de riesgo: SECURITY.md
        # exige que sea siempre visible y siempre con confirmación.
        $arriesgados = @($marcados | Where-Object {
            $_.Riesgo -ne 'Bajo' -or -not [string]::IsNullOrWhiteSpace($_.Aviso) -or $_.Metodo -eq 'Comando'
        })

        $simular = [bool]$c.ChkSimular.IsChecked
        $estado.Configuracion.Simular = $simular

        # Simular no pide confirmación: no se borra nada, y confirmar sin
        # necesidad acostumbra a aceptar sin leer.
        if (-not $simular) {
            $confirmado = Show-Confirmacion -Propietario $ventana -CarpetaUi $estado.CarpetaUi `
                                            -Elementos $marcados.Count -Bytes $bytes `
                                            -Permanente $estado.Configuracion.Permanente `
                                            -Arriesgados $arriesgados
            if (-not $confirmado) {
                & $escribir 'Eliminación cancelada en la confirmación.' 'AVISO'
                return
            }
        }

        $lote = @($marcados | ForEach-Object { $_.Origen })
        $estado.Ocupado       = $true
        $estado.Fase          = 'borrado'
        $estado.SimulandoLote = $simular
        $estado.ModulosLote   = @($lote | ForEach-Object { $_.ModuloId } | Select-Object -Unique)
        $estado.Total   = $lote.Count
        $estado.LibreInicial = Get-EspacioLibre $estado.Configuracion.Unidad

        $c.BtnEliminar.IsEnabled   = $false
        $c.BtnAnalizar.IsEnabled   = $false
        # Se oculta el botón de la papelera de la limpieza anterior.
        $c.BtnAbrirPapelera.Visibility = 'Collapsed'
        $c.BarraBorrado.Visibility = 'Visible'
        $c.BarraBorrado.Value      = 0
        # Se puede detener a mitad; lo ya borrado sigue borrado.
        $c.BtnCancelarBorrado.Visibility = 'Visible'
        # Se reactiva por si quedó deshabilitado de una detención anterior.
        $c.BtnCancelarBorrado.IsEnabled  = $true

        & $escribir ''
        if ($simular) {
            & $escribir ('SIMULANDO {0} elementos ({1}). No se va a borrar nada.' -f `
                         $lote.Count, (Format-Tamano $bytes)) 'SIMULACION'
        } else {
            & $escribir ('ELIMINANDO {0} elementos ({1}). Destino: {2}.' -f `
                         $lote.Count, (Format-Tamano $bytes),
                         $(if ($estado.Configuracion.Permanente) { 'borrado permanente' } else { 'papelera de reciclaje' })) 'BORRADO'
        }

        & $lanzarTrabajo $codigoBorrado @{
            lote       = $lote
            permanente = $estado.Configuracion.Permanente
            simular    = $simular
        }
    })

    # ---- Simular ----
    # Con "Solo simular" marcado, el botón cambia de rótulo y deja de usar
    # el estilo de peligro.
    $sincronizarSimular = {
        if ([bool]$c.ChkSimular.IsChecked) {
            $c.BtnEliminar.Content = 'Simular limpieza'
            $c.BtnEliminar.Style   = $ventana.FindResource('BotonSecundario')
        } else {
            $c.BtnEliminar.Content = 'Eliminar lo marcado'
            $c.BtnEliminar.Style   = $ventana.FindResource('BotonPeligro')
        }
    }
    $c.ChkSimular.Add_Checked($sincronizarSimular)
    $c.ChkSimular.Add_Unchecked($sincronizarSimular)

    # ---- Registro ----
    $c.BtnCopiarRegistro.Add_Click({
        try { [Windows.Clipboard]::SetText($c.Consola.Text) }
        catch { Show-Aviso -Mensaje 'Otro programa esta bloqueando el portapapeles.' -Tipo 'Warning' }
    })
    $c.BtnAbrirRegistro.Add_Click({
        # La carpeta puede no existir o el Explorador puede fallar.
        try { Start-Process -FilePath (Get-RutaExplorador) -ArgumentList "`"$(Join-Path $estado.Configuracion.CarpetaDatos 'registros')`"" }
        catch { Show-Aviso -Mensaje "No se ha podido abrir la carpeta del registro:`n$($_.Exception.Message)" -Tipo 'Warning' }
    })

    # ---- Informes ----
    $exportar = {
        param([string] $Formato)
        if ($estado.Candidatos.Count -eq 0) {
            [Windows.MessageBox]::Show('Analiza el equipo primero: todavía no hay nada que exportar.',
                'Sin datos', 'OK', 'Information') | Out-Null
            return
        }
        # Dos try separados: un fallo al abrir el Explorador no debe
        # notificarse como fallo al guardar el informe.
        #
        # La casilla equivale a -InformeAnonimo de la consola: ambas llegan
        # al parámetro -Anonimo de Report.ps1. La ventana no anonimiza por su
        # cuenta (lo comprueba una invariante).
        $anonimo = [bool]$c.ChkAnonimizar.IsChecked

        $ruta = $null
        try {
            $ruta = New-NombreInforme -Tipo 'analisis' -Extension $Formato -CarpetaDatos $estado.Configuracion.CarpetaDatos
            switch ($Formato) {
                'html' { Export-InformeHtml -Candidatos $estado.Candidatos -Ruta $ruta -Configuracion $estado.Configuracion -Modulos $estado.Modulos -Anonimo:$anonimo -Confirm:$false }
                'csv'  { Export-InformeCsv  -Candidatos $estado.Candidatos -Ruta $ruta -Anonimo:$anonimo -Confirm:$false }
                'json' { Export-InformeJson -Candidatos $estado.Candidatos -Ruta $ruta -Configuracion $estado.Configuracion -Anonimo:$anonimo -Confirm:$false }
            }
            # Se indica si se ha anonimizado: el nombre del archivo es el mismo.
            $comoSeGuardo = if ($anonimo) { ' (con las rutas anonimizadas)' } else { '' }
            & $escribir (('Informe guardado: {0}{1}' -f $ruta, $comoSeGuardo))
        } catch {
            # Al registro con pila; en pantalla, sin ella.
            & $escribir ('No se ha podido guardar el informe: {0}' -f (Get-DetalleExcepcion -ErrorRecord $_ -ConPila)) 'ERROR'
            Show-Aviso -Tipo 'Error' -Titulo 'Error' -Mensaje (
                "No se ha podido guardar el informe:`n{0}`n`nEl detalle completo está en el registro (pestaña Registro)." -f
                (Get-DetalleExcepcion -ErrorRecord $_))
            return
        }

        try {
            Start-Process -FilePath (Get-RutaExplorador) -ArgumentList "/select,`"$ruta`""
        } catch {
            # El informe sí se ha guardado; solo falla abrir el Explorador.
            & $escribir ('El informe está guardado, pero no se ha podido abrir el Explorador: {0}' -f
                         (Get-DetalleExcepcion -ErrorRecord $_)) 'AVISO'
        }
    }
    $c.BtnExportarHtml.Add_Click({ & $exportar 'html' })
    $c.BtnExportarCsv.Add_Click({  & $exportar 'csv' })
    $c.BtnExportarJson.Add_Click({ & $exportar 'json' })
    $c.BtnExportar.Add_Click({     & $exportar 'html' })

    # ---- Marcar y quitar una categoría entera ----
    # Los botones están dentro de la plantilla de la cabecera de grupo, que
    # el panel virtualizado crea y destruye: FindName no los encuentra. El
    # evento se engancha en la tabla y se identifica el origen.
    $c.TablaResultados.AddHandler(
        [Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [Windows.RoutedEventHandler]{
            param($remitente, $argumentos)

            $boton = $argumentos.OriginalSource -as [Windows.Controls.Button]
            if ($null -eq $boton) { return }

            $categoria = [string]$boton.Tag
            if ([string]::IsNullOrWhiteSpace($categoria)) { return }

            # Por nombre y no por el texto del botón, que puede cambiar.
            if ($boton.Name -eq 'BtnMarcarGrupo')      { $marcar = $true }
            elseif ($boton.Name -eq 'BtnQuitarGrupo')  { $marcar = $false }
            else { return }

            & $marcarCategoria $categoria $marcar
        })

    # Marcar o desmarcar una categoría entera (botones de la cabecera de
    # grupo y "Desmarcar el grupo" del menú contextual). Se define después
    # del manejador que lo usa, que solo se evalúa al pulsar.
    $marcarCategoria = {
        param([string] $Categoria, [bool] $Marcar)

        # Suprime el recálculo del resumen por cada casilla.
        $estado.SuprimirResumen = $true
        try {
            foreach ($item in $estado.Items) {
                if ($item.Categoria -ne $Categoria) { continue }
                # Marcar respeta lo no borrable; desmarcar vale para todo.
                if ($Marcar -and -not $item.Borrable) { continue }
                $item.Seleccionado = $Marcar
            }
        } finally {
            $estado.SuprimirResumen = $false
        }
        & $actualizarResumenSeleccion
    }

    # =================================================================
    #  MENÚ CONTEXTUAL DE LA TABLA
    # =================================================================
    # Las órdenes actúan sobre la fila seleccionada y avisan si no hay
    # ninguna (el menú también se abre sobre la cabecera). Se comprueba que
    # existan las entradas: $null.Add_Click() lanzaría y la ventana no se
    # abriría; en su lugar se registra un error.
    $faltanMenuFila = @(@('MenuAbrirUbicacion', 'MenuCopiarRuta',
                          'MenuExcluirSiempre', 'MenuDesmarcarGrupo') |
                        Where-Object { $null -eq $c[$_] })
    if ($faltanMenuFila.Count -gt 0) {
        Write-Registro -Sync $estado.Sync -Nivel 'ERROR' -Mensaje (
            'No se han encontrado estas entradas del menú contextual de la tabla, y no van a responder: {0}' -f
            ($faltanMenuFila -join ', '))
    } else {

        $c.MenuAbrirUbicacion.Add_Click({ & $abrirUbicacion $c.TablaResultados.SelectedItem })

        # ---- Copiar ruta ----
        # Sin ruta real no se copia nada (una etiqueta parecería una ruta) y
        # se explica el motivo. El comando ya es visible en la fila.
        $c.MenuCopiarRuta.Add_Click({
            $item = $c.TablaResultados.SelectedItem
            if ($null -eq $item) {
                Show-Aviso -Mensaje 'Elige antes una fila de la lista: es su ruta la que se copia.' -Tipo 'Information'
                return
            }

            if (-not $item.TieneRutaReal) {
                Show-Aviso -Tipo 'Information' -Mensaje (
                    (& $describirSinRuta $item 'ruta que copiar') +
                    [Environment]::NewLine + [Environment]::NewLine +
                    'No se ha copiado nada: dejar ahí una etiqueta que parece una ruta solo se descubre al pegarla, en otro sitio y sin ninguna pista de qué ha pasado.')
                return
            }

            try {
                [Windows.Clipboard]::SetText($item.Ruta)
                # Sin cuadro de diálogo si se copia bien; solo al registro.
                & $escribir ('Ruta copiada al portapapeles: {0}' -f $item.Ruta)
            } catch {
                Show-Aviso -Mensaje 'Otro programa está bloqueando el portapapeles. Vuelve a intentarlo.' -Tipo 'Warning'
            }
        })

        # ---- Excluir siempre esto ----
        # Se guarda $item.ClaveExclusion sin recalcularla (la decide
        # Get-ClaveExclusion), porque es la que compara el motor de borrado.
        # Se pide confirmación nombrando el elemento: una exclusión errónea
        # deja de verse en los análisis. Quitarla no pregunta (ver
        # $quitarExclusion).
        $c.MenuExcluirSiempre.Add_Click({
            $item = $c.TablaResultados.SelectedItem
            if ($null -eq $item) {
                Show-Aviso -Mensaje 'Elige antes una fila de la lista: es ese elemento el que se excluye.' -Tipo 'Information'
                return
            }

            $clave = [string]$item.ClaveExclusion
            if ([string]::IsNullOrWhiteSpace($clave)) {
                Show-Aviso -Tipo 'Warning' -Mensaje (
                    'Esta fila no trae la clave con la que se guardan las exclusiones, así que excluirla no serviría de nada: no habría nada con lo que comparar. Vuelve a analizar y prueba otra vez.')
                return
            }

            # La misma función que usan el análisis y el motor de borrado.
            $excluidas = @($estado.Preferencias.RutasExcluidas)
            if (Test-ClaveExcluida -Clave $clave -Excluidas $excluidas) {
                Show-Aviso -Tipo 'Information' -Mensaje (
                    '«{0}» ya está cubierto por tu lista de cosas que no se tocan nunca. No hace falta volver a excluirlo.' -f $item.Nombre)
                return
            }

            # Paréntesis alrededor de toda la concatenación: -f tiene más
            # precedencia que +, y sin ellos solo se formatearía el último trozo.
            $pregunta = ('Vas a excluir «{0}» para siempre.' + [Environment]::NewLine + [Environment]::NewLine +
                         'Se guarda esta clave: {1}' + [Environment]::NewLine + [Environment]::NewLine +
                         'Si es una carpeta, queda fuera también todo lo que haya dentro. No volverá a proponerse en ningún análisis, y el motor de borrado lo rechazará aunque llegue a estar marcado.' +
                         [Environment]::NewLine + [Environment]::NewLine +
                         'Podrás quitarlo cuando quieras en Ajustes, en la tarjeta «Lo que no se toca nunca».' +
                         [Environment]::NewLine + [Environment]::NewLine +
                         '¿Lo excluyes?') -f $item.Nombre, $clave

            if ([Windows.MessageBox]::Show($pregunta, 'Excluir siempre', 'YesNo', 'Question') -ne 'Yes') { return }

            # Se actualizan las preferencias y la configuración: solo se
            # sincronizan al refrescar los discos, y debe aplicarse ya.
            $estado.Preferencias.RutasExcluidas = @(@($excluidas) + $clave |
                                                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                                                    Select-Object -Unique)
            $estado.Configuracion.RutasExcluidas = @($estado.Preferencias.RutasExcluidas)

            # Se guarda al momento para que un cierre anormal no la pierda.
            & $guardarPreferencias

            # La tarjeta de Ajustes se actualiza ya, aunque también se
            # actualice al abrir el panel.
            & $refrescarExclusiones

            # Se desmarca lo que la exclusión cubre, con la misma función que
            # usa el motor; si no, el motor lo rechazaría como error.
            $ahora = @($estado.Preferencias.RutasExcluidas)
            $desmarcados = 0
            $estado.SuprimirResumen = $true
            try {
                foreach ($fila in $estado.Items) {
                    if (-not $fila.Seleccionado) { continue }
                    if (-not (Test-ClaveExcluida -Clave $fila.ClaveExclusion -Excluidas $ahora)) { continue }
                    $fila.Seleccionado = $false
                    $desmarcados++
                }
            } finally {
                $estado.SuprimirResumen = $false
            }
            & $actualizarResumenSeleccion

            $cola = if ($desmarcados -eq 0) {
                'En la lista de ahora no quedaba nada marcado que la exclusión cubra.'
            } elseif ($desmarcados -eq 1) {
                'Se ha desmarcado 1 elemento que la exclusión cubre.'
            } else {
                'Se han desmarcado {0} elementos que la exclusión cubre.' -f $desmarcados
            }

            & $escribir ('Excluido para siempre: {0}. {1}' -f $clave, $cola)
            Show-Aviso -Tipo 'Information' -Mensaje (
                ('«{0}» ya no se propondrá en ningún análisis.' +
                 [Environment]::NewLine + [Environment]::NewLine + '{1}') -f $item.Nombre, $cola)
        })

        # ---- Desmarcar el grupo ----
        # Mismo cierre que el botón "Quitar" de la cabecera de grupo, con la
        # categoría de la fila seleccionada.
        $c.MenuDesmarcarGrupo.Add_Click({
            $item = $c.TablaResultados.SelectedItem
            if ($null -eq $item) {
                Show-Aviso -Mensaje 'Elige antes una fila de la lista: se desmarca la categoría a la que pertenece.' -Tipo 'Information'
                return
            }
            & $marcarCategoria $item.Categoria $false
        })
    }

    # ---- Abrir la papelera ----
    # Un "deshacer" real (restaurar solo lo de esta limpieza) requeriría
    # IFileOperation por COM; de momento se abre la papelera.
    # shell:RecycleBinFolder no es una ruta y no pasa por la guardia, lo
    # cual es correcto: aquí no se borra nada.
    $c.BtnAbrirPapelera.Add_Click({
        try {
            Start-Process -FilePath (Get-RutaExplorador) -ArgumentList 'shell:RecycleBinFolder'
        } catch {
            Show-Aviso -Tipo 'Warning' -Mensaje (
                "No se ha podido abrir la papelera:`n{0}" -f (Get-DetalleExcepcion -ErrorRecord $_))
        }
    })

    # ---- Abrir un informe ----
    # Único punto del programa que abre un archivo con la aplicación
    # predeterminada. La ruta se vuelve a validar aunque ya se validó al
    # construir la lista: el archivo puede haber cambiado o haber sido
    # sustituido por un enlace desde entonces.
    $abrirInforme = {
        param([string] $Ruta)
        $valida = Resolve-InformeAbrible -Ruta $Ruta -CarpetaDatos $estado.Configuracion.CarpetaDatos
        if ($null -eq $valida) {
            [Windows.MessageBox]::Show(
                "Este informe ya no se puede abrir.`n`nO se ha borrado o movido, o no esta donde el programa guarda los informes. Solo se abren archivos .html, .csv y .json de esa carpeta.",
                'Informe no disponible', 'OK', 'Warning') | Out-Null
            & $refrescarHistorial
            return
        }
        try {
            Start-Process -FilePath $valida
        } catch {
            [Windows.MessageBox]::Show("No se ha podido abrir el informe:`n$($_.Exception.Message)",
                'Error', 'OK', 'Error') | Out-Null
        }
    }

    # ListBox con SelectionChanged en vez de un botón en la plantilla. La
    # selección se deshace para poder volver a pulsar la misma fila; eso
    # vuelve a disparar el evento con SelectedItem a $null, que se ignora.
    $abrirSeleccionInforme = {
        param($Lista)
        $seleccion = $Lista.SelectedItem
        if ($null -eq $seleccion) { return }
        $Lista.SelectedIndex = -1
        & $abrirInforme $seleccion.Ruta
    }

    $c.ListaInformesHtml.Add_SelectionChanged({ & $abrirSeleccionInforme $c.ListaInformesHtml })
    $c.ListaInformesCsv.Add_SelectionChanged({  & $abrirSeleccionInforme $c.ListaInformesCsv  })
    $c.ListaInformesJson.Add_SelectionChanged({ & $abrirSeleccionInforme $c.ListaInformesJson })

    $c.ListaHistorial.Add_SelectionChanged({
        $entrada = $c.ListaHistorial.SelectedItem
        if ($null -eq $entrada) { return }
        $c.ListaHistorial.SelectedIndex = -1
        # Entradas antiguas o con el informe borrado: se informa al usuario.
        if ([string]::IsNullOrEmpty($entrada.Informe)) {
            [Windows.MessageBox]::Show(
                "Esta ejecución no tiene ningún informe guardado.`n`nDesde ahora, cada análisis y cada limpieza generan el suyo automáticamente; las ejecuciones anteriores a este cambio solo dejaron el resumen que ves en la tarjeta.",
                'Sin informe', 'OK', 'Information') | Out-Null
            return
        }
        & $abrirInforme $entrada.Informe
    })

    # ---- Ajustes ----
    # Cambiar cualquier umbral pasa el perfil a Personalizado, para que el
    # perfil mostrado corresponda a los valores que se usan.
    $pasarAPersonalizado = {
        # No cuando es la propia aplicación la que ajusta los controles.
        if ($estado.SincronizandoPerfil) { return }
        $vista = @($estado.PerfilesVista | Where-Object { $_.Id -eq 'personalizado' })[0]
        if ($null -ne $vista -and -not $vista.Activo) { $vista.Activo = $true }
    }

    # El runspace de trabajo lee el mismo objeto de configuración (por
    # referencia). Con un trabajo en marcha se rechazan los cambios de
    # ajustes y se restauran los controles, para no mezclar configuraciones
    # ni escribir sobre un objeto que otro hilo está leyendo.
    $ajusteBloqueadoPorTrabajo = {
        # Con la bandera puesta es la propia aplicación la que ajusta los
        # controles; sin esta comprobación habría recursión infinita.
        if ($estado.SincronizandoPerfil) { return $false }
        if (-not $estado.Ocupado) { return $false }
        $estado.SincronizandoPerfil = $true
        try {
            $c.SliderMinimoMB.Value    = $estado.Configuracion.MinimoMB
            $c.SliderDias.Value        = $estado.Configuracion.DiasSinUso
            $c.ChkMenores.IsChecked    = $estado.Configuracion.IncluirMenores
            $c.ChkPermanente.IsChecked = $estado.Configuracion.Permanente
        } finally {
            $estado.SincronizandoPerfil = $false
        }
        Show-Aviso -Mensaje 'Hay un análisis o una limpieza en marcha. Los ajustes se aplican al empezar, así que cambiarlos ahora dejaría el trabajo a medias con dos configuraciones distintas. Espera a que termine o cancélalo.' -Tipo 'Information'
        return $true
    }

    $c.SliderMinimoMB.Add_ValueChanged({
        if (& $ajusteBloqueadoPorTrabajo) { return }
        $c.TxtMinimoMB.Text = '{0} MB' -f [int]$c.SliderMinimoMB.Value
        $estado.Preferencias.MinimoMB = [int]$c.SliderMinimoMB.Value
        & $pasarAPersonalizado
    })
    $c.SliderDias.Add_ValueChanged({
        if (& $ajusteBloqueadoPorTrabajo) { return }
        $c.TxtDiasSinUso.Text = '{0} días' -f [int]$c.SliderDias.Value
        $estado.Preferencias.DiasSinUso = [int]$c.SliderDias.Value
        & $pasarAPersonalizado
    })
    # Add_Checked + Add_Unchecked y no Add_Click: Click solo salta cuando
    # pulsa el usuario, no al asignar IsChecked desde código (elegir perfil,
    # "Restablecer"). Con Click, la preferencia de borrado permanente podía
    # quedar activada aunque la casilla se mostrara desmarcada.
    $sincronizarMenores = {
        if (& $ajusteBloqueadoPorTrabajo) { return }
        $estado.Preferencias.IncluirMenores = [bool]$c.ChkMenores.IsChecked
        & $pasarAPersonalizado
    }
    $c.ChkMenores.Add_Checked($sincronizarMenores)
    $c.ChkMenores.Add_Unchecked($sincronizarMenores)

    $sincronizarPermanente = {
        if (& $ajusteBloqueadoPorTrabajo) { return }
        $estado.Preferencias.Permanente = [bool]$c.ChkPermanente.IsChecked
        & $pasarAPersonalizado
    }
    $c.ChkPermanente.Add_Checked($sincronizarPermanente)
    $c.ChkPermanente.Add_Unchecked($sincronizarPermanente)

    # ---- Quitar una exclusión ----
    # El botón "Quitar" está dentro de la plantilla de cada fila: el evento
    # se engancha en la lista, como en la cabecera de grupo de la tabla.
    $c.ListaExclusiones.AddHandler(
        [Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [Windows.RoutedEventHandler]{
            param($remitente, $argumentos)

            $boton = $argumentos.OriginalSource -as [Windows.Controls.Button]
            if ($null -eq $boton) { return }

            # Por nombre y no por el texto del botón, que puede cambiar.
            if ($boton.Name -ne 'BtnQuitarExclusion') { return }

            # Se usa la clave (en el Tag) y no el título visible, que difiere
            # en comandos y papelera.
            & $quitarExclusion ([string]$boton.Tag)
        })

    $c.BtnAbrirDatos.Add_Click({
        try { Start-Process -FilePath (Get-RutaExplorador) -ArgumentList "`"$($estado.Configuracion.CarpetaDatos)`"" }
        catch { Show-Aviso -Mensaje "No se ha podido abrir la carpeta de datos:`n$($_.Exception.Message)" -Tipo 'Warning' }
    })

    $c.BtnRestablecer.Add_Click({
        if ($estado.Ocupado) {
            Show-Aviso -Mensaje 'Hay un análisis o una limpieza en marcha. Espera a que termine o cancélalo antes de restablecer los ajustes.' -Tipo 'Information'
            return
        }

        # El mensaje indica también lo que no se toca, incluidas las
        # exclusiones del usuario.
        $respuesta = [Windows.MessageBox]::Show(
            ('Se van a restablecer los umbrales, el perfil, los módulos marcados y la ' +
             'selección de discos. El tema, el historial y lo que hayas excluido no se tocan.' + [Environment]::NewLine +
             [Environment]::NewLine + 'Continuar?'),
            'Restablecer ajustes', 'YesNo', 'Question')
        if ($respuesta -ne 'Yes') { return }

        # Volver al perfil por defecto también devuelve los umbrales a sus
        # valores, así que se hace primero y después se refresca todo.
        $vista = @($estado.PerfilesVista | Where-Object { $_.Id -eq 'equilibrado' })[0]
        if ($null -ne $vista) { $vista.Activo = $true }

        $estado.SincronizandoPerfil = $true
        try {
            $c.SliderMinimoMB.Value    = $estado.Configuracion.MinimoMB
            $c.SliderDias.Value        = $estado.Configuracion.DiasSinUso
            $c.ChkMenores.IsChecked    = $estado.Configuracion.IncluirMenores
            $c.ChkPermanente.IsChecked = $estado.Configuracion.Permanente
        } finally {
            $estado.SincronizandoPerfil = $false
        }

        # Todos los discos vuelven a entrar en el análisis.
        $estado.Preferencias.UnidadesExcluidas = @()
        foreach ($disco in $estado.DiscosVista) { $disco.Seleccionado = $true }

        & $refrescarModulos

        # Se guarda al momento por si el programa no se cierra con normalidad.
        & $guardarPreferencias
        & $escribir 'Ajustes restablecidos: perfil Equilibrado, umbrales por defecto, todos los discos.'
    })

    $c.BtnReiniciarAdmin.Add_Click({
        $entrada = Join-Path $estado.Raiz 'Cachivache.ps1'
        try {
            # Se guarda antes de lanzar la copia elevada, que lee
            # preferencias.json al arrancar (evita una carrera con el cierre).
            & $guardarPreferencias

            Start-Process -FilePath (Get-RutaPowerShell) -Verb RunAs -ArgumentList @(
                '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$entrada`""
            )
            $ventana.Close()
        } catch {
            [Windows.MessageBox]::Show('No se ha podido reiniciar con permisos de administrador.',
                'Permisos', 'OK', 'Warning') | Out-Null
        }
    })

    $c.BtnRepositorio.Add_Click({
        try { Start-Process $script:RepositorioUrl }
        catch { Show-Aviso -Mensaje "No se ha podido abrir el navegador. La direccion es: $script:RepositorioUrl" }
    })

    # ---- Acerca de: comprobar si hay una versión nueva ----
    # La consulta de red se hace en un runspace aparte para no bloquear la
    # ventana durante el tiempo de espera. Solo carga Version.ps1, que no
    # toca el disco ni la guardia.
    $codigoVersion = @'
$ErrorActionPreference = 'Stop'
. $archivoVersion
Get-UltimaVersionPublicada -TiempoEspera 6
'@

    # Muestra el resultado; el texto lo decide Get-AvisoActualizacion.
    $pintarAvisoVersion = {
        param([AllowNull()] [string] $Publicada)

        $aviso = Get-AvisoActualizacion -Instalada $script:VersionCachivache -Publicada $Publicada
        $c.TxtActualizacion.Text = $aviso.Texto
        $c.BtnIrAVersionNueva.Visibility = if ($aviso.Hay) { 'Visible' } else { 'Collapsed' }
        $c.BtnBuscarActualizacion.IsEnabled = $true
    }

    # Libera la consulta. Se llama desde el sondeo y desde el cierre de la
    # ventana, para que un hilo esperando a la red no retrase la salida.
    $soltarComprobacionVersion = {
        if ($estado.TemporizadorVersion) { $estado.TemporizadorVersion.Stop() }

        $trabajo = $estado.TrabajoVersion
        # Se pone a $null antes de liberar: si Dispose lanza, el botón sigue
        # utilizable.
        $estado.TrabajoVersion = $null
        if (-not $trabajo) { return }

        try { $trabajo.Ps.Stop() }        catch { Write-Verbose "Al parar la consulta de versión: $($_.Exception.Message)" }
        try { $trabajo.Ps.Dispose() }     catch { Write-Verbose "Al soltar la consulta de versión: $($_.Exception.Message)" }
        try { $trabajo.Runspace.Dispose() } catch { Write-Verbose "Al soltar el runspace de versión: $($_.Exception.Message)" }
    }

    # Sondeo con DispatcherTimer, como en el análisis, para volver al hilo
    # de la interfaz sin bloquearlo.
    $revisarComprobacionVersion = {
        $trabajo = $estado.TrabajoVersion
        if (-not $trabajo) {
            if ($estado.TemporizadorVersion) { $estado.TemporizadorVersion.Stop() }
            return
        }
        if (-not $trabajo.Handle.IsCompleted) { return }

        # Cadena vacía = "no se ha podido saber" para Get-AvisoActualizacion.
        $publicada = ''
        try {
            $salida = $trabajo.Ps.EndInvoke($trabajo.Handle)
            if ($salida -and $salida.Count -gt 0) { $publicada = [string]$salida[$salida.Count - 1] }
        } catch {
            Write-Verbose "La consulta de versión no ha devuelto nada: $($_.Exception.Message)"
        }

        & $soltarComprobacionVersion
        & $pintarAvisoVersion $publicada
    }

    $estado.TemporizadorVersion = New-Object Windows.Threading.DispatcherTimer
    $estado.TemporizadorVersion.Interval = [TimeSpan]::FromMilliseconds(200)
    $estado.TemporizadorVersion.Add_Tick($revisarComprobacionVersion)

    $c.BtnBuscarActualizacion.Add_Click({
        # Evita lanzar dos consultas a la vez.
        if ($estado.TrabajoVersion) { return }

        $c.BtnBuscarActualizacion.IsEnabled = $false
        $c.BtnIrAVersionNueva.Visibility = 'Collapsed'
        $c.TxtActualizacion.Text = 'Comprobando en GitHub cuál es la última versión publicada...'

        try {
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $runspace.SessionStateProxy.SetVariable('archivoVersion',
                (Join-Path (Join-Path (Join-Path $estado.Raiz 'src') 'Core') 'Version.ps1'))

            $consulta = [powershell]::Create()
            $consulta.Runspace = $runspace
            [void]$consulta.AddScript($codigoVersion)

            $estado.TrabajoVersion = @{
                Ps       = $consulta
                Runspace = $runspace
                Handle   = $consulta.BeginInvoke()
            }
            $estado.TemporizadorVersion.Start()
        } catch {
            # Para el usuario equivale a un fallo de red: mismo mensaje.
            Write-Verbose "No se ha podido lanzar la consulta de versión: $($_.Exception.Message)"
            $estado.TrabajoVersion = $null
            & $pintarAvisoVersion ''
        }
    })

    $c.BtnIrAVersionNueva.Add_Click({
        # Solo se abre la página: el programa no se actualiza a sí mismo.
        $url = Get-UrlUltimaVersion
        try { Start-Process $url }
        catch { Show-Aviso -Mensaje "No se ha podido abrir el navegador. La dirección es: $url" }
    })

    # ---- Acerca de: copiar el diagnóstico ----
    # La misma función que .\Cachivache.ps1 -Diagnostico (lo comprueba una
    # invariante).
    $c.BtnCopiarDiagnostico.Add_Click({
        try {
            $diagnostico = Get-InformeDiagnostico -Admin $estado.Configuracion.Admin `
                                                  -CarpetaDatos $estado.Configuracion.CarpetaDatos
            [Windows.Clipboard]::SetText($diagnostico)
            & $escribir 'Diagnóstico copiado al portapapeles.'
            # Se confirma con un aviso: la copia no es visible.
            Show-Aviso -Tipo 'Information' -Titulo 'Diagnóstico copiado' -Mensaje (
                'El diagnóstico está en el portapapeles. Pégalo en la incidencia con Control+V.')
        } catch {
            Show-Aviso -Tipo 'Warning' -Mensaje (
                "No se ha podido copiar el diagnóstico:`n{0}" -f (Get-DetalleExcepcion -ErrorRecord $_))
        }
    })

    # ---- Perfiles ----
    foreach ($perfil in (Get-PerfilesLimpieza)) {
        $vista = New-Object Cachivache.PerfilVista
        $vista.Id      = $perfil.Id
        $vista.Nombre  = $perfil.Nombre
        $vista.Resumen = $perfil.Resumen
        $vista.Activo  = ($perfil.Id -eq $estado.Configuracion.Perfil)
        $vista.add_PropertyChanged({
            param($remitente, $argumentos)
            if ($argumentos.PropertyName -ne 'Activo' -or -not $remitente.Activo) { return }

            # Set-PerfilConfiguracion modifica el objeto de configuración que
            # lee el runspace: con un trabajo en marcha se ignora el cambio y
            # se restaura la tarjeta.
            if ($estado.Ocupado) {
                $estado.SincronizandoPerfil = $true
                try {
                    foreach ($otro in $estado.PerfilesVista) {
                        $otro.Activo = ($otro.Id -eq $estado.Configuracion.Perfil)
                    }
                } finally {
                    $estado.SincronizandoPerfil = $false
                }
                Show-Aviso -Mensaje 'Hay un análisis o una limpieza en marcha. El perfil se aplica al empezar, así que cambiarlo ahora dejaría el trabajo a medias con dos configuraciones distintas. Espera a que termine o cancélalo.' -Tipo 'Information'
                return
            }

            $estado.Configuracion = Set-PerfilConfiguracion -Configuracion $estado.Configuracion -Perfil $remitente.Id
            $estado.Preferencias.Perfil = $remitente.Id
            if ($remitente.Id -ne 'personalizado') {
                # La bandera evita que ajustar estos controles pase el perfil
                # a Personalizado.
                $estado.SincronizandoPerfil = $true
                try {
                    $c.SliderMinimoMB.Value    = $estado.Configuracion.MinimoMB
                    $c.SliderDias.Value        = $estado.Configuracion.DiasSinUso
                    $c.ChkMenores.IsChecked    = $estado.Configuracion.IncluirMenores
                    $c.ChkPermanente.IsChecked = $estado.Configuracion.Permanente
                } finally {
                    $estado.SincronizandoPerfil = $false
                }
                # Solo un perfil con nombre redefine los módulos. Personalizado
                # conserva lo marcado: se llega a él al cambiar una casilla,
                # y refrescar aquí desharía ese cambio.
                & $refrescarModulos
            }
        }.GetNewClosure())
        $estado.PerfilesVista.Add($vista)
    }

    # ---- Guardado de preferencias al cerrar ----
    $ventana.Add_Closing({
        # Los parámetros se declaran aunque no se usen: sin ellos no se
        # podría cancelar el cierre.
        param($remitente, $argumentos)

        $estabaBorrando = $estado.Ocupado -and $estado.Fase -eq 'borrado'

        $estado.Sync.Cancelar = $true
        & $limpiarTrabajo
        # Un tick del filtro tras el cierre tocaría controles ya inexistentes.
        if ($estado.TemporizadorFiltro) { $estado.TemporizadorFiltro.Stop() }
        # Se libera la consulta de versión para no retrasar la salida.
        & $soltarComprobacionVersion
        # Última pasada de la cola del registro. Invoke-VaciarColaRegistro y
        # no $volcarRegistro: basta con que las líneas lleguen al archivo.
        [void](Invoke-VaciarColaRegistro -Sync $estado.Sync)

        # Si se cierra a mitad de un borrado, $terminarBorrado no se ejecuta:
        # se anota en el historial una limpieza interrumpida con las últimas
        # cifras conocidas, antes de cerrar el runspace. Una simulación no se
        # anota, igual que al terminar.
        if ($estabaBorrando -and -not $estado.SimulandoLote) {
            try {
                $parcial  = $estado.Sync.Resultado
                $liberado = if ($parcial) { [double]$parcial.Liberado } else { 0.0 }
                $hechos   = if ($parcial) { [int]$parcial.Hechos } else { 0 }
                $motivo   = 'Se cerró la ventana a mitad: se eliminaron {0} de {1} elementos marcados.' -f $hechos, $estado.Total

                Add-EntradaHistorial -Tipo 'limpieza-interrumpida' `
                                     -Perfil $estado.Configuracion.Perfil `
                                     -Modulos @($estado.ModulosLote) `
                                     -Elementos $hechos -Bytes $liberado `
                                     -Incompleto -Motivo $motivo `
                                     -CarpetaDatos $estado.Configuracion.CarpetaDatos -Confirm:$false | Out-Null
            } catch {
                Write-Verbose "No se ha podido anotar la limpieza interrumpida: $($_.Exception.Message)"
            }
        }

        & $cerrarRunspace
        & $guardarPreferencias
    })

