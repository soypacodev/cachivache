<#
.SYNOPSIS
    Cierres auxiliares de la ventana: escribir en consola, refrescar listas,
    filtrar y cambiar de tema.

.DESCRIPTION
    Se carga antes que los demás trozos porque estos usan sus cierres.

    Este archivo no se ejecuta solo: Show-VentanaPrincipal (Window.ps1) lo
    carga con dot-source dentro de la función, por lo que usa $c, $estado y
    $ventana sin declararlos. Ver docs/ESTRUCTURA.md (sección 3).
#>

    # =================================================================
    #  FUNCIONES AUXILIARES DE INTERFAZ
    # =================================================================
    # Líneas que se conservan en el panel de Registro y margen antes de
    # recortar. Recortar reconstruye todo el texto, así que se hace de vez en
    # cuando y de golpe. El archivo de registro conserva todas las líneas.
    $maximoLineasConsola = 2000
    $margenLineasConsola = 1000

    # Único camino hacia el panel de Registro: vacía la cola (del hilo de la
    # ventana o del runspace) y muestra exactamente las mismas líneas que van
    # al archivo.
    $volcarRegistro = {
        $lineas = @(Invoke-VaciarColaRegistro -Sync $estado.Sync)
        if ($lineas.Count -eq 0) { return }

        # Una sola llamada por bloque para no repintar por cada línea.
        $c.Consola.AppendText(($lineas -join [Environment]::NewLine) + [Environment]::NewLine)
        $estado.LineasConsola += $lineas.Count

        if ($estado.LineasConsola -gt ($maximoLineasConsola + $margenLineasConsola)) {
            $conservadas = @($c.Consola.Text -split "`r?`n" | Select-Object -Last $maximoLineasConsola)
            $c.Consola.Text = '--- líneas anteriores recortadas; en el archivo del registro están todas ---' +
                              [Environment]::NewLine + ($conservadas -join [Environment]::NewLine)
            $estado.LineasConsola = $conservadas.Count + 1
        }

        $c.Consola.ScrollToEnd()
    }

    $escribir = {
        param([string] $Texto, [string] $Nivel = 'INFO')
        Write-Registro -Sync $estado.Sync -Mensaje $Texto -Nivel $Nivel
        # Se vuelca al momento: normalmente el temporizador está parado.
        & $volcarRegistro
    }

    # =================================================================
    #  Conservar desplazamiento y selección al reenganchar la tabla
    # =================================================================
    # Estos cierres solo leen y escriben en WPF; la decisión es de
    # Get-PlanRestauracionTabla (Posicion.ps1). Un fallo aquí no debe
    # interrumpir el análisis: se registra como AVISO y se continúa.
    $desplazadorDeTabla = {
        # El ScrollViewer está dentro de la plantilla del DataGrid: se busca
        # en el árbol visual por tipo, no por el nombre "DG_ScrollViewer" de
        # la plantilla por defecto, que desaparece si se redefine la plantilla.
        if ($null -ne $estado.DesplazadorTabla) { return $estado.DesplazadorTabla }

        # ::new() y no New-Object para colecciones genéricas (lo exige una
        # invariante; ver la nota de Candidatos en Window.ps1).
        $pila = [System.Collections.Generic.Stack[System.Windows.DependencyObject]]::new()
        $pila.Push($c.TablaResultados)
        while ($pila.Count -gt 0) {
            $nodo = $pila.Pop()
            if ($nodo -is [System.Windows.Controls.ScrollViewer]) {
                $estado.DesplazadorTabla = $nodo
                return $nodo
            }
            $cuantos = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($nodo)
            for ($i = 0; $i -lt $cuantos; $i++) {
                $pila.Push([System.Windows.Media.VisualTreeHelper]::GetChild($nodo, $i))
            }
        }
        return $null
    }

    # Se llama justo antes de poner ItemsSource a $null. Nunca devuelve $null.
    $guardarPosicionTabla = {
        $desplazamiento = 0.0
        try {
            $sv = & $desplazadorDeTabla
            if ($null -ne $sv) { $desplazamiento = [double] $sv.VerticalOffset }
        } catch {
            Write-Registro -Sync $estado.Sync -Nivel 'AVISO' -Mensaje (
                'No se ha podido guardar la posición de la tabla: {0}' -f $_.Exception.Message)
        }
        return [pscustomobject]@{
            Desplazamiento = $desplazamiento
            Seleccion      = $c.TablaResultados.SelectedItem
        }
    }

    # Se llama justo después de volver a enganchar la colección.
    $restaurarPosicionTabla = {
        param($Guardado)

        if ($null -eq $Guardado) { return }

        try {
            $sv = & $desplazadorDeTabla

            # Hay que forzar la medida: tras reenganchar, ScrollableHeight
            # aún refleja la lista anterior y ScrollToVerticalOffset
            # recortaría contra ese valor.
            if ($null -ne $sv) { $c.TablaResultados.UpdateLayout() }

            $maximo = 0.0
            if ($null -ne $sv) { $maximo = [double] $sv.ScrollableHeight }

            $habia   = $null -ne $Guardado.Seleccion
            $visible = $false
            if ($habia) {
                # Se invoca el propio predicado del filtro: Vista.Contains
                # recorrería toda la vista.
                $filtro = $null
                if ($null -ne $estado.Vista) { $filtro = $estado.Vista.Filter }
                if ($null -eq $filtro) { $visible = $true }
                else { $visible = [bool] $filtro.Invoke($Guardado.Seleccion) }
            }

            $plan = Get-PlanRestauracionTabla -Guardado ([double] $Guardado.Desplazamiento) `
                                              -Maximo $maximo `
                                              -HabiaSeleccion:$habia -SeleccionVisible:$visible
            if (-not $plan.HayQueHacerAlgo) { return }

            if ($plan.RestaurarSeleccion) {
                # Deliberadamente sin ScrollIntoView: chocaría con el
                # desplazamiento restaurado (lo comprueba una invariante).
                $c.TablaResultados.SelectedItem = $Guardado.Seleccion
            }
            if ($plan.Desplazamiento -gt 0 -and $null -ne $sv) {
                $sv.ScrollToVerticalOffset($plan.Desplazamiento)
            }
        } catch {
            Write-Registro -Sync $estado.Sync -Nivel 'AVISO' -Mensaje (
                'No se ha podido restaurar la posición de la tabla: {0}' -f $_.Exception.Message)
        }
    }

    # Manejador único para las casillas de las unidades. Sin GetNewClosure:
    # capturaría solo el ámbito local y dejaría a $null los cierres que usa.
    $manejadorUnidadGlobal = {
        param($remitente, $argumentos)
        if ($argumentos.PropertyName -ne 'Seleccionado') { return }
        & $actualizarUnidadesElegidas
    }

    # Traslada las unidades marcadas a la configuración. El filtro real está
    # en ModuleRegistry.ps1 (Test-UnidadSeleccionada).
    $actualizarUnidadesElegidas = {
        $elegidas = @($estado.DiscosVista | Where-Object { $_.Seleccionado } | ForEach-Object { $_.Letra })
        $estado.Configuracion.UnidadesSeleccionadas = $elegidas
        $estado.Preferencias.UnidadesExcluidas =
            @($estado.DiscosVista | Where-Object { -not $_.Seleccionado } | ForEach-Object { $_.Letra })

        if ($elegidas.Count -eq 0) {
            & $escribir 'No queda ninguna unidad marcada: el análisis no encontrará nada.' 'AVISO'
        }
    }

    $refrescarDiscos = {
        $estado.Configuracion.Unidades = @(Get-UnidadesAnalizables)
        $estado.LibreCache = Get-EspacioLibre $estado.Configuracion.Unidad

        # Las exclusiones del usuario pasan de las preferencias a la
        # configuración, que es lo que consultan el análisis y el borrado.
        $estado.Configuracion.RutasExcluidas = @($estado.Preferencias.RutasExcluidas)

        # Se guardan las unidades excluidas, no las incluidas, para que un
        # disco nuevo aparezca marcado por defecto.
        $excluidas = @($estado.Preferencias.UnidadesExcluidas)

        $c.ListaDiscos.ItemsSource = $null
        $lista = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.DiscoVista]
        foreach ($unidad in $estado.Configuracion.Unidades) {
            $vista = New-Object Cachivache.DiscoVista
            $vista.Letra      = $unidad.Letra
            $vista.Titulo     = '{0}  {1}' -f $unidad.Letra, $unidad.Etiqueta
            $vista.Detalle    = '{0} libres de {1}' -f (Format-Tamano $unidad.Libre), (Format-Tamano $unidad.Total)
            $vista.Porcentaje = '{0}%' -f $unidad.PorcentajeUsado
            $vista.AnchoUsado = [Math]::Round(160 * $unidad.PorcentajeUsado / 100, 0)
            # Rojo o ámbar cuando queda poco espacio.
            $vista.ColorBarra = if ($unidad.PorcentajeUsado -ge 92) { Get-ColorAcentoTema 'Peligro' $estado.Tema }
                                elseif ($unidad.PorcentajeUsado -ge 80) { Get-ColorAcentoTema 'Aviso' $estado.Tema }
                                else { Get-ColorAcentoTema 'Acento' $estado.Tema }
            $vista.Seleccionado = ($excluidas -notcontains $unidad.Letra)
            $vista.add_PropertyChanged($manejadorUnidadGlobal)
            $lista.Add($vista)
        }
        $estado.DiscosVista = $lista
        $c.ListaDiscos.ItemsSource = $lista
        & $actualizarUnidadesElegidas
    }

    # =================================================================
    #  EXCLUSIONES DEL USUARIO (tarjeta de Ajustes)
    # =================================================================
    # La lista se reconstruye entera cada vez (son pocas filas). Cómo se
    # presenta cada clave lo decide Get-ExclusionVista; aquí no se interpreta
    # la clave.
    $refrescarExclusiones = {
        $lista = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.ExclusionVista]
        foreach ($clave in @($estado.Preferencias.RutasExcluidas)) {
            $vista = Get-ExclusionVista -Clave ([string]$clave)
            # $null indica una entrada no representable (p. ej. en blanco en
            # un preferencias.json editado a mano): se omite.
            if ($null -eq $vista) { continue }

            $fila = New-Object Cachivache.ExclusionVista
            $fila.Clave   = $vista.Clave
            $fila.Titulo  = $vista.Titulo
            $fila.Detalle = $vista.Detalle
            $fila.Tipo    = $vista.Tipo
            $lista.Add($fila)
        }

        $c.ListaExclusiones.ItemsSource = $lista
        # Se cuentan las filas mostradas, no las entradas de las preferencias.
        $c.TxtResumenExclusiones.Text = Get-TextoListaExclusiones -Cuantas $lista.Count
    }

    # Quitar una exclusión no pide confirmación (añadirla sí). Añadir oculta
    # el elemento de todos los análisis, y un error pasaría desapercibido;
    # quitar solo vuelve a proponerlo, y entre proponer y borrar siguen la
    # casilla, el diálogo de confirmación y la guardia. Confirmar todo haría
    # que las confirmaciones importantes se acepten sin leer.
    $quitarExclusion = {
        param([string] $Clave)

        if ([string]::IsNullOrWhiteSpace($Clave)) { return }

        # Comparación ordinal exacta: la clave del Tag es la cadena guardada.
        # Ignorar mayúsculas podría quitar otra entrada distinta.
        $antes  = @($estado.Preferencias.RutasExcluidas)
        $quedan = @($antes | Where-Object { -not [string]::Equals([string]$_, $Clave, [StringComparison]::Ordinal) })

        if ($quedan.Count -eq $antes.Count) {
            # No debería ocurrir; si ocurre, la tarjeta está desfasada y se
            # vuelve a pintar.
            & $escribir ('Se ha pedido quitar una exclusión que ya no estaba en la lista: {0}' -f $Clave) 'AVISO'
            & $refrescarExclusiones
            return
        }

        # Se actualizan las preferencias y también la configuración: solo se
        # sincronizan al refrescar los discos, y el cambio debe aplicarse ya.
        $estado.Preferencias.RutasExcluidas  = $quedan
        $estado.Configuracion.RutasExcluidas = @($estado.Preferencias.RutasExcluidas)

        # Se guarda al momento, igual que al añadir, para que un cierre
        # anormal no pierda el cambio.
        & $guardarPreferencias
        & $refrescarExclusiones
        & $escribir ('Ya no está excluido: {0}. Volverá a proponerse en los próximos análisis.' -f $Clave)
    }

    # Las tres listas de informes. Se reconstruyen al abrir el panel porque
    # los archivos pueden cambiar desde fuera.
    $refrescarInformes = {
        # Los controles se nombran literalmente, sin componer el nombre, para
        # que la prueba que contrasta los nombres con el XAML los detecte.
        $destinos = @(
            @{ Formato = 'html'; Lista = $c.ListaInformesHtml; Vacio = $c.TxtSinInformesHtml }
            @{ Formato = 'csv';  Lista = $c.ListaInformesCsv;  Vacio = $c.TxtSinInformesCsv  }
            @{ Formato = 'json'; Lista = $c.ListaInformesJson; Vacio = $c.TxtSinInformesJson }
        )

        $ahora = [datetime]::Now
        foreach ($destino in $destinos) {
            $lista = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.InformeVista]
            foreach ($informe in @(Get-InformesGuardados -Formato $destino.Formato `
                                       -CarpetaDatos $estado.Configuracion.CarpetaDatos)) {
                $vista = New-Object Cachivache.InformeVista
                $vista.Nombre = $informe.Nombre
                $vista.Ruta   = $informe.Ruta
                $vista.Tamano = Format-Tamano $informe.Bytes

                $etiqueta = if ($informe.Tipo -eq 'limpieza') { 'Limpieza' }
                            elseif ($informe.Tipo -eq 'analisis') { 'Analisis' }
                            else { 'Informe' }
                $dias = [int]($ahora.Date - $informe.Fecha.Date).TotalDays
                $cuando = if ($dias -le 0) { 'hoy' }
                          elseif ($dias -eq 1) { 'ayer' }
                          else { "hace $dias días" }
                $vista.Detalle = '{0} - {1}, {2}' -f $etiqueta, $informe.Fecha.ToString('d \d\e MMMM \d\e yyyy, HH:mm'), $cuando

                $lista.Add($vista)
            }

            $destino.Lista.ItemsSource = $lista
            $destino.Vacio.Visibility = if ($lista.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        }
    }

    $refrescarHistorial = {
        $entradas = @(Get-Historial -CarpetaDatos $estado.Configuracion.CarpetaDatos)
        $lista = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.HistorialVista]
        foreach ($entrada in ($entradas | Select-Object -Last 25)) {
            $vista = New-Object Cachivache.HistorialVista
            $esLimpieza = [string]$entrada.Tipo -eq 'limpieza'
            $vista.Tipo      = if ($esLimpieza) { 'LIMPIEZA' } else { 'ANALISIS' }
            # Colores del tema activo: verde para limpiezas y acento para
            # análisis.
            $vista.ColorTipo = if ($esLimpieza) { Get-ColorAcentoTema 'Exito' $estado.Tema }
                               else { Get-ColorAcentoTema 'Acento' $estado.Tema }
            $fecha = try { [datetime]::Parse($entrada.Fecha) } catch { Get-Date }
            $vista.Titulo  = $fecha.ToString('dddd d \d\e MMMM, HH:mm')
            $cuantos = if ("$($entrada.Elementos)" -eq '1') { '1 elemento' } else { '{0} elementos' -f $entrada.Elementos }
            $vista.Detalle = '{0} - perfil {1}' -f $cuantos, $entrada.Perfil
            # ConvertTo-DoubleSeguro y no [double]: el dato viene de un archivo
            # editable y una excepción aquí impediría abrir la ventana.
            $vista.Tamano  = Format-Tamano (ConvertTo-DoubleSeguro $entrada.Bytes)

            # El historial es un JSON editable y no es de fiar: la ruta del
            # informe se valida antes de guardarla en la vista. Si no pasa,
            # queda vacía y la tarjeta muestra "sin informe".
            $informe = ''
            if ($entrada.PSObject.Properties['Informe'] -and $entrada.Informe) {
                $informe = [string](Resolve-InformeAbrible -Ruta $entrada.Informe `
                                                           -CarpetaDatos $estado.Configuracion.CarpetaDatos)
            }
            $vista.Informe = $informe

            $lista.Insert(0, $vista)
        }
        $c.ListaHistorial.ItemsSource = $lista
        $c.TxtHistorialVacio.Visibility = if ($lista.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        & $refrescarInformes

        $resumen = Get-ResumenHistorial -CarpetaDatos $estado.Configuracion.CarpetaDatos
        if ($resumen.Limpiezas -gt 0) {
            $veces = if ($resumen.Limpiezas -eq 1) { '1 limpieza' } else { '{0} limpiezas' -f $resumen.Limpiezas }
            $c.TxtTotalHistorico.Text = 'Recuperados {0} en {1}.' -f (Format-Tamano $resumen.BytesTotales), $veces
        } else {
            $c.TxtTotalHistorico.Text = 'Sin limpiezas registradas todavía.'
        }
    }

    # Manejador único para las casillas de los módulos (sin GetNewClosure,
    # como el de las filas). Cambiar un módulo pasa el perfil a
    # Personalizado: $refrescarModulos solo respeta ModulosActivos en ese
    # perfil.
    $manejadorModuloGlobal = {
        param($remitente, $argumentos)
        if ($argumentos.PropertyName -ne 'Seleccionado') { return }
        & $pasarAPersonalizado
    }

    $refrescarModulos = {
        $estado.ModulosVista.Clear()
        $perfil = $estado.Configuracion.Perfil
        foreach ($modulo in $estado.Modulos) {
            $vista = New-Object Cachivache.ModuloVista
            $vista.Id          = $modulo.Id
            $vista.Nombre      = $modulo.Nombre
            $vista.Descripcion = $modulo.Descripcion
            $vista.Riesgo      = $modulo.Riesgo
            $vista.ColorRiesgo = Get-ColorRiesgo -Riesgo $modulo.Riesgo -Tema $estado.Tema

            $notas = @()
            if ($modulo.SoloInforma) { $notas += 'Solo informa: este módulo nunca borra nada.' }
            if ($modulo.RequiereAdmin -and -not $estado.Configuracion.Admin) {
                $notas += 'Necesita permisos de administrador.'
            }
            $vista.Nota       = $notas -join ' '
            $vista.Disponible = -not ($modulo.RequiereAdmin -and -not $estado.Configuracion.Admin)
            $vista.Seleccionado = $vista.Disponible -and (Test-ModuloEnPerfil -Modulo $modulo -Perfil $perfil)

            if ($perfil -eq 'personalizado' -and @($estado.Preferencias.ModulosActivos).Count -gt 0) {
                $vista.Seleccionado = $vista.Disponible -and ($estado.Preferencias.ModulosActivos -contains $modulo.Id)
            }

            # El manejador se engancha después de fijar Seleccionado, para que
            # rellenar la lista no pase el perfil a Personalizado.
            $vista.add_PropertyChanged($manejadorModuloGlobal)
            $estado.ModulosVista.Add($vista)
        }
    }

    # Manejador único compartido por todas las filas de la tabla. Sin
    # GetNewClosure: capturaría solo el ámbito local y dejaría
    # $actualizarResumenSeleccion a $null.
    $manejadorSeleccionGlobal = {
        param($remitente, $argumentos)
        if ($argumentos.PropertyName -ne 'Seleccionado') { return }
        $remitente.Origen.Seleccionado = $remitente.Seleccionado
        if ($estado.SuprimirResumen) { return }
        & $actualizarResumenSeleccion
    }

    # =================================================================
    #  ESTADOS VACÍOS DE LA TABLA
    # =================================================================
    # Los controles del cartel se resuelven en la lista de $c de Window.ps1,
    # como todos los demás. FindName devuelve $null sin lanzar si falta un
    # nombre, y leer $null.Text tampoco lanza: se comprueba aquí y se
    # registra un error, sin impedir que la ventana se abra.
    $faltanControlesVacio = @(@('EstadoVacio', 'TxtEstadoVacio', 'BtnQuitarFiltros', 'BtnMostrarHechos') |
                              Where-Object { $null -eq $c[$_] })
    if ($faltanControlesVacio.Count -gt 0) {
        Write-Registro -Sync $estado.Sync -Nivel 'ERROR' -Mensaje (
            'No se han encontrado en la ventana estos controles, y la tabla vacía no podrá explicarse: {0}' -f
            ($faltanControlesVacio -join ', '))
    }

    $actualizarEstadoVacio = {
        if ($faltanControlesVacio.Count -gt 0) { return }

        # Fase de la sesión. $estado.Cronometro se crea al pulsar "Analizar
        # el equipo" y no vuelve a $null, así que $null significa que aún no
        # se ha analizado nada (una invariante vincula ambas cosas).
        $fase = if ($estado.Ocupado -and $estado.Fase -eq 'analisis') { 'analizando' }
                elseif ($null -eq $estado.Cronometro)                 { 'sin-analizar' }
                else                                                  { 'terminado' }

        # IsEmpty y no @($estado.Vista).Count: se evalúa en cada clic de
        # casilla y contar la vista obliga a materializarla entera.
        $hayVisibles = if ($null -ne $estado.Vista) { -not $estado.Vista.IsEmpty }
                       else { $estado.Items.Count -gt 0 }

        $veredicto = Get-EstadoVacio -Fase $fase -Total $estado.Items.Count -HayVisibles $hayVisibles `
                         -TextoFiltro $c.CampoFiltro.Text `
                         -RiesgoFiltro (Get-RiesgoDelFiltro -Indice $c.FiltroRiesgo.SelectedIndex) `
                         -OcultandoHechos ([bool]$c.ChkOcultarHechos.IsChecked)

        $c.TxtEstadoVacio.Text = $veredicto.Texto

        # El rótulo solo se asigna cuando el botón es visible, para no dejar
        # botones sin texto (accesibilidad).
        if ($veredicto.OfrecerQuitarFiltro) {
            $c.BtnQuitarFiltros.Content    = $veredicto.TextoBoton
            $c.BtnQuitarFiltros.Visibility = 'Visible'
        } else {
            $c.BtnQuitarFiltros.Visibility = 'Collapsed'
        }

        # Get-EstadoVacio garantiza que no se ofrecen ambos botones a la vez,
        # pero cada uno se oculta de forma independiente.
        if ($veredicto.OfrecerMostrarHechos) {
            $c.BtnMostrarHechos.Content    = $veredicto.TextoBoton
            $c.BtnMostrarHechos.Visibility = 'Visible'
        } else {
            $c.BtnMostrarHechos.Visibility = 'Collapsed'
        }

        $c.EstadoVacio.Visibility = if ($veredicto.Vacio) { 'Visible' } else { 'Collapsed' }
    }

    $quitarFiltros = {
        # Se quitan siempre los dos filtros (texto y riesgo): quitar solo uno
        # podría dejar la tabla igual de vacía. El rótulo del botón lo indica.
        $c.FiltroRiesgo.SelectedIndex = 0
        $c.CampoFiltro.Text = ''

        # Vaciar el cuadro de texto arma el temporizador del filtro; se
        # detiene para no filtrar dos veces.
        $estado.TemporizadorFiltro.Stop()
        & $aplicarFiltro

        # El botón pulsado desaparece con el cartel: el foco pasa al cuadro
        # de filtro para que el teclado no quede sin destino.
        [void] $c.CampoFiltro.Focus()
    }

    # =================================================================
    #  ABRIR LA UBICACIÓN DE UNA FILA
    # =================================================================
    # Un único cierre para el botón de la barra, la entrada del menú
    # contextual y el doble clic, de modo que la comprobación se escribe
    # una sola vez. Cada caso sin ubicación (sin fila, ruta inexistente,
    # elemento sin ruta real) muestra su propio mensaje.
    $abrirUbicacion = {
        param($Item)

        if ($null -eq $Item) {
            Show-Aviso -Mensaje 'Elige antes una fila de la lista: es su carpeta la que se abre.' -Tipo 'Information'
            return
        }

        # TieneRutaReal y no "el método es Comando": la papelera tampoco
        # tiene ruta y no es un comando.
        if (-not $Item.TieneRutaReal) {
            Show-Aviso -Tipo 'Information' -Mensaje (& $describirSinRuta $Item 'ubicación que abrir')
            return
        }

        $ruta = $Item.Ruta
        if (-not (Test-Path -LiteralPath $ruta)) {
            Show-Aviso -Mensaje ("Ya no existe: {0}`n`nO se ha borrado o movido desde el análisis. Vuelve a analizar para tener la lista al día." -f $ruta) -Tipo 'Warning'
            return
        }

        try {
            if ((Get-Item -LiteralPath $ruta -Force).PSIsContainer) {
                Start-Process -FilePath (Get-RutaExplorador) -ArgumentList "`"$ruta`""
            } else {
                Start-Process -FilePath (Get-RutaExplorador) -ArgumentList "/select,`"$ruta`""
            }
        } catch {
            Show-Aviso -Mensaje ("No se ha podido abrir la ubicación:`n{0}" -f $_.Exception.Message) -Tipo 'Warning'
        }
    }

    # Mensaje común para "este elemento no tiene ruta", compartido por
    # "Abrir ubicación" y "Copiar ruta". Quien llama completa la frase.
    $describirSinRuta = {
        param($Item, [string] $QueNoHay)

        $que = if (-not [string]::IsNullOrWhiteSpace($Item.Comando)) {
            'es un comando del sistema ({0})' -f $Item.Comando
        } else {
            'es una etiqueta del programa, no una carpeta ni un archivo del disco'
        }
        return ('«{0}» {1}, así que no hay ninguna {2}.' -f $Item.Nombre, $que, $QueNoHay)
    }

    $actualizarResumenSeleccion = {
        if ($estado.SuprimirResumen) { return }

        # El cartel de tabla vacía se actualiza aquí porque este cierre se
        # llama en todos los casos en que cambia la lista.
        & $actualizarEstadoVacio

        # El resumen de la simulación caduca al cambiar la selección. Quien lo
        # muestra lo hace después de llamar aquí.
        if ($c.AvisoSimulacion.Visibility -ne 'Collapsed') {
            $c.AvisoSimulacion.Visibility = 'Collapsed'
            $c.TxtAvisoSimulacion.Text    = ''
        }

        # La barra de herramientas se desactiva con la tabla vacía.
        $hayResultados = $estado.Items.Count -gt 0
        $c.BtnMarcarTodo.IsEnabled    = $hayResultados
        $c.BtnDesmarcarTodo.IsEnabled = $hayResultados
        $c.BtnSoloSeguros.IsEnabled   = $hayResultados
        $c.BtnAbrirCarpeta.IsEnabled  = $hayResultados
        $c.BtnVerContenido.IsEnabled = $hayResultados
        $c.BtnExportar.IsEnabled      = $hayResultados

        # El total sale de Items, no de la vista: es lo que se borrará,
        # aunque el filtro lo oculte. Un solo foreach (sin Where-Object)
        # porque se ejecuta en cada clic de casilla.
        $cuentaMarcados = 0
        $bytes = 0.0
        foreach ($item in $estado.Items) {
            if ($item.Seleccionado -and -not $item.Hecho) {
                $cuentaMarcados++
                $bytes += $item.Bytes
            }
        }

        if ($cuentaMarcados -eq 0) {
            $c.TxtSeleccion.Text  = 'Nada marcado.'
            $c.TxtProyeccion.Text = if ($hayResultados) { 'Marca los elementos que quieras eliminar.' }
                                    else { 'Analiza el equipo para ver aquí lo que se puede recuperar.' }
            $c.BtnEliminar.IsEnabled = $false
            return
        }

        # Marcados que el filtro oculta: el usuario debe saber que borrará
        # algo que no ve. Sin filtro no puede haber ocultos y se omite el
        # recorrido.
        $ocultos = 0
        if ($null -ne $estado.Vista -and $null -ne $estado.Vista.Filter) {
            $visiblesMarcados = 0
            foreach ($item in @($estado.Vista)) {
                if ($item.Seleccionado -and -not $item.Hecho) { $visiblesMarcados++ }
            }
            $ocultos = $cuentaMarcados - $visiblesMarcados
        }

        $libre = $estado.LibreCache
        $cuantos = if ($cuentaMarcados -eq 1) { '1 elemento marcado' } else { '{0} elementos marcados' -f $cuentaMarcados }
        # Carpetas vacías y accesos rotos se marcan solos y no ocupan nada:
        # "se recuperarían 0 B" parecería un fallo.
        $c.TxtSeleccion.Text = if ($bytes -gt 0) {
            '{0} - se recuperarían {1}' -f $cuantos, (Format-Tamano $bytes)
        } else {
            '{0} - no ocupan espacio' -f $cuantos
        }
        if ($ocultos -gt 0) {
            $c.TxtSeleccion.Text += ' ({0} que el filtro no está mostrando)' -f $ocultos
        }
        $c.TxtProyeccion.Text = if ($bytes -gt 0) {
            'En {0} pasarías de {1} libres a {2} libres.' -f `
                $estado.Configuracion.Unidad, (Format-Tamano $libre), (Format-Tamano ($libre + $bytes))
        } else {
            'Borrarlos ordena el equipo, pero no libera espacio en {0}.' -f $estado.Configuracion.Unidad
        }
        $c.BtnEliminar.IsEnabled = -not $estado.Ocupado
    }

    $aplicarFiltro = {
        if ($null -eq $estado.Vista) { return }
        $texto  = $c.CampoFiltro.Text
        # La correspondencia de posiciones del desplegable está en
        # Get-RiesgoDelFiltro, compartida con el cartel de tabla vacía.
        $riesgo = Get-RiesgoDelFiltro -Indice $c.FiltroRiesgo.SelectedIndex

        # "Ocultar hechos" no cuenta en Test-HayFiltroPuesto, que se refiere
        # solo a filtros de búsqueda (de ella depende el rótulo del botón del
        # cartel); aquí se considera aparte. Si el control falta, da $false.
        $ocultarHechos = [bool]$c.ChkOcultarHechos.IsChecked

        # Sin criterios se quita el filtro (Filter = $null) en vez de instalar
        # un predicado que acepte todo: WPF lo invocaría por cada fila, y el
        # resumen del pie usa "Filter no es $null" para saber si hay filtro.
        # Test-HayFiltroPuesto es la misma función que usa el cartel.
        if (-not (Test-HayFiltroPuesto -TextoFiltro $texto -RiesgoFiltro $riesgo) -and -not $ocultarHechos) {
            if ($null -ne $estado.Vista.Filter) { $estado.Vista.Filter = $null }
            & $actualizarResumenSeleccion
            return
        }

        $estado.Vista.Filter = [Predicate[object]] {
            param($objeto)
            $item = [Cachivache.ItemVista]$objeto
            # Se filtra por Hecho, que solo es $true si el borrado tuvo éxito:
            # los fallos nunca se ocultan.
            if ($ocultarHechos -and $item.Hecho) { return $false }
            if ($riesgo -and $item.Riesgo -ne $riesgo) { return $false }
            if ([string]::IsNullOrWhiteSpace($texto)) { return $true }

            # IndexOf ordinal y no -like "*$texto*": -like interpretaría "*",
            # "?" y "[" como comodines. Además es más rápido.
            $comparacion = [StringComparison]::OrdinalIgnoreCase
            if ($item.Nombre -and $item.Nombre.IndexOf($texto, $comparacion) -ge 0) { return $true }
            if ($item.Ruta   -and $item.Ruta.IndexOf($texto, $comparacion)   -ge 0) { return $true }
            if ($item.Info   -and $item.Info.IndexOf($texto, $comparacion)   -ge 0) { return $true }
            return $false
        }.GetNewClosure()
        # Sin Refresh(): asignar Filter ya recorre la vista. Se actualiza el
        # pie porque el filtro puede ocultar elementos marcados.
        & $actualizarResumenSeleccion
    }

    # Retardo del filtro de texto: se filtra 250 ms después de la última
    # tecla, en vez de una pasada completa por tecla. Por debajo de ~200 ms
    # se vuelve a disparar al teclear; por encima de ~350 ms se nota retraso.
    # Sin GetNewClosure (ver $manejadorSeleccionGlobal).
    $estado.TemporizadorFiltro = New-Object Windows.Threading.DispatcherTimer
    $estado.TemporizadorFiltro.Interval = [TimeSpan]::FromMilliseconds(250)
    $estado.TemporizadorFiltro.Add_Tick({
        $estado.TemporizadorFiltro.Stop()
        & $aplicarFiltro
    })

    $solicitarFiltro = {
        # Reinicia la cuenta atrás en cada tecla.
        $estado.TemporizadorFiltro.Stop()
        $estado.TemporizadorFiltro.Start()
    }

    $mostrarPanel = {
        param([string] $Cual)
        foreach ($nombre in @('PanelInicio', 'PanelResultados', 'PanelRegistro', 'PanelInformes', 'PanelAjustes', 'PanelAcerca')) {
            $c[$nombre].Visibility = if ($nombre -eq $Cual) { 'Visible' } else { 'Collapsed' }
        }

        # El foco pasa al panel mostrado para que los lectores de pantalla
        # anuncien su nombre (su título visible). Se enfoca el panel y no su
        # primer control para no dejar el foco sobre "Analizar el equipo".
        # Va después del bucle: Focus() sobre un elemento Collapsed no hace
        # nada. Se descarta el resultado para no contaminar la salida.
        [void] $c[$Cual].Focus()
    }

    $aplicarTema = {
        param([string] $Nuevo)
        $estado.Tema = $Nuevo
        $estado.Preferencias.Tema = $Nuevo
        $archivo = if ($Nuevo -eq 'claro') { 'Theme.Light.xaml' } else { 'Theme.Dark.xaml' }
        $app.Resources.MergedDictionaries[0] = Import-Xaml (Join-Path $estado.CarpetaUi $archivo)

        # Los colores de las etiquetas viajan como cadenas, así que hay que
        # recalcularlos a mano al cambiar de tema.
        foreach ($vista in $estado.ModulosVista) {
            $vista.ColorRiesgo = Get-ColorRiesgo -Riesgo $vista.Riesgo -Tema $Nuevo
        }
        $c.ListaModulos.ItemsSource = $null
        $c.ListaModulos.ItemsSource = $estado.ModulosVista

        # Las filas de resultados llevan sus colores como cadenas y esas
        # propiedades no notifican cambios, así que hay que recalcularlas
        # y volver a enganchar la lista para que se repinte.
        foreach ($item in $estado.Items) {
            $item.ColorRiesgo = Get-ColorRiesgo -Riesgo $item.Riesgo -Tema $Nuevo
        }
        if ($estado.Items.Count -gt 0) {
            # Refresh() no basta: con VirtualizationMode="Recycling" un
            # contenedor reciclado puede recibir el mismo objeto y no
            # reevaluar enlaces a propiedades que no notifican (ColorRiesgo).
            # Reasignar ItemsSource obliga a crear contenedores nuevos; la
            # vista (filtro y agrupación) es la misma instancia y se conserva.
            # Se guarda y restaura la posición, como en el análisis.
            $posicionTabla = & $guardarPosicionTabla
            $c.TablaResultados.ItemsSource = $null
            $c.TablaResultados.ItemsSource = $estado.Items
            $estado.Vista.Refresh()
            & $restaurarPosicionTabla $posicionTabla
        }

        # El icono alterna entre luna (tema oscuro) y sol (tema claro).
        $c.IconoTema.Data = Get-GeometriaTema $Nuevo

        # Durante un trabajo no se refrescan los discos: $refrescarDiscos
        # escribe en $estado.Configuracion, que el runspace está leyendo por
        # referencia (carrera de datos).
        if (-not $estado.Ocupado) {
            & $refrescarDiscos
            & $refrescarHistorial
        }
    }

