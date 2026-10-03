<#
    Pruebas de lo que muestra el diálogo de confirmación antes de borrar.

    El diálogo es una ventana WPF que no arranca aquí, pero la decisión de
    qué se muestra vive en Get-LineasConfirmacion (texto de entrada y de
    salida) precisamente para poder probarla.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Dialogs.ps1')

    # Se evita el verbo "New-", que el analizador obliga a acompañar de
    # ShouldProcess: aquí solo se compone un objeto de prueba.
    function Get-Falso {
        param([string] $Nombre, [double] $Bytes, [string] $Comando = '',
              [string] $Aviso = '', [string] $Riesgo = 'Medio')
        [pscustomobject]@{
            Nombre = $Nombre; Bytes = $Bytes; Tamano = ('{0} B' -f $Bytes)
            Comando = $Comando; Aviso = $Aviso; Riesgo = $Riesgo
        }
    }
}

Describe 'Get-LineasConfirmacion: ningun comando externo puede quedarse sin ver' {

    It 'un comando se enseña aunque sea el elemento MÁS PEQUEÑO de todos' {
        <#
            Elegir solo los más grandes dejaría fuera un comando externo
            pequeño (p. ej. "docker system prune -a -f") y el usuario
            confirmaría algo que no ha visto. SECURITY.md lo exige.
        #>
        $lote = @(1..40 | ForEach-Object { Get-Falso -Nombre "grande$_" -Bytes (1GB * $_) })
        $lote += Get-Falso -Nombre 'docker' -Bytes 1 -Comando 'docker system prune -a -f'

        $lineas = @(Get-LineasConfirmacion -Arriesgados $lote)
        ($lineas -join "`n") | Should -BeLike '*docker system prune -a -f*'
    }

    It 'los que llevan comando van los PRIMEROS' {
        # Al final de una lista larga quedarían fuera de la parte visible
        # del desplazamiento.
        $lote = @(1..30 | ForEach-Object { Get-Falso -Nombre "x$_" -Bytes (1GB * $_) })
        $lote += Get-Falso -Nombre 'dism' -Bytes 5 -Comando 'dism /online /cleanup-image'

        $lineas = @(Get-LineasConfirmacion -Arriesgados $lote)
        $lineas[0] | Should -BeLike '*dism*'
    }

    It 'TODOS los comandos, no solo el primero' {
        $lote = @(
            Get-Falso -Nombre 'a' -Bytes 1 -Comando 'comando-uno'
            Get-Falso -Nombre 'b' -Bytes 2 -Comando 'comando-dos'
            Get-Falso -Nombre 'c' -Bytes 3 -Comando 'comando-tres'
        )
        $texto = (Get-LineasConfirmacion -Arriesgados $lote) -join "`n"
        foreach ($c in @('comando-uno', 'comando-dos', 'comando-tres')) {
            $texto | Should -BeLike "*$c*"
        }
    }

    It 'el comando aparece completo, sin recortar' {
        $largo = 'docker system prune -a -f --volumes --filter until=24h'
        $lote = @(Get-Falso -Nombre 'd' -Bytes 1 -Comando $largo)
        (Get-LineasConfirmacion -Arriesgados $lote) -join "`n" | Should -BeLike "*$largo*"
    }
}

Describe 'Get-LineasConfirmacion: no se calla lo que no cabe' {

    It 'dice cuantos quedan fuera' {
        # Listar unos pocos sin mencionar el resto parece la lista entera.
        $lote = @(1..40 | ForEach-Object { Get-Falso -Nombre "x$_" -Bytes $_ })
        $lineas = @(Get-LineasConfirmacion -Arriesgados $lote -Maximo 25)

        $lineas[-1] | Should -BeLike '*15*'
        $lineas[-1] | Should -BeLike '*más que no caben*'
    }

    It 'con pocos elementos no añade el aviso de sobrantes' {
        $lote = @(1..3 | ForEach-Object { Get-Falso -Nombre "x$_" -Bytes $_ })
        $lineas = @(Get-LineasConfirmacion -Arriesgados $lote)
        $lineas.Count | Should -Be 3
        ($lineas -join "`n") | Should -Not -BeLike '*no caben*'
    }

    It 'los comandos NO cuentan para el tope' {
        # Si contaran, un lote con treinta comandos dejaría fuera a la
        # mitad, que es lo que la regla prohíbe.
        $lote = @(1..30 | ForEach-Object { Get-Falso -Nombre "c$_" -Bytes $_ -Comando "cmd$_" })
        $lineas = @(Get-LineasConfirmacion -Arriesgados $lote -Maximo 25)
        $lineas.Count | Should -Be 30
    }

    It 'los que se enseñan son los mas grandes' {
        $lote = @(1..10 | ForEach-Object { Get-Falso -Nombre "x$_" -Bytes (1MB * $_) })
        $lineas = @(Get-LineasConfirmacion -Arriesgados $lote -Maximo 3)
        $lineas[0] | Should -BeLike '*x10*'
        $lineas[1] | Should -BeLike '*x9*'
        $lineas[2] | Should -BeLike '*x8*'
    }
}

Describe 'Get-LineasConfirmacion: casos de borde' {

    It 'una lista vacia no revienta' {
        { Get-LineasConfirmacion -Arriesgados @() } | Should -Not -Throw
        @(Get-LineasConfirmacion -Arriesgados @()).Count | Should -Be 0
    }

    It 'usa el aviso cuando lo hay, y el riesgo cuando no' {
        $conAviso = @(Get-Falso -Nombre 'a' -Bytes 1 -Aviso 'contiene una carpeta projects')
        (Get-LineasConfirmacion -Arriesgados $conAviso) -join '' | Should -BeLike '*projects*'

        $sinAviso = @(Get-Falso -Nombre 'b' -Bytes 1 -Riesgo 'Alto')
        (Get-LineasConfirmacion -Arriesgados $sinAviso) -join '' | Should -BeLike '*riesgo alto*'
    }
}

Describe 'la plantilla del dialogo no puede volver a recortar' {

    BeforeAll {
        # Sin los comentarios XML: una prueba que lee archivos como texto
        # solo debe mirar el código, no los comentarios que lo explican.
        $script:Xaml = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/ConfirmDialog.xaml')),
            '(?s)<!--.*?-->', '')
    }

    It 'la prueba encuentra marcado: si no, no comprueba nada' {
        $script:Xaml | Should -Match 'ListaRiesgo'
    }

    It 'la lista ajusta lineas en vez de recortarlas' {
        $script:Xaml | Should -Not -Match 'TextTrimming'
        $script:Xaml | Should -Match 'TextWrapping="Wrap"'
    }

    It 'la lista se desplaza y tiene altura maxima' {
        # Sin tope, el diálogo (que crece con su contenido) dejaría los
        # botones fuera de la pantalla.
        $script:Xaml | Should -Match 'ScrollViewer'
        $script:Xaml | Should -Match 'MaxHeight="\d+"'
    }
}
