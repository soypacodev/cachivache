<#
    Pruebas de ItemVista: un fallo de borrado no puede pintarse en verde ni
    quedar invisible.

    No se prueba XAML (no arranca en las pruebas), sino las propiedades de
    las que depende lo que se ve. Por eso la lógica está en la clase y no
    en un Trigger de XAML: una propiedad se puede comprobar.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Types.ps1')
    Initialize-TiposInterfaz
}

Describe 'el estado de una fila dice la verdad' {

    It 'antes de borrar no hay nada que enseñar' {
        $item = [Cachivache.ItemVista]::new()
        $item.VisibilidadEstado | Should -Be 'Collapsed'
        $item.EstadoEsFallo     | Should -BeFalse
    }

    It 'un borrado correcto se ve, y NO como fallo' {
        $item = [Cachivache.ItemVista]::new()
        $item.Hecho  = $true
        $item.Estado = 'Eliminado'

        $item.VisibilidadEstado | Should -Be 'Visible'
        $item.EstadoEsFallo     | Should -BeFalse -Because 'se borro: va en verde'
    }

    It 'un FALLO se ve' {
        # Si la visibilidad dependiera de Hecho, un elemento no borrado
        # quedaría sin ningún estado visible.
        $item = [Cachivache.ItemVista]::new()
        $item.Hecho  = $false
        $item.Estado = 'Excluido por ti: C:\Proyectos'

        $item.VisibilidadEstado | Should -Be 'Visible'
        $item.EstadoEsFallo     | Should -BeTrue -Because 'no se borro: va en rojo'
    }

    It 'las dos propiedades se recalculan al cambiar Estado' {
        # WPF no detecta que una propiedad derivada ha cambiado: sin el
        # aviso, la fila conservaría el color y la visibilidad anteriores.
        $item = [Cachivache.ItemVista]::new()
        $item.VisibilidadEstado | Should -Be 'Collapsed'
        $item.Estado = 'No se ha podido borrar'
        $item.VisibilidadEstado | Should -Be 'Visible'
        $item.EstadoEsFallo     | Should -BeTrue
    }

    It 'y al cambiar Hecho' {
        $item = [Cachivache.ItemVista]::new()
        $item.Estado = 'Eliminado'
        $item.EstadoEsFallo | Should -BeTrue -Because 'todavia no consta como hecho'
        $item.Hecho = $true
        $item.EstadoEsFallo | Should -BeFalse
    }

    It 'avisa por PropertyChanged de las derivadas, no solo de la que se toca' {
        # Sin esto la clase sería correcta, pero la ventana no repintaría.
        $item = [Cachivache.ItemVista]::new()
        $avisadas = [Collections.Generic.List[string]]::new()
        $item.add_PropertyChanged({ param($o, $e) $avisadas.Add($e.PropertyName) })

        $item.Estado = 'algo'
        $avisadas | Should -Contain 'Estado'
        $avisadas | Should -Contain 'VisibilidadEstado'
        $avisadas | Should -Contain 'EstadoEsFallo'

        $avisadas.Clear()
        $item.Hecho = $true
        $avisadas | Should -Contain 'Hecho'
        $avisadas | Should -Contain 'EstadoEsFallo'
    }
}

