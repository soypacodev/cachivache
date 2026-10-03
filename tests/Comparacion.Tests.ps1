<#
    Pruebas de la comparación con el análisis anterior.

    La mayoría comprueban lo que no se puede afirmar: comparar un análisis
    con una limpieza, dar por buena la cifra de un análisis cancelado o
    restar números de perfiles distintos. Las tres producirían "antes había
    menos" y las tres serían falsas.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
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

    $script:RutaComparacion = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Comparacion.ps1'
    $script:Codigo = script:Get-CodigoSinComentarios $script:RutaComparacion

    # Entrada de historial como la que escribe Add-EntradaHistorial. Las
    # fechas llevan una hora de margen: con un cambio de horario, "hace 4
    # días" puede quedar en 3,96 y truncarse a 3.
    function script:New-EntradaFalsa {
        param(
            [string] $Tipo = 'analisis',
            [double] $DiasAtras = 4,
            [string] $Perfil = 'equilibrado',
            [string[]] $Modulos = @('caches', 'temporales'),
            [int] $Elementos = 890,
            [double] $Bytes = 3435973836.8,
            [bool] $Incompleto = $false
        )
        [pscustomobject]@{
            Fecha        = (Get-Date).AddDays(-$DiasAtras).AddHours(-1).ToString('o')
            Tipo         = $Tipo
            Perfil       = $Perfil
            Modulos      = @($Modulos)
            Elementos    = $Elementos
            Bytes        = $Bytes
            LibreAntes   = 0
            LibreDespues = 0
            Informe      = ''
            Incompleto   = $Incompleto
            Motivo       = ''
        }
    }
}

