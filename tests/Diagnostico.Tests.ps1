<#
    Anonimizar el informe y copiar el diagnóstico desde la ventana.

    Ambas capacidades existen en Export-Informe* (-Anonimo) y en
    Get-InformeDiagnostico, y se prueban en Report.Tests.ps1 y
    Log.Tests.ps1. Aquí se comprueba que la ventana y la consola llaman a
    las mismas funciones, que es lo que podría volver a separarse.
#>

BeforeAll {
    $script:Raiz     = Split-Path $PSScriptRoot -Parent
    $script:CarpetaUI = Join-Path (Join-Path $script:Raiz 'src') 'UI'

    # Se quitan los comentarios antes de buscar: los de estos archivos
    # citan '-Anonimo' y 'Get-InformeDiagnostico' por su nombre.
    function Get-CodigoSinComentarios {
        param([Parameter(Mandatory)] [string] $Ruta)
        $texto = Get-Content -Raw -LiteralPath $Ruta
        return ($texto -replace '(?s)<#.*?#>', '' -replace '(?m)^\s*#.*$', '')
    }

    $script:CodigoEventos = Get-CodigoSinComentarios (Join-Path $script:CarpetaUI 'Window.Eventos.ps1')
    $script:CodigoCli     = Get-CodigoSinComentarios (Join-Path (Join-Path $script:Raiz 'src') 'Cli/Cli.ps1')
    $script:CodigoEntrada = Get-CodigoSinComentarios (Join-Path $script:Raiz 'Cachivache.ps1')
    $script:XamlResultados = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUI 'Panel.Resultados.xaml')
    $script:XamlAcerca     = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUI 'Panel.Acerca.xaml')
}

Describe 'la guarda de estas pruebas' {

    It 'se ha leido codigo de verdad en los cuatro sitios' {
        # Si un archivo se moviera, las cadenas quedarían vacías y las
        # comprobaciones siguientes pasarían sin mirar nada.
        $script:CodigoEventos.Length  | Should -BeGreaterThan 10000
        $script:CodigoCli.Length      | Should -BeGreaterThan 3000
        $script:CodigoEntrada.Length  | Should -BeGreaterThan 1000
        $script:XamlResultados.Length | Should -BeGreaterThan 5000
    }

    It 'quitar los comentarios no se ha llevado el codigo por delante' {
        $script:CodigoEventos | Should -Match 'Add_Click'
        $script:CodigoCli     | Should -Match 'Invoke-CachivacheCli'
    }
}

Describe 'anonimizar las rutas del informe' {

    It 'la casilla existe en Resultados, pegada al boton de guardar' {
        $script:XamlResultados | Should -Match 'x:Name="ChkAnonimizar"'

        # Entre la casilla y el botón no puede haber otro control: una
        # opción lejos del botón al que afecta se activa y se olvida.
        $posCasilla = $script:XamlResultados.IndexOf('x:Name="ChkAnonimizar"')
        $posBoton   = $script:XamlResultados.IndexOf('x:Name="BtnExportar"')
        $posCasilla | Should -BeGreaterThan 0
        $posBoton   | Should -BeGreaterThan $posCasilla
        $entreMedias = $script:XamlResultados.Substring($posCasilla, $posBoton - $posCasilla)
        # Un solo <Button entre medias: el que abre el propio BtnExportar.
        @([regex]::Matches($entreMedias, '<Button')).Count | Should -Be 1
    }

    It 'la casilla tiene rotulo y explicacion' {
        $script:XamlResultados | Should -Match 'Content="Anonimizar rutas"'
        $script:XamlResultados | Should -Match 'ToolTip="En el informe que guardes'
    }

    It 'las tres exportaciones de la ventana pasan -Anonimo' {
        # Olvidar el CSV haría que el usuario publicara su nombre de
        # usuario creyendo que el informe está anonimizado.
        $exportaciones = @([regex]::Matches($script:CodigoEventos, 'Export-Informe(Html|Csv|Json)[^\r\n]*'))
        $exportaciones.Count | Should -BeGreaterOrEqual 3 -Because 'si no se encuentran, esta prueba no comprueba nada'

        $sinAnonimo = @($exportaciones |
            Where-Object { $_.Value -notmatch '-Anonimo' } |
            ForEach-Object { $_.Value.Trim() })

        # Las exportaciones automáticas (informes de análisis y limpieza)
        # viven en otros archivos y no llevan casilla; aquí solo se miran
        # las del cierre $exportar.
        $sinAnonimo | Should -BeNullOrEmpty -Because (
            'la casilla tiene que valer para los tres formatos, no solo para el HTML')
    }

    It 'lo que se pasa es el valor de la casilla, no una constante' {
        # -Anonimo:$true fijo pasaría la prueba anterior y anularía la
        # casilla.
        $script:CodigoEventos | Should -Match '\$anonimo\s*=\s*\[bool\]\$c\.ChkAnonimizar\.IsChecked'
        $script:CodigoEventos | Should -Not -Match '-Anonimo:\$true'
        $script:CodigoEventos | Should -Not -Match '-Anonimo:\$false'
    }

    It 'la ventana DICE si el informe salio anonimizado' {
        # Dos informes con el mismo nombre y distinto contenido deben
        # poder distinguirse sin abrirlos.
        $script:CodigoEventos | Should -Match 'anonimizadas'
    }

    It 'la consola sigue haciendo lo mismo, y por la misma puerta' {
        $script:CodigoEntrada | Should -Match '\[switch\]\s*\$InformeAnonimo'
        $exportacionesCli = @([regex]::Matches($script:CodigoCli, 'Export-Informe(Html|Csv|Json)[^\r\n]*'))
        $exportacionesCli.Count | Should -BeGreaterOrEqual 3
        @($exportacionesCli | Where-Object { $_.Value -match '-Candidatos \$todos' -and $_.Value -notmatch '-Anonimo' }) |
            Should -BeNullOrEmpty
    }

    It 'la anonimizacion se escribe una sola vez en todo el programa' {
        # Un segundo sustituidor de rutas haría que la ventana y la consola
        # produjeran informes distintos.
        $definiciones = 0
        foreach ($archivo in @(Get-ChildItem (Join-Path $script:Raiz 'src') -Filter '*.ps1' -Recurse)) {
            $texto = Get-CodigoSinComentarios $archivo.FullName
            $definiciones += @([regex]::Matches($texto, 'function\s+ConvertTo-RutaAnonima')).Count
        }
        $definiciones | Should -Be 1 -Because 'dos sustituidores de rutas son dos informes distintos'
    }

    It 'la ventana llega a ella por -Anonimo, no por su cuenta' {
        # La única vía de la ventana es el parámetro de las funciones de
        # Report.ps1, el mismo que usa la consola.
        $culpables = @()
        foreach ($archivo in @(Get-ChildItem $script:CarpetaUI -Filter '*.ps1' -Recurse)) {
            $texto = Get-CodigoSinComentarios $archivo.FullName
            if ($texto -match 'ConvertTo-RutaAnonima') { $culpables += $archivo.Name }
        }
        $culpables | Should -BeNullOrEmpty -Because (
            'la interfaz pide informes anonimos, no los anonimiza ella')
    }
}