Describe 'la vista no puede volver a esconder los fallos' {

    BeforeAll {
        $script:Xaml = Get-Content -Raw -LiteralPath (
            Join-Path $script:Raiz 'src/UI/Panel.Resultados.xaml')
        $script:Cierre = (Get-Content -LiteralPath (
            Join-Path $script:Raiz 'src/UI/Window.Eliminacion.ps1') |
            Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'la visibilidad del estado NO depende de Hecho' {
        $script:Xaml | Should -Match 'Visibility="\{Binding VisibilidadEstado\}"'
    }

    It 'el color deja de ser verde fijo' {
        $script:Xaml | Should -Match 'DataTrigger Binding="\{Binding EstadoEsFallo\}" Value="True"'
        $script:Xaml | Should -Match 'Value="\{DynamicResource Peligro\}"'
    }

    It 'solo se desmarca lo que SE BORRO' {
        # Desmarcarlo todo haría desaparecer de la selección lo no borrado.
        $script:Cierre | Should -Match 'if \(\$item\.Origen\.Hecho\) \{ \$item\.Seleccionado = \$false \}'
    }

    It 'una fila fallida no se atenua como las hechas' {
        # La opacidad reducida indica "resuelto"; un fallo debe destacar.
        $script:Xaml | Should -Match '(?s)DataTrigger Binding="\{Binding Hecho\}" Value="True">\s*<Setter Property="Opacity"'
    }
}

Describe 'el texto completo de la columna que sostiene la decision' {

    It 'junta los cuatro textos en el orden en que se leen' {
        $item = [Cachivache.ItemVista]::new()
        $item.Aviso   = 'contiene una carpeta projects'
        $item.Efecto  = 'No coincide con ningun programa instalado.'
        $item.Comando = 'docker system prune -a -f'
        $item.Estado  = 'No se ha podido borrar'

        $t = $item.TextoCompleto
        $t | Should -BeLike '*projects*'
        $t | Should -BeLike '*No coincide*'
        $t | Should -BeLike '*docker system prune -a -f*'
        $t | Should -BeLike '*No se ha podido borrar*'
        $t.IndexOf('projects')  | Should -BeLessThan $t.IndexOf('No coincide')
    }

    It 'omite lo que no hay, sin dejar huecos ni separadores sueltos' {
        $item = [Cachivache.ItemVista]::new()
        $item.Efecto = 'Solo esto.'
        $item.TextoCompleto | Should -Be 'Solo esto.'
    }

    It 'un elemento sin nada devuelve cadena vacia, no un salto de linea' {
        [Cachivache.ItemVista]::new().TextoCompleto | Should -Be ''
    }

    It 'el comando entra COMPLETO: es lo que SECURITY.md exige enseñar' {
        $largo = 'dism /online /cleanup-image /startcomponentcleanup /resetbase'
        $item = [Cachivache.ItemVista]::new()
        $item.Comando = $largo
        $item.TextoCompleto | Should -BeLike "*$largo*"
    }

    It 'se recalcula al cambiar Estado' {
        $item = [Cachivache.ItemVista]::new()
        $avisadas = [Collections.Generic.List[string]]::new()
        $item.add_PropertyChanged({ param($o, $e) $avisadas.Add($e.PropertyName) })
        $item.Estado = 'algo'
        $avisadas | Should -Contain 'TextoCompleto'
    }
}

Describe 'la altura de fila deja de recortar' {

    It 'el estilo usa altura MINIMA, no exacta' {
        # RowHeight fija una altura exacta y recorta el contenido sin
        # avisar.
        $estilos = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Styles.xaml')),
            '(?s)<!--.*?-->', '')
        $estilos | Should -Match 'Property="MinRowHeight"'
        $estilos | Should -Not -Match 'Property="RowHeight"'
    }

    It 'la celda lleva el texto completo en la ayuda emergente' {
        $xaml = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Panel.Resultados.xaml')),
            '(?s)<!--.*?-->', '')
        $xaml | Should -Match 'Binding TextoCompleto'
    }
}

