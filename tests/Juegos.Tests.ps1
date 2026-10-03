<#
    Pruebas del módulo de juegos (33-Juegos.ps1).

    Se monta una instalación de Steam sintética (libraryfolders.vdf,
    appmanifest y una segunda biblioteca) y se comprueba que el módulo
    distingue:

      * basura regenerable, que se propone marcada;
      * instalaciones que Steam ya no reconoce, que se proponen sin marcar;
      * partidas guardadas, que nunca se proponen para borrar.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    function New-ArchivoDe {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo crea archivos de prueba en una ruta temporal propia.')]
        [CmdletBinding()]
        param([string] $Ruta, [int] $Kb = 4, [string] $Texto = $null)

        $carpeta = Split-Path $Ruta -Parent
        if (-not (Test-Path -LiteralPath $carpeta)) {
            New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        }
        $contenido = if ($Texto) { $Texto } else { 'x' * ($Kb * 1024) }
        Set-Content -LiteralPath $Ruta -Value $contenido -NoNewline
    }

    function New-SteamDePrueba {
        <#
        .SYNOPSIS
            Instalación de Steam sintética con dos bibliotecas.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo crea un arbol de prueba en una ruta temporal propia.')]
        [CmdletBinding()]
        param([Parameter(Mandatory)] [string] $Raiz)

        $steam    = Join-Path (Join-Path $Raiz 'ProgramFilesX86') 'Steam'
        $apps     = Join-Path $steam 'steamapps'
        $segunda  = Join-Path $Raiz 'SegundaBiblioteca'
        $apps2    = Join-Path $segunda 'steamapps'

        # --- libraryfolders.vdf: declara la segunda biblioteca ---------
        # Las barras van escapadas, como en el archivo real de Valve.
        $vdf = @"
"libraryfolders"
{
    "0"
    {
        "path"        "$($steam -replace '\\', '\\')"
    }
    "1"
    {
        "path"        "$($segunda -replace '\\', '\\')"
    }
}
"@
        New-ArchivoDe -Ruta (Join-Path $apps 'libraryfolders.vdf') -Texto $vdf

        # --- Biblioteca principal --------------------------------------
        # Un juego instalado de verdad, con su manifiesto.
        New-ArchivoDe -Ruta (Join-Path $apps 'appmanifest_620.acf') -Texto @'
"AppState"
{
    "appid"        "620"
    "installdir"        "Portal 2"
}
'@
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $apps 'common') 'Portal 2') 'juego.bin') -Kb 200

        # Un juego que Steam ya NO reconoce: sin manifiesto.
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $apps 'common') 'Juego Fantasma') 'datos.bin') -Kb 400

        # Basura regenerable.
        New-ArchivoDe -Ruta (Join-Path (Join-Path $apps 'downloading') 'trozo.tmp') -Kb 1500
        New-ArchivoDe -Ruta (Join-Path (Join-Path $apps 'temp') 'algo.tmp') -Kb 1500

        # Sombreadores: uno del juego instalado, otro de uno que ya no esta.
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $apps 'shadercache') '620') 'sh.bin') -Kb 100
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $apps 'shadercache') '999999') 'sh.bin') -Kb 500

        # Taller: contenido de un juego desinstalado.
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path (Join-Path $apps 'workshop') 'content') '888888') 'mod.bin') -Kb 250

        # --- Segunda biblioteca ----------------------------------------
        New-ArchivoDe -Ruta (Join-Path $apps2 'appmanifest_400.acf') -Texto @'
"AppState"
{
    "appid"        "400"
    "installdir"        "Portal"
}
'@
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $apps2 'common') 'Portal') 'juego.bin') -Kb 150
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $apps2 'common') 'Otro Fantasma') 'datos.bin') -Kb 350

        return [pscustomobject]@{
            ProgramFilesX86 = Join-Path $Raiz 'ProgramFilesX86'
            Apps            = $apps
            Apps2           = $apps2
        }
    }
}

