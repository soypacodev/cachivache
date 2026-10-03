<#
    Atajos de teclado.

    Get-AtajoDeTecla es cálculo puro y no toca WPF, así que se puede probar
    combinación por combinación sin interfaz gráfica. Lo único que queda
    sin verificar fuera de Windows es el cableado de eventos.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Atajos.ps1')
}

Describe 'Get-AtajoDeTecla' {

    Context 'Las teclas sueltas' {
        It 'F5 analiza' {
            Get-AtajoDeTecla -Tecla 'F5' | Should -Be 'Analizar'
        }

        It 'Escape cancela' {
            Get-AtajoDeTecla -Tecla 'Escape' | Should -Be 'Cancelar'
        }

        It 'F5 y Escape siguen valiendo escribiendo en un cuadro de texto' {
            # Quien escribe en el filtro también necesita poder parar un
            # análisis sin buscar el ratón.
            Get-AtajoDeTecla -Tecla 'F5'     -EnCuadroDeTexto | Should -Be 'Analizar'
            Get-AtajoDeTecla -Tecla 'Escape' -EnCuadroDeTexto | Should -Be 'Cancelar'
        }

        It 'una letra cualquiera no es atajo' {
            Get-AtajoDeTecla -Tecla 'K' | Should -BeNullOrEmpty
        }

        It 'F5 con Control NO analiza' {
            # El atajo es F5 a secas: Ctrl+F5 tiene otro significado y no
            # debe disparar acciones.
            Get-AtajoDeTecla -Tecla 'F5' -Control | Should -BeNullOrEmpty
        }
    }

    Context 'Con Control' {
        It 'Ctrl+F lleva al filtro' {
            Get-AtajoDeTecla -Tecla 'F' -Control | Should -Be 'Filtrar'
        }

        It 'Ctrl+A marca todo' {
            Get-AtajoDeTecla -Tecla 'A' -Control | Should -Be 'MarcarTodo'
        }

        It 'la F y la A sin Control no son atajo' {
            # Si lo fueran, escribir "familia" en el filtro marcaría la lista
            # entera.
            Get-AtajoDeTecla -Tecla 'F' | Should -BeNullOrEmpty
            Get-AtajoDeTecla -Tecla 'A' | Should -BeNullOrEmpty
        }
    }

    Context 'El unico choque: Ctrl+A dentro de un cuadro de texto' {
        It 'Ctrl+A en un cuadro de texto NO marca todo' {
            # Ahí Ctrl+A ya significa "seleccionar todo el texto"; el registro
            # de la sesión es un cuadro de texto y debe poder copiarse.
            Get-AtajoDeTecla -Tecla 'A' -Control -EnCuadroDeTexto | Should -BeNullOrEmpty
        }

        It 'los demas atajos con Control siguen valiendo en un cuadro de texto' {
            Get-AtajoDeTecla -Tecla 'F'  -Control -EnCuadroDeTexto | Should -Be 'Filtrar'
            Get-AtajoDeTecla -Tecla 'D2' -Control -EnCuadroDeTexto | Should -Be 'NavResultados'
        }
    }

    Context 'Ctrl+1..6, los seis paneles' {
        It 'Ctrl+<Tecla> lleva a <Esperado>' -ForEach @(
            @{ Tecla = 'D1'; Esperado = 'NavInicio' }
            @{ Tecla = 'D2'; Esperado = 'NavResultados' }
            @{ Tecla = 'D3'; Esperado = 'NavRegistro' }
            @{ Tecla = 'D4'; Esperado = 'NavInformes' }
            @{ Tecla = 'D5'; Esperado = 'NavAjustes' }
            @{ Tecla = 'D6'; Esperado = 'NavAcerca' }
        ) {
            Get-AtajoDeTecla -Tecla $Tecla -Control | Should -Be $Esperado
        }

        It 'el teclado numerico hace lo mismo que la fila de arriba' {
            # Para el usuario es la misma tecla.
            foreach ($n in 1..6) {
                $arriba  = Get-AtajoDeTecla -Tecla ('D{0}' -f $n)      -Control
                $numerico = Get-AtajoDeTecla -Tecla ('NumPad{0}' -f $n) -Control
                $numerico | Should -Be $arriba
            }
        }

        It 'no hay Ctrl+7 ni Ctrl+0: no hay septimo panel' {
            Get-AtajoDeTecla -Tecla 'D7' -Control | Should -BeNullOrEmpty
            Get-AtajoDeTecla -Tecla 'D0' -Control | Should -BeNullOrEmpty
        }

        It 'los numeros SIN Control no son atajo' {
            Get-AtajoDeTecla -Tecla 'D3' | Should -BeNullOrEmpty
        }
    }

    Context 'No revienta con lo que le llegue' {
        # Por esta función pasa cada tecla pulsada, dentro de un manejador
        # de teclado: una excepción ahí es especialmente dañina.
        It 'con nulo devuelve nada, no lanza' {
            { Get-AtajoDeTecla -Tecla $null } | Should -Not -Throw
            Get-AtajoDeTecla -Tecla $null | Should -BeNullOrEmpty
        }

        It 'con cadena vacia o espacios devuelve nada, no lanza' {
            { Get-AtajoDeTecla -Tecla '' } | Should -Not -Throw
            Get-AtajoDeTecla -Tecla ''   | Should -BeNullOrEmpty
            Get-AtajoDeTecla -Tecla '   ' | Should -BeNullOrEmpty
        }

        It 'con un nombre de tecla que no existe devuelve nada' {
            Get-AtajoDeTecla -Tecla 'TeclaQueNoExiste' -Control | Should -BeNullOrEmpty
        }
    }
}