Describe 'ordenar la tabla produce un orden con sentido' {

    <#
        Una DataGridTemplateColumn no indica a WPF por qué campo ordenar, y
        declarar el campo sin criterio produce órdenes absurdos que parecen
        funcionar.
    #>

    It 'el riesgo se ordena por gravedad, no por alfabeto' {
        # Por la cadena saldría Alto, Bajo, Medio: orden alfabético sin
        # significado.
        $alto  = [Cachivache.ItemVista]::new(); $alto.Riesgo  = 'Alto'
        $medio = [Cachivache.ItemVista]::new(); $medio.Riesgo = 'Medio'
        $bajo  = [Cachivache.ItemVista]::new(); $bajo.Riesgo  = 'Bajo'

        $alto.OrdenRiesgo  | Should -BeLessThan $medio.OrdenRiesgo
        $medio.OrdenRiesgo | Should -BeLessThan $bajo.OrdenRiesgo
    }

    It 'un riesgo desconocido va al final, no al principio' {
        # Arriba, un valor raro encabezaría la lista sin merecerlo.
        $raro = [Cachivache.ItemVista]::new(); $raro.Riesgo = 'Loquesea'
        $alto = [Cachivache.ItemVista]::new(); $alto.Riesgo = 'Alto'
        $raro.OrdenRiesgo | Should -BeGreaterThan $alto.OrdenRiesgo
    }

    It 'ordenados de verdad, salen en el orden que espera el usuario' {
        $filas = @('Bajo', 'Alto', 'Medio', 'Bajo') | ForEach-Object {
            $i = [Cachivache.ItemVista]::new(); $i.Riesgo = $_; $i
        }
        $orden = @($filas | Sort-Object OrdenRiesgo | ForEach-Object { $_.Riesgo })
        $orden[0] | Should -Be 'Alto'
        $orden[1] | Should -Be 'Medio'
    }

    It 'el tamano se ordena por Bytes, no por el texto formateado' {
        # "9,52 GB" es alfabéticamente menor que "980 MB".
        $gb = [Cachivache.ItemVista]::new(); $gb.Bytes = 9.52GB; $gb.Tamano = '9,52 GB'
        $mb = [Cachivache.ItemVista]::new(); $mb.Bytes = 980MB;  $mb.Tamano = '980,0 MB'

        # Orden incorrecto:
        @(@($gb, $mb) | Sort-Object Tamano -Descending)[0].Tamano | Should -Be '980,0 MB'
        # Orden de la tabla:
        @(@($gb, $mb) | Sort-Object Bytes  -Descending)[0].Tamano | Should -Be '9,52 GB'
    }
}

Describe 'las cinco columnas declaran por que ordenan' {

    BeforeAll {
        $script:XamlOrden = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Panel.Resultados.xaml')),
            '(?s)<!--.*?-->', '')
    }

    It 'ninguna columna se queda sin SortMemberPath' {
        # Una cabecera que parece pulsable y no hace nada es peor que una
        # que no lo parece. El espacio tras el nombre es imprescindible:
        # sin él, el patrón captura también <DataGridTemplateColumn.CellTemplate>.
        $columnas = @([regex]::Matches($script:XamlOrden, '<DataGridTemplateColumn\s[^>]*>'))
        $columnas.Count | Should -Be 5 -Because 'si no son cinco, la prueba mira otra cosa'

        $sinOrden = @($columnas | Where-Object { $_.Value -notmatch 'SortMemberPath' })
        $sinOrden | Should -BeNullOrEmpty
    }

    It 'el tamano ordena por Bytes y el riesgo por OrdenRiesgo' {
        # Con eñe: es texto que lee el usuario.
        $script:XamlOrden | Should -Match 'Header="TAMAÑO"[^>]*SortMemberPath="Bytes"'
        $script:XamlOrden | Should -Match 'Header="RIESGO"[^>]*SortMemberPath="OrdenRiesgo"'
    }

    It 'la lista sale ordenada de mayor a menor al terminar el analisis' {
        $analisis = (Get-Content -LiteralPath (Join-Path $script:Raiz 'src/UI/Window.Analisis.ps1') |
                     Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $analisis | Should -Match "SortDescription 'Bytes'"
        $analisis | Should -Match 'ListSortDirection\]::Descending'
    }
}