Describe 'Modulo de juegos: Steam' {

    BeforeAll {
        $script:Temporal = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-juegos-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Temporal -Force | Out-Null
        $script:Steam = New-SteamDePrueba -Raiz $script:Temporal

        $script:EntornoOriginal = @{
            PFX86       = ${env:ProgramFiles(x86)}
            PF          = $env:ProgramFiles
            LOCALAPPDATA = $env:LOCALAPPDATA
            APPDATA      = $env:APPDATA
            ProgramData  = $env:ProgramData
            USERPROFILE  = $env:USERPROFILE
        }
        ${env:ProgramFiles(x86)} = $script:Steam.ProgramFilesX86
        $env:ProgramFiles        = Join-Path $script:Temporal 'ProgramFiles'
        $env:LOCALAPPDATA        = Join-Path $script:Temporal 'Local'
        $env:APPDATA             = Join-Path $script:Temporal 'Roaming'
        $env:ProgramData         = Join-Path $script:Temporal 'ProgramData'
        $env:USERPROFILE         = Join-Path $script:Temporal 'Perfil'
        foreach ($z in @($env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, $env:USERPROFILE)) {
            New-Item -ItemType Directory -Path $z -Force | Out-Null
        }

        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio = ''; Documentos = ''; Descargas = ''
            Imagenes   = ''; Musica     = ''; Videos     = ''
            CarpetaDatos = ''
        })

        # En un equipo con Steam instalado, el registro apuntaría a la
        # instalación real en vez de a la de prueba.
        Mock Get-ItemProperty { $null } -ParameterFilter { $Path -eq 'HKCU:\SOFTWARE\Valve\Steam' }

        $modulo = Get-ModuloLimpieza -Id 'juegos' -Raiz $script:Raiz
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
                     -Configuracion ([pscustomobject]@{
                         MinimoMB = 0; DiasSinUso = 0; Admin = $true; IncluirMenores = $true
                     })

        $script:Candidatos = @($resultado.Candidatos)
        $script:Nombres    = @($script:Candidatos | ForEach-Object { $_.Nombre })
        $script:Error      = $resultado.Error
    }

    AfterAll {
        ${env:ProgramFiles(x86)} = $script:EntornoOriginal.PFX86
        $env:ProgramFiles        = $script:EntornoOriginal.PF
        $env:LOCALAPPDATA        = $script:EntornoOriginal.LOCALAPPDATA
        $env:APPDATA             = $script:EntornoOriginal.APPDATA
        $env:ProgramData         = $script:EntornoOriginal.ProgramData
        $env:USERPROFILE         = $script:EntornoOriginal.USERPROFILE
        Remove-Item -LiteralPath $script:Temporal -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'el modulo se ejecuta sin errores' {
        $script:Error | Should -BeNullOrEmpty
    }

    Context 'Lee las bibliotecas del VDF' {

        It 'encuentra la biblioteca principal y la segunda' {
            $rutas = @($script:Candidatos | ForEach-Object { $_.Ruta })
            ($rutas | Where-Object { $_ -like "$($script:Steam.Apps)*" }).Count |
                Should -BeGreaterThan 0 -Because 'la biblioteca principal tiene candidatos'
            ($rutas | Where-Object { $_ -like "$($script:Steam.Apps2)*" }).Count |
                Should -BeGreaterThan 0 -Because 'la segunda biblioteca esta declarada en libraryfolders.vdf'
        }
    }

    Context 'Juegos que Steam ya no reconoce' {

        It 'propone el juego sin manifiesto' {
            $script:Nombres | Should -Contain 'Juego Fantasma'
        }

        It 'propone tambien el de la segunda biblioteca' {
            $script:Nombres | Should -Contain 'Otro Fantasma'
        }

        It 'NO propone los juegos que si tienen manifiesto' {
            $script:Nombres | Should -Not -Contain 'Portal 2'
            $script:Nombres | Should -Not -Contain 'Portal'
        }

        It 'no los premarca: borrar una instalacion es una decision del usuario' {
            foreach ($nombre in @('Juego Fantasma', 'Otro Fantasma')) {
                $c = $script:Candidatos | Where-Object { $_.Nombre -eq $nombre }
                $c.Seleccionado | Should -BeFalse -Because "$nombre son decenas de GB pero puede ser una copia manual"
                $c.Riesgo       | Should -Be 'Medio'
            }
        }
    }

    Context 'Sombreadores y taller por identificador de juego' {

        It 'propone el sombreador del juego que ya no esta (999999)' {
            ($script:Nombres | Where-Object { $_ -match '999999' }).Count | Should -BeGreaterThan 0
        }

        It 'NO propone el sombreador del juego instalado (620)' {
            ($script:Nombres | Where-Object { $_ -match '\b620\b' }).Count | Should -Be 0
        }

        It 'propone el contenido del taller huerfano, pero con aviso' {
            $c = $script:Candidatos | Where-Object { $_.Nombre -match '888888' }
            $c | Should -Not -BeNullOrEmpty
            $c.Aviso        | Should -Not -BeNullOrEmpty -Because 'son mods descargados'
            $c.Seleccionado | Should -BeFalse
        }
    }

    Context 'Basura regenerable' {

        It 'propone las descargas a medias y los temporales' {
            $script:Nombres | Should -Contain 'Descargas de Steam a medias'
            $script:Nombres | Should -Contain 'Temporales de Steam'
        }

        It 'esa si va marcada: la plataforma la vuelve a crear sola' {
            $c = $script:Candidatos | Where-Object { $_.Nombre -eq 'Descargas de Steam a medias' }
            $c.Riesgo       | Should -Be 'Bajo'
            $c.Seleccionado | Should -BeTrue
        }
    }
}

