<#
    Pruebas del menú contextual y el doble clic de la tabla de Resultados,
    y de la casilla "Ocultar lo ya eliminado".

    Sin WPF no se puede pulsar ni el menú ni la casilla: la decisión vive en
    algo legible (una propiedad de ItemVista, un cierre de la ventana) y se
    comprueba por texto que la ventana no decide por su cuenta.

    Lo que se protege:

      1. La clave de exclusión se copia del candidato, nunca se recalcula
         en la ventana.
      2. "Copiar ruta" no copia una etiqueta: el portapapeles no dice de
         dónde salió lo que lleva.
      3. Solo se oculta lo que se borró bien; un fallo se ve siempre.

    Cada prueba de texto lleva su guarda previa.
#>

BeforeAll {
    $script:Raiz      = Split-Path $PSScriptRoot -Parent
    $script:CarpetaUi = Join-Path (Join-Path $script:Raiz 'src') 'UI'

    . (Join-Path $script:CarpetaUi 'Types.ps1')
    Initialize-TiposInterfaz

    # Núcleo completo: Get-ClaveExclusion y Test-ClaveExcluida son la
    # referencia contra la que se comparan las decisiones de la ventana.
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Código sin comentarios de línea (#), de bloque (<# #>) ni de C# (///):
    # ItemVista es C# dentro de Types.ps1 y sus comentarios nombran
    # Get-ClaveExclusion, lo que haría fallar la prueba de "la ventana no
    # recalcula la clave".
    function Get-CodigoSinComentarios {
        param([string] $Ruta)
        $lineas = @(Get-Content -LiteralPath $Ruta |
                    Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*///' })
        return [regex]::Replace(($lineas -join "`n"), '(?s)<#.*?#>', '')
    }

    $script:Eventos     = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Eventos.ps1')
    $script:Ayudantes   = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Ayudantes.ps1')
    $script:Analisis    = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Analisis.ps1')
    $script:Eliminacion = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Eliminacion.ps1')
    $script:Ventana     = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.ps1')

    # El XAML del panel, sin comentarios por el mismo motivo.
    $script:Panel = [regex]::Replace(
        (Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUi 'Panel.Resultados.xaml')),
        '(?s)<!--.*?-->', '')

    # Cada manejador del menú, acotado: terminan en una línea con ocho
    # espacios y "})".
    function Get-BloqueManejador {
        param([string] $Nombre)
        return [regex]::Match($script:Eventos,
            ('(?s)\$c\.{0}\.Add_Click\(\{{.*?\n        \}}\)' -f [regex]::Escape($Nombre))).Value
    }
}

Describe 'la clave de exclusion viaja pegada a la fila' {

    <#
        La clave debe viajar en ItemVista y no reconstruirse en la ventana.
        Get-ClaveExclusion elige entre la ruta y una cadena sintética, y
        esa regla es delicada (p. ej. reconocer rutas POSIX, ya que la
        suite corre en Linux): una segunda copia podría equivocarse sola.
    #>

    It 'la prueba lee los archivos: si no, no comprueba nada' {
        $script:Analisis.Length | Should -BeGreaterThan 2000
        $script:Eventos.Length  | Should -BeGreaterThan 2000
        Get-Command Get-ClaveExclusion -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'ItemVista declara la clave y la pregunta que se le hace' {
        $props = @([Cachivache.ItemVista].GetProperties() | ForEach-Object { $_.Name })
        $props | Should -Contain 'ClaveExclusion'
        $props | Should -Contain 'TieneRutaReal'
    }

    It 'la fila la copia del candidato, tal cual' {
        $script:Analisis | Should -Match '\$item\.ClaveExclusion = \$candidato\.ClaveExclusion'
    }

    It 'ningun archivo de la interfaz vuelve a calcularla' {
        # Si la ventana llamara a Get-ClaveExclusion, dos sitios decidirían
        # la misma clave y podrían discrepar: se excluiría una cosa y se
        # compararía otra.
        $culpables = @()
        foreach ($archivo in (Get-ChildItem $script:CarpetaUi -Filter '*.ps1')) {
            $codigo = Get-CodigoSinComentarios $archivo.FullName
            if ($codigo -match 'Get-ClaveExclusion') { $culpables += $archivo.Name }
        }
        $culpables | Should -BeNullOrEmpty -Because (
            'la clave la decide el nucleo al nacer el candidato y viaja en la fila: ' +
            'recalcularla aqui es un segundo sitio que puede equivocarse solo')
    }

    It 'TieneRutaReal contesta lo mismo que decidio Get-ClaveExclusion' -ForEach @(
        @{ Ruta = 'C:\Users\ana\AppData\Local\Temp'; Real = $true  }
        @{ Ruta = 'D:/Proyectos/web';               Real = $true  }
        @{ Ruta = '\\servidor\datos\copias';        Real = $true  }
        @{ Ruta = '/tmp/basura';                    Real = $true  }
        @{ Ruta = 'docker system prune -a -f';      Real = $false }
        @{ Ruta = 'Papelera de reciclaje';          Real = $false }
        @{ Ruta = '';                               Real = $false }
    ) {
        # La clave se pide a la función del núcleo, como hace el candidato
        # real: si la regla cambia, la prueba cambia con ella.
        $item = [Cachivache.ItemVista]::new()
        $item.Ruta = $Ruta
        $item.ClaveExclusion = Get-ClaveExclusion -Ruta $Ruta -ModuloId 'modulo' -Nombre 'Nombre'

        $item.TieneRutaReal | Should -Be $Real
    }

    It 'sin clave no hay ruta real: no se inventa una' {
        # Una fila incompleta no puede hacer pasar una etiqueta por ruta.
        $item = [Cachivache.ItemVista]::new()
        $item.Ruta = 'C:\Windows'
        $item.TieneRutaReal | Should -BeFalse
    }

    It 'no revienta con nulos por ningun lado' {
        $item = [Cachivache.ItemVista]::new()
        { $item.TieneRutaReal } | Should -Not -Throw
        $item.TieneRutaReal | Should -BeFalse
        $item.Ruta = '   '
        $item.ClaveExclusion = '   '
        $item.TieneRutaReal | Should -BeFalse -Because 'tres espacios no son una ruta'
    }
}

Describe 'el menu contextual esta declarado y enganchado' {

    BeforeAll {
        $script:Entradas = @('MenuAbrirUbicacion', 'MenuCopiarRuta',
                             'MenuExcluirSiempre', 'MenuDesmarcarGrupo')
        $script:BloqueMenu = [regex]::Match($script:Panel,
            '(?s)<DataGrid\.ContextMenu>.*?</DataGrid\.ContextMenu>').Value
    }

    It 'el menu esta en el panel: si no, esta prueba no mira nada' {
        $script:BloqueMenu | Should -Not -BeNullOrEmpty
        @([regex]::Matches($script:BloqueMenu, '<MenuItem ')).Count |
            Should -Be 4 -Because 'el menú contextual tiene cuatro órdenes'
    }

    It 'cuelga de la tabla, que es lo que permite darles nombre' {
        # Dentro del estilo de fila, los MenuItem nacen y mueren con la
        # virtualización y FindName no los encuentra.
        $script:Panel | Should -Match '(?s)<DataGrid x:Name="TablaResultados".*?<DataGrid\.ContextMenu>'
    }

    It 'la orden <Entrada> existe con su rotulo' -ForEach @(
        @{ Entrada = 'MenuAbrirUbicacion'; Rotulo = 'Abrir ubicación' }
        @{ Entrada = 'MenuCopiarRuta';     Rotulo = 'Copiar ruta' }
        @{ Entrada = 'MenuExcluirSiempre'; Rotulo = 'Excluir siempre esto' }
        @{ Entrada = 'MenuDesmarcarGrupo'; Rotulo = 'Desmarcar el grupo' }
    ) {
        # El rótulo con sus tildes: es texto que lee el usuario.
        $script:BloqueMenu | Should -Match ('x:Name="{0}" Header="{1}"' -f $Entrada, [regex]::Escape($Rotulo))
    }

    It 'ni un disparador ni un conversor deciden nada dentro del menu' {
        # Sin WPF, un mecanismo de XAML no se puede verificar.
        $script:BloqueMenu | Should -Not -Match 'DataTrigger'
        $script:BloqueMenu | Should -Not -Match '<Style'
        $script:BloqueMenu | Should -Not -Match 'Converter='
    }

    It 'la entrada <Entrada> la resuelve Window.ps1 y la engancha la ventana' -ForEach @(
        @{ Entrada = 'MenuAbrirUbicacion' }
        @{ Entrada = 'MenuCopiarRuta' }
        @{ Entrada = 'MenuExcluirSiempre' }
        @{ Entrada = 'MenuDesmarcarGrupo' }
    ) {
        # Un nombre fuera de la lista de $c deja el control a $null y el
        # menú no responde, sin error.
        $script:Ventana | Should -Match ("'{0}'" -f $Entrada)
        $script:Eventos | Should -Match ('\$c\.{0}\.Add_Click' -f $Entrada)
    }

    It 'si el XAML no trajera el menu, la ventana sigue abriendo' {
        # FindName devuelve $null sin avisar y $null.Add_Click() lanza: sin
        # esta comprobación, un menú ausente impediría abrir la ventana.
        $script:Eventos | Should -Match '\$faltanMenuFila'
        $script:Eventos | Should -Match "(?s)\`$faltanMenuFila.*?Where-Object \{ \`$null -eq \`$c\[\`$_\] \}"
    }
}

Describe 'abrir la ubicacion se decide en un solo sitio' {

    BeforeAll {
        # El manejador del doble clic, acotado: con "(?s).*?" sobre el
        # archivo entero se llegaría hasta la llamada del menú y quitar la
        # del doble clic no haría fallar nada.
        $script:DobleClic = [regex]::Match($script:Eventos,
            '(?s)Add_MouseDoubleClick\(\{.*?\n    \}\)').Value
    }

    It 'existe el cierre y se encuentra el doble clic: si no, esto no mira nada' {
        $script:Ayudantes  | Should -Match '\$abrirUbicacion = \{'
        $script:DobleClic  | Should -Not -BeNullOrEmpty
        $script:DobleClic.Length | Should -BeLessThan 400 -Because 'si abarca medio archivo, no esta acotado'
    }

    It 'los tres caminos llaman al mismo cierre' {
        # El botón de la barra, la orden del menú y el doble clic: tres
        # copias divergirían y el doble clic podría abrir algo que el botón
        # rechaza.
        $script:Eventos   | Should -Match '\$c\.BtnAbrirCarpeta\.Add_Click\(\{ & \$abrirUbicacion'
        $script:Eventos   | Should -Match '\$c\.MenuAbrirUbicacion\.Add_Click\(\{ & \$abrirUbicacion'
        $script:DobleClic | Should -Match '& \$abrirUbicacion'
    }

    It 'solo hay un sitio en toda la interfaz que abra la carpeta de una fila' {
        # Preguntar si la ruta es carpeta o archivo es la firma de "abrir la
        # ubicación": decide entre abrir la carpeta o mostrar el archivo en
        # ella. Debe haber una sola copia de esa decisión y de la
        # comprobación de seguridad que la precede.
        #
        # No se cuenta "/select,": también lo usa el guardado de informes,
        # que abre un archivo que acaba de escribir el propio programa.
        $veces = 0
        foreach ($archivo in (Get-ChildItem $script:CarpetaUi -Filter '*.ps1')) {
            $codigo = Get-CodigoSinComentarios $archivo.FullName
            $veces += @([regex]::Matches($codigo, 'PSIsContainer')).Count
        }
        $veces | Should -Be 1
    }

    It 'no abre el archivo: lo enseña en su carpeta' {
        # Abrir el archivo sería ejecutar algo que el programa propone
        # borrar.
        $cierre = [regex]::Match($script:Ayudantes, '(?s)\$abrirUbicacion = \{.*?\n    \}').Value
        $cierre | Should -Not -BeNullOrEmpty
        $cierre | Should -Match 'Get-RutaExplorador'
        $cierre | Should -Not -Match 'Start-Process -FilePath \$ruta'
    }

    It 'el doble clic sin fila elegida no dice nada' {
        # El doble clic también cae en la cabecera (que ordena) y en el
        # hueco bajo la última fila: un diálogo ahí sería accidental.
        $script:DobleClic | Should -Match 'if \(\$null -eq \$item\) \{ return \}'
        $script:DobleClic | Should -Not -Match 'Show-Aviso'
    }

    It 'la ruta que no existe y la que no es ruta dicen cosas distintas' {
        $cierre = [regex]::Match($script:Ayudantes, '(?s)\$abrirUbicacion = \{.*?\n    \}').Value
        $cierre | Should -Match 'TieneRutaReal'
        $cierre | Should -Match 'Ya no existe'
    }
}

Describe 'copiar ruta no deja una etiqueta en el portapapeles' {

    <#
        Si el elemento no tiene ruta real (un comando, la papelera), no se
        copia nada: una etiqueta en el portapapeles parece una ruta y falla
        más tarde en otro programa. El comando ya se ve entero en la fila
        (lo exige SECURITY.md). Tampoco se calla: se dice que no hay ruta y
        por qué.
    #>

    BeforeAll {
        $script:Copiar = Get-BloqueManejador 'MenuCopiarRuta'
    }

    It 'el manejador esta ahi: si no, esta prueba no mira nada' {
        $script:Copiar | Should -Not -BeNullOrEmpty
        $script:Copiar.Length | Should -BeGreaterThan 300
        $script:Copiar | Should -Match 'Clipboard'
    }

    It 'solo copia cuando hay una ruta de verdad' {
        $script:Copiar | Should -Match 'if \(-not \$item\.TieneRutaReal\)'
        $script:Copiar | Should -Match 'SetText\(\$item\.Ruta\)'
    }

    It 'la comprobacion va ANTES de tocar el portapapeles, y corta' {
        # Si la guarda estuviera después o no cortara, la etiqueta entraría
        # igual: el portapapeles no se puede deshacer.
        $iGuarda = $script:Copiar.IndexOf('TieneRutaReal')
        $iCopia  = $script:Copiar.IndexOf('SetText')
        $iGuarda | Should -BeGreaterThan -1
        $iCopia  | Should -BeGreaterThan $iGuarda

        $guarda = $script:Copiar.Substring($iGuarda, $iCopia - $iGuarda)
        $guarda | Should -Match 'return'
        $guarda | Should -Match 'No se ha copiado nada'
    }

    It 'el portapapeles se toca UNA sola vez en el manejador' {
        @([regex]::Matches($script:Copiar, 'SetText')).Count | Should -Be 1
    }

    It 'el motivo se explica con la misma frase que "abrir ubicación"' {
        # Si una lo llamara comando y la otra etiqueta, parecerían casos
        # distintos.
        $script:Copiar    | Should -Match '& \$describirSinRuta'
        $script:Ayudantes | Should -Match '\$describirSinRuta = \{'
    }

    It 'copiar bien no abre un cuadro de dialogo' {
        # Copiar es frecuente y sin riesgo, y se comprueba al pegar; sí se
        # anota en el registro.
        $script:Copiar | Should -Match '& \$escribir'
    }
}

Describe 'excluir siempre usa el camino de la lista de exclusiones, no uno nuevo' {

    BeforeAll {
        $script:Excluir = Get-BloqueManejador 'MenuExcluirSiempre'
    }

    It 'el manejador esta ahi: si no, esta prueba no mira nada' {
        $script:Excluir | Should -Not -BeNullOrEmpty
        $script:Excluir.Length | Should -BeGreaterThan 800
    }

    It 'guarda la clave de la fila, no una recompuesta' {
        $script:Excluir | Should -Match '\$item\.ClaveExclusion'
    }

    It 'la lista es la de las preferencias' {
        $script:Excluir | Should -Match '\$estado\.Preferencias\.RutasExcluidas ='
    }

    It 'y tambien la copia que miran el embudo y el motor de borrado' {
        # Las dos, porque solo se sincronizan al refrescar los discos: sin
        # esta línea la exclusión no valdría para la limpieza inminente.
        $script:Excluir | Should -Match '\$estado\.Configuracion\.RutasExcluidas ='
    }

    It 'se guarda en disco al momento, no al cerrar la ventana' {
        # Promete "nunca más": un cierre anormal no puede perder la
        # exclusión.
        $script:Excluir | Should -Match '& \$guardarPreferencias'
    }

    It 'pregunta antes: hoy esto no se puede deshacer desde la ventana' {
        $script:Excluir | Should -Match "MessageBox\]::Show\(\`$pregunta"
        $script:Excluir | Should -Match "'YesNo'"
        $script:Excluir | Should -Match "-ne 'Yes'\) \{ return \}"
    }

    It 'la pregunta nombra el elemento y enseña la clave que se guarda' {
        # El menú actúa sobre la fila seleccionada: nombrarla deja ver si
        # se abrió sobre otra fila antes de excluir lo que no era.
        $script:Excluir | Should -Match '\$pregunta = \('
        $script:Excluir | Should -Match 'Se guarda esta clave'
        $script:Excluir | Should -Match '-f \$item\.Nombre, \$clave'
    }

    It 'pregunta si ya estaba excluido con la MISMA funcion que el motor' {
        # Con -contains diría "no estaba" de una carpeta hija de otra ya
        # excluida, y luego el motor la rechazaría igual.
        $script:Excluir | Should -Match 'Test-ClaveExcluida -Clave \$clave'
        $script:Excluir | Should -Not -Match '\$excluidas -contains'
    }

    It 'desmarca al momento lo que la exclusion cubre, con esa misma funcion' {
        # Si no, la fila seguiría marcada y el motor la rechazaría en la
        # limpieza con un error.
        $script:Excluir | Should -Match 'Test-ClaveExcluida -Clave \$fila\.ClaveExclusion'
        $script:Excluir | Should -Match '\$fila\.Seleccionado = \$false'
        $script:Excluir | Should -Match '\$estado\.SuprimirResumen = \$true'
        $script:Excluir | Should -Match '& \$actualizarResumenSeleccion'
    }

    It 'no dice "1 elementos"' {
        # La cuenta de lo desmarcado tiene sus tres casos.
        $script:Excluir | Should -Match '\$desmarcados -eq 0'
        $script:Excluir | Should -Match '\$desmarcados -eq 1'
    }

    It 'la exclusion que se guarda es la que compara el nucleo' {
        # Comprobación de comportamiento: el mismo recorrido que la ventana
        # (clave del candidato, lista, Test-ClaveExcluida) para las dos
        # formas de clave.
        $carpeta = Get-ClaveExclusion -Ruta 'C:\Proyectos\web' -ModuloId 'proyectos' -Nombre 'web'
        Test-ClaveExcluida -Clave $carpeta -Excluidas @($carpeta) | Should -BeTrue
        Test-ClaveExcluida -Clave 'C:\Proyectos\web\node_modules' -Excluidas @($carpeta) |
            Should -BeTrue -Because 'excluir una carpeta excluye lo que cuelga de ella'

        $comando = Get-ClaveExclusion -Ruta 'docker system prune -a -f' -ModuloId 'dockerwsl' -Nombre 'Cache de Docker'
        Test-ClaveExcluida -Clave $comando -Excluidas @($comando) | Should -BeTrue
        Test-ClaveExcluida -Clave 'C:\Proyectos\web' -Excluidas @($comando) |
            Should -BeFalse -Because 'una etiqueta no puede alcanzar a una carpeta'
    }
}

Describe 'desmarcar el grupo es el mismo cierre que el boton de la cabecera' {

    It 'existe el cierre y lo llaman los dos' {
        $script:Eventos | Should -Match '\$marcarCategoria = \{'
        $script:Eventos | Should -Match '& \$marcarCategoria \$categoria \$marcar'
        $script:Eventos | Should -Match '& \$marcarCategoria \$item\.Categoria \$false'
    }

    It 'solo hay UN bucle que marque una categoria entera' {
        # Dos copias del bucle acabarían divergiendo.
        @([regex]::Matches($script:Eventos, '\$item\.Seleccionado = \$Marcar')).Count | Should -Be 1

        # El manejador de los botones de la cabecera delega; un bucle propio
        # sería un segundo sitio que puede dejar de parecerse.
        $handler = [regex]::Match($script:Eventos,
            '(?s)\$c\.TablaResultados\.AddHandler\(.*?\n        \}\)').Value
        $handler | Should -Not -BeNullOrEmpty
        $handler | Should -Not -Match 'foreach'
        $handler | Should -Match '& \$marcarCategoria'
    }

    It 'el menu no puede marcar, solo desmarcar' {
        # Marcar una categoría entera desde el menú marcaría a ciegas cosas
        # que no se ven. Desmarcar nunca hace daño.
        $bloque = Get-BloqueManejador 'MenuDesmarcarGrupo'
        $bloque | Should -Not -BeNullOrEmpty
        $bloque | Should -Not -Match '\$true'
    }
}

Describe 'ocultar lo ya eliminado esconde lo que se borro BIEN' {

    <#
        Es una casilla y no algo automático: esconder el resultado justo
        después de limpiar ocultaría lo que el usuario quiere ver. Así,
        esconderlo es decisión suya y reversible.

        Se oculta por Hecho, que la ventana solo levanta cuando el elemento
        se borró de verdad; un fallo queda con Hecho a falso y su texto en
        Estado. Lo fallido es lo que aún se puede reintentar.
    #>

    It 'la casilla esta en el panel: si no, esta prueba no mira nada' {
        $script:Panel | Should -Match '<CheckBox x:Name="ChkOcultarHechos"'
        $script:Panel | Should -Match 'Content="Ocultar lo ya eliminado"'
    }

    It 'nace desmarcada' {
        # Marcada, escondería el resultado anterior sin que nadie lo pida.
        $elemento = [regex]::Match($script:Panel, '(?s)<CheckBox x:Name="ChkOcultarHechos".*?/>').Value
        $elemento | Should -Not -BeNullOrEmpty
        $elemento | Should -Not -Match 'IsChecked'
    }

    It 'la casilla usa Checked y Unchecked, nunca Click' {
        # Click solo se levanta al pulsar el usuario: si el código cambia
        # la casilla, el filtro y la casilla quedarían desincronizados.
        $script:Eventos | Should -Match '\$c\.ChkOcultarHechos\.Add_Checked'
        $script:Eventos | Should -Match '\$c\.ChkOcultarHechos\.Add_Unchecked'
        $script:Eventos | Should -Not -Match '\$c\.ChkOcultarHechos\.Add_Click'
    }

    It 'tocarla vuelve a filtrar la tabla' {
        $script:Eventos | Should -Match '\$sincronizarOcultarHechos = \{ & \$aplicarFiltro \}'
    }

    It 'el predicado esconde por Hecho' {
        $script:Ayudantes | Should -Match '\$ocultarHechos = \[bool\]\$c\.ChkOcultarHechos\.IsChecked'
        $script:Ayudantes | Should -Match 'if \(\$ocultarHechos -and \$item\.Hecho\) \{ return \$false \}'
    }

    It 'y NUNCA por el estado, que es donde vive el fallo' {
        # Detecta cambiar Hecho por EstadoEsFallo o Estado: escondería lo
        # único que hay que mirar.
        $filtro = [regex]::Match($script:Ayudantes,
            '(?s)\$estado\.Vista\.Filter = \[Predicate\[object\]\] \{.*?\}\.GetNewClosure\(\)').Value
        $filtro | Should -Not -BeNullOrEmpty
        $filtro | Should -Match '\$item\.Hecho'
        $filtro | Should -Not -Match 'EstadoEsFallo'
        $filtro | Should -Not -Match '\$item\.Estado'
    }

    It 'un fallo NUNCA puede estar hecho, asi que no se puede esconder' {
        # Sobre la clase: si la fila indica fallo, Hecho es falso, y el
        # predicado solo esconde lo que tiene Hecho.
        foreach ($hecho in @($true, $false)) {
            foreach ($estado in @('', 'Eliminado', 'No se ha podido borrar: en uso')) {
                $item = [Cachivache.ItemVista]::new()
                $item.Hecho  = $hecho
                $item.Estado = $estado
                if ($item.EstadoEsFallo) {
                    $item.Hecho | Should -BeFalse -Because 'un fallo no esta hecho, y solo se esconde lo hecho'
                }
            }
        }
    }

    It 'Hecho significa "se borro de verdad", y lo pone la eliminacion' {
        # Si Hecho se levantara también con un fallo, se esconderían
        # fallos.
        $script:Eliminacion | Should -Match '\$item\.Hecho = \[bool\]\$item\.Origen\.Hecho'
        $script:Eliminacion | Should -Match 'if \(\$item\.Origen\.Hecho\) \{ \$item\.Seleccionado = \$false \}'
    }

    It 'la casilla no cuenta como filtro de busqueda' {
        # Test-HayFiltroPuesto decide el rótulo del botón del cartel de
        # tabla vacía: si la casilla contara, el botón prometería quitar
        # algo que no quita.
        $script:Ayudantes | Should -Match (
            '-not \(Test-HayFiltroPuesto -TextoFiltro \$texto -RiesgoFiltro \$riesgo\) -and -not \$ocultarHechos')
        # "[^)]*" se detiene en el paréntesis que cierra la llamada: mira
        # dentro de los argumentos, no la condición entera.
        $script:Ayudantes | Should -Not -Match 'Test-HayFiltroPuesto[^)]*\$ocultarHechos'
    }

    It 'con la casilla puesta si hay predicado, aunque no haya filtro de texto' {
        # Sin esto la casilla no haría nada sin un filtro de texto escrito.
        $bloque = [regex]::Match($script:Ayudantes,
            '(?s)\$ocultarHechos = \[bool\].*?\$estado\.Vista\.Filter = \[Predicate').Value
        $bloque | Should -Not -BeNullOrEmpty
        $bloque | Should -Match '\$estado\.Vista\.Filter = \$null'
    }
}
