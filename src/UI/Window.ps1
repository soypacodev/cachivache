<#
.SYNOPSIS
    Ventana principal: carga del XAML, enlace de datos y orquestación.

.DESCRIPTION
    El análisis y la eliminación se ejecutan en runspaces aparte para que la
    ventana no se congele. La comunicación es una tabla hash sincronizada
    que un DispatcherTimer consulta cinco veces por segundo (cada 200 ms);
    así todo lo que toca controles ocurre siempre en el hilo de la interfaz.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

# Xaml.ps1, Atajos.ps1, Posicion.ps1 y Lotes.ps1 son cálculo puro sin WPF,
# separados para poder probarlos sin interfaz gráfica. Maximizar.ps1 es la
# interoperabilidad con Win32 para el maximizado.
. (Join-Path $PSScriptRoot 'Xaml.ps1')
. (Join-Path $PSScriptRoot 'Maximizar.ps1')
. (Join-Path $PSScriptRoot 'Atajos.ps1')
. (Join-Path $PSScriptRoot 'Posicion.ps1')
. (Join-Path $PSScriptRoot 'Lotes.ps1')

# =====================================================================
#  CARGA DE XAML
# =====================================================================
function Import-Xaml {
    <#
    .SYNOPSIS
        Carga un archivo XAML y devuelve el objeto que describe.
    .DESCRIPTION
        Se usa ReadAllText en vez de Get-Content para que la marca de orden
        de bytes no llegue al analizador, que la rechazaría. Las marcas de
        panel se resuelven antes de interpretar (ver Expand-PanelesXaml).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Ruta)

    if (-not (Test-Path -LiteralPath $Ruta)) {
        throw "No se encuentra el archivo de interfaz: $Ruta"
    }
    $texto = [IO.File]::ReadAllText($Ruta)
    if ($texto -match '<!--#panel') {
        $texto = Expand-PanelesXaml -Texto $texto -Carpeta (Split-Path $Ruta -Parent)
    }
    try {
        return [Windows.Markup.XamlReader]::Parse($texto)
    } catch {
        throw "Error al interpretar $([IO.Path]::GetFileName($Ruta)): $($_.Exception.Message)"
    }
}

function Get-CarpetaInterfaz {
    [OutputType([string])]
    param()
    return $PSScriptRoot
}

# =====================================================================
#  COLORES DE ETIQUETA
# =====================================================================
function Get-GeometriaTema {
    <#
    .SYNOPSIS
        Icono del botón de tema: luna para el oscuro, sol para el claro.
    .DESCRIPTION
        El Path del XAML se dibuja con Fill y sin Stroke, así que la
        geometría debe estar formada solo por figuras cerradas: los rayos
        del sol son rectángulos, no segmentos de línea (que no se verían).
    #>
    [CmdletBinding()]
    [OutputType([Windows.Media.Geometry])]
    param(
        [ValidateSet('claro', 'oscuro')]
        [string] $Tema
    )

    # Lienzo de 24x24 en ambos casos, para que Stretch="Uniform" los deje
    # del mismo tamaño óptico.
    $trazado = if ($Tema -eq 'claro') {
        # Sol: disco central de radio 5 y ocho rayos rectangulares.
        'M12,7 A5,5 0 1,1 12,17 A5,5 0 1,1 12,7 Z ' +
        'M11.1,3 L12.9,3 L12.9,5.2 L11.1,5.2 Z ' +
        'M11.1,18.8 L12.9,18.8 L12.9,21 L11.1,21 Z ' +
        'M3,11.1 L5.2,11.1 L5.2,12.9 L3,12.9 Z ' +
        'M18.8,11.1 L21,11.1 L21,12.9 L18.8,12.9 Z ' +
        'M16.17,17.44 L17.73,19 L19,17.73 L17.44,16.17 Z ' +
        'M6.56,16.17 L5,17.73 L6.27,19 L7.83,17.44 Z ' +
        'M7.83,6.56 L6.27,5 L5,6.27 L6.56,7.83 Z ' +
        'M17.44,7.83 L19,6.27 L17.73,5 L16.17,6.56 Z'
    } else {
        # Luna: una sola figura cerrada.
        'M12,3 A9,9 0 1,0 21,12 A7,7 0 0,1 12,3 Z'
    }
    return [Windows.Media.Geometry]::Parse($trazado)
}

