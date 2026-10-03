<#
    Lo que se puede comprobar del sondeo de la ventana sin Windows.

    El sondeo (tools/Sondeo-Robot.ps1) abre la ventana real y aquí no se
    ejecuta, pero se fijan tres cosas:

      1. Los nombres que busca existen en el XAML: un robot que no
         encuentra un control se queda esperando en vez de fallar.
      2. No pulsa nada peligroso: abre la ventana del usuario y podría
         borrar de verdad.
      3. Cierra el proceso que abre: en la CI, un proceso colgado parece
         una prueba lenta.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    $script:RutaSondeo = Join-Path (Join-Path $script:Raiz 'tools') 'Sondeo-Robot.ps1'

    function script:Get-CodigoSondeo {
        # Primero los bloques <# #> y después las líneas '#'. La cabecera
        # del sondeo nombra los botones que promete no pulsar: leer los
        # comentarios haría fallar la prueba correspondiente.
        $t = [IO.File]::ReadAllText($script:RutaSondeo)
        $t = [regex]::Replace($t, '(?s)<#.*?#>', '')
        return (@($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
    }

    $script:Codigo = script:Get-CodigoSondeo
    $script:Xaml = (@(Get-ChildItem -Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') -Filter '*.xaml') |
                    ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
}

Describe 'el sondeo de la ventana' {

    It 'existe y es sintacticamente valido' {
        Test-Path -LiteralPath $script:RutaSondeo | Should -BeTrue
        $errores = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $script:RutaSondeo, [ref]$null, [ref]$errores)
        @($errores).Count | Should -Be 0
    }

    It 'SIGUE HACIENDO LAS CINCO PREGUNTAS QUE PROMETE' {
        # Las demás pruebas miran detalles; esta comprueba que el sondeo
        # sigue haciendo todos sus pasos. Se compara el conjunto entero de
        # pasos anunciados con los prometidos, para detectar tanto uno que
        # falte como uno que sobre (p. ej. un '3c.' renumerado).
        $prometidos = @('0.', '1.', '2.', '2b.', '3.', '3b.', '4.', '5.')
        $anunciados = @([regex]::Matches($script:Codigo, "Write-Paso\s+'([^']+)'") |
                        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

        @($anunciados).Count | Should -BeGreaterThan 4 -Because 'si no encuentra pasos, no esta mirando el codigo'
        ($anunciados -join ' ') | Should -Be (($prometidos | Sort-Object -Unique) -join ' ') -Because (
            'el sondeo tiene que anunciar exactamente los pasos que promete su cabecera: ni uno menos ni uno mas')
    }

    It 'no llama a ninguna funcion suya que no exista' {
        # En PowerShell una llamada a una función inexistente no se detecta
        # hasta ejecutar esa línea, y aquí eso requiere una ventana.
        $errores = $null
        $arbol = [System.Management.Automation.Language.Parser]::ParseFile(
                    $script:RutaSondeo, [ref]$null, [ref]$errores)

        $definidas = @($arbol.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })

        # Solo nombres Verbo-Algo definidos en este archivo, para no
        # perseguir cmdlets del sistema.
        $llamadas = @($arbol.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ -and ($_ -match '^(Get|Write)-(Paso|PorNombre|Navegacion)$') } |
            Sort-Object -Unique)

        @($llamadas).Count | Should -BeGreaterThan 2 -Because 'si no encuentra llamadas, no esta mirando el arbol'
        $huerfanas = @($llamadas | Where-Object { $definidas -notcontains $_ })
        $huerfanas -join ', ' | Should -BeNullOrEmpty -Because (
            'una funcion que no existe no se nota hasta que se ejecuta esa linea, y aqui hace falta una ventana para eso')
    }

    It 'TODO BOTON DE NAVEGACION QUE BUSCA EXISTE EN EL XAML' {
        # Los nombres de $buscados deben ser el Content de un RadioButton
        # de navegación: si se renombra un botón, falla aquí y no en un
        # robot que espera indefinidamente.
        #
        # Se mira Content y no AutomationProperties.Name: los paneles no se
        # pulsan, y un control de contenido sin AutomationProperties.Name
        # se anuncia por su Content (lo que ven el lector de pantalla y el
        # robot).
        $m = [regex]::Match($script:Codigo, '(?s)\$buscados\s*=\s*@\((?<lista>.*?)\)')
        $m.Success | Should -BeTrue -Because 'sin la lista no hay nada que comprobar, y esta prueba estaria pasando por no mirar'

        $nombres = @([regex]::Matches($m.Groups['lista'].Value, "'([^']+)'") |
                     ForEach-Object { $_.Groups[1].Value })
        $nombres.Count | Should -Be 6 -Because 'son los seis paneles que tiene la ventana'

        $principal = [IO.File]::ReadAllText(
            (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'MainWindow.xaml'))
        $huerfanos = @($nombres | Where-Object {
            $principal -notmatch ('(?s)<RadioButton[^>]*?Content="' + [regex]::Escape($_) + '"')
        })
        $huerfanos -join ', ' | Should -BeNullOrEmpty -Because (
            'un robot que busca un boton que ya no se llama asi no falla: se queda ciego')
    }

    It 'el panel que usa para comprobar el efecto del clic tambien existe' {
        # El sondeo pulsa "Acerca de" y busca el panel "Acerca de
        # Cachivache" para confirmar el clic; si el nombre cambiara, daría
        # un falso negativo.
        $script:Codigo | Should -Match ([regex]::Escape("Get-PorNombre 'Acerca de Cachivache'"))
        $script:Xaml   | Should -Match ([regex]::Escape('AutomationProperties.Name="Acerca de Cachivache"'))
    }

    It 'no supone el patron de automatizacion: le pregunta al elemento' {
        # Un RadioButton de WPF no se invoca, se selecciona ("Modelo no
        # admitido"): hay que preguntar al elemento qué patrones admite.
        $script:Codigo | Should -Match 'GetSupportedPatterns'
        $script:Codigo | Should -Match 'SelectionItemPattern'
    }

    It 'desempata por tipo de control, porque hay nombres repetidos' {
        # NavAjustes (Content="Ajustes") y el panel de ajustes
        # (AutomationProperties.Name="Ajustes") comparten nombre accesible.
        # Se comprueba que la ambigüedad existe (si desapareciera, el
        # filtro por tipo sobraría) y que el código la desempata.
        $script:Codigo | Should -Match 'ControlTypeProperty'
        $script:Codigo | Should -Match 'AndCondition'

        $principal = [IO.File]::ReadAllText(
            (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'MainWindow.xaml'))
        $principal | Should -Match ([regex]::Escape('Content="Ajustes"'))
        $script:Xaml | Should -Match ([regex]::Escape('AutomationProperties.Name="Ajustes"'))
    }

    It 'NO PULSA NADA QUE BORRE, y eso no es una promesa del comentario' {
        # El sondeo abre la ventana del usuario, con sus discos reales. Se
        # comprueba el código, no la cabecera que lo promete.
        foreach ($peligroso in 'BtnEliminar', 'BtnAnalizar', 'Eliminar lo marcado', 'Analizar') {
            $script:Codigo | Should -Not -Match ([regex]::Escape($peligroso)) -Because (
                "el sondeo solo mira y cambia de panel; '$peligroso' no pinta nada aqui")
        }
    }

    It 'busca la ventana por identificador de proceso y no por titulo' {
        # Por título encontraría cualquier ventana con el mismo nombre
        # (otra copia del programa, un explorador) y mediría otra cosa.
        $script:Codigo | Should -Match 'ProcessIdProperty'
    }

    It 'cierra lo que abre, y con red por si no se cierra solo' {
        $script:Codigo | Should -Match 'CloseMainWindow'
        $script:Codigo | Should -Match '\.Kill\(\)' -Because (
            'una ventana que no responde dejaria el proceso colgado en el ejecutor de la CI')
        $script:Codigo | Should -Match 'finally' -Because (
            'si el sondeo lanza a mitad, el proceso hay que cerrarlo igual')
    }

    It 'comprueba que UI Automation existe ANTES de arrancar nada' {
        # Si faltan las bibliotecas (Server Core, un contenedor, un runner
        # de la CI) no tiene sentido abrir una ventana. Se busca con límite
        # de palabra y no con IndexOf: "UIAutomationCliente" no debe
        # satisfacer la comprobación.
        $mUia = [regex]::Match($script:Codigo, 'UIAutomationClient(?![A-Za-z])')
        $mUia.Success | Should -BeTrue -Because 'el nombre del ensamblado tiene que estar entero'

        $mArranque = [regex]::Match($script:Codigo, 'Start-Process')
        $mArranque.Success | Should -BeTrue
        $mArranque.Index | Should -BeGreaterThan $mUia.Index -Because (
            'preguntar primero lo barato es el orden que hace util un sondeo')
    }
}
