<#
    Funciones que deciden qué binario se lanza y dónde se escribe.

      Resolve-EjecutableDeSistema  ancla las herramientas de Windows a
                                   System32 del propio equipo. Un nombre
                                   suelto lo resolvería Windows mirando
                                   antes la carpeta del programa y el
                                   directorio actual (secuestro del orden
                                   de búsqueda).

      Get-RutaPowerShell           resuelve el único ejecutable que se
                                   lanza elevado: uno ajeno sería una
                                   escalada de privilegios.

    Las funciones leen $env:SystemRoot y $env:LOCALAPPDATA, vacías en
    Linux; para ejercitar la lógica real se fabrica un árbol de carpetas
    falso y se apunta la variable ahí.

    Las rutas esperadas se calculan con la misma expresión Join-Path que el
    código: en Windows 'System32\x.exe' son dos niveles y en Linux
    Join-Path normaliza las barras.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Parámetros comunes que añade PowerShell, para distinguir los que
    # declara la función.
    $script:Comunes = @([Management.Automation.PSCmdlet]::CommonParameters) +
                      @([Management.Automation.PSCmdlet]::OptionalCommonParameters)
}

Describe 'Resolve-EjecutableDeSistema: nada que no cuelgue de System32' {

    BeforeAll {
        $script:SystemRootAnterior = $env:SystemRoot

        $script:Taller = Join-Path ([IO.Path]::GetTempPath()) ('sys32-' + [guid]::NewGuid().ToString('N'))
        $script:System32 = Join-Path $script:Taller 'System32'
        [void](New-Item -ItemType Directory -Path $script:System32 -Force)

    # Caso legítimo: una herramienta de Windows en su sitio.
        $script:DismEsperado = Join-Path (Join-Path $script:Taller 'System32') 'Dism.exe'
        Set-Content -LiteralPath $script:DismEsperado -Value 'no es un ejecutable de verdad'

        # Una carpeta con nombre de programa: sin -PathType Leaf se
        # devolvería como si fuera un archivo.
        [void](New-Item -ItemType Directory -Path (Join-Path $script:System32 'carpeta.exe') -Force)

        # Cebo: un ejecutable real justo fuera de System32. Sin el filtro
        # de separadores y de '..', Join-Path + Test-Path lo alcanzarían.
        $script:Fuera = Join-Path $script:Taller 'evil.exe'
        Set-Content -LiteralPath $script:Fuera -Value 'el binario del atacante'

        # Otro dentro de un subdirectorio, alcanzable con una barra en el
        # nombre.
        [void](New-Item -ItemType Directory -Path (Join-Path $script:System32 'sub') -Force)
        $script:EnSubcarpeta = Join-Path (Join-Path $script:System32 'sub') 'Dism.exe'
        Set-Content -LiteralPath $script:EnSubcarpeta -Value 'otro binario'

        $env:SystemRoot = $script:Taller
    }

    AfterAll {
        $env:SystemRoot = $script:SystemRootAnterior
        Remove-Item -LiteralPath $script:Taller -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'resuelve un nombre normal a la ruta anclada bajo System32' {
        Resolve-EjecutableDeSistema -Nombre 'Dism.exe' | Should -Be $script:DismEsperado
    }

    It 'devuelve un unico valor, no una lista' {
        # .Count sobre un objeto suelto vale $null en 5.1: se envuelve en
        # @() para que signifique lo mismo en las dos versiones.
        @(Resolve-EjecutableDeSistema -Nombre 'Dism.exe').Count | Should -Be 1
    }

    It 'devuelve $null si el nombre no existe bajo System32' {
        Resolve-EjecutableDeSistema -Nombre 'NoExisteEnAbsoluto.exe' | Should -BeNullOrEmpty
    }

    It 'una carpeta con nombre de programa no se resuelve como si fuera un ejecutable' {
        Test-Path -LiteralPath (Join-Path $script:System32 'carpeta.exe') -PathType Container |
            Should -BeTrue -Because 'sin la carpeta cebo esta prueba no mira nada'
        Resolve-EjecutableDeSistema -Nombre 'carpeta.exe' | Should -BeNullOrEmpty
    }

    It 'no se puede salir de System32 con .. aunque el archivo exista de verdad' {
        # Se comprueba que, sin el filtro, la ruta compuesta sí llegaría al
        # binario de fuera; si no, el rechazo no demostraría nada.
        Test-Path -LiteralPath (Join-Path $script:System32 '..\evil.exe') -PathType Leaf |
            Should -BeTrue -Because 'el cebo tiene que ser alcanzable para que rechazarlo signifique algo'

        foreach ($salida in @('..\evil.exe', '../evil.exe', '..\..\evil.exe', '..')) {
            Resolve-EjecutableDeSistema -Nombre $salida |
                Should -BeNullOrEmpty -Because "'$salida' sale de System32"
        }
    }

    It 'un nombre con barra no se resuelve, ni siquiera hacia dentro de System32' {
        # El destino existe: el $null solo puede venir del filtro.
        Test-Path -LiteralPath $script:EnSubcarpeta -PathType Leaf |
            Should -BeTrue -Because 'sin el cebo, el rechazo no significaria nada'

        foreach ($conBarra in @('sub\Dism.exe', 'sub/Dism.exe')) {
            Resolve-EjecutableDeSistema -Nombre $conBarra |
                Should -BeNullOrEmpty -Because "'$conBarra' no es un nombre de archivo, es una ruta"
        }
    }

    It 'un nombre con dos puntos no se resuelve' {
        # 'C:Dism.exe' es relativa a la unidad y 'C:\...' absoluta: las dos
        # dejan de estar ancladas al System32 del equipo.
        foreach ($conDosPuntos in @('C:Dism.exe', 'C:\Windows\System32\Dism.exe', 'x:y')) {
            Resolve-EjecutableDeSistema -Nombre $conDosPuntos |
                Should -BeNullOrEmpty -Because "'$conDosPuntos' lleva unidad"
        }
    }

    It 'los dos puntos se rechazan aunque no vayan con separador' {
        # El filtro rechaza '..' en cualquier posición: rechazar un nombre
        # raro no cuesta nada; aceptarlo podría ejecutar algo de fuera.
        Resolve-EjecutableDeSistema -Nombre '..Dism.exe' | Should -BeNullOrEmpty
    }

    It 'un SystemRoot vacio o en blanco no resuelve nada' {
        # Con SystemRoot en blanco, Join-Path compondría una ruta relativa
        # al directorio actual.
        try {
            foreach ($vacio in @('', '   ')) {
                $env:SystemRoot = $vacio
                Resolve-EjecutableDeSistema -Nombre 'Dism.exe' |
                    Should -BeNullOrEmpty -Because 'sin SystemRoot no hay System32 en el que confiar'
            }
        } finally {
            $env:SystemRoot = $script:Taller
        }
        # El nombre vuelve a resolver: lo anterior falló por el motivo
        # correcto.
        Resolve-EjecutableDeSistema -Nombre 'Dism.exe' | Should -Be $script:DismEsperado
    }

    It 'no consulta el PATH' {
        # Si alguien añade un Get-Command, el mock lanza.
        Mock Get-Command { throw 'Resolve-EjecutableDeSistema no debe consultar el PATH' }

        { Resolve-EjecutableDeSistema -Nombre 'Dism.exe' } | Should -Not -Throw
        { Resolve-EjecutableDeSistema -Nombre 'vssadmin.exe' } | Should -Not -Throw
    }

    It 'un nombre en blanco no revienta' {
        # No puede ser vacía (es Mandatory), pero sí espacios; quien llama
        # está a mitad de un análisis.
        { Resolve-EjecutableDeSistema -Nombre '   ' } | Should -Not -Throw
        Resolve-EjecutableDeSistema -Nombre '   ' | Should -BeNullOrEmpty
    }
}

Describe 'Get-RutaPowerShell: la unica linea que se lanza elevada' {

    BeforeAll {
        $script:SystemRootAnterior = $env:SystemRoot

        $script:Windir = Join-Path ([IO.Path]::GetTempPath()) ('windir-' + [guid]::NewGuid().ToString('N'))

        # Misma expresión que el código: en Windows son cuatro niveles; en
        # Linux Join-Path normaliza las barras.
        $script:PsEsperado = Join-Path $script:Windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path $script:PsEsperado -Parent) -Force)
        Set-Content -LiteralPath $script:PsEsperado -Value 'el powershell de Windows'

        # Árbol sin el powershell.exe legítimo y con dos cebos donde el
        # orden de búsqueda miraría antes. Lo correcto es $null: mejor no
        # ofrecer elevación que elevar cualquier cosa.
        $script:SoloCebos = Join-Path ([IO.Path]::GetTempPath()) ('cebos-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $script:SoloCebos 'System32') -Force)
        $script:CeboRaiz = Join-Path $script:SoloCebos 'powershell.exe'
        $script:CeboSystem32 = Join-Path (Join-Path $script:SoloCebos 'System32') 'powershell.exe'
        Set-Content -LiteralPath $script:CeboRaiz -Value 'el powershell del atacante'
        Set-Content -LiteralPath $script:CeboSystem32 -Value 'el powershell del atacante'

        $env:SystemRoot = $script:Windir
    }

    AfterAll {
        $env:SystemRoot = $script:SystemRootAnterior
        Remove-Item -LiteralPath $script:Windir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:SoloCebos -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'devuelve exactamente el powershell.exe de System32\WindowsPowerShell\v1.0' {
        Get-RutaPowerShell | Should -Be $script:PsEsperado
    }

    It 'la ruta devuelta cuelga del SystemRoot de este equipo' {
        # Una ruta fija (C:\Windows\...) sería falsa en equipos con Windows
        # instalado en otro sitio.
        (Get-RutaPowerShell).StartsWith($script:Windir) | Should -BeTrue
    }

    It 'devuelve un unico valor, no una lista' {
        @(Get-RutaPowerShell).Count | Should -Be 1
    }

    It 'no cae en un powershell.exe colocado en la raiz de Windows ni en System32' {
        try {
            $env:SystemRoot = $script:SoloCebos

            # Los cebos existen: el $null viene del rechazo, no de que no
            # haya nada.
            Test-Path -LiteralPath $script:CeboRaiz -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $script:CeboSystem32 -PathType Leaf | Should -BeTrue

            Get-RutaPowerShell |
                Should -BeNullOrEmpty -Because 'no elevar es mejor que elevar un binario ajeno'
        } finally {
            $env:SystemRoot = $script:Windir
        }
    }

    It 'un SystemRoot vacio o en blanco devuelve $null' {
        try {
            foreach ($vacio in @('', '   ')) {
                $env:SystemRoot = $vacio
                Get-RutaPowerShell | Should -BeNullOrEmpty
            }
        } finally {
            $env:SystemRoot = $script:Windir
        }
        Get-RutaPowerShell | Should -Be $script:PsEsperado
    }

    It 'no consulta el PATH' {
        Mock Get-Command { throw 'Get-RutaPowerShell no debe consultar el PATH' }
        { Get-RutaPowerShell } | Should -Not -Throw
    }

    It 'no acepta ningun parametro: quien llama no elige que se eleva' {
        # Si admitiera una ruta, quien llama decidiría qué se eleva y el
        # anclaje a System32 no serviría de nada.
        $declarados = @((Get-Command Get-RutaPowerShell).Parameters.Keys |
                        Where-Object { $script:Comunes -notcontains $_ })
        $declarados | Should -BeNullOrEmpty -Because 'lo que se eleva no puede venir de fuera'
    }
}

Describe 'Test-EsAdministrador' {

    # La rama principal consulta WindowsIdentity, que solo existe en
    # Windows (en Linux se ejecuta el catch). Se comprueba que nunca lanza,
    # que devuelve un booleano estable y que ante la duda responde $false.
    # El IsInRole verdadero de un proceso elevado no se cubre.

    It 'devuelve un booleano de verdad, no $null ni una cadena' {
        # Se usa como condición: un $null se leería como "no soy
        # administrador" por casualidad.
        $r = Test-EsAdministrador
        @($r).Count | Should -Be 1
        $r -is [bool] | Should -BeTrue
    }

    It 'no lanza nunca, ni siquiera donde la identidad de Windows no existe' {
        { Test-EsAdministrador } | Should -Not -Throw
    }

    It 'es estable: dos llamadas seguidas dicen lo mismo' {
        Test-EsAdministrador | Should -Be (Test-EsAdministrador)
    }

    # Pester evalúa -Skip durante el descubrimiento, antes de cualquier
    # BeforeAll: la condición se escribe completa aquí.
    It 'si no se puede saber, la respuesta es NO' -Skip:($IsWindows -or ($null -eq $IsWindows)) {
        # Aquí WindowsIdentity lanza y se ejercita el catch. Creerse
        # administrador sin serlo llevaría a saltarse la elevación e
        # intentar borrados privilegiados que fallarían uno a uno.
        Test-EsAdministrador | Should -BeFalse
    }

    It 'en Windows responde lo mismo que la propia API, ni mas ni menos' `
        -Skip:(-not ($IsWindows -or ($null -eq $IsWindows))) {
        # Detecta una constante, una condición invertida o un rol distinto
        # (p. ej. PowerUser).
        $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identidad)
        $esperado = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Test-EsAdministrador | Should -Be $esperado
    }
}

Describe 'Get-CarpetaDatos' {

    BeforeAll {
        $script:LocalAnterior = $env:LOCALAPPDATA
        $script:TempAnterior = $env:TEMP
        $script:BaseDatos = Join-Path ([IO.Path]::GetTempPath()) ('datos-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:BaseDatos -Force)
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:LocalAnterior
        $env:TEMP = $script:TempAnterior
        Remove-Item -LiteralPath $script:BaseDatos -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'cuelga de LOCALAPPDATA y se llama Cachivache' {
        $base = Join-Path $script:BaseDatos 'caso-local'
        try {
            $env:LOCALAPPDATA = $base
            $carpeta = Get-CarpetaDatos
            @($carpeta).Count | Should -Be 1
            $carpeta | Should -Be (Join-Path $base 'Cachivache')
        } finally {
            $env:LOCALAPPDATA = $script:LocalAnterior
        }
    }

    It 'crea la carpeta y sus dos subcarpetas, no solo devuelve el nombre' {
        # Si solo compusiera la ruta, el registro y los informes fallarían
        # al escribir mucho más tarde.
        $base = Join-Path $script:BaseDatos 'caso-crea'
        try {
            $env:LOCALAPPDATA = $base
            $carpeta = Get-CarpetaDatos
            Test-Path -LiteralPath $carpeta -PathType Container | Should -BeTrue
            foreach ($sub in @('informes', 'registros')) {
                Test-Path -LiteralPath (Join-Path $carpeta $sub) -PathType Container |
                    Should -BeTrue -Because "hace falta la subcarpeta '$sub'"
            }
        } finally {
            $env:LOCALAPPDATA = $script:LocalAnterior
        }
    }

    It 'llamarla dos veces no lanza ni se lleva por delante lo ya guardado' {
        # Se llama en cada arranque: New-Item -Force sobre una carpeta
        # existente no borra nada.
        $base = Join-Path $script:BaseDatos 'caso-idem'
        try {
            $env:LOCALAPPDATA = $base
            $primera = Get-CarpetaDatos
            $informe = Join-Path (Join-Path $primera 'informes') 'informe-viejo.html'
            Set-Content -LiteralPath $informe -Value 'un informe de una ejecucion anterior'

            $segunda = Get-CarpetaDatos
            $segunda | Should -Be $primera
            Test-Path -LiteralPath $informe -PathType Leaf |
                Should -BeTrue -Because 'los informes anteriores no se tocan'
        } finally {
            $env:LOCALAPPDATA = $script:LocalAnterior
        }
    }

    It 'sin LOCALAPPDATA cae a TEMP' {
        # Sin respaldo se compondría una ruta relativa al directorio
        # actual.
        $base = Join-Path $script:BaseDatos 'caso-temp'
        try {
            foreach ($vacio in @('', '   ')) {
                $env:LOCALAPPDATA = $vacio
                $env:TEMP = $base
                Get-CarpetaDatos | Should -Be (Join-Path $base 'Cachivache')
            }
        } finally {
            $env:LOCALAPPDATA = $script:LocalAnterior
            $env:TEMP = $script:TempAnterior
        }
    }

    It 'nunca escribe dentro del arbol del proyecto' {
        # El repositorio debe poder clonarse en solo lectura y no
        # ensuciarse con datos generados.
        $base = Join-Path $script:BaseDatos 'caso-fuera'
        try {
            $env:LOCALAPPDATA = $base
            $carpeta = Get-CarpetaDatos
            $carpeta.StartsWith($script:Raiz) |
                Should -BeFalse -Because 'los datos generados no viven en el repositorio'
            $carpeta.StartsWith($base) | Should -BeTrue
        } finally {
            $env:LOCALAPPDATA = $script:LocalAnterior
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