Describe 'de donde sale "el analisis anterior"' {

    It 'devuelve los ocho campos que la ventana necesita' {
        # Si el objeto cambiara de forma, las pruebas siguientes
        # compararían $null contra $null y pasarían.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa) -Perfil 'equilibrado' `
                                     -Modulos @('caches', 'temporales')
        foreach ($campo in @('HayReferencia', 'Caso', 'Motivos', 'Fecha',
                             'Elementos', 'Bytes', 'Texto', 'Sufijo')) {
            $r.PSObject.Properties.Name | Should -Contain $campo
        }
    }

    It 'una limpieza NO sirve de termino de comparacion' {
        # En una limpieza, Elementos y Bytes son lo borrado y liberado; no
        # son comparables con lo que encuentra un análisis.
        $historial = @(
            script:New-EntradaFalsa -Tipo 'analisis' -DiasAtras 9 -Elementos 890
            script:New-EntradaFalsa -Tipo 'limpieza' -DiasAtras 2 -Elementos 12
        )
        # Comprueba que el historial de prueba trae las dos clases.
        @($historial | Where-Object { $_.Tipo -eq 'limpieza' }).Count | Should -Be 1
        @($historial | Where-Object { $_.Tipo -eq 'analisis' }).Count | Should -Be 1

        $r = Get-ComparacionAnalisis -Historial $historial -Perfil 'equilibrado' `
                                     -Modulos @('caches', 'temporales')
        $r.Elementos | Should -Be 890
        $r.Texto     | Should -Not -BeLike '*12 elementos*'
    }

    It 'un tipo que no se conoce tampoco sirve' {
        # historial.json es texto plano en una carpeta escribible y puede
        # traer cualquier cosa: lo desconocido no se compara.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Tipo 'limpieza-interrumpida') `
                                     -Perfil 'equilibrado' -Modulos @('caches')
        $r.HayReferencia | Should -BeFalse
        $r.Caso          | Should -Be 'sin-referencia'
    }

    It 'se compara con el ULTIMO analisis, no con el ultimo apunte' {
        $historial = @(
            script:New-EntradaFalsa -Tipo 'analisis' -DiasAtras 30 -Elementos 100
            script:New-EntradaFalsa -Tipo 'analisis' -DiasAtras 4  -Elementos 890
            script:New-EntradaFalsa -Tipo 'limpieza' -DiasAtras 1  -Elementos 5
        )
        (Get-ComparacionAnalisis -Historial $historial -Perfil 'equilibrado' `
                                 -Modulos @('caches', 'temporales')).Elementos | Should -Be 890
    }

    It 'sin ningun analisis anterior no se dice nada' {
        # Primer análisis: no hubo una medición de cero, no hubo medición.
        foreach ($h in @(@(), @($null), @(script:New-EntradaFalsa -Tipo 'limpieza'))) {
            $r = Get-ComparacionAnalisis -Historial $h -Perfil 'equilibrado' -Modulos @('caches')
            $r.HayReferencia | Should -BeFalse
            $r.Caso          | Should -Be 'sin-referencia'
            $r.Texto         | Should -BeNullOrEmpty
            $r.Sufijo        | Should -BeNullOrEmpty
            $r.Texto         | Should -Not -Match '0 elementos'
        }
    }

    It 'no revienta con nulos ni con un historial corrupto' {
        { Get-ComparacionAnalisis -Historial $null -Perfil $null -Modulos $null } | Should -Not -Throw
        (Get-ComparacionAnalisis -Historial $null -Perfil $null -Modulos $null).Caso |
            Should -Be 'sin-referencia'

        # Cadenas sueltas, nulos y campos con un array donde se espera un
        # número: lo que puede devolver Get-Historial con un archivo dañado.
        $basura = @(
            'esto no es una entrada'
            $null
            [pscustomobject]@{ Tipo = 'analisis'; Elementos = @(1, 2); Bytes = @('x'); Fecha = @('a') }
        )
        { Get-ComparacionAnalisis -Historial $basura -Perfil 'equilibrado' -Modulos @('caches') } |
            Should -Not -Throw
        (Get-ComparacionAnalisis -Historial $basura -Perfil 'equilibrado' -Modulos @('caches')).Elementos |
            Should -Be 0
    }
}

Describe 'no se compara lo que no es comparable' {

    It 'dos analisis iguales SI son comparables' {
        # Si el caso bueno no saliera comparable, las pruebas siguientes
        # pasarían sin distinguir nada.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa) -Perfil 'equilibrado' `
                                     -Modulos @('caches', 'temporales')
        $r.Caso    | Should -Be 'comparable'
        $r.Motivos | Should -BeNullOrEmpty
    }

    It 'el orden y las mayusculas de los modulos no cuentan' {
        # Es un conjunto, no una lista: el orden no implica un cambio.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Modulos @('Caches', 'Temporales')) `
                                     -Perfil 'equilibrado' -Modulos @('temporales', 'caches')
        $r.Caso | Should -Be 'comparable'
    }

    It 'un analisis incompleto NUNCA se da por comparable' {
        # Un análisis cancelado encontró menos porque miró menos.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Incompleto $true) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Caso    | Should -Be 'no-equiparable'
        $r.Motivos | Should -Contain 'incompleto'
        $r.Texto   | Should -BeLike '*incompleto*'
    }

    It 'un analisis incompleto se sigue enseñando, con su aviso' {
        # Es el único dato disponible: se muestra, indicando que no es
        # del todo comparable.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Incompleto $true -Elementos 890) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.HayReferencia | Should -BeTrue
        $r.Texto         | Should -BeLike '*890 elementos*'
        $r.Texto         | Should -BeLike '*no son cifras equiparables*'
    }

    It 'un incompleto no acusa ademas de haber mirado otros modulos' {
        # Un análisis cancelado anota los módulos revisados, que son menos
        # por estar cancelado: no es un segundo motivo.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Incompleto $true -Modulos @('caches')) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Motivos | Should -Contain 'incompleto'
        $r.Motivos | Should -Not -Contain 'otros-modulos'
    }

    It 'otro perfil no es comparable, y se dice' {
        # Las dos cifras son correctas, pero la resta no significa nada.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Perfil 'agresivo') `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Caso    | Should -Be 'no-equiparable'
        $r.Motivos | Should -Contain 'otro-perfil'
        $r.Texto   | Should -BeLike '*otro perfil*'
    }

    It 'otros modulos no es comparable, y se dice' {
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Modulos @('caches')) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Caso    | Should -Be 'no-equiparable'
        $r.Motivos | Should -Contain 'otros-modulos'
        $r.Texto   | Should -BeLike '*otros módulos*'
    }

    It 'lo que no consta no se da por igual NI se acusa de distinto' {
        # Una entrada sin perfil o módulos anotados no indica que fueran
        # otros, sino que no se sabe.
        foreach ($caso in @(
            @{ Perfil = ''; Modulos = @('caches', 'temporales') }
            @{ Perfil = 'equilibrado'; Modulos = @() }
        )) {
            $r = Get-ComparacionAnalisis `
                    -Historial @(script:New-EntradaFalsa -Perfil $caso.Perfil -Modulos $caso.Modulos) `
                    -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
            $r.Caso    | Should -Be 'no-equiparable'
            $r.Motivos | Should -Contain 'no-consta'
            $r.Motivos | Should -Not -Contain 'otro-perfil'
            $r.Motivos | Should -Not -Contain 'otros-modulos'
        }
    }

    It 'no se acusa dos veces de lo mismo' {
        # 'no-consta' cubre los dos casos con un solo motivo y una frase.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Perfil '' -Modulos @()) `
                                     -Perfil 'equilibrado' -Modulos @('caches')
        @($r.Motivos | Where-Object { $_ -eq 'no-consta' }).Count | Should -Be 1
    }

    It 'varios motivos a la vez se dicen todos' {
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Perfil 'agresivo' -Incompleto $true) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Motivos | Should -Contain 'incompleto'
        $r.Motivos | Should -Contain 'otro-perfil'
        $r.Texto   | Should -BeLike '*quedó incompleto y usó otro perfil*'
    }
}

