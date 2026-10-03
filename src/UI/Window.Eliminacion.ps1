<#
.SYNOPSIS
    Eliminación: cierre del borrado y resumen final.

.DESCRIPTION
    El borrado real lo hace Invoke-EliminacionCandidato en el núcleo; aquí
    solo se decide qué se hace al terminar.

    Este archivo no se ejecuta solo: Show-VentanaPrincipal (Window.ps1) lo
    carga con dot-source dentro de la función, por lo que usa $c, $estado,
    $ventana y los cierres de Window.Ayudantes.ps1 sin declararlos. Ver
    docs/ESTRUCTURA.md (sección 3).
#>

    # =================================================================
    #  ELIMINACIÓN
    # =================================================================
    $terminarBorrado = {
        $estado.Ocupado = $false
        $estado.Fase    = 'reposo'

        # El runspace se comparte durante toda la operación y se cierra aquí.
        & $cerrarRunspace

        $resultado = $estado.Sync.Resultado
        $liberado  = if ($resultado) { [double]$resultado.Liberado } else { 0.0 }
        $hechos    = if ($resultado) { [int]$resultado.Hechos } else { 0 }

        # El modo se toma de $estado, fijado al pulsar el botón, y no de la
        # casilla (puede cambiar durante el lote) ni del resultado (no llega
        # si el trabajo falla a medias).
        $simulado  = [bool]$estado.SimulandoLote
        $simulados = if ($resultado -and $null -ne $resultado.Simulados) { [int]$resultado.Simulados } else { 0 }
        # Elementos que, según la simulación, no se podrían borrar.
        $bloqueados = if ($resultado -and $null -ne $resultado.Bloqueados) { [int]$resultado.Bloqueados } else { 0 }

        # Cada $item.Seleccionado = $false dispara el recálculo del resumen,
        # que recorre todos los elementos: con miles de filas el coste es
        # cuadrático y la ventana deja de responder. Se suprime y se recalcula
        # una sola vez al final (igual que en el marcado en lote).
        $estado.SuprimirResumen = $true
        try {
            foreach ($item in $estado.Items) {
                if ($item.Origen.Hecho -or $item.Origen.Error) {
                    $item.Hecho = [bool]$item.Origen.Hecho
                    # Solo se desmarca lo borrado: lo que falló sigue marcado
                    # para poder corregir la causa y volver a intentarlo.
                    if ($item.Origen.Hecho) { $item.Seleccionado = $false }
                    $item.Estado = if ($item.Origen.Error) { $item.Origen.Error } else { 'Eliminado' }
                    if ($item.Origen.Error) {
                        # Se encola y se vuelca una sola vez al salir del
                        # bucle; $escribir escribiría en disco y repintaría
                        # por cada línea.
                        Write-Registro -Sync $estado.Sync -Nivel 'AVISO' -Mensaje (
                            '  Aviso en {0}: {1}' -f $item.Nombre, $item.Origen.Error)
                    }
                }
            }
        } finally {
            $estado.SuprimirResumen = $false
            & $volcarRegistro
        }

        $c.BarraBorrado.Visibility       = 'Collapsed'
        $c.BtnCancelarBorrado.Visibility = 'Collapsed'
        $c.BtnEliminar.IsEnabled         = $true
        $c.BtnAnalizar.IsEnabled         = $true

        # ---- Simulación: se informa de lo que habría pasado y se termina ----
        # Sin informe ni entrada en el historial (no se ha borrado nada), y
        # sin refrescar el espacio en disco, que no ha cambiado.
        if ($simulado) {
            & $escribir ''
            & $escribir ('SIMULACIÓN TERMINADA: se habrían eliminado {0} elementos y liberado {1}.' -f `
                         $simulados, (Format-Tamano $liberado)) 'SIMULACION'
            if ($bloqueados -gt 0) {
                & $escribir ('{0} {1} se habrían quedado sin borrar. Mira las líneas [BLOQUEADO] de arriba.' -f `
                             $bloqueados, $(if ($bloqueados -eq 1) { 'elemento' } else { 'elementos' })) 'BLOQUEADO'
            }
            & $escribir 'NO SE HA BORRADO NADA. Lo marcado sigue marcado: desmarca lo que quieras conservar,' 'SIMULACION'
            & $escribir 'quita "Solo simular" y vuelve a pulsar para hacerlo de verdad.' 'SIMULACION'

            # El cartel se muestra después de actualizar el resumen, porque
            # esa llamada oculta el cartel anterior.
            & $actualizarResumenSeleccion

            $resumen = Format-ResumenSimulacion `
                -Simulados $simulados -Liberado $liberado -Bloqueados $bloqueados

            # Si falta el cartel se informa en el registro: un FindName nulo
            # no lanza y el resultado se perdería en silencio.
            if ($null -eq $c.AvisoSimulacion -or $null -eq $c.TxtAvisoSimulacion) {
                & $escribir (('AVISO INTERNO: no se encuentra el cartel de la simulación en la ventana. ' +
                              'El resultado solo se ve aquí: {0}') -f $resumen) 'ERROR'
            } else {
                $c.TxtAvisoSimulacion.Text    = $resumen
                $c.AvisoSimulacion.Visibility = 'Visible'
            }

            $estado.Vista.Refresh()
            return
        }

        # Una limpieza detenida se anota en el historial como incompleta.
        $detenida = [bool]$estado.Sync.Cancelar
        $motivo   = if ($detenida) {
            'La detuviste a mitad: se eliminaron {0} de {1} elementos marcados.' -f $hechos, $estado.Total
        } else { '' }

        $libreAhora = Get-EspacioLibre $estado.Configuracion.Unidad
        & $escribir ''
        if ($detenida) {
            & $escribir ('LIMPIEZA DETENIDA: {0} de {1} elementos, {2} liberados. Lo ya borrado sigue borrado.' -f `
                         $hechos, $estado.Total, (Format-Tamano $liberado)) 'AVISO'
        } else {
            & $escribir ('LIMPIEZA TERMINADA: {0} elementos, {1} liberados.' -f $hechos, (Format-Tamano $liberado)) 'BORRADO'
        }
        & $escribir ('Espacio libre en {0}: {1} (antes {2}).' -f `
                     $estado.Configuracion.Unidad, (Format-Tamano $libreAhora), (Format-Tamano $estado.LibreInicial))

        # ---- Qué se puede recuperar ----
        # Debe ser exacto: vaciar la papelera, los comandos externos (DISM) y
        # las cachés con ForzarPermanente no se pueden deshacer.
        $rescate = Get-ResumenRecuperable -Candidatos $estado.Candidatos `
                                          -Permanente:$estado.Configuracion.Permanente
        if ($rescate.Recuperables -gt 0) {
            & $escribir ('{0} {1} en la papelera de Windows: se {2} recuperar desde ahí mientras no la vacíes.' -f `
                         $rescate.Recuperables,
                         $(if ($rescate.Recuperables -eq 1) { 'elemento está' } else { 'elementos están' }),
                         $(if ($rescate.Recuperables -eq 1) { 'puede' } else { 'pueden' }))
            $c.BtnAbrirPapelera.Visibility = 'Visible'
        }
        if ($rescate.Definitivos -gt 0) {
            & $escribir ('{0} {1} sin paso por la papelera: eso no tiene vuelta atrás.' -f `
                         $rescate.Definitivos,
                         $(if ($rescate.Definitivos -eq 1) { 'elemento se ha borrado' } else { 'elementos se han borrado' })) 'AVISO'
        }

        # El informe se genera antes de la entrada del historial para guardar
        # en ella su ruta. Si falla, la entrada se anota sin informe.
        $rutaInforme = ''
        try {
            $rutaInforme = New-NombreInforme -Tipo 'limpieza' -Extension 'html' -CarpetaDatos $estado.Configuracion.CarpetaDatos
            Export-InformeHtml -Candidatos @($estado.Candidatos | Where-Object { $_.Hecho }) -Ruta $rutaInforme `
                               -Configuracion $estado.Configuracion -Tipo 'limpieza' -Modulos $estado.Modulos -Confirm:$false
            & $escribir ('Informe guardado en: {0}' -f $rutaInforme)
        } catch {
            & $escribir ('No se ha podido generar el informe: {0}' -f
                         (Get-DetalleExcepcion -ErrorRecord $_ -ConPila)) 'AVISO'
            $rutaInforme = ''
        }

        Add-EntradaHistorial -Tipo 'limpieza' -Elementos $hechos -Bytes $liberado `
                             -Perfil $estado.Configuracion.Perfil `
                             -LibreAntes $estado.LibreInicial -LibreDespues $libreAhora `
                             -Informe $rutaInforme `
                             -Incompleto:$detenida -Motivo $motivo `
                             -CarpetaDatos $estado.Configuracion.CarpetaDatos -Confirm:$false

        & $refrescarDiscos
        & $refrescarHistorial
        & $actualizarResumenSeleccion
        $estado.Vista.Refresh()
    }