Describe 'Modulo de juegos: sin manifiestos no se declara nada huerfano' {

    <#
        Si Steam aún no ha escrito los manifiestos, o la carpeta no es una
        biblioteca real, "todo lo de common sin manifiesto" sería la
        colección entera del usuario.
    #>

    BeforeAll {
        $script:Temp2 = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-juegos2-' + [guid]::NewGuid())
        $apps = Join-Path (Join-Path (Join-Path $script:Temp2 'ProgramFilesX86') 'Steam') 'steamapps'
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $apps 'common') 'Un Juego Carisimo') 'datos.bin') -Kb 500

        $script:Pfx86Original = ${env:ProgramFiles(x86)}
        ${env:ProgramFiles(x86)} = Join-Path $script:Temp2 'ProgramFilesX86'

        $modulo = Get-ModuloLimpieza -Id 'juegos' -Raiz $script:Raiz
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
                     -Configuracion ([pscustomobject]@{
                         MinimoMB = 0; DiasSinUso = 0; Admin = $true; IncluirMenores = $true
                     })
        $script:Nombres2 = @($resultado.Candidatos | ForEach-Object { $_.Nombre })
    }

    AfterAll {
        ${env:ProgramFiles(x86)} = $script:Pfx86Original
        Remove-Item -LiteralPath $script:Temp2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'no propone ningun juego si no hay ni un solo manifiesto' {
        $script:Nombres2 | Should -Not -Contain 'Un Juego Carisimo' -Because (
            'sin manifiestos no se puede afirmar que Steam no reconozca el juego, ' +
            'y equivocarse aqui seria proponer borrar la coleccion entera')
    }
}

Describe 'Modulo de juegos: las partidas guardadas no se proponen para borrar' {

    BeforeAll {
        $script:Temp3 = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-juegos3-' + [guid]::NewGuid())
        $perfil = Join-Path $script:Temp3 'Perfil'
        $guardadas = Join-Path $perfil 'Saved Games'

        New-ArchivoDe -Ruta (Join-Path (Join-Path $guardadas 'Juego Con Partidas') 'partida01.sav') -Kb 300
        New-ArchivoDe -Ruta (Join-Path (Join-Path (Join-Path $guardadas 'Juego Con Partidas') 'Logs') 'motor.log') -Kb 2048

        $script:UpOriginal = $env:USERPROFILE
        $env:USERPROFILE = $perfil

        $modulo = Get-ModuloLimpieza -Id 'juegos' -Raiz $script:Raiz
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
                     -Configuracion ([pscustomobject]@{
                         MinimoMB = 0; DiasSinUso = 0; Admin = $true; IncluirMenores = $true
                     })
        $script:Candidatos3 = @($resultado.Candidatos)
    }

    AfterAll {
        $env:USERPROFILE = $script:UpOriginal
        Remove-Item -LiteralPath $script:Temp3 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'la carpeta del juego se informa, pero no se puede borrar' {
        $c = $script:Candidatos3 | Where-Object { $_.Nombre -eq 'Juego Con Partidas' }
        $c | Should -Not -BeNullOrEmpty -Because 'el usuario quiere saber lo que ocupa'
        $c.Metodo       | Should -Be 'Informativo' -Because 'ahi viven las partidas'
        $c.Seleccionado | Should -BeFalse
    }

    It 'sus registros internos si se proponen, y marcados' {
        $c = $script:Candidatos3 | Where-Object { $_.Nombre -eq 'Juego Con Partidas - Logs' }
        $c | Should -Not -BeNullOrEmpty
        $c.Metodo       | Should -Be 'Contenido' -Because 'se vacia el contenido y la carpeta se queda'
        $c.Riesgo       | Should -Be 'Bajo'
        $c.Seleccionado | Should -BeTrue
    }

    It 'ningun candidato de partidas usa un metodo que borre la carpeta' {
        foreach ($c in @($script:Candidatos3 | Where-Object { $_.Categoria -eq 'Partidas guardadas' })) {
            $c.Metodo | Should -Be 'Informativo'
        }
    }
}

Describe 'Get-ValorVdf' {

    It 'lee un valor y desescapa las barras' {
        $ruta = Join-Path ([IO.Path]::GetTempPath()) ('vdf-' + [guid]::NewGuid() + '.vdf')
        Set-Content -LiteralPath $ruta -Value '"path"        "D:\\Juegos\\Steam"' -NoNewline
        try {
            Get-ValorVdf -Ruta $ruta -Clave 'path' | Should -Be 'D:\Juegos\Steam'
        } finally {
            Remove-Item -LiteralPath $ruta -Force -ErrorAction SilentlyContinue
        }
    }

    It 'devuelve vacio si el archivo no existe, sin lanzar' {
        { Get-ValorVdf -Ruta 'C:\no\existe\nada.vdf' -Clave 'path' } | Should -Not -Throw
        @(Get-ValorVdf -Ruta 'C:\no\existe\nada.vdf' -Clave 'path').Count | Should -Be 0
    }
}

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
}
