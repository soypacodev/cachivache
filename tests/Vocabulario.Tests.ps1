<#
    Pruebas del vocabulario de programas instalados (Registry.ps1).

    Decide cuánta basura encuentra el programa: comparar por subcadena en
    las dos direcciones contra palabras genéricas declararía "conocida"
    casi cualquier carpeta. Pero endurecer la comparación sin más cambiaría
    falsos negativos (basura que se queda) por falsos positivos (proponer
    borrar algo necesario), que es peor. Las dos mitades importan.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    function New-Vocabulario {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo compone un objeto en memoria.')]
        [CmdletBinding()]
        param([string[]] $Fuertes = @(), [string[]] $Debiles = @())

        $v = New-VocabularioInstalado
        foreach ($t in $Fuertes) { Add-TokenVocabulario -Vocabulario $v -Texto $t -Fuerte }
        foreach ($t in $Debiles) { Add-TokenVocabulario -Vocabulario $v -Texto $t }
        return $v
    }
}

Describe 'ConvertTo-TokenSinVersion' {

    It 'quita los digitos del final: "<Texto>" -> "<Esperado>"' -ForEach @(
        @{ Texto = 'Python 3.9';   Esperado = 'python' }
        @{ Texto = 'Office 2016';  Esperado = 'office' }
        @{ Texto = 'Java 8';       Esperado = 'java' }
        @{ Texto = 'Notepad++';    Esperado = 'notepad' }
    ) { ConvertTo-TokenSinVersion $Texto | Should -Be $Esperado }

    It 'NO quita los digitos de delante: "<Texto>" -> "<Esperado>"' -ForEach @(
        @{ Texto = '7-Zip';      Esperado = '7zip' }
        @{ Texto = '1Password';  Esperado = '1password' }
    ) {
        # Quitarlos convertiría 7zip en "zip" y 1password en "password",
        # que son programas distintos.
        ConvertTo-TokenSinVersion $Texto | Should -Be $Esperado
    }

    It 'devuelve el token entero si al recortar no queda casi nada' {
        # "H2" recortado sería "h": una letra no empareja nada.
        ConvertTo-TokenSinVersion 'H2' | Should -Be 'h2'
    }
}

Describe 'Test-TokenConocido: lo que SI esta instalado' {

    It 'reconoce una coincidencia exacta con un programa instalado' {
        $v = New-Vocabulario -Fuertes @('Adobe Acrobat DC')
        Test-TokenConocido -Nombre 'Adobe Acrobat DC' -Vocabulario $v | Should -BeTrue
    }

    It 'reconoce una coincidencia exacta con un token debil' {
        # Los débiles valen para coincidencia exacta: un servicio con el
        # mismo nombre que la carpeta sí es una señal.
        $v = New-Vocabulario -Debiles @('Spooler')
        Test-TokenConocido -Nombre 'Spooler' -Vocabulario $v | Should -BeTrue
    }

    It 'reconoce el mismo programa con y sin numero de version' {
        $v = New-Vocabulario -Fuertes @('Python 3.9')
        Test-TokenConocido -Nombre 'Python'   -Vocabulario $v | Should -BeTrue
        Test-TokenConocido -Nombre 'Python39' -Vocabulario $v | Should -BeTrue
    }

    It 'reconoce por prefijo cuando el nombre comparte casi todo' {
        # "Adobe Acrobat" (12) contra "Adobe Acrobat DC" (14): 0.86.
        $v = New-Vocabulario -Fuertes @('Adobe Acrobat DC')
        Test-TokenConocido -Nombre 'Adobe Acrobat' -Vocabulario $v | Should -BeTrue
    }

    It 'el prefijo funciona en las dos direcciones' {
        $v = New-Vocabulario -Fuertes @('Adobe Acrobat')
        Test-TokenConocido -Nombre 'Adobe Acrobat DC' -Vocabulario $v | Should -BeTrue
    }

    It 'ante un nombre demasiado corto responde conocido' {
        # Un nombre de dos letras no distingue nada: no se propone.
        $v = New-Vocabulario
        Test-TokenConocido -Nombre 'ab' -Vocabulario $v | Should -BeTrue
    }

    It 'examina nombres de tres letras' {
        # Un umbral de 4 dejaría fuera "obs", "vlc" y "nvda".
        $v = New-Vocabulario -Fuertes @('Steam')
        Test-TokenConocido -Nombre 'OBS' -Vocabulario $v | Should -BeFalse
    }
}

