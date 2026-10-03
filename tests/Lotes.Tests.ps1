<#
    Marcado en lote de miles de filas sin bloquear la ventana.

    Sin WPF no se puede medir si la ventana responde, pero sí el reparto:
    los trozos deben cubrir exactamente las filas. Trocear es la forma
    clásica de perder la última fila.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Lotes.ps1')
}

Describe 'Get-PlanMarcadoEnLote: cuando trocear y cuando no' {

    It 'por debajo del umbral NO se trocea' {
        foreach ($n in @(1, 10, 119, 500, 1999, 2000)) {
            $p = Get-PlanMarcadoEnLote -Total $n
            $p.PorTrozos | Should -BeFalse -Because "con $n filas trocear solo añade lentitud y parpadeo"
            $p.Trozos    | Should -Be 1
            $p.Tamano    | Should -Be $n
        }
    }

    It 'justo por encima del umbral SI se trocea' {
        $p = Get-PlanMarcadoEnLote -Total 2001
        $p.PorTrozos | Should -BeTrue
        $p.Trozos    | Should -BeGreaterThan 1
    }

    It '5.000 filas se trocean' {
        $p = Get-PlanMarcadoEnLote -Total 5000
        $p.PorTrozos | Should -BeTrue
        $p.Total     | Should -Be 5000
        $p.Trozos    | Should -Be 10
    }

    It 'sin filas no hay nada que hacer, y se dice sin lanzar' {
        foreach ($nada in @(0, -1, -5000, $null, 'no soy un numero', @())) {
            { Get-PlanMarcadoEnLote -Total $nada } | Should -Not -Throw
            $p = Get-PlanMarcadoEnLote -Total $nada
            $p.Total     | Should -Be 0
            $p.PorTrozos | Should -BeFalse
            $p.Trozos    | Should -Be 0
        }
    }

    It 'un umbral o un tamaño imposibles NO dejan el plan en cero trozos' {
        # Un tamaño de cero sería un bucle infinito en la ventana, y un
        # umbral de cero trocearía hasta una sola fila.
        foreach ($t in @(0, -1, -500)) {
            $p = Get-PlanMarcadoEnLote -Total 5000 -Tamano $t
            $p.Tamano | Should -BeGreaterThan 0
            $p.Trozos | Should -BeGreaterThan 0
        }
        foreach ($u in @(0, -1)) {
            $p = Get-PlanMarcadoEnLote -Total 100 -Umbral $u
            $p.Trozos | Should -BeGreaterThan 0
        }
    }

    It 'el numero de trozos redondea HACIA ARRIBA: 5.001 filas no caben en diez trozos de 500' {
        (Get-PlanMarcadoEnLote -Total 5001).Trozos | Should -Be 11
        (Get-PlanMarcadoEnLote -Total 2500).Trozos | Should -Be 5
        (Get-PlanMarcadoEnLote -Total 2501).Trozos | Should -Be 6
    }
}

Describe 'LA INVARIANTE: los trozos cubren exactamente las filas' {

    It 'ni una fila de menos ni una de mas, se trocee o no' {
        # Tamaños alrededor de todos los bordes: el umbral, los múltiplos
        # exactos del trozo y los que sobran por uno.
        $casos = @(0, 1, 2, 499, 500, 501, 1999, 2000, 2001, 2499, 2500, 2501,
                   4999, 5000, 5001, 9999, 10000, 123456)
        foreach ($n in $casos) {
            $plan   = Get-PlanMarcadoEnLote -Total $n
            $tramos = @(Get-RangosDeLote -Plan $plan)

            $suma = 0
            foreach ($t in $tramos) { $suma += [int]$t.Cuantas }
            $suma | Should -Be $n -Because "con $n filas los trozos tienen que sumar $n"

            if ($n -gt 0) {
                @($tramos).Count | Should -Be $plan.Trozos -Because "el plan dice $($plan.Trozos) trozos"
                # Sin huecos ni solapes: cada tramo empieza donde acaba el
                # anterior (un hueco y un solape podrían compensarse en la
                # suma).
                $esperado = 0
                foreach ($t in $tramos) {
                    [int]$t.Desde | Should -Be $esperado
                    $esperado += [int]$t.Cuantas
                }
                $esperado | Should -Be $n
            }
        }
    }

    It 'recorriendo los tramos se toca CADA fila una sola vez' {
        # Se simula el recorrido de la ventana y se cuenta cuántas veces se
        # toca cada posición.
        $n = 5001
        $tocadas = [int[]]::new($n)
        $plan = Get-PlanMarcadoEnLote -Total $n
        foreach ($t in @(Get-RangosDeLote -Plan $plan)) {
            for ($i = 0; $i -lt $t.Cuantas; $i++) { $tocadas[$t.Desde + $i]++ }
        }
        @($tocadas | Where-Object { $_ -ne 1 }).Count | Should -Be 0 -Because (
            'una fila sin tocar es una fila que el usuario cree marcada y no lo esta')
    }

    It 'con un plan nulo o vacio no hay tramos, y no lanza' {
        { Get-RangosDeLote -Plan $null } | Should -Not -Throw
        @(Get-RangosDeLote -Plan $null).Count | Should -Be 0
        @(Get-RangosDeLote -Plan (Get-PlanMarcadoEnLote -Total 0)).Count | Should -Be 0
    }
}