function Get-ColorRiesgo {
    <#
    .SYNOPSIS
        Traduce un nivel de riesgo a su color.
    .DESCRIPTION
        Los valores coinciden con Exito/Aviso/Peligro de los diccionarios de
        tema; si se cambian allí, hay que cambiarlos aquí. Viajan como
        cadenas porque las clases de Types.ps1 no dependen de WPF.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Riesgo, [string] $Tema = 'oscuro')

    $oscuro = @{ 'Bajo' = '#4ADE80'; 'Medio' = '#FBBF24'; 'Alto' = '#FB7185' }
    $claro  = @{ 'Bajo' = '#15803D'; 'Medio' = '#B45309'; 'Alto' = '#DC2626' }
    $tabla = if ($Tema -eq 'claro') { $claro } else { $oscuro }
    if (-not $tabla.ContainsKey($Riesgo)) { $Riesgo = 'Bajo' }
    return $tabla[$Riesgo]
}

function Get-ColorAcentoTema {
    <#
    .SYNOPSIS
        Los cuatro colores de acento del tema en curso.

    .DESCRIPTION
        Para los colores que se asignan desde código (barras del panel de
        discos, etiquetas del historial) y deben seguir el tema activo. Los
        valores coinciden con Theme.Dark.xaml y Theme.Light.xaml.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Exito', 'Aviso', 'Peligro', 'Acento')] [string] $Cual,
        [string] $Tema = 'oscuro'
    )

    $oscuro = @{ Exito = '#4ADE80'; Aviso = '#FBBF24'; Peligro = '#FB7185'; Acento = '#2DD4BF' }
    $claro  = @{ Exito = '#15803D'; Aviso = '#B45309'; Peligro = '#DC2626'; Acento = '#0D9488' }
    $tabla = if ($Tema -eq 'claro') { $claro } else { $oscuro }
    return $tabla[$Cual]
}

