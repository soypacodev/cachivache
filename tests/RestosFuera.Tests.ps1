<#
    Pruebas de los dos módulos que buscan restos fuera de AppData:
    32-RestosRegistro y 37-AppsUWP. Se centran en lo que puede fallar en
    silencio.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Pester no puede simular un comando inexistente, y Get-AppxPackage
    # solo existe en Windows con el módulo Appx: se declara un sustituto
    # vacío cuando falta.
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        Set-Item -Path 'function:script:Get-AppxPackage' -Value { @() }
    }

    function New-CarpetaCon {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo crea carpetas de prueba en una ruta temporal propia.')]
        [CmdletBinding()]
        param([string] $Ruta, [int] $Kb = 2048)

        New-Item -ItemType Directory -Path $Ruta -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Ruta 'datos.bin') -Value ('x' * ($Kb * 1024)) -NoNewline
    }

    function Invoke-ModuloDePrueba {
        [CmdletBinding()]
        param([string] $Id, [int] $MinimoMB = 0, [int] $DiasSinUso = 0)

        $modulo = Get-ModuloLimpieza -Id $Id -Raiz $script:Raiz
        return Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
               -Configuracion ([pscustomobject]@{
                   MinimoMB = $MinimoMB; DiasSinUso = $DiasSinUso
                   Admin = $true; IncluirMenores = $true
               })
    }
}

Describe 'Versiones antiguas de aplicaciones Electron' {

    BeforeAll {
        $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-electron-' + [guid]::NewGuid())
        $local = Join-Path $script:Temp 'Local'

        # Discord con tres versiones: ordenadas como texto, "app-1.0.10" va
        # antes que "app-1.0.9" y se propondría borrar la que está en uso.
        New-CarpetaCon (Join-Path (Join-Path $local 'Discord') 'app-1.0.9')
        New-CarpetaCon (Join-Path (Join-Path $local 'Discord') 'app-1.0.10')
        New-CarpetaCon (Join-Path (Join-Path $local 'Discord') 'app-1.0.8')

        # Una aplicación con una sola versión: no sobra nada.
        New-CarpetaCon (Join-Path (Join-Path $local 'Slack') 'app-4.29.149')

        $script:Original = @{ LA = $env:LOCALAPPDATA; RA = $env:APPDATA; PF = $env:ProgramFiles
                              PFX = ${env:ProgramFiles(x86)}; SD = $env:SystemDrive; PD = $env:ProgramData }
        $env:LOCALAPPDATA = $local
        $env:APPDATA      = Join-Path $script:Temp 'Roaming'
        $env:ProgramFiles = Join-Path $script:Temp 'SinNada'
        ${env:ProgramFiles(x86)} = Join-Path $script:Temp 'SinNada'
        $env:SystemDrive  = Join-Path $script:Temp 'SinNada'
        $env:ProgramData  = Join-Path $script:Temp 'SinNada'
        New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null

        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio = ''; Documentos = ''; Descargas = ''
            Imagenes = ''; Musica = ''; Videos = ''; CarpetaDatos = ''
        })

        $resultado = Invoke-ModuloDePrueba -Id 'restosregistro'
        $script:Nombres = @($resultado.Candidatos | ForEach-Object { $_.Nombre })
        $script:Error   = $resultado.Error
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:Original.LA
        $env:APPDATA      = $script:Original.RA
        $env:ProgramFiles = $script:Original.PF
        ${env:ProgramFiles(x86)} = $script:Original.PFX
        $env:SystemDrive  = $script:Original.SD
        $env:ProgramData  = $script:Original.PD
        Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'el modulo se ejecuta sin errores' {
        $script:Error | Should -BeNullOrEmpty
    }

    It 'propone las dos versiones antiguas de Discord' {
        $script:Nombres | Should -Contain 'Discord - app-1.0.8'
        $script:Nombres | Should -Contain 'Discord - app-1.0.9'
    }

    It 'CONSERVA la 1.0.10, que es la mas nueva aunque ordenada como texto no lo parezca' {
        $script:Nombres | Should -Not -Contain 'Discord - app-1.0.10' -Because (
            'comparadas como cadenas "1.0.10" va antes que "1.0.9", y se propondria borrar la version en uso')
    }

    It 'no toca una aplicacion con una sola version' {
        ($script:Nombres | Where-Object { $_ -like 'Slack*' }).Count |
            Should -Be 0 -Because 'la unica version que hay es la que se esta usando'
    }
}