Describe 'la ventana trocea, y se protege mientras lo hace' {

    BeforeAll {
        $script:Eventos = [IO.File]::ReadAllText(
            (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Window.Eventos.ps1'))
        $script:Codigo = ($script:Eventos -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $script:Lote = [regex]::Match($script:Codigo, '(?s)\$marcarEnLote = \{.*?\n    \}').Value
    }

    It 'la prueba encuentra el cierre: si no, no comprueba nada' {
        $script:Lote | Should -Not -BeNullOrEmpty
        $script:Lote.Length | Should -BeGreaterThan 300
    }

    It 'el reparto lo decide la funcion pura, no un numero escrito en la ventana' {
        $script:Lote | Should -Match 'Get-PlanMarcadoEnLote'
        $script:Lote | Should -Match 'Get-RangosDeLote'
        # Sin umbrales sueltos: un número en dos sitios acaba discrepando.
        $script:Lote | Should -Not -Match '\b2000\b'
        $script:Lote | Should -Not -Match '\b500\b'
    }

    It 'deja respirar a la ventana entre trozos' {
        $script:Lote | Should -Match 'Dispatcher'
        $script:Lote | Should -Match 'Background'
    }

    It 'Y APAGA los botones que pueden hacer daño mientras dura' {
        # Una ventana que responde acepta clics, y "Eliminar lo marcado"
        # no debe usarse con la mitad de las filas marcadas.
        $script:Lote | Should -Match 'BtnEliminar'
        $script:Lote | Should -Match 'IsEnabled\s*=\s*\$false'
    }

    It 'y los vuelve a encender pase lo que pase' {
        # Un finally: si el criterio lanza a mitad, los botones no deben
        # quedarse apagados.
        $script:Lote | Should -Match 'finally'
        ([regex]::Matches($script:Lote, 'finally')).Count | Should -BeGreaterOrEqual 2
    }

    It 'sigue recorriendo la VISTA y no la coleccion entera' {
        # Con un filtro puesto, recorrer Items marcaría también lo que el
        # usuario no ve.
        $script:Lote | Should -Match '\$estado\.Vista'
        $script:Lote | Should -Not -Match '\$estado\.Items'
    }

    It 'y sigue suprimiendo el recalculo del resumen mientras marca' {
        $script:Lote | Should -Match 'SuprimirResumen\s*=\s*\$true'
        $script:Lote | Should -Match 'SuprimirResumen\s*=\s*\$false'
    }
}

Describe 'Lotes.ps1 no toca WPF' {

    BeforeAll {
        function script:Get-CodigoSinComentariosLotes {
            param([string] $Ruta)
            $t = [IO.File]::ReadAllText($Ruta)
            # Primero los bloques <# #> y después las líneas '#': al revés,
            # el primer paso se lleva la línea del "#>" y el bloque queda
            # abierto.
            $t = [regex]::Replace($t, '(?s)<#.*?#>', '')
            return (@($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        }
        $script:CarpetaUiLotes = Join-Path (Join-Path $script:Raiz 'src') 'UI'
    }

    It 'no menciona ni un tipo de System.Windows' {
        # Es lo que permite ejecutar lo anterior sin interfaz gráfica. Se
        # mira el código y no los comentarios, que mencionan
        # System.Windows.
        $texto = script:Get-CodigoSinComentariosLotes (Join-Path $script:CarpetaUiLotes 'Lotes.ps1')
        $texto | Should -Not -Match 'System\.Windows'
        $texto | Should -Not -Match '\[Windows\.'
    }

    It 'la prueba de arriba mira codigo de verdad: si no, no comprueba nada' {
        $texto = script:Get-CodigoSinComentariosLotes (Join-Path $script:CarpetaUiLotes 'Lotes.ps1')
        $texto | Should -Match 'function Get-PlanMarcadoEnLote'
        $texto | Should -Match 'function Get-RangosDeLote'
    }

    It 'la ventana lo carga' {
        $ventana = script:Get-CodigoSinComentariosLotes (Join-Path $script:CarpetaUiLotes 'Window.ps1')
        $ventana | Should -Match "Lotes\.ps1"
    }
}