# =====================================================================
#  VENTANA PRINCIPAL
# =====================================================================
function Show-VentanaPrincipal {
    <#
    .SYNOPSIS
        Construye y muestra la ventana. Devuelve cuando el usuario la cierra.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Configuracion,
        [Parameter(Mandatory)] $Modulos,
        [Parameter(Mandatory)] [hashtable] $Preferencias,
        [Parameter(Mandatory)] [string] $Raiz
    )

    Initialize-TiposInterfaz
    [void](Initialize-MotorBorrado)
    [void](Initialize-Registro -CarpetaDatos $Configuracion.CarpetaDatos)

    $carpetaUi = Get-CarpetaInterfaz

    # ---------- Aplicación y recursos -----------------------------------
    $app = [Windows.Application]::Current
    if ($null -eq $app) { $app = New-Object Windows.Application }
    $app.ShutdownMode = [Windows.ShutdownMode]::OnMainWindowClose

    $tema = if ($Preferencias.Tema -eq 'claro') { 'Theme.Light.xaml' } else { 'Theme.Dark.xaml' }
    $app.Resources.MergedDictionaries.Clear()
    $app.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $carpetaUi $tema)))
    $app.Resources.MergedDictionaries.Add((Import-Xaml (Join-Path $carpetaUi 'Styles.xaml')))

    $ventana = Import-Xaml (Join-Path $carpetaUi 'MainWindow.xaml')

    # El icono se asigna desde código y no con Icon="..." en el XAML: con
    # XamlReader.Parse no hay ensamblado contra el que resolver una ruta
    # relativa o un URI pack. Si falla, se usa el icono genérico de Windows.
    try {
        $rutaIcono = Join-Path (Join-Path $Raiz 'assets') 'cachivache.ico'
        if (Test-Path -LiteralPath $rutaIcono) {
            $ventana.Icon = New-Object Windows.Media.Imaging.BitmapImage ([uri]$rutaIcono)
        }
    } catch {
        Write-Verbose "No se ha podido cargar el icono de la ventana: $($_.Exception.Message)"
    }

    # Con WindowStyle="None", Windows no calcula los límites de maximizado y
    # la ventana taparía la barra de tareas.
    Register-LimiteMaximizado -Ventana $ventana

    # ---------- Estado compartido ---------------------------------------
    $estado = [pscustomobject]@{
        Configuracion = $Configuracion
        Modulos       = $Modulos
        Preferencias  = $Preferencias
        Raiz          = $Raiz
        CarpetaUi     = $carpetaUi
        Tema          = if ($Preferencias.Tema -eq 'claro') { 'claro' } else { 'oscuro' }
        # ::new() y no New-Object: una List[object] creada con New-Object no
        # se puede enumerar con @( ), que lanza ArgumentException ("Los tipos
        # de argumentos no coinciden"), incluso vacía. foreach, la
        # canalización, .Count y .ToArray() sí funcionan, y Export-InformeHtml
        # empieza con @($Candidatos).
        Candidatos    = [Collections.Generic.List[object]]::new()
        Items         = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.ItemVista]
        ModulosVista  = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.ModuloVista]
        PerfilesVista = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.PerfilVista]
        DiscosVista   = New-Object System.Collections.ObjectModel.ObservableCollection[Cachivache.DiscoVista]
        Cola          = @()
        # El ScrollViewer interno del DataGrid, una vez encontrado. La
        # plantilla no se aplica hasta que la ventana se carga, así que solo
        # se guarda cuando aparece (nunca se cachea su ausencia).
        DesplazadorTabla = $null
        Indice        = 0
        Total         = 0
        Ocupado       = $false
        Fase          = 'reposo'
        Sync          = (New-EstadoSincronizado)
        Runspace      = $null
        PowerShell    = $null
        Handle        = $null
        LibreInicial  = 0.0
        # Si el lote en curso es una simulación. Se fija al pulsar el botón:
        # la casilla puede cambiar durante el lote, y el historial debe
        # reflejar cómo se ejecutó realmente.
        SimulandoLote = $false
        # Módulos de los elementos del lote en curso, para el historial.
        ModulosLote   = @()
        # Distinguen un análisis cancelado o con módulos fallidos de uno
        # completo.
        AnalisisCancelado = $false
        ModulosFallidos   = [Collections.Generic.List[string]]::new()
        # Caché del espacio libre: la consulta WMI tarda decenas de ms y el
        # resumen del pie se recalcula en cada clic de casilla.
        LibreCache    = 0.0
        # Mientras está a $true, marcar casillas no recalcula el resumen.
        SuprimirResumen = $false
        # Mientras está a $true, cambiar los controles de Ajustes no pasa el
        # perfil a Personalizado (los está ajustando la propia aplicación).
        SincronizandoPerfil = $false
        # Líneas del panel de Registro. Se cuentan a mano porque contarlas en
        # el TextBox obliga a partir todo el texto en cada volcado.
        LineasConsola = 0
        Cronometro    = $null
        Vista         = $null
        # Temporizador del filtro: se filtra 250 ms después de la última
        # tecla. Se guarda aquí para que no lo libere el recolector.
        TemporizadorFiltro = $null
        # Comprobación de versión nueva; se guardan aquí para que no los
        # libere el recolector. TrabajoVersion es $null si no hay consulta en
        # curso, lo que evita lanzar dos a la vez.
        TemporizadorVersion = $null
        TrabajoVersion      = $null
    }

    # Una cabecera por arranque, con el ID de sesión que llevará cada línea
    # del registro de este proceso.
    Write-CabeceraSesion -Perfil $Preferencias.Perfil -Admin $Configuracion.Admin -Sync $estado.Sync

    # ---------- Acceso rápido a los controles ---------------------------
    $c = @{}
    foreach ($nombre in @(
        'TxtVersionBarra', 'InsigniaAdmin', 'PuntoAdmin', 'TxtInsigniaAdmin',
        'BtnTema', 'IconoTema', 'BtnMinimizar', 'BtnMaximizar', 'BtnCerrar',
        'NavInicio', 'NavResultados', 'NavRegistro', 'NavInformes', 'NavAjustes', 'NavAcerca',
        'ListaDiscos', 'TxtTotalHistorico',
        'PanelInicio', 'PanelResultados', 'PanelRegistro', 'PanelInformes', 'PanelAjustes', 'PanelAcerca',
        'ListaPerfiles', 'ListaModulos', 'BtnModulosTodos', 'BtnModulosNinguno',
        'TxtEstadoInicio', 'BarraInicio', 'BtnAnalizar', 'BtnCancelar',
        'TxtResumenAnalisis', 'CampoFiltro', 'FiltroRiesgo',
        'BtnMarcarTodo', 'BtnDesmarcarTodo', 'BtnSoloSeguros', 'BtnAbrirCarpeta', 'BtnVerContenido',
        'ChkOcultarHechos', 'BtnMostrarHechos',
        'MenuAbrirUbicacion', 'MenuCopiarRuta', 'MenuExcluirSiempre', 'MenuDesmarcarGrupo',
        'TablaResultados', 'TxtSeleccion', 'TxtProyeccion', 'BarraBorrado',
        'BtnExportar', 'BtnEliminar', 'BtnCancelarBorrado', 'ChkSimular', 'ChkAnonimizar', 'BtnAbrirPapelera',
        'EstadoVacio', 'TxtEstadoVacio', 'BtnQuitarFiltros',
        'AvisoIncompleto', 'TxtAvisoIncompleto',
        'AvisoSimulacion', 'TxtAvisoSimulacion',
        'Consola', 'BtnCopiarRegistro', 'BtnAbrirRegistro',
        'BtnExportarHtml', 'BtnExportarCsv', 'BtnExportarJson',
        'ListaInformesHtml', 'TxtSinInformesHtml',
        'ListaInformesCsv', 'TxtSinInformesCsv',
        'ListaInformesJson', 'TxtSinInformesJson',
        'ListaHistorial', 'TxtHistorialVacio',
        'SliderMinimoMB', 'TxtMinimoMB', 'SliderDias', 'TxtDiasSinUso',
        'ChkMenores', 'ChkPermanente', 'TxtEstadoAdmin', 'BtnReiniciarAdmin',
        'TxtResumenExclusiones', 'ListaExclusiones',
        'TxtCarpetaDatos', 'BtnAbrirDatos', 'BtnRestablecer',
        'TxtVersionAcerca', 'BtnRepositorio',
        'TxtActualizacion', 'BtnBuscarActualizacion', 'BtnIrAVersionNueva', 'BtnCopiarDiagnostico')) {
        $c[$nombre] = $ventana.FindName($nombre)
    }

    # =================================================================
    #  EL CUERPO DE LA VENTANA, POR PARTES
    # =================================================================
    # Cada archivo es un trozo del cuerpo de esta función y se carga con
    # dot-source aquí dentro, para que vea $c, $estado, $ventana y los
    # cierres de los demás. Cargarlos fuera no funcionaría: las definiciones
    # morirían con el ámbito del cargador.
    #
    # Al cargarse, cada archivo solo define cierres; las referencias cruzadas
    # se evalúan más tarde, con los cuatro ya cargados. Ver
    # docs/ESTRUCTURA.md (sección 3).
    . (Join-Path $carpetaUi 'Window.Ayudantes.ps1')
    . (Join-Path $carpetaUi 'Window.Analisis.ps1')
    . (Join-Path $carpetaUi 'Window.Eliminacion.ps1')
    . (Join-Path $carpetaUi 'Window.Eventos.ps1')

    # =================================================================
    #  ESTADO INICIAL
    # =================================================================
    if ($estado.Tema -eq 'claro') {
        $c.IconoTema.Data = Get-GeometriaTema 'claro'
    }

    $c.TxtVersionBarra.Text  = 'v' + $script:VersionCachivache
    $c.TxtVersionAcerca.Text = 'Versión {0} - PowerShell {1} - {2}' -f `
                               $script:VersionCachivache, $PSVersionTable.PSVersion, $estado.Configuracion.Windows
    $c.TxtCarpetaDatos.Text  = $estado.Configuracion.CarpetaDatos

    # La insignia siempre es visible: verde como administrador (todo
    # disponible) y ámbar en modo estándar (hay módulos no disponibles).
    $c.InsigniaAdmin.Visibility = 'Visible'
    if ($estado.Configuracion.Admin) {
        $c.TxtInsigniaAdmin.Text = 'Administrador'
        $c.TxtEstadoAdmin.Text = 'El programa se está ejecutando como administrador: todos los módulos están disponibles.'
        $c.BtnReiniciarAdmin.IsEnabled = $false
        $pincelInsignia = $app.Resources['Exito']
    } else {
        $c.TxtInsigniaAdmin.Text = 'Modo estándar'
        $c.TxtEstadoAdmin.Text = 'Modo estándar. Los módulos de registros del sistema, Windows Update, almacén de componentes y perfiles de usuario necesitan permisos de administrador.'
        $pincelInsignia = $app.Resources['Aviso']
    }
    $c.PuntoAdmin.Fill = $pincelInsignia
    $c.TxtInsigniaAdmin.Foreground = $pincelInsignia

    $c.SliderMinimoMB.Value    = [int]$estado.Preferencias.MinimoMB
    $c.SliderDias.Value        = [int]$estado.Preferencias.DiasSinUso
    $c.ChkMenores.IsChecked    = [bool]$estado.Preferencias.IncluirMenores
    $c.ChkPermanente.IsChecked = [bool]$estado.Preferencias.Permanente
    $c.TxtMinimoMB.Text        = '{0} MB' -f [int]$estado.Preferencias.MinimoMB
    $c.TxtDiasSinUso.Text      = '{0} días' -f [int]$estado.Preferencias.DiasSinUso

    & $refrescarModulos
    $c.ListaModulos.ItemsSource   = $estado.ModulosVista
    $c.ListaPerfiles.ItemsSource  = $estado.PerfilesVista

    # La vista se configura antes de asignar la colección al DataGrid: si
    # ya está enlazado (tiene GroupStyle en el XAML), añadir la agrupación
    # lanza "no se puede cambiar ... mientras Refresh se está aplazando" y la
    # ventana no se abre. GetDefaultView devuelve siempre la misma instancia,
    # así que el DataGrid recibe esta vista ya agrupada. La comprobación de
    # Count evita duplicar la agrupación.
    $estado.Vista = [Windows.Data.CollectionViewSource]::GetDefaultView($estado.Items)
    if ($estado.Vista.GroupDescriptions.Count -eq 0) {
        $estado.Vista.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Categoria'))
    }
    $c.TablaResultados.ItemsSource = $estado.Items

    # Estos paneles se rellenan con datos de disco no imprescindibles: un
    # error al leerlos no debe impedir que la ventana se abra.
    foreach ($paso in @(
        @{ Que = 'los discos';   Hacer = $refrescarDiscos },
        @{ Que = 'el historial'; Hacer = $refrescarHistorial },
        @{ Que = 'el resumen';   Hacer = $actualizarResumenSeleccion })) {
        try {
            & $paso.Hacer
        } catch {
            # Write-Registro y no $escribir, que vuelca a la consola de la
            # ventana y puede ser lo que ha fallado.
            Write-Registro -Nivel 'ERROR' -Mensaje (
                'No se ha podido preparar {0} al arrancar: {1}' -f $paso.Que, $_.Exception.Message)
        }
    }

    & $escribir ('Cachivache v{0} iniciado. Equipo: {1}. {2}' -f `
                 $script:VersionCachivache, $estado.Configuracion.Equipo,
                 $(if ($estado.Configuracion.Admin) { 'Modo administrador.' } else { 'Modo estandar.' }))

    # ---------- Arranque -------------------------------------------------
    # Los fallos dentro de manejadores de WPF ocurren dentro de $app.Run;
    # este manejador los registra con detalle y evita que cierren el proceso.
    $app.Add_DispatcherUnhandledException({
        param($remitente, $argumentos)
        $ex = $argumentos.Exception
        Write-Host ''
        Write-Host '  Fallo dentro de la interfaz (no en el arranque lineal):' -ForegroundColor Red
        Write-Host "    $($ex.Message)"
        $interna = $ex.InnerException
        while ($interna) {
            Write-Host "    causado por: $($interna.Message)"
            $interna = $interna.InnerException
        }
        Write-Host ''
        Write-Host '  Pila de .NET:' -ForegroundColor Yellow
        Write-Host $ex.StackTrace
        Write-Host ''
        try {
            Write-Registro -Nivel 'ERROR' -Mensaje ("Fallo en la interfaz: {0}`n{1}" -f $ex.Message, $ex.StackTrace)
        } catch {
            Write-Verbose "Tampoco se ha podido anotar el fallo en el registro: $($_.Exception.Message)"
        }

        # Solo se muestra la primera vez de cada fallo distinto: dentro del
        # bucle de WPF un fallo puede repetirse en cada tick o en cada fila.
        # Al registro van todos.
        try {
            if (Test-DebeAvisarDelFallo -Firma (Get-FirmaDeFallo -Excepcion $ex)) {
                [void][Windows.MessageBox]::Show(
                    ("Ha fallado algo dentro de la ventana:`n`n{0}`n`nEl programa sigue abierto. Si esto se repite, solo se anotará en el registro, para no llenarte la pantalla de avisos. El detalle completo está ahí; si vuelve a pasar, adjúntalo al informar del fallo." -f $ex.Message),
                    'Ha fallado algo', 'OK', 'Warning')
            }
        } catch {
            Write-Verbose "No se ha podido avisar del fallo por pantalla: $($_.Exception.Message)"
        }

        # Sin esto el proceso termina sin pasar por Closing, que detiene el
        # runspace de trabajo y guarda las preferencias.
        $argumentos.Handled = $true
    })

    $app.MainWindow = $ventana
    [void]$app.Run($ventana)
}