Describe 'Aplicaciones de la Store: sin lista de instaladas no se declara nada huerfano' {

    <#
        Get-AppxPackage no existe fuera de Windows y en algunos equipos
        falla. Tratar "lista vacía" como "nada instalado" propondría borrar
        los datos de todas las aplicaciones de la Store.
    #>

    BeforeAll {
        $script:Temp2 = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-uwp-' + [guid]::NewGuid())
        $local = Join-Path $script:Temp2 'Local'
        $paquetes = Join-Path $local 'Packages'

        New-CarpetaCon (Join-Path (Join-Path $paquetes 'Empresa.AplicacionViva_abc123') 'LocalState')
        New-CarpetaCon (Join-Path (Join-Path $paquetes 'Empresa.AplicacionViva_abc123') 'LocalCache') -Kb 6144
        New-CarpetaCon (Join-Path (Join-Path $paquetes 'Empresa.AplicacionMuerta_xyz789') 'LocalState')

        $script:LaOriginal = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $local

        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio = ''; Documentos = ''; Descargas = ''
            Imagenes = ''; Musica = ''; Videos = ''; CarpetaDatos = ''
        })
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:LaOriginal
        Remove-Item -LiteralPath $script:Temp2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Get-AppxPackage no responde' {

        BeforeAll {
            Mock Get-AppxPackage { @() }
            $r = Invoke-ModuloDePrueba -Id 'appsuwp'
            $script:SinLista = @($r.Candidatos)
        }

        It 'no propone ninguna carpeta de paquete entera' {
            @($script:SinLista | Where-Object { $_.Categoria -eq 'Aplicaciones de la Store desinstaladas' }).Count |
                Should -Be 0 -Because 'sin saber que hay instalado, todo paquete pareceria huerfano'
        }

        It 'pero si limpia las cachés internas, que son seguras se mire como se mire' {
            @($script:SinLista | Where-Object { $_.Categoria -eq 'Cachés de aplicaciones de la Store' }).Count |
                Should -BeGreaterThan 0
        }
    }

    Context 'Get-AppxPackage responde' {

        BeforeAll {
            Mock Get-AppxPackage {
                [pscustomobject]@{ PackageFamilyName = 'Empresa.AplicacionViva_abc123' }
            }
            $r = Invoke-ModuloDePrueba -Id 'appsuwp'
            $script:ConLista = @($r.Candidatos)
            $script:NombresUwp = @($script:ConLista | ForEach-Object { $_.Nombre })
        }

        It 'propone el paquete que ya no esta instalado' {
            $script:NombresUwp | Should -Contain 'Empresa.AplicacionMuerta_xyz789'
        }

        It 'NO propone la carpeta de la aplicacion instalada' {
            $script:NombresUwp | Should -Not -Contain 'Empresa.AplicacionViva_abc123'
        }

        It 'el paquete huerfano lleva aviso y no va marcado' {
            $c = $script:ConLista | Where-Object { $_.Nombre -eq 'Empresa.AplicacionMuerta_xyz789' }
            $c.Aviso        | Should -Not -BeNullOrEmpty -Because 'LocalState puede guardar datos del usuario'
            $c.Seleccionado | Should -BeFalse
        }

        It 'de la aplicacion viva solo se propone su cache, nunca LocalState' {
            $suyos = @($script:ConLista | Where-Object { $_.Nombre -like 'Empresa.AplicacionViva*' })
            $suyos.Count | Should -BeGreaterThan 0
            foreach ($c in $suyos) {
                $c.Nombre | Should -Not -Match 'LocalState' -Because 'ahi viven los datos de la aplicacion'
                $c.Metodo | Should -Be 'Contenido'
            }
        }
    }
}

