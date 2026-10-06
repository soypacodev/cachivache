<#
    Pruebas del historial: entradas incompletas y su motivo.

    El historial es lo único que se conserva a largo plazo (el registro se
    rota por meses), así que una limpieza detenida a mitad debe quedar
    anotada como tal.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
}

Describe 'Add-EntradaHistorial: incompleto y motivo' {

    BeforeEach {
        $script:Datos = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-hist-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Datos -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Datos -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'por defecto una entrada NO es incompleta' {
        # El caso normal no puede requerir que nadie se acuerde de nada.
        Add-EntradaHistorial -Tipo 'analisis' -Elementos 10 -Bytes 1000 `
                             -CarpetaDatos $script:Datos -Confirm:$false
        $e = @(Get-Historial -CarpetaDatos $script:Datos)[-1]
        $e.Incompleto | Should -BeFalse
        $e.Motivo     | Should -BeNullOrEmpty
    }

    It 'guarda que quedo incompleta y por que' {
        Add-EntradaHistorial -Tipo 'limpieza' -Elementos 3 -Bytes 500 `
                             -Incompleto -Motivo 'La detuviste a mitad: 3 de 400.' `
                             -CarpetaDatos $script:Datos -Confirm:$false
        $e = @(Get-Historial -CarpetaDatos $script:Datos)[-1]
        $e.Incompleto | Should -BeTrue
        $e.Motivo     | Should -BeLike '*3 de 400*'
    }

    It 'los dos campos sobreviven a la ida y vuelta por JSON' {
        # Un campo que se escribe pero no se relee no sirve de nada.
        Add-EntradaHistorial -Tipo 'analisis' -Elementos 1 -Bytes 1 `
                             -Incompleto -Motivo 'Fallaron 2 modulos.' `
                             -CarpetaDatos $script:Datos -Confirm:$false

        $texto = Get-Content -Raw -LiteralPath (Get-RutaHistorial -CarpetaDatos $script:Datos)
        $texto | Should -BeLike '*Incompleto*'
        $texto | Should -BeLike '*Fallaron 2 modulos*'
    }

    It 'una entrada antigua sin los campos nuevos se sigue leyendo' {
        # historial.json puede venir de una versión anterior: añadir campos
        # no debe romper su lectura.
        $ruta = Get-RutaHistorial -CarpetaDatos $script:Datos
        $viejo = @([pscustomobject]@{
            Fecha = (Get-Date).ToString('o'); Tipo = 'limpieza'; Perfil = 'equilibrado'
            Modulos = @('caches'); Elementos = 5; Bytes = 100
            LibreAntes = 0; LibreDespues = 0; Informe = ''
        })
        $viejo | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ruta -Encoding UTF8

        $leido = @(Get-Historial -CarpetaDatos $script:Datos)
        $leido.Count | Should -Be 1
        $leido[0].Elementos | Should -Be 5
        # Sin el campo la propiedad no existe; la ausencia equivale a
        # "completa".
        [bool]$leido[0].Incompleto | Should -BeFalse
    }

    It 'añadir una entrada nueva junto a otra antigua no rompe nada' {
        $ruta = Get-RutaHistorial -CarpetaDatos $script:Datos
        @([pscustomobject]@{
            Fecha = (Get-Date).ToString('o'); Tipo = 'analisis'; Perfil = 'equilibrado'
            Modulos = @(); Elementos = 1; Bytes = 1
            LibreAntes = 0; LibreDespues = 0; Informe = ''
        }) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ruta -Encoding UTF8

        Add-EntradaHistorial -Tipo 'limpieza' -Elementos 2 -Bytes 2 -Incompleto `
                             -CarpetaDatos $script:Datos -Confirm:$false

        $leido = @(Get-Historial -CarpetaDatos $script:Datos)
        $leido.Count | Should -Be 2
        [bool]$leido[-1].Incompleto | Should -BeTrue
    }
}

Describe 'Add-EntradaHistorial: historial ilegible' {

    BeforeEach {
        $script:Datos = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-hist-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Datos -Force | Out-Null
        $script:RutaHist = Get-RutaHistorial -CarpetaDatos $script:Datos
        Mock Write-Registro { }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Datos -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'guarda una copia del archivo ilegible antes de reescribirlo' {
        $roto = '[{ "Tipo": "limpieza", "Bytes": }]'
        Set-Content -LiteralPath $script:RutaHist -Value $roto -NoNewline

        Add-EntradaHistorial -Tipo 'analisis' -Elementos 1 -Bytes 1 -CarpetaDatos $script:Datos -Confirm:$false

        Get-Content -LiteralPath "$($script:RutaHist).corrupto" -Raw | Should -Be $roto
        @(Get-Historial -CarpetaDatos $script:Datos).Count | Should -Be 1
        Should -Invoke Write-Registro -Times 1 -ParameterFilter { $Nivel -eq 'AVISO' }
    }

    It 'un historial legible no deja copia' {
        Add-EntradaHistorial -Tipo 'analisis' -Elementos 1 -Bytes 1 -CarpetaDatos $script:Datos -Confirm:$false
        Add-EntradaHistorial -Tipo 'analisis' -Elementos 2 -Bytes 2 -CarpetaDatos $script:Datos -Confirm:$false

        Test-Path -LiteralPath "$($script:RutaHist).corrupto" | Should -BeFalse
        @(Get-Historial -CarpetaDatos $script:Datos).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $script:Datos -Filter 'historial.json.*.tmp').Count | Should -Be 0
    }

    It 'Read-ArchivoHistorial distingue un archivo ilegible de uno vacio o ausente' {
        (Read-ArchivoHistorial -Ruta $script:RutaHist).Ilegible | Should -BeFalse
        Set-Content -LiteralPath $script:RutaHist -Value '' -NoNewline
        (Read-ArchivoHistorial -Ruta $script:RutaHist).Ilegible | Should -BeFalse
        Set-Content -LiteralPath $script:RutaHist -Value '{ roto' -NoNewline
        $lectura = Read-ArchivoHistorial -Ruta $script:RutaHist
        $lectura.Ilegible | Should -BeTrue
        @($lectura.Entradas).Count | Should -Be 0
    }

    It 'Get-Historial solo lee: no copia el archivo ilegible' {
        Set-Content -LiteralPath $script:RutaHist -Value '{ roto' -NoNewline
        @(Get-Historial -CarpetaDatos $script:Datos).Count | Should -Be 0
        Test-Path -LiteralPath "$($script:RutaHist).corrupto" | Should -BeFalse
    }
}

Describe 'la limpieza interrumpida al cerrar se anota como las demas' {
    <#
        Window.Eventos.ps1 no se puede ejecutar sin WPF: se comprueba la
        llamada en el AST.
    #>

    BeforeAll {
        $ruta = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Window.Eventos.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
        $script:LlamadaInterrumpida = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Add-EntradaHistorial' -and
            $n.Extent.Text -match "'limpieza-interrumpida'" }, $true))
        $script:TextoLlamada = if ($script:LlamadaInterrumpida.Count -eq 1) { $script:LlamadaInterrumpida[0].Extent.Text } else { '' }
        $script:Parametros = @($script:LlamadaInterrumpida | ForEach-Object { $_.CommandElements } |
            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
            ForEach-Object { $_.ParameterName })
    }

    It 'hay exactamente una llamada' {
        $script:LlamadaInterrumpida.Count | Should -Be 1
    }

    It 'la marca como incompleta, con motivo y sin pedir confirmacion' {
        $script:Parametros | Should -Contain 'Incompleto'
        $script:Parametros | Should -Contain 'Motivo'
        $script:Parametros | Should -Contain 'Confirm'
    }

    It 'anota los modulos del lote, no todos los modulos' {
        $script:TextoLlamada | Should -Match 'ModulosLote'
        $script:TextoLlamada | Should -Not -Match '\$estado\.Modulos\s'
    }
}

Describe 'la limpieza terminada anota los modulos que ha tocado' {
    # Se comprueba en el AST: la ventana necesita WPF y la consola, un disco real.

    BeforeAll {
        $script:LlamadaLimpieza = {
            param([string] $Relativa)
            $ruta = Join-Path $script:Raiz $Relativa
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
            @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Add-EntradaHistorial' -and
                $n.Extent.Text -match "-Tipo 'limpieza'\s" }, $true))
        }
    }

    It 'la ventana pasa los modulos del lote' {
        $llamadas = & $script:LlamadaLimpieza 'src/UI/Window.Eliminacion.ps1'
        $llamadas.Count | Should -Be 1
        $llamadas[0].Extent.Text | Should -Match '-Modulos @\(\$estado\.ModulosLote\)'
    }

    It 'la consola pasa los modulos de lo marcado' {
        $llamadas = & $script:LlamadaLimpieza 'src/Cli/Cli.ps1'
        $llamadas.Count | Should -Be 1
        $llamadas[0].Extent.Text | Should -Match '-Modulos @\(\$marcados'
    }
}