Describe 'plegar grupos y marcar categorias enteras' {

    BeforeAll {
        $script:XamlG = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Panel.Resultados.xaml')),
            '(?s)<!--.*?-->', '')
        $script:RutaEventosG = Join-Path $script:Raiz 'src/UI/Window.Eventos.ps1'
        $script:EventosG = [regex]::Replace(
            ((Get-Content -LiteralPath (Join-Path $script:Raiz 'src/UI/Window.Eventos.ps1') |
              Where-Object { $_ -notmatch '^\s*#' }) -join "`n"), '(?s)<#.*?#>', '')
        $script:EstilosG = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Styles.xaml')),
            '(?s)<!--.*?-->', '')
    }

    It 'la cabecera de grupo se puede plegar' {
        $script:XamlG | Should -Match 'ToggleButton x:Name="BtnPlegarGrupo"'
        $script:XamlG | Should -Match 'ElementName=BtnPlegarGrupo'
    }

    It 'los grupos nacen desplegados' {
        # Plegados esconderían los resultados recién encontrados.
        $script:XamlG | Should -Match 'BtnPlegarGrupo"[\s\S]{0,120}IsChecked="True"'
    }

    It 'el conversor que usa el plegado esta declarado' {
        # Un StaticResource inexistente no falla al escribirlo, sino al
        # abrir la ventana.
        $script:EstilosG | Should -Match '<BooleanToVisibilityConverter x:Key="BoolAVisible"/>'
    }

    It 'el ItemsPresenter sigue colgando directamente del Grid' {
        # La virtualización depende de esa estructura: un Expander u otro
        # contenedor intermedio da altura infinita a las filas y deja de
        # virtualizar, inviable con miles de elementos.
        $script:XamlG | Should -Match '<ItemsPresenter Grid.Row="1"'
        $script:XamlG | Should -Not -Match '<Expander'
    }

    It 'los dos botones de grupo llevan la categoria en Tag' {
        # Se extrae el elemento entero en vez de limitar a N caracteres:
        # un tope fijo haría fallar la prueba por el tamaño de un
        # comentario.
        foreach ($nombre in @('BtnMarcarGrupo', 'BtnQuitarGrupo')) {
            $i = $script:XamlG.IndexOf('<Button x:Name="' + $nombre + '"')
            $i | Should -BeGreaterThan -1 -Because "tiene que existir $nombre"

            $fin = $script:XamlG.IndexOf('/>', $i)
            $fin | Should -BeGreaterThan $i
            $elemento = $script:XamlG.Substring($i, $fin - $i)

            $elemento | Should -BeLike '*Tag="{Binding Name}"*' -Because (
                "$nombre necesita la categoria para saber a quien marcar")
        }
    }

    It 'el manejador distingue por NOMBRE, no por el texto del boton' {
        # Depender del Content ataría el comportamiento al rótulo.
        $script:EventosG | Should -Match "\`$boton\.Name -eq 'BtnMarcarGrupo'"
        $script:EventosG | Should -Not -Match "\`$boton\.Content -eq"
    }

    It 'el evento se engancha en la TABLA, no en cada boton' {
        # Las cabeceras se crean y destruyen con el desplazamiento: no hay
        # un botón estable al que engancharse.
        $script:EventosG | Should -Match 'TablaResultados\.AddHandler'
        $script:EventosG | Should -Match 'ButtonBase\]::ClickEvent'
    }

    It 'marcar respeta lo que no se puede borrar' {
        # Un elemento informativo no se marca ni en bloque.
        $script:EventosG | Should -Match '\$marcar -and -not \$item\.Borrable'
    }

    It 'el marcado en bloque suprime el recalculo del resumen' {
        # Sin esto, marcar doscientas filas dispara doscientos recálculos y
        # la ventana deja de responder.
        #
        # Se mira dentro de $marcarCategoria, extraído por AST. Contar
        # caracteres desde el AddHandler solo comprobaría proximidad y
        # obligaría a un orden concreto en el código.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                   $script:RutaEventosG, [ref]$null, [ref]$null)

        $cierre = @($ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                      $n.Left.Extent.Text -eq '$marcarCategoria'
        }, $true))

        $cierre.Count | Should -Be 1 -Because 'si no, la prueba no esta mirando el cierre que cree'
        $trozo = $cierre[0].Right.Extent.Text

        $trozo | Should -Match '\$estado\.SuprimirResumen = \$true'
        $trozo | Should -Match '\$estado\.SuprimirResumen = \$false'
        $trozo | Should -Match 'actualizarResumenSeleccion'
    }

    It 'y el manejador de la tabla delega en ese cierre, no repite lo que hace' {
        # Sin esto, el manejador podría marcar por su cuenta y saltarse la
        # supresión.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                   $script:RutaEventosG, [ref]$null, [ref]$null)

        $llamada = @($ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                      $n.Member.Extent.Text -eq 'AddHandler' -and
                      $n.Expression.Extent.Text -like '*TablaResultados*'
        }, $true))

        $llamada.Count | Should -Be 1
        $llamada[0].Extent.Text | Should -Match 'marcarCategoria'
    }
}