Describe 'Entradas de desinstalacion fantasma: solo informan' {

    It 'el modulo nunca escribe en el registro' {
        # Comprobación estructural sobre el AST: ningún comando de
        # escritura en el registro puede aparecer en el archivo.
        $ruta = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Modules') '32-RestosRegistro.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
        $comandos = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                      ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

        foreach ($prohibido in @('Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
                                 'Remove-Item', 'New-Item', 'Set-Item')) {
            $comandos | Should -Not -Contain $prohibido -Because 'el programa no escribe jamas en el registro de Windows'
        }
    }

    It 'el candidato de entradas fantasma es informativo por construccion' {
        $ruta = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Modules') '32-RestosRegistro.ps1'
        $texto = Get-Content -LiteralPath $ruta -Raw
        $bloque = $texto.Substring($texto.IndexOf('Entradas de desinstalación fantasma'))
        $bloque | Should -Match "Metodo 'Informativo'"
    }
}

Describe 'Huerfanos de Archivos de programa: carpetas protegidas' {

    BeforeAll {
        $script:EntornoPf = @{ LA = $env:LOCALAPPDATA; RA = $env:APPDATA; PF = $env:ProgramFiles
                               PFX = ${env:ProgramFiles(x86)}; SD = $env:SystemDrive; PD = $env:ProgramData }
        $script:pfTemp   = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-pf-' + [guid]::NewGuid())
        $script:pfPrueba = Join-Path $script:pfTemp 'ProgramFiles'
        New-CarpetaCon (Join-Path $script:pfPrueba 'Application Verifier')
        New-CarpetaCon (Join-Path $script:pfPrueba 'Herramienta Olvidada')
        $vacia = Join-Path $script:pfTemp 'SinNada'
        New-Item -ItemType Directory -Path $vacia -Force | Out-Null
        $env:ProgramFiles = $script:pfPrueba
        ${env:ProgramFiles(x86)} = $null
        $env:LOCALAPPDATA = $vacia
        $env:APPDATA      = $vacia
        $env:SystemDrive  = $vacia
        $env:ProgramData  = $vacia
        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio = ''; Documentos = ''; Descargas = ''
            Imagenes = ''; Musica = ''; Videos = ''; CarpetaDatos = ''
        })

        Mock Get-TokensProgramasInstalados { New-VocabularioInstalado }
        $r = Invoke-ModuloDePrueba -Id 'restosregistro'
        $script:NombresPf = @($r.Candidatos |
            Where-Object { $_.Categoria -eq 'Huérfanos de Archivos de programa' } |
            ForEach-Object { $_.Nombre })
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:EntornoPf.LA; $env:APPDATA = $script:EntornoPf.RA
        $env:ProgramFiles = $script:EntornoPf.PF; ${env:ProgramFiles(x86)} = $script:EntornoPf.PFX
        $env:SystemDrive  = $script:EntornoPf.SD; $env:ProgramData = $script:EntornoPf.PD
        Remove-Item -LiteralPath $script:pfTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'propone una carpeta sin nada que la respalde (control)' {
        $script:NombresPf | Should -Contain 'Herramienta Olvidada'
    }

    It 'no propone "Application Verifier", que esta en la lista de protegidas' {
        $script:NombresPf | Should -Not -Contain 'Application Verifier'
    }

    It 'cada entrada de la lista de protegidas es ya un token' {
        # Se compara contra ConvertTo-Token del nombre de carpeta: una entrada
        # con espacios, mayusculas o simbolos nunca casaria.
        $ruta = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Modules') '32-RestosRegistro.ps1'
        $texto = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8
        $bloque = [regex]::Match($texto, '(?s)\$protegidas\s*=\s*@\((.*?)\)').Groups[1].Value
        $entradas = @([regex]::Matches($bloque, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })
        $entradas.Count | Should -BeGreaterThan 0
        foreach ($entrada in $entradas) {
            ConvertTo-Token $entrada | Should -BeExactly $entrada
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
