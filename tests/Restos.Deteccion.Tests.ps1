<#
    Banco de pruebas de detección del módulo de restos de programas.

    Modulos.Regresion.Tests.ps1 fija fallos concretos; esto mide la
    precisión del módulo sobre un árbol sintético con doce casos (seis que
    son restos y seis que no), para saber si subir la sensibilidad rompe
    la precisión.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    <#
        Vocabulario de "lo instalado" fijado a mano: las pruebas corren en
        Linux, sin registro ni Get-AppxPackage, y un vocabulario controlado
        distingue un fallo de detección de una casualidad del equipo.

        Los tokens débiles salen de nombres de servicio, de proceso y de
        accesos directos del menú Inicio, y son genéricos: no deben bastar
        para declarar conocida una carpeta que los contenga ("games",
        "launcher").
    #>
    $script:TokensFuertes = @(
        # Programas instalados: DisplayName de la lista de desinstalación o
        # carpeta de Archivos de programa.
        'cachivacheinstalado'
        'ubisoftgamelauncher'
    )
    $script:TokensDebiles = @(
        # Genéricos (servicios, procesos, editores, accesos directos):
        # ninguno basta por sí solo para declarar conocida una carpeta.
        'ubisoft'
        'games'
        'launcher'
        'power'
        'themes'
    )

    function New-VocabularioDePrueba {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo compone un objeto en memoria.')]
        [CmdletBinding()]
        param()

        $v = New-VocabularioInstalado
        foreach ($t in $script:TokensFuertes) { Add-TokenVocabulario -Vocabulario $v -Texto $t -Fuerte }
        foreach ($t in $script:TokensDebiles) { Add-TokenVocabulario -Vocabulario $v -Texto $t }
        return $v
    }

    function New-ArbolDeRestos {
        <#
        .SYNOPSIS
            Fabrica un AppData falso con los doce casos del banco.
        .DESCRIPTION
            Devuelve las zonas: Local, Roaming, ProgramData y LocalLow.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo crea un arbol de prueba en una carpeta temporal propia.')]
        [CmdletBinding()]
        param([Parameter(Mandatory)] [string] $Raiz)

        # Distribución real de un perfil de Windows: el módulo deriva
        # LocalLow de %USERPROFILE%.
        $appData = Join-Path $Raiz 'AppData'
        $zonas = @{
            Local      = Join-Path $appData 'Local'
            Roaming    = Join-Path $appData 'Roaming'
            LocalLow   = Join-Path $appData 'LocalLow'
            Datos      = Join-Path $Raiz 'ProgramData'
        }
        foreach ($z in $zonas.Values) { New-Item -ItemType Directory -Path $z -Force | Out-Null }

        # Carpeta con un archivo y la antigüedad pedida. Cuenta la fecha
        # del archivo: Get-ResumenArbol usa el máximo LastWriteTime de los
        # archivos, no el de la carpeta.
        function New-CarpetaConEdad {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Solo crea una carpeta de prueba en una ruta temporal propia.')]
            [CmdletBinding()]
            param([string] $Ruta, [int] $Dias, [string] $Archivo = 'datos.dat')

            New-Item -ItemType Directory -Path $Ruta -Force | Out-Null
            $completa = Join-Path $Ruta $Archivo
            Set-Content -LiteralPath $completa -Value ('x' * 2048) -NoNewline
            (Get-Item -LiteralPath $completa).LastWriteTime = (Get-Date).AddDays(-$Dias)
        }

        # ---- Sí son restos (deben aparecer) ---------------------------
        New-CarpetaConEdad (Join-Path (Join-Path $zonas.LocalLow 'UnityGameStudios') 'Cosmic Drift') 400
        New-CarpetaConEdad (Join-Path (Join-Path $zonas.Roaming 'Ubisoft') 'Bandera Roja') 400
        New-CarpetaConEdad (Join-Path $zonas.Local 'EA Games') 400
        New-CarpetaConEdad (Join-Path $zonas.Local 'Warframe Launcher') 400
        New-CarpetaConEdad (Join-Path $zonas.Local 'PowerDVD Cache') 400
        New-CarpetaConEdad (Join-Path $zonas.Local 'Presets Antiguos') 400

        # ---- NO son restos (no deben aparecer) ------------------------
        New-CarpetaConEdad (Join-Path $zonas.Local 'Cachivache Instalado') 400
        New-CarpetaConEdad (Join-Path (Join-Path $zonas.Roaming 'Ubisoft') 'Ubisoft Game Launcher') 400
        New-CarpetaConEdad (Join-Path $zonas.Local 'Programa Reciente') 2
        New-CarpetaConEdad (Join-Path $zonas.Local 'Microsoft') 400
        New-CarpetaConEdad (Join-Path $zonas.Local 'Bitdefender Restos') 400
        New-CarpetaConEdad (Join-Path $zonas.Datos 'Copias') 400

        # ---- Caso especial: resto CON partidas guardadas dentro -------
        # Debe aparecer, pero con aviso y sin premarcar (lo garantiza
        # New-Candidato).
        $conPartidas = Join-Path $zonas.Local 'Mi Juego Retro'
        New-CarpetaConEdad (Join-Path $conPartidas 'saves') 400 'partida01.sav'

        return $zonas
    }
}

