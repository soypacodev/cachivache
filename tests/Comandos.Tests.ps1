<#
    Pruebas de Comandos.ps1: qué programas externos puede llegar a lanzar
    Cachivache y de dónde se resuelven.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent

    # Entorno reproducible: la resolución de Docker está anclada a las
    # carpetas de Archivos de programa, que en Linux no existen.
    $env:ProgramFiles = 'C:\Program Files'
    ${env:ProgramFiles(x86)} = 'C:\Program Files (x86)'

    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
}

Describe 'Resolve-EjecutablePermitido' {

    It 'devuelve $null para una cadena vacia' {
        Resolve-EjecutablePermitido -Ejecutable '' | Should -BeNullOrEmpty
    }

    It 'devuelve $null para un ejecutable fuera de la lista blanca' {
        Resolve-EjecutablePermitido -Ejecutable 'powershell' | Should -BeNullOrEmpty
        Resolve-EjecutablePermitido -Ejecutable 'cmd' | Should -BeNullOrEmpty
        Resolve-EjecutablePermitido -Ejecutable 'evil' | Should -BeNullOrEmpty
    }

    It 'resuelve "dism" a la ruta real bajo System32, no a una ruta arbitraria' {
        # 'dism' nunca se fía de la ruta declarada: solo mira el nombre base
        # y resuelve bajo System32 de $env:SystemRoot. Se fabrica un
        # SystemRoot de prueba con un Dism.exe falso.
        #
        # El archivo se crea en la misma ruta que calcula el código
        # (Join-Path $env:SystemRoot 'System32\Dism.exe'): en Linux la barra
        # invertida no separa carpetas, sino que forma parte del nombre.
        $raizPrueba = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        $dismDeMentira = Join-Path $raizPrueba 'System32\Dism.exe'
        New-Item -ItemType Directory -Path (Split-Path $dismDeMentira -Parent) -Force | Out-Null
        Set-Content -LiteralPath $dismDeMentira -Value 'no es un ejecutable de verdad'

        $anterior = $env:SystemRoot
        try {
            $env:SystemRoot = $raizPrueba
            # Se declara una ruta distinta: debe ignorarse y devolverse solo
            # la ruta de confianza bajo System32.
            Resolve-EjecutablePermitido -Ejecutable 'C:\otra\carpeta\cualquiera\dism.exe' |
                Should -Be $dismDeMentira
        } finally {
            $env:SystemRoot = $anterior
            Remove-Item -LiteralPath $raizPrueba -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'devuelve $null para "dism" si no existe bajo System32' {
        $raizPrueba = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $raizPrueba -Force | Out-Null
        $anterior = $env:SystemRoot
        try {
            $env:SystemRoot = $raizPrueba
            Resolve-EjecutablePermitido -Ejecutable 'dism' | Should -BeNullOrEmpty
        } finally {
            $env:SystemRoot = $anterior
            Remove-Item -LiteralPath $raizPrueba -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'resuelve "docker" contra Archivos de programa, nunca por PATH' {
        # No se resuelve por PATH: el PATH de cualquier usuario incluye
        # %LOCALAPPDATA%\Microsoft\WindowsApps, que el propio usuario puede
        # escribir.
        $esperada = $env:ProgramFiles + '\Docker\Docker\resources\bin\docker.exe'
        Mock Test-Path { $LiteralPath -eq $esperada }

        Resolve-EjecutablePermitido -Ejecutable 'docker' | Should -Be $esperada
    }

    It 'devuelve $null si Docker no esta instalado en ninguna ruta conocida' {
        Mock Test-Path { $false }
        Resolve-EjecutablePermitido -Ejecutable 'docker' | Should -BeNullOrEmpty
    }

    It 'no consulta Get-Command para resolver nada de la lista blanca' {
        # Garantiza que la lista blanca nunca consulta el PATH.
        Mock Get-Command { throw 'Resolve-EjecutablePermitido no debe consultar el PATH' }
        Mock Test-Path { $false }

        { Resolve-EjecutablePermitido -Ejecutable 'docker' } | Should -Not -Throw
        { Resolve-EjecutablePermitido -Ejecutable 'dism' }   | Should -Not -Throw
    }

    It 'npm ya no esta en la lista blanca: se elimino con el metodo NpmClean' {
        # Resolver "npm" devolvía npm.cmd, y un .cmd siempre se ejecuta a
        # través de cmd.exe, el intérprete que la lista blanca excluye.
        Resolve-EjecutablePermitido -Ejecutable 'npm' | Should -BeNullOrEmpty
    }

    It 'nada fuera de la lista blanca se resuelve, ni siquiera con ruta absoluta' {
        foreach ($prohibido in @(
                'powershell', 'cmd', 'node', 'python', 'git', 'wget', 'curl', 'rundll32',
                'C:\Windows\System32\cmd.exe', 'C:\Users\x\node.exe')) {
            Resolve-EjecutablePermitido -Ejecutable $prohibido |
                Should -BeNullOrEmpty -Because "'$prohibido' no esta en la lista blanca"
        }
    }

    It 'todo nombre de la lista blanca tiene su rama de resolucion' {
        # Un nombre en la lista sin rama en el switch devolvería $null
        # siempre: pasaría el filtro y luego fallaría en silencio.
        $texto = Get-Content (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Comandos.ps1') -Raw
        $lista = [regex]::Match($texto, '\$script:EjecutablesPermitidos\s*=\s*@\(([^)]*)\)')
        $lista.Success | Should -BeTrue -Because 'sin encontrar la lista, esta prueba no comprueba nada'
        $nombres = @([regex]::Matches($lista.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $nombres.Count | Should -BeGreaterThan 0
        $switch = [regex]::Match($texto, '(?s)switch \(\$nombre\) \{.*?\n    \}')
        foreach ($n in $nombres) {
            $switch.Value | Should -Match "'$n'" -Because "'$n' esta permitido pero no tiene rama que lo resuelva"
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
