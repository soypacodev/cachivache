<#
    Pruebas de la lista de exclusiones en Ajustes: verla y quitar entradas.

    Lo que se protege:

      1. La clave no se pierde: lo que se muestra y lo que se guarda son
         distintos ("modulo:<Id>|<Nombre>" no es una ruta) y el botón de
         quitar debe llevar la clave guardada.
      2. La cadena interna no llega a la pantalla.
      3. La tarjeta vacía dice algo útil: es el estado normal al abrir
         Ajustes por primera vez.
      4. Quitar actualiza preferencias y configuración y guarda al momento,
         igual que añadir.
      5. Quitar no pide confirmación y añadir sí; se comprueban los dos
         sentidos.

    El código se lee sin comentarios para que las pruebas de texto no
    encuentren lo que buscan en las explicaciones.
#>

BeforeAll {
    $script:Raiz      = Split-Path $PSScriptRoot -Parent
    $script:CarpetaUi = Join-Path (Join-Path $script:Raiz 'src') 'UI'

    . (Join-Path $script:CarpetaUi 'Types.ps1')
    Initialize-TiposInterfaz

    # Núcleo completo: Get-ExclusionVista, Get-ClaveExclusion y
    # Test-ClaveExcluida son las piezas cuya coherencia se prueba.
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Sin comentarios de línea (#), de bloque (<# #>) ni de C# (///), que
    # es como se comentan las clases dentro de Types.ps1.
    function Get-CodigoSinComentarios {
        param([string] $Ruta)
        $lineas = @(Get-Content -LiteralPath $Ruta |
                    Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*///' })
        return [regex]::Replace(($lineas -join "`n"), '(?s)<#.*?#>', '')
    }

    $script:Ayudantes = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Ayudantes.ps1')
    $script:Eventos   = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.Eventos.ps1')
    $script:Ventana   = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Window.ps1')
    $script:Tipos     = Get-CodigoSinComentarios (Join-Path $script:CarpetaUi 'Types.ps1')

    # El XAML del panel sin comentarios <!-- -->, por el mismo motivo.
    $script:PanelAjustes = [regex]::Replace(
        (Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUi 'Panel.Ajustes.xaml')),
        '(?s)<!--.*?-->', '')

    # Bloque de la tarjeta, desde su título hasta el ItemsControl, para no
    # mirar los estilos legítimos del resto del panel.
    $script:TarjetaXaml = [regex]::Match($script:PanelAjustes,
        '(?s)<TextBlock Text="Lo que no se toca nunca".*?</ItemsControl>').Value

    $script:QuitarExclusion = [regex]::Match($script:Ayudantes,
        '(?s)\$quitarExclusion = \{.*?\n    \}').Value
    $script:RefrescarExclusiones = [regex]::Match($script:Ayudantes,
        '(?s)\$refrescarExclusiones = \{.*?\n    \}').Value
    $script:ManejadorQuitar = [regex]::Match($script:Eventos,
        '(?s)\$c\.ListaExclusiones\.AddHandler\(.*?\n        \}\)').Value
    $script:Excluir = [regex]::Match($script:Eventos,
        '(?s)\$c\.MenuExcluirSiempre\.Add_Click\(\{.*?\n        \}\)').Value

    # Claves compuestas con la misma función que usa el programa; una
    # copia a mano del formato no detectaría un cambio en
    # Get-ClaveExclusion.
    $script:ClaveCarpeta = Get-ClaveExclusion -Ruta 'C:\Proyectos\web' -ModuloId 'proyectos' -Nombre 'web'
    $script:ClaveComando = Get-ClaveExclusion -Ruta 'docker system prune -a -f' `
                               -ModuloId 'dockerwsl' -Nombre 'Caché de Docker'
    $script:ClaveManual  = 'docker system prune'
}

Describe 'cada clave se presenta segun lo que es' {

    It 'devuelve los cuatro campos que la tarjeta necesita' {
        # Si el objeto cambiara de forma, las pruebas siguientes
        # compararían $null contra $null y pasarían.
        $r = Get-ExclusionVista -Clave $script:ClaveCarpeta
        foreach ($campo in @('Clave', 'Titulo', 'Detalle', 'Tipo')) {
            $r.PSObject.Properties.Name | Should -Contain $campo
        }
    }

    It 'las dos formas de clave existen de verdad y no se parecen' {
        # Si Get-ClaveExclusion devolviera lo mismo, solo se probaría un
        # camino.
        $script:ClaveCarpeta | Should -Be 'C:\Proyectos\web'
        $script:ClaveComando | Should -Not -Be $script:ClaveCarpeta
        $script:ClaveComando | Should -Match '\|'
    }

    It 'una ruta se enseña entera, no solo el ultimo tramo' {
        # Dos proyectos "web" en carpetas distintas darían filas
        # idénticas.
        $r = Get-ExclusionVista -Clave $script:ClaveCarpeta
        $r.Tipo   | Should -Be 'carpeta'
        $r.Titulo | Should -Be 'C:\Proyectos\web'
        $r.Detalle | Should -Match 'dentro'
    }

    It 'una clave sintetica enseña el nombre, no la cadena interna' {
        $r = Get-ExclusionVista -Clave $script:ClaveComando
        $r.Tipo   | Should -Be 'modulo'
        $r.Titulo | Should -Be 'Caché de Docker'
        $r.Titulo | Should -Not -Match 'modulo:'
        $r.Titulo | Should -Not -Match '\|'
    }

    It 'y el detalle nombra el modulo, que es lo que las distingue' {
        # Dos módulos pueden traer elementos con el mismo nombre: el Id es
        # lo que los distingue.
        $r = Get-ExclusionVista -Clave $script:ClaveComando
        $r.Detalle | Should -Match 'dockerwsl'
        $r.Detalle | Should -Match 'no es una carpeta'
    }

    It 'lo escrito a mano se enseña tal cual y dice hasta donde llega' {
        # Solo puede venir de editar preferencias.json o de -Excluir en
        # consola. Test-ClaveExcluida compara por igualdad exacta y hay que
        # decirlo.
        $r = Get-ExclusionVista -Clave $script:ClaveManual
        $r.Tipo   | Should -Be 'texto'
        $r.Titulo | Should -Be $script:ClaveManual
        $r.Detalle | Should -Match 'exactamente'
    }

    It 'ningun titulo se queda en blanco' {
        # Una fila sin texto no se ve y no se puede quitar.
        foreach ($clave in @($script:ClaveCarpeta, $script:ClaveComando, $script:ClaveManual,
                             'modulo:dockerwsl|', 'modulo:|Algo', 'modulo:|', 'C:\', '\\equipo\recurso')) {
            $r = Get-ExclusionVista -Clave $clave
            $r         | Should -Not -BeNullOrEmpty -Because "'$clave' tiene contenido"
            $r.Titulo  | Should -Not -BeNullOrEmpty -Because "'$clave' se tiene que poder ver"
            $r.Detalle | Should -Not -BeNullOrEmpty
        }
    }

    It 'un nombre con barras verticales dentro llega entero' {
        # El Id no admite la barra, el nombre sí: se parte por la primera.
        $r = Get-ExclusionVista -Clave 'modulo:raro|Uno | Dos'
        $r.Titulo | Should -Be 'Uno | Dos'
    }

    It 'no revienta con nulo ni con blanco, y no enseña una fila vacia' {
        { Get-ExclusionVista -Clave $null } | Should -Not -Throw
        Get-ExclusionVista -Clave $null  | Should -BeNullOrEmpty
        Get-ExclusionVista -Clave ''     | Should -BeNullOrEmpty
        Get-ExclusionVista -Clave '   '  | Should -BeNullOrEmpty
    }
}

Describe 'la clave que se ofrece quitar es la que compara el nucleo' {

    <#
        Lo que se quita debe ser la cadena exacta guardada que compara el
        motor. Si la presentación recortara, normalizara o cambiara
        mayúsculas, el botón no quitaría nada.
    #>

    It 'la clave vuelve identica, caracter por caracter' {
        foreach ($clave in @($script:ClaveCarpeta, $script:ClaveComando, $script:ClaveManual,
                             'C:\Proyectos\WEB', 'c:/proyectos/web/', 'modulo:dockerwsl|Caché de Docker')) {
            (Get-ExclusionVista -Clave $clave).Clave | Should -BeExactly $clave
        }
    }

    It 'lo que devuelve la presentacion sigue excluyendo lo mismo' {
        # Recorrido completo: la clave que sale de la tarjeta se compara con
        # la misma función que usan el embudo y el motor.
        foreach ($clave in @($script:ClaveCarpeta, $script:ClaveComando, $script:ClaveManual)) {
            $ofrecida = (Get-ExclusionVista -Clave $clave).Clave
            Test-ClaveExcluida -Clave $clave -Excluidas @($ofrecida) |
                Should -BeTrue -Because 'quitar de la lista lo que muestra la tarjeta tiene que quitar esa misma exclusión'
        }
    }

    It 'y el titulo NO sirve para excluir cuando la clave es sintetica' {
        # Motivo de que Clave y Titulo estén separados.
        $vista = Get-ExclusionVista -Clave $script:ClaveComando
        Test-ClaveExcluida -Clave $script:ClaveComando -Excluidas @($vista.Titulo) |
            Should -BeFalse -Because 'el titulo es texto para leer, no la clave'
    }
}

Describe 'la tarjeta vacia dice algo util' {

    It 'con la lista vacia no se queda en blanco y dice como se llena' {
        # Un hueco en blanco se lee como datos perdidos, y el vacío es el
        # estado normal antes de excluir nada.
        $t = Get-TextoListaExclusiones -Cuantas 0
        $t | Should -Not -BeNullOrEmpty
        $t | Should -Match 'Excluir siempre esto'
        $t | Should -Match 'Resultados'
    }

    It 'un negativo se trata como vacio' {
        Get-TextoListaExclusiones -Cuantas -3 | Should -Be (Get-TextoListaExclusiones -Cuantas 0)
    }

    It 'no dice "1 elementos"' {
        $uno = Get-TextoListaExclusiones -Cuantas 1
        $uno | Should -Match '1 elemento excluido'
        $uno | Should -Not -Match '1 elementos'
    }

    It 'con varios dice cuantos' {
        Get-TextoListaExclusiones -Cuantas 7 | Should -Match '7 elementos excluidos'
    }

    It 'los tres textos dicen que quitar de la lista no borra nada' {
        # Por eso quitar no pide confirmación: devuelve el elemento a estar
        # propuesto, no destruye nada.
        foreach ($cuantas in @(0, 1, 7)) {
            Get-TextoListaExclusiones -Cuantas $cuantas |
                Should -Match 'quitar|Quitar' -Because 'la tarjeta tiene que decir que se puede quitar'
        }
        Get-TextoListaExclusiones -Cuantas 1 | Should -Match 'no borra nada'
        Get-TextoListaExclusiones -Cuantas 7 | Should -Match 'no borra nada'
    }
}

Describe 'la clase de la vista y la funcion no pueden divergir' {

    It 'ExclusionVista existe y se puede rellenar' {
        $fila = New-Object Cachivache.ExclusionVista
        $fila.Clave   = $script:ClaveComando
        $fila.Titulo  = 'Caché de Docker'
        $fila.Detalle = 'x'
        $fila.Tipo    = 'modulo'
        $fila.Clave | Should -BeExactly $script:ClaveComando
    }

    It 'la clase declara exactamente los campos que devuelve la funcion' {
        # Si divergen, un campo se calcula y no llega a la pantalla.
        $devueltos = @((Get-ExclusionVista -Clave $script:ClaveCarpeta).PSObject.Properties.Name | Sort-Object)
        $declarados = @([regex]::Matches($script:Tipos,
                            '(?s)class ExclusionVista.*?\n    \}') |
                        ForEach-Object { [regex]::Matches($_.Value, 'public string (\w+)') } |
                        ForEach-Object { $_.Groups[1].Value } | Sort-Object)

        $declarados.Count | Should -BeGreaterThan 3 -Because 'si no, se leyo mal Types.ps1'
        ($declarados -join ',') | Should -Be ($devueltos -join ',')
    }
}

Describe 'la tarjeta de Ajustes enseña la lista' {

    It 'la tarjeta esta en el panel: si no, esta prueba no mira nada' {
        $script:TarjetaXaml | Should -Not -BeNullOrEmpty
        $script:TarjetaXaml.Length | Should -BeGreaterThan 400
        $script:PanelAjustes | Should -Match 'Lo que no se toca nunca'
    }

    It 'tiene el rotulo del resumen y la lista' {
        $script:TarjetaXaml | Should -Match 'x:Name="TxtResumenExclusiones"'
        $script:TarjetaXaml | Should -Match 'x:Name="ListaExclusiones"'
    }

    It 'cada fila enseña el titulo y el detalle' {
        $script:TarjetaXaml | Should -Match '\{Binding Titulo\}'
        $script:TarjetaXaml | Should -Match '\{Binding Detalle\}'
    }

    It 'el boton de quitar lleva la CLAVE en el Tag, no el titulo' {
        # Con el título en el Tag, quitar una exclusión sintética no
        # encontraría nada.
        $boton = [regex]::Match($script:TarjetaXaml, '(?s)<Button x:Name="BtnQuitarExclusion".*?/>').Value
        $boton | Should -Not -BeNullOrEmpty
        $boton | Should -Match 'Tag="\{Binding Clave\}"'
        $boton | Should -Match 'Content="Quitar"'
    }

    It 'la tarjeta no decide nada con mecanismos de XAML' {
        # Sin WPF no se puede comprobar un disparador: lo que se ve sale de
        # una función pura y lo asigna la ventana.
        $script:TarjetaXaml | Should -Not -Match 'DataTrigger'
        $script:TarjetaXaml | Should -Not -Match 'Trigger'
        $script:TarjetaXaml | Should -Not -Match 'Converter'
        $script:TarjetaXaml | Should -Not -Match 'Visibility='
    }

    It 'los dos controles los resuelve la lista de siempre de Window.ps1' {
        # Una tabla de controles aparte quedaría fuera de la invariante que
        # impide que $c y el XAML diverjan.
        $bloque = [regex]::Match($script:Ventana,
            '(?s)\$c = @\{\}.*?\$c\[\$nombre\] = \$ventana\.FindName').Value
        $bloque | Should -Not -BeNullOrEmpty
        $bloque | Should -Match "'TxtResumenExclusiones'"
        $bloque | Should -Match "'ListaExclusiones'"
    }

    It 'el rotulo sale de la funcion pura, no de un texto compuesto en la ventana' {
        $script:RefrescarExclusiones | Should -Not -BeNullOrEmpty
        $script:RefrescarExclusiones | Should -Match '\$c\.TxtResumenExclusiones\.Text = Get-TextoListaExclusiones'
        $script:RefrescarExclusiones | Should -Match 'Get-ExclusionVista -Clave'
    }

    It 'la ventana no interpreta la clave por su cuenta' {
        # La forma de la clave solo la conoce src/Core/Exclusiones.ps1.
        $script:Ayudantes | Should -Match 'ExclusionVista' -Because 'si no, se leyo mal el archivo'
        foreach ($texto in @($script:Ayudantes, $script:Eventos, $script:Ventana, $script:Tipos)) {
            $texto | Should -Not -Match 'modulo:'
        }
    }

    It 'la lista se rellena en UN solo sitio' {
        @([regex]::Matches($script:Ayudantes, '\$c\.ListaExclusiones\.ItemsSource')).Count | Should -Be 1
    }

    It 'la tarjeta se rehace al abrir Ajustes' {
        $script:Eventos | Should -Match '\$c\.NavAjustes\.Add_Checked\(\{\s*& \$refrescarExclusiones'
    }
}

Describe 'quitar una exclusion' {

    It 'el cierre y su manejador estan ahi: si no, esto no mira nada' {
        $script:QuitarExclusion  | Should -Not -BeNullOrEmpty
        $script:QuitarExclusion.Length | Should -BeGreaterThan 300
        $script:ManejadorQuitar  | Should -Not -BeNullOrEmpty
    }

    It 'actualiza la lista de las preferencias Y la de la configuracion' {
        # Solo se sincronizan al refrescar los discos: sin la segunda, el
        # motor seguiría rechazando el elemento en la siguiente limpieza.
        $script:QuitarExclusion | Should -Match '\$estado\.Preferencias\.RutasExcluidas\s*='
        $script:QuitarExclusion | Should -Match '\$estado\.Configuracion\.RutasExcluidas\s*='
    }

    It 'guarda en disco al momento, no al cerrar la ventana' {
        # Igual que al añadir: un cierre anormal no debe resucitar la
        # exclusión.
        $script:QuitarExclusion | Should -Match '& \$guardarPreferencias'
    }

    It 'vuelve a pintar la tarjeta' {
        $script:QuitarExclusion | Should -Match '& \$refrescarExclusiones'
    }

    It 'compara la clave de forma exacta' {
        # La clave viene del Tag y es la cadena guardada; comparar sin
        # distinguir mayúsculas podría quitar otra entrada.
        $script:QuitarExclusion | Should -Match 'StringComparison\]::Ordinal'
        $script:QuitarExclusion | Should -Not -Match 'OrdinalIgnoreCase'
    }

    It 'NO pregunta' {
        # Quitar no destruye nada: el elemento vuelve a proponerse y siguen
        # mediando la casilla, el diálogo de confirmación y la guardia. Una
        # confirmación constante se aprende a ignorar.
        $script:QuitarExclusion | Should -Not -Match 'MessageBox'
        $script:QuitarExclusion | Should -Not -Match 'YesNo'
    }

    It 'y añadir SI pregunta' {
        # Añadir promete "nunca más" y lo excluido deja de verse: un error
        # sería invisible.
        $script:Excluir | Should -Not -BeNullOrEmpty
        $script:Excluir | Should -Match "'YesNo'"
        $script:Excluir | Should -Match "-ne 'Yes'\) \{ return \}"
    }

    It 'el boton se reconoce por su nombre, no por su rotulo' {
        # Depender del Content ataría el comportamiento al rótulo.
        $script:ManejadorQuitar | Should -Match "\`$boton\.Name -ne 'BtnQuitarExclusion'"
        $script:ManejadorQuitar | Should -Not -Match '\$boton\.Content'
    }

    It 'el manejador pasa el Tag, que es la clave' {
        $script:ManejadorQuitar | Should -Match '& \$quitarExclusion \(\[string\]\$boton\.Tag\)'
    }

    It 'el dialogo de excluir ya no promete que solo se deshace a mano' {
        # La exclusión ya se puede quitar desde Ajustes.
        $script:Excluir | Should -Not -Match 'preferencias\.json'
        $script:Excluir | Should -Match 'Lo que no se toca nunca'
    }

    It 'restablecer los ajustes no se lleva por delante las exclusiones' {
        # La tarjeta está junto a ese botón: se comprueba que no la toca y
        # que lo dice.
        $restablecer = [regex]::Match($script:Eventos,
            '(?s)\$c\.BtnRestablecer\.Add_Click\(\{.*?\n    \}\)').Value
        $restablecer | Should -Not -BeNullOrEmpty
        $restablecer | Should -Not -Match 'RutasExcluidas'
        $restablecer | Should -Match 'lo que hayas excluido no se tocan'
    }
}
