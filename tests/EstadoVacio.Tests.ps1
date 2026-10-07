<#
    Pruebas del cartel de tabla vacía: debe distinguir entre recién
    abierto, análisis sin resultados y filtro que no deja pasar nada. El
    último es el delicado: si se ve igual que un análisis fallido, el
    usuario vuelve a analizar o cierra el programa.

    Se prueba la función pura y, sobre el texto de los archivos, que la
    ventana delega en ella.
#>

BeforeAll {
    $script:Raiz      = Split-Path $PSScriptRoot -Parent
    $script:CarpetaUi = Join-Path (Join-Path $script:Raiz 'src') 'UI'
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Código sin comentarios: una prueba que busca texto no debe
    # encontrarlo en los comentarios que lo explican.
    function script:Get-CodigoSinComentarios {
        param([string] $Ruta)
        $lineas = [IO.File]::ReadAllText($Ruta) -split "`r?`n"
        $fuera  = $false
        $limpio = foreach ($linea in $lineas) {
            if ($linea -match '<#')  { $fuera = $true }
            if ($fuera) {
                if ($linea -match '#>') { $fuera = $false }
                continue
            }
            if ($linea -match '^\s*#') { continue }
            $linea
        }
        ($limpio -join "`n")
    }

    $script:Ayudantes = script:Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Ayudantes.ps1')
    $script:Eventos   = script:Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Eventos.ps1')

    # El XAML sin comentarios <!-- -->, por el mismo motivo.
    $script:PanelXaml = [regex]::Replace(
        [IO.File]::ReadAllText((Join-Path $script:CarpetaUi 'Panel.Resultados.xaml')),
        '(?s)<!--.*?-->', '')
}

Describe 'Get-EstadoVacio distingue los tres vacios' {

    It 'devuelve los seis campos que la ventana necesita' {
        # Si el objeto cambiara de forma, las pruebas siguientes
        # compararían $null contra $null y pasarían.
        $r = Get-EstadoVacio -Fase 'terminado' -Total 0 -HayVisibles $false
        foreach ($campo in @('Vacio', 'Caso', 'Texto', 'OfrecerQuitarFiltro',
                             'OfrecerMostrarHechos', 'TextoBoton')) {
            $r.PSObject.Properties.Name | Should -Contain $campo
        }
    }

    It 'con filas a la vista no enseña ningun cartel' {
        $r = Get-EstadoVacio -Fase 'terminado' -Total 900 -HayVisibles $true -TextoFiltro 'chrome'
        $r.Vacio | Should -BeFalse
        $r.Caso  | Should -Be 'con-datos'
        $r.Texto | Should -BeNullOrEmpty
        $r.OfrecerQuitarFiltro | Should -BeFalse
    }

    It 'recien abierto dice que todavia no se ha analizado' {
        $r = Get-EstadoVacio -Fase 'sin-analizar' -Total 0 -HayVisibles $false
        $r.Vacio | Should -BeTrue
        $r.Caso  | Should -Be 'sin-analizar'
        $r.Texto | Should -BeLike '*Todavía no se ha analizado nada*'
        $r.OfrecerQuitarFiltro | Should -BeFalse
    }

    It 'mientras analiza no dice que no hay nada, dice que se esta llenando' {
        $r = Get-EstadoVacio -Fase 'analizando' -Total 0 -HayVisibles $false
        $r.Caso  | Should -Be 'analizando'
        $r.Texto | Should -BeLike '*se irá llenando*'
    }

    It 'analizado y sin resultados NO suena a fallo' {
        # Cero resultados no es un error: no hay basura.
        $r = Get-EstadoVacio -Fase 'terminado' -Total 0 -HayVisibles $false
        $r.Caso  | Should -Be 'sin-resultados'
        $r.Texto | Should -BeLike '*buena noticia*'
        $r.Texto | Should -Not -Match '(?i)(error|no se ha podido|ha fallado|problema)'
    }

    It 'analizado y sin resultados dice de que depende el resultado' {
        # "Tu equipo está limpio" sería exagerar: se sabe que no hay nada
        # con estos módulos y ajustes.
        $r = Get-EstadoVacio -Fase 'terminado' -Total 0 -HayVisibles $false
        $r.Texto | Should -BeLike '*módulos*'
        $r.Texto | Should -BeLike '*ajustes*'
    }

    It 'con filtro que no deja pasar nada dice que la lista esta filtrada, no vacia' {
        $r = Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false -TextoFiltro 'chromme'
        $r.Vacio | Should -BeTrue
        $r.Caso  | Should -Be 'filtrado'
        $r.Texto | Should -BeLike '*812 elementos*'
        $r.Texto | Should -BeLike '*filtrada*'
        $r.OfrecerQuitarFiltro | Should -BeTrue
    }

    It 'el caso del filtro nombra CUANTOS elementos hay detras' {
        # El número es lo que muestra que los resultados siguen ahí.
        (Get-EstadoVacio -Fase 'terminado' -Total 1 -HayVisibles $false -RiesgoFiltro 'Alto').Texto |
            Should -BeLike '*1 elemento,*'
        (Get-EstadoVacio -Fase 'terminado' -Total 2 -HayVisibles $false -RiesgoFiltro 'Alto').Texto |
            Should -BeLike '*2 elementos,*'
    }

    It 'un filtro de solo espacios no cuenta como filtro' {
        # El filtro usa IsNullOrWhiteSpace: tres espacios no esconden nada
        # y el botón no cambiaría nada.
        $r = Get-EstadoVacio -Fase 'terminado' -Total 5 -HayVisibles $false -TextoFiltro '   '
        $r.Caso | Should -Be 'oculto'
        $r.OfrecerQuitarFiltro | Should -BeFalse
    }

    It 'analizando con la lista llena y filtrada habla del filtro, no del analisis' {
        # El filtro se comprueba antes que la fase: si no, un análisis en
        # marcha diría "se irá llenando" sobre filas ocultas por el filtro.
        $r = Get-EstadoVacio -Fase 'analizando' -Total 700 -HayVisibles $false -TextoFiltro 'zzz'
        $r.Caso | Should -Be 'filtrado'
    }

    It 'una fase desconocida nunca afirma que hubo un analisis' {
        foreach ($fase in @('', 'reposo', 'borrado', 'lo-que-sea')) {
            (Get-EstadoVacio -Fase $fase -Total 0 -HayVisibles $false).Caso |
                Should -Be 'sin-analizar' -Because "la fase '$fase' no dice que se haya analizado"
        }
    }

    It 'no revienta con nulos ni con un total negativo' {
        { Get-EstadoVacio -Fase $null -Total 0 -HayVisibles $false -TextoFiltro $null -RiesgoFiltro $null } |
            Should -Not -Throw
        { Get-EstadoVacio -Fase 'terminado' -Total -5 -HayVisibles $false } | Should -Not -Throw
        (Get-EstadoVacio -Fase 'terminado' -Total -5 -HayVisibles $false).Caso | Should -Be 'sin-resultados'
    }
}