Describe 'Banco de deteccion de restos de programas' {

    BeforeAll {
        $script:Temporal = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-restos-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temporal -Force | Out-Null
        $script:Zonas = New-ArbolDeRestos -Raiz $script:Temporal

        # El módulo lee las zonas de las variables de entorno: se apuntan
        # al árbol falso y se restauran en el AfterAll.
        $script:EntornoOriginal = @{
            LOCALAPPDATA = $env:LOCALAPPDATA
            APPDATA      = $env:APPDATA
            ProgramData  = $env:ProgramData
            USERPROFILE  = $env:USERPROFILE
        }
        $env:LOCALAPPDATA = $script:Zonas.Local
        $env:APPDATA      = $script:Zonas.Roaming
        $env:ProgramData  = $script:Zonas.Datos
        $env:USERPROFILE  = $script:Temporal

        # La guardia se inicializa después de sustituir el entorno: su
        # lista negra se construye a partir de esas variables.
        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio = ''; Documentos = ''; Descargas = ''
            Imagenes   = ''; Musica     = ''; Videos     = ''
            CarpetaDatos = ''
        })

        $script:Modulo = Get-ModuloLimpieza -Id 'restos' -Raiz $script:Raiz
        $script:Configuracion = [pscustomobject]@{
            MinimoMB   = 0
            DiasSinUso = 180
            Admin      = $true
        }
    }

    AfterAll {
        foreach ($clave in $script:EntornoOriginal.Keys) {
            Set-Item -Path "env:$clave" -Value $script:EntornoOriginal[$clave] -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $script:Temporal -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-TokensProgramasInstalados { New-VocabularioDePrueba }

        $resultado = Invoke-ModuloLimpieza -Modulo $script:Modulo `
                                           -Configuracion $script:Configuracion `
                                           -Sync (New-EstadoSincronizado)
        $script:Nombres = @($resultado.Candidatos | ForEach-Object { $_.Nombre })
        $script:Candidatos = $resultado.Candidatos

        # Se comprueba por ruta y no por nombre: proponer
        # "LocalLow\UnityGameStudios" entero cubre "Cosmic Drift" (menos
        # elementos, más bytes). Un candidato cubre una ruta si es esa ruta
        # o un antepasado suyo.
        $script:Cubre = {
            param([string] $Objetivo)
            foreach ($c in $script:Candidatos) {
                if ($Objetivo.Equals($c.Ruta, [StringComparison]::OrdinalIgnoreCase)) { return $true }
                if ($Objetivo.StartsWith($c.Ruta.TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar,
                                         [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
        }
    }

    Context 'Lo que SI es un resto y debe aparecer' {

        It 'encuentra <Que>' -ForEach @(
            @{ Que = 'el juego de Unity en LocalLow'
               Ruta = @('AppData', 'LocalLow', 'UnityGameStudios', 'Cosmic Drift')
               Porque = 'AppData\LocalLow es donde deja sus datos todo juego de Unity, y hay que recorrerlo' }
            @{ Que = 'el juego bajo un editor instalado'
               Ruta = @('AppData', 'Roaming', 'Ubisoft', 'Bandera Roja')
               Porque = 'está a profundidad 2 bajo un editor que sigue instalado: no basta con mirar el primer nivel' }
            @{ Que = 'la carpeta que contiene "games"'
               Ruta = @('AppData', 'Local', 'EA Games')
               Porque = '"games" es un token débil y no debe casar por subcadena con un programa instalado' }
            @{ Que = 'la carpeta que contiene "launcher"'
               Ruta = @('AppData', 'Local', 'Warframe Launcher')
               Porque = '"launcher" es un token débil' }
            @{ Que = 'la carpeta que contiene "power"'
               Ruta = @('AppData', 'Local', 'PowerDVD Cache')
               Porque = '"power" viene de un servicio y no dice nada sobre PowerDVD' }
            @{ Que = 'la carpeta que contiene "eset"'
               Ruta = @('AppData', 'Local', 'Presets Antiguos')
               Porque = '"eset" está dentro de "Presets" y Test-NombreSensible no debe casar por subcadena' }
        ) {
            $objetivo = $script:Temporal
            foreach ($segmento in $Ruta) { $objetivo = Join-Path $objetivo $segmento }
            (& $script:Cubre $objetivo) | Should -BeTrue -Because $Porque
        }
    }

    Context 'Lo que NO es un resto y no debe aparecer' {

        It 'no propone "<Nombre>"' -ForEach @(
            @{ Nombre = 'Cachivache Instalado'
               Porque = 'coincide exactamente con un programa instalado' }
            @{ Nombre = 'Ubisoft Game Launcher'
               Porque = 'esta instalado, aunque cuelgue de un editor cuyas otras carpetas si son restos' }
            @{ Nombre = 'Programa Reciente'
               Porque = 'se toco hace dos dias y no llega al umbral de dias sin uso' }
            @{ Nombre = 'Microsoft'
               Porque = 'esta en la lista de carpetas protegidas del sistema' }
            @{ Nombre = 'Bitdefender Restos'
               Porque = 'lleva el nombre de un antivirus y la guardia veta los nombres sensibles' }
            @{ Nombre = 'Copias'
               Porque = 'es una carpeta de copias de seguridad' }
        ) {
            $script:Nombres | Should -Not -Contain $Nombre -Because $Porque
        }
    }

    Context 'Invariante: nada con partidas guardadas se premarca' {

        It 'propone la carpeta con partidas pero con aviso' {
            $candidato = $script:Candidatos | Where-Object { $_.Nombre -eq 'Mi Juego Retro' }
            $candidato | Should -Not -BeNullOrEmpty
            $candidato.Aviso | Should -Not -BeNullOrEmpty -Because 'contiene una subcarpeta saves con una partida dentro'
        }

        It 'no premarca ningun candidato que lleve aviso' {
            foreach ($candidato in $script:Candidatos) {
                if (-not [string]::IsNullOrWhiteSpace($candidato.Aviso)) {
                    $candidato.Seleccionado | Should -BeFalse -Because "el candidato $($candidato.Nombre) lleva aviso"
                }
            }
        }
    }

    Context 'Metrica del banco' {

        It 'acierta los doce casos' {
            # La coma delante de cada elemento evita que PowerShell aplane
            # el array de arrays.
            $debenAparecer = @(
                ,@('AppData', 'LocalLow', 'UnityGameStudios', 'Cosmic Drift')
                ,@('AppData', 'Roaming', 'Ubisoft', 'Bandera Roja')
                ,@('AppData', 'Local', 'EA Games')
                ,@('AppData', 'Local', 'Warframe Launcher')
                ,@('AppData', 'Local', 'PowerDVD Cache')
                ,@('AppData', 'Local', 'Presets Antiguos')
            )
            $noDebenAparecer = @('Cachivache Instalado', 'Ubisoft Game Launcher',
                                 'Programa Reciente', 'Microsoft', 'Bitdefender Restos', 'Copias')

            $fallos = @()
            foreach ($partes in $debenAparecer) {
                $objetivo = $script:Temporal
                foreach ($segmento in $partes) { $objetivo = Join-Path $objetivo $segmento }
                if (-not (& $script:Cubre $objetivo)) { $fallos += "no encuentra $($partes[-1])" }
            }
            foreach ($n in $noDebenAparecer) {
                if ($script:Nombres -contains $n) { $fallos += "propone $n" }
            }

            $fallos -join '; ' | Should -BeNullOrEmpty
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