Describe 'copiar el diagnostico' {

    It 'el boton existe en Acerca de' {
        $script:XamlAcerca | Should -Match 'x:Name="BtnCopiarDiagnostico"'
        $script:XamlAcerca | Should -Match 'Content="Copiar diagnóstico"'
    }

    It 'la ventana y la consola llaman a la MISMA funcion' {
        $script:CodigoEventos | Should -Match 'Get-InformeDiagnostico'
        $script:CodigoEntrada | Should -Match 'Get-InformeDiagnostico'
    }

    It 'lo que se copia es lo que devuelve esa funcion' {
        # Copiar otra cosa (p. ej. el texto del registro) pasaría la prueba
        # anterior.
        $script:CodigoEventos | Should -Match '(?s)\$diagnostico = Get-InformeDiagnostico.*Clipboard\]::SetText\(\$diagnostico\)'
    }

    It 'nadie se escribe su propio diagnostico' {
        # La cabecera del informe aparece una sola vez, en Log.ps1: dos
        # diagnósticos acabarían divergiendo.
        $cabeceras = 0
        foreach ($archivo in @(Get-ChildItem (Join-Path $script:Raiz 'src') -Filter '*.ps1' -Recurse)) {
            $texto = Get-CodigoSinComentarios $archivo.FullName
            $cabeceras += @([regex]::Matches($texto, '=== Diagnostico de Cachivache ===')).Count
        }
        $cabeceras | Should -Be 1 -Because 'el diagnostico se arma en Log.ps1 y en ningun otro sitio'
    }

    It 'se confirma que se ha copiado' {
        # Copiar al portapapeles no se ve, y desde Acerca de tampoco el
        # registro: sin confirmación parece que el botón no funciona.
        $script:CodigoEventos | Should -Match 'portapapeles'
    }

    It 'si el portapapeles falla, se dice, y no se lleva la ventana por delante' {
        # Otro programa puede bloquear el portapapeles y SetText lanza.
        $bloque = [regex]::Match($script:CodigoEventos,
            '(?s)\$c\.BtnCopiarDiagnostico\.Add_Click\(\{.*?\n    \}\)')
        $bloque.Success | Should -BeTrue -Because 'si no se encuentra el manejador, esta prueba no comprueba nada'
        $bloque.Value | Should -Match 'try'
        $bloque.Value | Should -Match 'catch'
        $bloque.Value | Should -Match 'Show-Aviso'
    }
}

Describe 'los controles nuevos estan donde la ventana los busca' {

    <#
        Window.ps1 resuelve los controles por nombre con FindName. Un nombre
        ausente deja $c.Loquesea a $null: el control no responde y no hay
        error. Invariantes.Tests.ps1 lo comprueba para toda la ventana; aquí
        se fija para estos controles concretos.
    #>

    BeforeAll {
        $texto = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUI 'Window.ps1')
        $script:BloqueControles = [regex]::Match($texto,
            '(?s)\$c = @\{\}.*?\$c\[\$nombre\] = \$ventana\.FindName').Value
    }

    It 'la prueba encuentra la lista: si no, no comprueba nada' {
        $script:BloqueControles.Length | Should -BeGreaterThan 500
    }

    It '<Control> esta en la lista que Window.ps1 resuelve' -ForEach @(
        @{ Control = 'ChkAnonimizar' }
        @{ Control = 'TxtActualizacion' }
        @{ Control = 'BtnBuscarActualizacion' }
        @{ Control = 'BtnIrAVersionNueva' }
        @{ Control = 'BtnCopiarDiagnostico' }
    ) {
        $script:BloqueControles | Should -Match ("'" + $Control + "'")
    }
}