Describe 'Test-TokenConocido: lo que NO esta instalado' {

    <#
        Cada caso es una carpeta que debe examinarse; el vocabulario es el
        mínimo que reproduce el problema.
    #>

    It 'un token debil generico no basta: <Carpeta> con "<Debil>" instalado' -ForEach @(
        @{ Carpeta = 'EA Games';           Debil = 'games' }
        @{ Carpeta = 'Warframe Launcher';  Debil = 'launcher' }
        @{ Carpeta = 'PowerDVD';           Debil = 'power' }
        @{ Carpeta = 'ThemeEngine';        Debil = 'themes' }
        @{ Carpeta = 'NodeCache';          Debil = 'node' }
    ) {
        $v = New-Vocabulario -Debiles @($Debil)
        Test-TokenConocido -Nombre $Carpeta -Vocabulario $v |
            Should -BeFalse -Because "que exista '$Debil' no dice nada sobre una carpeta llamada '$Carpeta'"
    }

    It 'el editor por si solo no cubre a sus productos' {
        # Que el editor tenga algo instalado no valida una carpeta suelta
        # de un juego suyo ya desinstalado.
        $v = New-Vocabulario -Debiles @('Ubisoft')
        Test-TokenConocido -Nombre 'Ubisoft Old Launcher' -Vocabulario $v | Should -BeFalse
    }

    It 'un prefijo que no llega al ratio no cuenta como el mismo programa' {
        # "Discord" (7) dentro de "Discord Canary" (13) es 0.54: son dos
        # aplicaciones distintas.
        $v = New-Vocabulario -Fuertes @('Discord')
        Test-TokenConocido -Nombre 'Discord Canary Old' -Vocabulario $v | Should -BeFalse
    }

    It 'un token fuerte corto no arrastra por prefijo a nombres largos' {
        $v = New-Vocabulario -Fuertes @('Steam')
        Test-TokenConocido -Nombre 'SteamOldLauncherBackupData' -Vocabulario $v | Should -BeFalse
    }
}

Describe 'Test-TokenConocido: rendimiento' {

    It 'no recorre el vocabulario entero por cada consulta' {
        <#
            Comparar por subcadena contra todo el conjunto supone millones
            de comparaciones (miles de tokens por cientos de carpetas). Con
            coincidencia exacta sobre HashSet y prefijo sobre un índice de
            las tres primeras letras, el coste no depende del tamaño del
            vocabulario: multiplicarlo por veinte no puede multiplicar por
            veinte el tiempo.
        #>
        $pequeno = New-Vocabulario -Debiles (1..200  | ForEach-Object { "ServicioNumero$_" })
        $grande  = New-Vocabulario -Debiles (1..4000 | ForEach-Object { "ServicioNumero$_" })

        $consultas = 1..200 | ForEach-Object { "Carpeta Huerfana Numero $_" }

        $cronometro = [Diagnostics.Stopwatch]::StartNew()
        foreach ($n in $consultas) { [void](Test-TokenConocido -Nombre $n -Vocabulario $pequeno) }
        $conPequeno = $cronometro.Elapsed.TotalMilliseconds

        $cronometro.Restart()
        foreach ($n in $consultas) { [void](Test-TokenConocido -Nombre $n -Vocabulario $grande) }
        $conGrande = $cronometro.Elapsed.TotalMilliseconds
        $cronometro.Stop()

        # Margen amplio: se comprueba que no hay crecimiento lineal, no un
        # número concreto que dependería de la máquina.
        $conGrande | Should -BeLessThan ([Math]::Max($conPequeno * 5, 50)) -Because (
            "con 20 veces mas vocabulario tardo ${conGrande}ms frente a ${conPequeno}ms: " +
            'si creciera de forma lineal, el bucle O(n*m) seguiria ahi')
    }
}

Describe 'Construccion del vocabulario' {

    It 'separa fuertes de debiles' {
        $v = New-Vocabulario -Fuertes @('Programa Instalado') -Debiles @('servicio generico')
        $v.Fuertes.Contains('programainstalado') | Should -BeTrue
        $v.Debiles.Contains('serviciogenerico')  | Should -BeTrue
        $v.Fuertes.Contains('serviciogenerico')  | Should -BeFalse
    }

    It 'solo los fuertes entran en el indice de prefijos' {
        $v = New-Vocabulario -Debiles @('serviciogenerico')
        $v.IndicePrefijo.Count | Should -Be 0 -Because 'el prefijo solo se compara contra evidencia fuerte'
    }

    It 'descarta los tokens demasiado cortos' {
        $v = New-Vocabulario -Fuertes @('ab')
        $v.Fuertes.Count | Should -Be 0
    }

    It 'lee tambien la clave de 32 bits por usuario' {
        # Sin ella, los programas de 32 bits instalados sin permisos de
        # administrador no aportarían tokens y sus carpetas se propondrían
        # como huérfanas.
        $texto = Get-Content -LiteralPath (
            Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Registry.ps1') -Raw
        $texto | Should -Match 'HKCU:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall'
    }
}

Describe 'Vocabulario: procesos sin editor legible' {

    It 'el aviso nombra el proceso, no el error' {
        # En los procesos protegidos, leer Company lanza; dentro del catch
        # $_ es el error y no el proceso. PowerShell se traga las excepciones
        # de los getters simulados, así que se hace fallar el uso del editor.
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'ProcesoBlindado'; Company = 'EditorBlindado' } }
        Mock Add-TokenVocabulario { }
        Mock Add-TokenVocabulario { throw 'Acceso denegado' } -ParameterFilter { $Texto -eq 'EditorBlindado' }

        # Fuera de Windows algunas fuentes avisan por rutas de unidad inexistentes.
        $mensajes = @(Get-TokensProgramasInstalados -Verbose -ErrorAction SilentlyContinue 4>&1 |
                      Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                      ForEach-Object { $_.Message })

        $mensajes | Should -Contain 'Sin editor para el proceso ProcesoBlindado.'
    }
}
