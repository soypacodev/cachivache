<#
.SYNOPSIS
    Diálogos modales de la interfaz.
#>

function Get-LineasConfirmacion {
    <#
    .SYNOPSIS
        Las líneas que se muestran en el diálogo de confirmación antes de borrar.

    .DESCRIPTION
        Separada de Show-Confirmacion (que necesita WPF) para poder probarla.
        Aplica dos reglas:

        1. Todo elemento con comando externo se lista, primero y sin tope:
           SECURITY.md exige que un comando externo sea siempre visible y
           siempre con confirmación.
        2. Del resto se listan los de mayor tamaño hasta -Maximo, y se
           indica cuántos quedan sin mostrar.

    .PARAMETER Maximo
        Cuántos elementos sin comando se listan como mucho. Los que llevan
        comando no cuentan para este tope.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Arriesgados,
        [int] $Maximo = 25
    )

    $todos = @($Arriesgados)
    if ($todos.Count -eq 0) { return @() }

    $describir = {
        param($Elemento)
        $motivo = if ([string]::IsNullOrWhiteSpace($Elemento.Aviso)) {
            "riesgo $([string]$Elemento.Riesgo)".ToLower()
        } else { $Elemento.Aviso }
        $linea = '- {0} ({1}) - {2}' -f $Elemento.Nombre, $Elemento.Tamano, $motivo
        if (-not [string]::IsNullOrWhiteSpace($Elemento.Comando)) {
            $linea += "`n     Ejecuta: $($Elemento.Comando)"
        }
        return $linea
    }

    $conComando = @($todos | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Comando) })
    $sinComando = @($todos | Where-Object { [string]::IsNullOrWhiteSpace($_.Comando) } |
                    Sort-Object Bytes -Descending)

    $lineas = [Collections.Generic.List[string]]::new()
    foreach ($elemento in $conComando) { $lineas.Add((& $describir $elemento)) }

    $mostrados = @($sinComando | Select-Object -First $Maximo)
    foreach ($elemento in $mostrados) { $lineas.Add((& $describir $elemento)) }

    $ocultos = $sinComando.Count - $mostrados.Count
    if ($ocultos -gt 0) {
        $lineas.Add(('  ... y {0} {1} más que no caben aquí. Están todos marcados en la lista de resultados.' -f
                     $ocultos, $(if ($ocultos -eq 1) { 'elemento' } else { 'elementos' })))
    }

    return $lineas.ToArray()
}

function Show-Confirmacion {
    <#
    .SYNOPSIS
        Pide confirmación escrita antes de eliminar.

    .DESCRIPTION
        Obliga a teclear una palabra exacta. Si en el lote hay elementos de
        riesgo medio o alto, la palabra cambia y se listan los casos que
        hacen falta para decidir (los elige Get-LineasConfirmacion).

    .OUTPUTS
        [bool] $true si el usuario ha confirmado.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Propietario,
        [Parameter(Mandatory)] [string] $CarpetaUi,
        [Parameter(Mandatory)] [int]    $Elementos,
        [Parameter(Mandatory)] [double] $Bytes,
        [bool] $Permanente = $false,
        $Arriesgados = @()
    )

    $dialogo = Import-Xaml (Join-Path $CarpetaUi 'ConfirmDialog.xaml')
    $dialogo.Owner = $Propietario

    # Tope de altura según la pantalla real. El MaxHeight del XAML (760) no
    # basta con escalado: a 768 px y 150 % el escritorio mide 512 puntos y los
    # botones quedarían fuera. WorkArea ya viene en puntos y descuenta la
    # barra de tareas; el margen lo decide Get-AlturaMaximaDialogo.
    try {
        $dialogo.MaxHeight = Get-AlturaMaximaDialogo `
            -AltoAreaUtil ([System.Windows.SystemParameters]::WorkArea.Height)
    } catch {
        # Si no se puede consultar el escritorio, se mantiene el valor del XAML.
        Write-Verbose "No se ha podido ajustar la altura del diálogo: $($_.Exception.Message)"
    }

    $lista = @($Arriesgados)

    # Destino, rótulo del botón y palabra salen de una única función para que
    # no se contradigan (el XAML no sabe si el borrado será permanente).
    $textos = Get-TextosDestinoBorrado -Permanente:$Permanente

    # Con elementos de riesgo la palabra es ELIMINAR aunque el destino sea la
    # papelera: la fricción la exige el contenido, no el destino.
    $palabra = if ($lista.Count -gt 0) { 'ELIMINAR' } else { $textos.Palabra }

    $txtSubtitulo = $dialogo.FindName('TxtSubtitulo')
    $txtElementos = $dialogo.FindName('TxtElementos')
    $txtEspacio   = $dialogo.FindName('TxtEspacio')
    $txtDestino   = $dialogo.FindName('TxtDestino')
    $marcoRiesgo  = $dialogo.FindName('MarcoRiesgo')
    $txtRiesgo    = $dialogo.FindName('TxtRiesgo')
    $listaRiesgo  = $dialogo.FindName('ListaRiesgo')
    $txtInstruccion = $dialogo.FindName('TxtInstruccion')
    $campo        = $dialogo.FindName('CampoConfirmacion')
    $txtError     = $dialogo.FindName('TxtError')
    $btnSi        = $dialogo.FindName('BtnSi')
    $btnNo        = $dialogo.FindName('BtnNo')

    $txtSubtitulo.Text = 'Esta acción no la puede deshacer el programa.'
    $txtElementos.Text = '{0}' -f $Elementos
    $txtEspacio.Text   = Format-Tamano $Bytes
    $txtDestino.Text   = $textos.Destino
    $btnSi.Content     = $textos.Boton
    $txtInstruccion.Text = "Para continuar, escribe $palabra tal cual:"

    if ($lista.Count -gt 0) {
        $marcoRiesgo.Visibility = 'Visible'
        $txtRiesgo.Text = '{0} de los elementos marcados requieren tu criterio:' -f $lista.Count
        $listaRiesgo.ItemsSource = @(Get-LineasConfirmacion -Arriesgados $lista)
    }

    $validar = {
        $coincide = $campo.Text.Trim() -ceq $palabra
        $btnSi.IsEnabled = $coincide
        $txtError.Visibility = if ($campo.Text.Length -gt 0 -and -not $coincide) { 'Visible' } else { 'Collapsed' }
    }.GetNewClosure()

    $campo.Add_TextChanged($validar)
    # Enter solo desde el cuadro de texto y si la palabra coincide. Escape lo
    # resuelve IsCancel="True" del botón Cancelar, con el foco donde esté.
    $campo.Add_KeyDown({
        param($remitente, $argumentos)
        if ($argumentos.Key -eq 'Enter' -and $btnSi.IsEnabled) { $dialogo.DialogResult = $true }
    }.GetNewClosure())

    $btnSi.Add_Click({ $dialogo.DialogResult = $true }.GetNewClosure())
    $btnNo.Add_Click({ $dialogo.DialogResult = $false }.GetNewClosure())
    $dialogo.Add_ContentRendered({ $campo.Focus() }.GetNewClosure())

    return [bool]$dialogo.ShowDialog()
}

function Show-Aviso {
    <#
    .SYNOPSIS
        Mensaje breve con el estilo del sistema.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Mensaje,
        [string] $Titulo = 'Cachivache',
        [ValidateSet('Information', 'Warning', 'Error')] [string] $Tipo = 'Information'
    )
    [void][Windows.MessageBox]::Show($Mensaje, $Titulo, 'OK', $Tipo)
}
