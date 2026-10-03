<#
    Pruebas de la resolución de ejecutables a partir de una línea de
    comandos del registro o de un servicio.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
}

Describe 'Test-EjecutableExiste' {

    It 'una cadena vacia se da por existente: ante la duda, no se acusa de roto' {
        Test-EjecutableExiste '' | Should -BeTrue
        Test-EjecutableExiste '   ' | Should -BeTrue
    }

    It 'un archivo que existe de verdad se reconoce' {
        $archivo = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.exe')
        Set-Content -LiteralPath $archivo -Value 'x'
        try   { Test-EjecutableExiste $archivo | Should -BeTrue }
        finally { Remove-Item -LiteralPath $archivo -Force -ErrorAction SilentlyContinue }
    }

    It 'reconoce un servicio registrado sin la extension .exe' {
        $base = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        Set-Content -LiteralPath "$base.exe" -Value 'x'
        try   { Test-EjecutableExiste $base | Should -BeTrue }
        finally { Remove-Item -LiteralPath "$base.exe" -Force -ErrorAction SilentlyContinue }
    }

    It 'una ruta completa que no existe se declara rota' {
        $inventada = Join-Path ([IO.Path]::GetTempPath()) (([Guid]::NewGuid().ToString()) + '\no-existe.exe')
        Test-EjecutableExiste $inventada | Should -BeFalse
    }

    It 'un alias o funcion de PowerShell NO cuenta como ejecutable' {
        # Get-Command sin -CommandType Application resuelve alias, funciones
        # y cmdlets: una entrada de arranque llamada "where" o "sc" pasaría
        # por válida.
        function global:EntradaDeArranqueInventada { 'soy una funcion, no un programa' }
        Set-Alias -Name aliasinventadodeprueba -Value Get-Date -Scope Global
        try {
            Test-EjecutableExiste 'EntradaDeArranqueInventada' | Should -BeFalse
            Test-EjecutableExiste 'aliasinventadodeprueba'     | Should -BeFalse
        } finally {
            Remove-Item -Path 'function:global:EntradaDeArranqueInventada' -ErrorAction SilentlyContinue
            Remove-Item -Path 'alias:aliasinventadodeprueba' -ErrorAction SilentlyContinue
        }
    }

    It 'no pregunta al PATH por rutas que ya traen carpeta' {
        # Una ruta con carpeta que no existe está rota; buscarla en el PATH
        # solo puede dar un falso positivo.
        Mock Get-Command { throw 'no deberia consultarse el PATH para una ruta con carpeta' }
        Test-EjecutableExiste 'C:\carpeta\que\no\existe\programa.exe' | Should -BeFalse
        Should -Invoke Get-Command -Times 0 -Exactly
    }
}

Describe 'Get-EjecutableDeComando' {

    It 'extrae "<Esperado>" de <Comando>' -ForEach @(
        @{ Comando = '"C:\Program Files\App\app.exe" -silent'; Esperado = 'C:\Program Files\App\app.exe' }
        @{ Comando = 'C:\Program Files\App\app.exe --flag';    Esperado = 'C:\Program Files\App\app.exe' }
        @{ Comando = 'C:\tools\herramienta -x';                Esperado = 'C:\tools\herramienta' }
    ) { Get-EjecutableDeComando $Comando | Should -Be $Esperado }

    It 'devuelve cadena vacia si no hay comando' {
        Get-EjecutableDeComando '' | Should -Be ''
    }

    It 'normaliza el prefijo NT \??\ de los servicios' {
        Get-EjecutableDeComando '\??\C:\Windows\System32\drivers\algo.sys' |
            Should -Be 'C:\Windows\System32\drivers\algo.sys'
    }

    It 'normaliza \SystemRoot\ a %SystemRoot%' {
        $anterior = $env:SystemRoot
        try {
            $env:SystemRoot = 'C:\Windows'
            Get-EjecutableDeComando '\SystemRoot\System32\drivers\algo.sys' |
                Should -Be 'C:\Windows\System32\drivers\algo.sys'
        } finally {
            $env:SystemRoot = $anterior
        }
    }
}

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
}