Describe 'la casilla "Ocultar lo ya eliminado" tambien vacia la tabla' {

    <#
        La casilla que oculta las filas ya eliminadas también puede vaciar
        la tabla. Si el cartel culpara al filtro de texto, quitarlo no
        destaparía nada.
    #>

    It 'sin la casilla marcada nada cambia respecto a antes' {
        # Si el parámetro alterase el caso general, las pruebas siguientes
        # medirían otra cosa.
        (Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false -TextoFiltro 'zzz' `
             -OcultandoHechos $false).Caso | Should -Be 'filtrado'
        (Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false `
             -OcultandoHechos $false).Caso | Should -Be 'oculto'
    }

    It 'con la casilla marcada la nombra, y no habla de la lista vacia' {
        $r = Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false -OcultandoHechos $true
        $r.Vacio | Should -BeTrue
        $r.Caso  | Should -Be 'ocultando-hechos'
        $r.Texto | Should -BeLike '*812 elementos*'
        $r.Texto | Should -BeLike '*Ocultar lo ya eliminado*'
        $r.Texto | Should -BeLike '*no está vacía*'
    }

    It 'ofrece destapar lo eliminado, y el rotulo dice lo que hace' {
        $r = Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false -OcultandoHechos $true
        $r.OfrecerMostrarHechos | Should -BeTrue
        $r.TextoBoton           | Should -Be 'Mostrar lo ya eliminado'
    }

    It 'con filtro Y casilla se pregunta antes por la casilla' {
        # El filtro está a la vista en el cuadro; la casilla puede llevar
        # tiempo marcada sin que se note. Además, quitar los filtros no
        # destapa lo eliminado.
        $r = Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false `
                 -TextoFiltro 'chromme' -RiesgoFiltro 'Alto' -OcultandoHechos $true
        $r.Caso                 | Should -Be 'ocultando-hechos'
        $r.OfrecerMostrarHechos | Should -BeTrue
        $r.OfrecerQuitarFiltro  | Should -BeFalse
    }

    It 'con filtro Y casilla el texto NOMBRA LAS DOS causas' {
        # Ningún botón garantiza llenar la tabla: hay que nombrar las dos
        # causas.
        $r = Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false `
                 -TextoFiltro 'chromme' -OcultandoHechos $true
        $r.Texto | Should -BeLike '*filtro*'
        $r.Texto | Should -BeLike '*Ocultar lo ya eliminado*'
    }

    It 'sin filtro dice ademas por que estan escondidos' {
        # Si la casilla es lo único que oculta y no se ve nada, se borraron
        # todas: es la buena noticia.
        $r = Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false -OcultandoHechos $true
        $r.Texto | Should -BeLike '*ya se eliminaron*'
        $r.Texto | Should -Not -BeLike '*el filtro*'
    }

    It 'la casilla no manda si hay filas a la vista' {
        # Primero se mira si hay algo a la vista.
        (Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $true -OcultandoHechos $true).Caso |
            Should -Be 'con-datos'
    }

    It 'la casilla no acusa a nadie cuando no hay nada que esconder' {
        # Con Total 0 no hay filas ocultas que atribuir a la casilla.
        (Get-EstadoVacio -Fase 'terminado' -Total 0 -HayVisibles $false -OcultandoHechos $true).Caso |
            Should -Be 'sin-resultados'
        (Get-EstadoVacio -Fase 'analizando' -Total 0 -HayVisibles $false -OcultandoHechos $true).Caso |
            Should -Be 'analizando'
    }

    It 'NUNCA se ofrecen los dos botones a la vez' {
        # Comparten TextoBoton: ofrecidos juntos, uno llevaría el rótulo del
        # otro.
        foreach ($total in @(0, 1, 812)) {
            foreach ($visibles in @($true, $false)) {
                foreach ($texto in @('', 'chrome')) {
                    foreach ($riesgo in @('', 'Alto')) {
                        foreach ($hechos in @($true, $false)) {
                            foreach ($fase in @('sin-analizar', 'analizando', 'terminado')) {
                                $r = Get-EstadoVacio -Fase $fase -Total $total -HayVisibles $visibles `
                                         -TextoFiltro $texto -RiesgoFiltro $riesgo -OcultandoHechos $hechos
                                ($r.OfrecerQuitarFiltro -and $r.OfrecerMostrarHechos) |
                                    Should -BeFalse -Because "fase=$fase total=$total visibles=$visibles texto='$texto' riesgo='$riesgo' hechos=$hechos"
                                if (-not $r.OfrecerQuitarFiltro -and -not $r.OfrecerMostrarHechos) {
                                    $r.TextoBoton | Should -BeNullOrEmpty
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    It 'por defecto la casilla se considera sin marcar' {
        # Quien no pase el dato (p. ej. la consola) nunca verá culpar a una
        # casilla que quizá no esté marcada.
        (Get-EstadoVacio -Fase 'terminado' -Total 812 -HayVisibles $false).Caso | Should -Be 'oculto'
    }

    It 'no revienta con nulos' {
        { Get-EstadoVacio -Fase $null -Total 812 -HayVisibles $false -TextoFiltro $null `
              -RiesgoFiltro $null -OcultandoHechos $false } | Should -Not -Throw
    }
}

Describe 'el boton dice cuantos filtros va a quitar' {

    It 'con <Texto> y <Riesgo> el rotulo es <Esperado>' -ForEach @(
        @{ Texto = 'chrome'; Riesgo = 'Alto'; Esperado = 'Quitar los dos filtros' }
        @{ Texto = 'chrome'; Riesgo = '';     Esperado = 'Quitar el filtro de texto' }
        @{ Texto = '';       Riesgo = 'Bajo'; Esperado = 'Quitar el filtro de riesgo' }
    ) {
        $r = Get-EstadoVacio -Fase 'terminado' -Total 40 -HayVisibles $false `
                 -TextoFiltro $Texto -RiesgoFiltro $Riesgo
        $r.TextoBoton | Should -Be $Esperado
    }

    It 'nombrar los dos es lo que impide que el boton parezca roto' {
        # Si dijera "Quitar el filtro" y solo quitara uno, la tabla podría
        # seguir vacía y el botón parecería roto.
        (Get-TextoQuitarFiltros -TextoFiltro 'x' -RiesgoFiltro 'Alto') | Should -Be 'Quitar los dos filtros'
    }

    It 'no revienta con nulos' {
        { Get-TextoQuitarFiltros -TextoFiltro $null -RiesgoFiltro $null } | Should -Not -Throw
    }
}

Describe 'la tabla de riesgos del desplegable vive en un solo sitio' {

    It 'el indice <Indice> es "<Esperado>"' -ForEach @(
        @{ Indice = 0;  Esperado = '' }
        @{ Indice = 1;  Esperado = 'Bajo' }
        @{ Indice = 2;  Esperado = 'Medio' }
        @{ Indice = 3;  Esperado = 'Alto' }
        @{ Indice = -1; Esperado = '' }
        @{ Indice = 9;  Esperado = '' }
    ) { Get-RiesgoDelFiltro -Indice $Indice | Should -Be $Esperado }

    It 'las cuatro posiciones son las del ComboBox del panel' {
        # Una opción añadida al desplegable y no a la función dejaría de
        # filtrar en silencio.
        $opciones = @([regex]::Matches($script:PanelXaml,
                      '<ComboBoxItem Content="([^"]+)"')) | ForEach-Object { $_.Groups[1].Value }
        $opciones.Count | Should -Be 4 -Because 'la funcion mapea exactamente cuatro posiciones'
        $opciones[0] | Should -BeLike '*Todos*'
    }

    It 'Test-HayFiltroPuesto usa la misma regla que el cierre que filtra' {
        Test-HayFiltroPuesto -TextoFiltro ''    -RiesgoFiltro ''     | Should -BeFalse
        Test-HayFiltroPuesto -TextoFiltro '   ' -RiesgoFiltro ''     | Should -BeFalse
        Test-HayFiltroPuesto -TextoFiltro $null -RiesgoFiltro $null  | Should -BeFalse
        Test-HayFiltroPuesto -TextoFiltro 'a'   -RiesgoFiltro ''     | Should -BeTrue
        Test-HayFiltroPuesto -TextoFiltro ''    -RiesgoFiltro 'Alto' | Should -BeTrue
    }
}

Describe 'la decision no vive en el XAML' {

    <#
        Sin WPF un mecanismo de XAML no se puede verificar. Un Style con
        DataTrigger llegó a aplicar el disparador y no el valor por defecto
        en Windows, sin causa conocida.
    #>

    BeforeAll {
        $script:BloqueCartel = [regex]::Match($script:PanelXaml,
            '(?s)<Border x:Name="EstadoVacio".*?</Border>').Value
    }

    It 'el cartel esta en el panel: si no, esta prueba no mira nada' {
        $script:BloqueCartel | Should -Not -BeNullOrEmpty
        $script:BloqueCartel | Should -Match 'x:Name="TxtEstadoVacio"'
        $script:BloqueCartel | Should -Match 'x:Name="BtnQuitarFiltros"'
    }

    It 'nace plegado: el cartel de tabla vacia sobre la tabla llena seria peor que nada' {
        $script:BloqueCartel | Should -Match '<Border x:Name="EstadoVacio"[^>]*Visibility="Collapsed"'
    }

    It 'ni un disparador ni un conversor deciden que se ve' {
        $script:BloqueCartel | Should -Not -Match 'DataTrigger'
        $script:BloqueCartel | Should -Not -Match '<Style'
        $script:BloqueCartel | Should -Not -Match 'Converter='
    }

    It 'el texto y la visibilidad se asignan desde PowerShell' {
        $script:Ayudantes | Should -Match '\$c\.TxtEstadoVacio\.Text\s*='
        $script:Ayudantes | Should -Match '\$c\.EstadoVacio\.Visibility\s*='
        $script:Ayudantes | Should -Match '\$c\.BtnQuitarFiltros\.Visibility\s*='
    }

    It 'el boton tiene rotulo propio, asi que no queda mudo' {
        # Un Button sin Content de texto se anuncia como "botón" a secas.
        # Este es el rótulo general; el código lo reescribe según los
        # filtros.
        $script:BloqueCartel | Should -Match 'Content="Quitar los filtros"'
    }
}

Describe 'la ventana llama a la funcion y no vuelve a decidir por su cuenta' {

    It 'los archivos tienen contenido: si no, nada de esto comprueba nada' {
        $script:Ayudantes.Length | Should -BeGreaterThan 4000
        $script:Eventos.Length   | Should -BeGreaterThan 4000
    }

    It 'el cartel sale de Get-EstadoVacio, no de un if de la ventana' {
        $script:Ayudantes | Should -Match 'Get-EstadoVacio\s+-Fase'
    }

    It 'el filtro y el cartel preguntan lo mismo a la misma funcion' {
        # Si no, habría dos copias de la tabla de riesgos.
        $script:Ayudantes | Should -Match 'Get-RiesgoDelFiltro -Indice'
        $script:Ayudantes | Should -Match 'Test-HayFiltroPuesto -TextoFiltro'
        $script:Ayudantes | Should -Not -Match "1 \{ 'Bajo' \}"
    }

    It 'el resumen del pie arrastra el cartel, que es lo que lo mantiene al dia' {
        $script:Ayudantes | Should -Match '(?s)\$actualizarResumenSeleccion = \{.{0,400}& \$actualizarEstadoVacio'
    }

    It 'empezar un analisis refresca el cartel al momento' {
        # Si no, el resultado del análisis anterior quedaría sobre la lista
        # vacía hasta que termine el primer módulo.
        $script:Eventos | Should -Match '(?s)\$estado\.Items\.Clear\(\).*?& \$actualizarEstadoVacio'
    }

    It 'el boton del cartel esta enganchado' {
        $script:Eventos | Should -Match '\$c\.BtnQuitarFiltros\.Add_Click'
    }

    It 'el boton quita LOS DOS filtros' {
        # Si quitara solo uno, la tabla podría seguir vacía.
        $quitar = [regex]::Match($script:Ayudantes, '(?s)\$quitarFiltros = \{.*?\n    \}').Value
        $quitar | Should -Not -BeNullOrEmpty
        $quitar | Should -Match '\$c\.CampoFiltro\.Text\s*='
        $quitar | Should -Match '\$c\.FiltroRiesgo\.SelectedIndex\s*=\s*0'
    }

    It 'el cronometro se arranca al analizar, que es como se sabe que ya se analizo' {
        # Distingue "recién abierto" de "analizado sin resultados".
        $script:Eventos   | Should -Match '\$estado\.Cronometro = \[Diagnostics\.Stopwatch\]::StartNew\(\)'
        $script:Ayudantes | Should -Match '\$null -eq \$estado\.Cronometro'
    }

    It 'saber si hay algo a la vista no recorre la tabla entera' {
        # Se recalcula en cada clic de casilla: materializar miles de filas
        # para saber si hay una es demasiado lento.
        $script:Ayudantes | Should -Match '\$estado\.Vista\.IsEmpty'
    }
}

Describe 'los textos que ve el usuario estan bien escritos' {

    BeforeAll {
        # Un texto por caso con cartel. La cuenta impide que dos situaciones
        # distintas digan lo mismo.
        $script:Textos = @(
            (Get-EstadoVacio -Fase 'sin-analizar' -Total 0 -HayVisibles $false).Texto
            (Get-EstadoVacio -Fase 'analizando'   -Total 0 -HayVisibles $false).Texto
            (Get-EstadoVacio -Fase 'terminado'    -Total 0 -HayVisibles $false).Texto
            (Get-EstadoVacio -Fase 'terminado' -Total 9 -HayVisibles $false -TextoFiltro 'x').Texto
            (Get-EstadoVacio -Fase 'terminado' -Total 9 -HayVisibles $false).Texto
            (Get-EstadoVacio -Fase 'terminado' -Total 9 -HayVisibles $false -OcultandoHechos $true).Texto
            (Get-EstadoVacio -Fase 'terminado' -Total 9 -HayVisibles $false -TextoFiltro 'x' `
                 -OcultandoHechos $true).Texto
        )
    }

    It 'hay siete textos distintos: si no, esta prueba no compara nada' {
        @($script:Textos | Select-Object -Unique).Count | Should -Be 7
        foreach ($t in $script:Textos) { $t.Length | Should -BeGreaterThan 40 }
    }

    It 'ninguno usa una palabra sin su tilde' {
        $sinTilde = @('analisis', 'aqui', 'vacia', 'estan', 'ningun', 'despues', 'ultima', 'modulos')
        $patron = '\b(' + ($sinTilde -join '|') + ')\b'
        foreach ($t in $script:Textos) { $t | Should -Not -CMatch $patron }
    }

    It 'ninguno dice "1 elementos"' {
        (Get-EstadoVacio -Fase 'terminado' -Total 1 -HayVisibles $false -TextoFiltro 'x').Texto |
            Should -Not -Match '1 elementos'
    }
}

Describe 'la barra de seleccion cuando lo marcado no ocupa nada' {
    # Carpetas vacías y accesos rotos vienen marcados y suman 0 B: decir
    # "se recuperarían 0 B" parece un fallo del programa.

    It 'con 0 bytes dice que no ocupan espacio, no "se recuperarían 0 B"' {
        $script:Ayudantes | Should -Match ([regex]::Escape("'{0} - no ocupan espacio'"))
        $script:Ayudantes | Should -Match 'if \(\$bytes -gt 0\)'
    }

    It 'y la proyeccion no promete pasar de X libres a X libres' {
        $script:Ayudantes | Should -Match 'no libera espacio en'
    }
}