Describe 'cada motivo tiene su frase, y son distintas' {

    It 'los cuatro motivos se dicen de cuatro formas distintas' {
        # Si dos motivos compartieran frase, las pruebas anteriores
        # pasarían mirando la del otro.
        $codigos = @('incompleto', 'otro-perfil', 'otros-modulos', 'no-consta')
        $frases  = @($codigos | ForEach-Object { Get-FraseMotivoComparacion -Motivo $_ })
        @($frases | Select-Object -Unique).Count | Should -Be 4
        foreach ($f in $frases) { $f | Should -Not -BeNullOrEmpty }
    }

    It 'un motivo que no existe no inventa una frase' {
        Get-FraseMotivoComparacion -Motivo 'lo-que-sea' | Should -BeNullOrEmpty
    }

    It 'no revienta con nulos' {
        { Get-FraseMotivoComparacion -Motivo $null } | Should -Not -Throw
    }
}

Describe 'el texto que lee el usuario' {

    BeforeAll {
        $script:Textos = @(
            (Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa) `
                 -Perfil 'equilibrado' -Modulos @('caches', 'temporales')).Texto
            (Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Incompleto $true) `
                 -Perfil 'equilibrado' -Modulos @('caches', 'temporales')).Texto
            (Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Perfil 'agresivo') `
                 -Perfil 'equilibrado' -Modulos @('caches', 'temporales')).Texto
            (Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Modulos @('caches')) `
                 -Perfil 'equilibrado' -Modulos @('caches', 'temporales')).Texto
        )
    }

    It 'hay cuatro textos distintos: si no, esta prueba no compara nada' {
        @($script:Textos | Select-Object -Unique).Count | Should -Be 4
        foreach ($t in $script:Textos) { $t.Length | Should -BeGreaterThan 30 }
    }

    It 'ninguno usa una palabra sin su tilde' {
        $sinTilde = @('analisis', 'dias', 'modulos', 'quedo', 'uso', 'miro', 'anadido')
        $patron = '\b(' + ($sinTilde -join '|') + ')\b'
        foreach ($t in $script:Textos) { $t | Should -Not -CMatch $patron }
    }

    It 'dice cuando fue y cuanto habia' {
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -DiasAtras 4 -Elementos 890) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Texto | Should -BeLike '*hace 4 días*'
        $r.Texto | Should -BeLike '*890 elementos*'
        $r.Texto | Should -BeLike '*GB*'
    }

    It 'concuerda en singular: "era 1 elemento", nunca "eran 1 elementos"' {
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -Elementos 1) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Texto | Should -BeLike '*era 1 elemento *'
        $r.Texto | Should -Not -Match '1 elementos'
        $r.Texto | Should -Not -Match 'eran 1 '
    }

    It 'el Sufijo es el Texto con su espacio delante, y se pega sin un if' {
        # La ventana hace "$resumen += $comparacion.Sufijo" sin condición;
        # el espacio solo aparece cuando hay algo que añadir.
        $r = Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa) `
                                     -Perfil 'equilibrado' -Modulos @('caches', 'temporales')
        $r.Sufijo | Should -Be (' ' + $r.Texto)
        $r.Sufijo.StartsWith(' ') | Should -BeTrue

        $vacia = Get-ComparacionAnalisis -Historial @() -Perfil 'equilibrado' -Modulos @('caches')
        $vacia.Sufijo | Should -Be ''

        # Sin historial el resumen queda igual, sin espacio final.
        $resumen = '812 elementos encontrados.'
        ($resumen + $vacia.Sufijo) | Should -Be $resumen
    }

    It 'el tiempo transcurrido se dice en dias o en horas, segun toque' {
        (Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -DiasAtras 4) `
             -Perfil 'equilibrado' -Modulos @('caches', 'temporales')).Texto |
            Should -BeLike '*hace 4 días*'

        # Format-Antiguedad diría solo "hoy", que delante de una cifra se
        # lee como "ahora mismo".
        (Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -DiasAtras 0.0417) `
             -Perfil 'equilibrado' -Modulos @('caches', 'temporales')).Texto |
            Should -BeLike '*hace 2 h*'

        (Get-ComparacionAnalisis -Historial @(script:New-EntradaFalsa -DiasAtras 1) `
             -Perfil 'equilibrado' -Modulos @('caches', 'temporales')).Texto |
            Should -BeLike '*ayer*'
    }

    It 'una fecha ilegible o del futuro no se convierte en un "hace"' {
        # Reloj desajustado o archivo editado a mano: sin fecha fiable no
        # se dice "hace", pero sí cuánto había.
        $futuro = script:New-EntradaFalsa
        $futuro.Fecha = (Get-Date).AddDays(5).ToString('o')
        $rota = script:New-EntradaFalsa
        $rota.Fecha = 'esto no es una fecha'

        foreach ($entrada in @($futuro, $rota)) {
            $r = Get-ComparacionAnalisis -Historial @($entrada) -Perfil 'equilibrado' `
                                         -Modulos @('caches', 'temporales')
            $r.Texto | Should -BeLike '*el análisis anterior*'
            $r.Texto | Should -Not -Match 'hace '
            $r.Texto | Should -BeLike '*890 elementos*'
        }
    }
}

Describe 'no se escribe un segundo formateador' {

    It 'el archivo tiene codigo: si no, nada de esto comprueba nada' {
        $script:Codigo.Length | Should -BeGreaterThan 2000
    }

    It 'el tiempo lo formatean las funciones que ya estaban en Format.ps1' {
        # Dos formateadores de tiempo acaban discrepando ("ayer" en la
        # tabla, "hace 1 día" en el resumen).
        $script:Codigo | Should -Match 'Format-Antiguedad'
        $script:Codigo | Should -Match 'Format-Duracion'
    }

    It 'no hay aqui ni una unidad de tiempo escrita a mano' {
        # Una unidad escrita aquí indicaría un formateador duplicado.
        foreach ($palabra in @('días', 'meses', 'años', 'semanas')) {
            $script:Codigo | Should -Not -Match $palabra
        }
    }

    It 'el tamaño lo formatea Format-Tamano, no una division a mano' {
        $script:Codigo | Should -Match 'Format-Tamano'
        $script:Codigo | Should -Not -Match '/ 1GB'
    }

    It 'los numeros del historial pasan por ConvertTo-DoubleSeguro' {
        # Un array donde se esperaba un número puede tirar la ventana.
        $script:Codigo | Should -Match 'ConvertTo-DoubleSeguro'
    }
}

Describe 'el nucleo carga el archivo' {

    It 'Bootstrap.ps1 nombra Comparacion.ps1' {
        # Sin esto la función no existe en el hilo de la ventana y el
        # resumen falla en silencio en el catch general.
        $bootstrap = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
        $bootstrap | Should -Match "'Comparacion\.ps1'"
    }
}
