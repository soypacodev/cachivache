<#
    Pruebas del módulo de duplicados con zonas de usuario solapadas. El
    caso real es OneDrive con Known Folder Move, donde "OneDrive" y
    "OneDrive\Escritorio" conviven como zonas: un archivo indexado dos
    veces no debe tomarse por una copia de sí mismo.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio   = ''
        Documentos   = ''
        Descargas    = ''
        Imagenes     = ''
        Musica       = ''
        Videos       = ''
        CarpetaDatos = ''
    })

    $script:ModuloDuplicados = Get-ModuloLimpieza -Id 'duplicados' -Raiz $script:Raiz
    $script:ModuloDuplicados | Should -Not -BeNullOrEmpty
}

Describe 'Modulo duplicados: zonas solapadas' {

    BeforeEach {
        # Fuera de la carpeta temporal, que en Windows cuelga de AppData
        # (ver el Describe de enlaces duros).
        $script:carpetaPrueba = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'pruebas') `
                                          ('tmp-dup-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:carpetaPrueba -Force | Out-Null

        $script:sync = New-EstadoSincronizado
        $script:configuracionBase = [pscustomobject]@{
            MinimoDuplicadoMB = 0
            ZonasUsuario      = @()
            Admin             = $true
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:carpetaPrueba -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'NO propone borrar un archivo consigo mismo cuando dos zonas se anidan' {
        # Simula OneDrive con Known Folder Move: dos zonas de usuario, una
        # dentro de la otra.
        $oneDrive           = Join-Path $script:carpetaPrueba 'OneDrive'
        $oneDriveEscritorio = Join-Path $oneDrive 'Escritorio'
        New-Item -ItemType Directory -Path $oneDriveEscritorio -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $oneDriveEscritorio 'foto.jpg') -Value ('x' * 500) -NoNewline

        $configuracion = $script:configuracionBase
        $configuracion.ZonasUsuario = @($oneDrive, $oneDriveEscritorio)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:ModuloDuplicados -Configuracion $configuracion -Sync $script:sync

        $resultado.Error | Should -BeNullOrEmpty
        $resultado.Candidatos.Count | Should -Be 0 -Because 'el archivo se ha visto dos veces por culpa del anidamiento, pero es el mismo archivo'
    }

    It 'SIGUE detectando duplicados reales entre dos zonas independientes (no anidadas)' {
        $zonaA = Join-Path $script:carpetaPrueba 'ZonaA'
        $zonaB = Join-Path $script:carpetaPrueba 'ZonaB'
        New-Item -ItemType Directory -Path $zonaA -Force | Out-Null
        New-Item -ItemType Directory -Path $zonaB -Force | Out-Null

        # Mismo contenido y tamaño, dos archivos distintos.
        Set-Content -LiteralPath (Join-Path $zonaA 'original.jpg') -Value ('y' * 500) -NoNewline
        Start-Sleep -Milliseconds 50
        Set-Content -LiteralPath (Join-Path $zonaB 'copia.jpg') -Value ('y' * 500) -NoNewline

        $configuracion = $script:configuracionBase
        $configuracion.ZonasUsuario = @($zonaA, $zonaB)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:ModuloDuplicados -Configuracion $configuracion -Sync $script:sync

        $resultado.Error | Should -BeNullOrEmpty
        $resultado.Candidatos.Count | Should -Be 1 -Because 'son dos archivos distintos con el mismo contenido: uno es un duplicado real'
        $resultado.Candidatos[0].Ruta | Should -Be (Join-Path $zonaB 'copia.jpg') -Because 'se conserva el mas antiguo (original.jpg) y se propone el mas nuevo'
    }
}

Describe 'Select-RutasNoAnidadas' {

    It 'descarta una ruta que cuelga de otra de la lista' {
        $resultado = Select-RutasNoAnidadas @('C:\Users\x\OneDrive', 'C:\Users\x\OneDrive\Escritorio')
        @($resultado) | Should -Be @('C:\Users\x\OneDrive')
    }

    It 'ignora entradas nulas o vacias en vez de lanzar' {
        $resultado = @(Select-RutasNoAnidadas @($null, '', '   ', 'C:\Users\x\OneDrive', 'C:\Users\x\OneDrive\Escritorio'))
        $resultado | Should -Be @('C:\Users\x\OneDrive')
        @(Select-RutasNoAnidadas $null).Count | Should -Be 0
    }

    It 'conserva rutas independientes' {
        $resultado = @(Select-RutasNoAnidadas @('C:\Users\x\Documentos', 'C:\Users\x\Descargas'))
        $resultado.Count | Should -Be 2
    }

    It 'no confunde un prefijo textual con un ancestro real' {
        # "OneDrive2" NO cuelga de "OneDrive": no comparte separador de ruta.
        $resultado = @(Select-RutasNoAnidadas @('C:\Users\x\OneDrive', 'C:\Users\x\OneDrive2'))
        $resultado.Count | Should -Be 2
    }

    It 'envuelta en @() por quien la llama, una sola ruta superviviente sigue siendo un array de un elemento' {
        # PowerShell desenvuelve un array de un elemento; el @() es
        # responsabilidad de quien llama, como hace Config.ps1 al asignar
        # ZonasUsuario y RaicesProyecto.
        $resultado = @(Select-RutasNoAnidadas @('C:\Users\x\Unica'))
        $resultado.Count | Should -Be 1
        $resultado[0] | Should -Be 'C:\Users\x\Unica'
    }
}

Describe 'dos enlaces duros no son dos copias' {

    <#
        Dos enlaces duros tienen el mismo tamaño y hash, pero borrar uno no
        libera nada mientras quede otro enlace.
    #>

    BeforeAll {
        # Los cebos no pueden estar en la carpeta temporal de Windows: está
        # dentro de AppData, que el módulo de duplicados descarta a
        # propósito, y las pruebas comprobarían el vacío. Se usa pruebas\,
        # que está en .gitignore y no cuelga de AppData.
        $script:raizPruebas = Join-Path (Split-Path $PSScriptRoot -Parent) 'pruebas'
        $script:zonaDup = Join-Path $script:raizPruebas ('tmp-dup-hl-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:zonaDup -Force | Out-Null

        # Dos enlaces al mismo contenido.
        $uno = Join-Path $script:zonaDup 'documento.bin'
        [IO.File]::WriteAllBytes($uno, (New-Object byte[] 200000))
        $script:enlaceDup = Join-Path $script:zonaDup 'mismo-documento.bin'

        # Y dos copias reales, idénticas pero independientes: estas sí se
        # proponen.
        $copiaA = Join-Path $script:zonaDup 'copia-a.bin'
        $copiaB = Join-Path $script:zonaDup 'copia-b.bin'
        $contenido = New-Object byte[] 300000
        for ($i = 0; $i -lt 500; $i++) { $contenido[$i] = 42 }
        [IO.File]::WriteAllBytes($copiaA, $contenido)
        [IO.File]::WriteAllBytes($copiaB, $contenido)

        $script:HayEnlaces = $false
        try {
            if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                & cmd /c mklink /H "`"$script:enlaceDup`"" "`"$uno`"" 2>&1 | Out-Null
            } else {
                & ln $uno $script:enlaceDup 2>&1 | Out-Null
            }
            $script:HayEnlaces = (Test-Path -LiteralPath $script:enlaceDup) -and
                                 ($null -ne (Get-IdentidadArchivo -Ruta $uno))
        } catch { $script:HayEnlaces = $false }

        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio = ''; Documentos = ''; Descargas = ''
            Imagenes   = ''; Musica     = ''; Videos     = ''; CarpetaDatos = ''
        })

        $modulo = Get-ModuloLimpieza -Id 'duplicados' -Raiz (Split-Path $PSScriptRoot -Parent)
        $r = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
             -Configuracion ([pscustomobject]@{
                 ZonasUsuario = @($script:zonaDup)
                 MinimoDuplicadoMB = 0; MinimoMB = 0; DiasSinUso = 0; Admin = $true
                 Documentos = ''; Imagenes = ''; Musica = ''; Videos = ''; Descargas = ''
             })
        $script:RutasDup = @($r.Candidatos | ForEach-Object { $_.Ruta })
    }

    AfterAll {
        Remove-Item -LiteralPath $script:zonaDup -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'NO propone borrar un enlace duro' {
        if (-not $script:HayEnlaces) { Set-ItResult -Skipped -Because 'el sistema no admite enlaces duros'; return }
        $script:RutasDup | Should -Not -Contain $script:enlaceDup -Because (
            'borrar un enlace duro no libera un solo byte, y el programa lo apuntaria como espacio recuperado')
    }

    It 'pero SI sigue proponiendo las copias de verdad' {
        # Sin esta, un módulo que no propusiera nada pasaría la anterior.
        @($script:RutasDup | Where-Object { $_ -like '*copia-*' }).Count |
            Should -Be 1 -Because 'dos archivos identicos e independientes si son un duplicado'
    }
}

Describe 'Modulo duplicados: cual se conserva' {

    BeforeAll {
        # Igual que arriba: pruebas\ y no la carpeta temporal, que cuelga de AppData.
        $script:raizCons = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'pruebas') ('tmp-dup-cons-' + [guid]::NewGuid())
        $script:docsCons = Join-Path $script:raizCons 'Documentos'
        $script:descCons = Join-Path $script:raizCons 'Descargas'
        New-Item -ItemType Directory -Path $script:docsCons -Force | Out-Null
        New-Item -ItemType Directory -Path $script:descCons -Force | Out-Null

        # La de Descargas es la mas antigua, pero la de Documentos esta
        # mejor situada: se conserva la de Documentos.
        $contenido = New-Object byte[] 300000
        for ($i = 0; $i -lt 500; $i++) { $contenido[$i] = 7 }
        $script:enDescargas  = Join-Path $script:descCons 'foto.bin'
        $script:enDocumentos = Join-Path $script:docsCons 'foto.bin'
        [IO.File]::WriteAllBytes($script:enDescargas, $contenido)
        Start-Sleep -Milliseconds 50
        [IO.File]::WriteAllBytes($script:enDocumentos, $contenido)

        $r = Invoke-ModuloLimpieza -Modulo $script:ModuloDuplicados -Sync (New-EstadoSincronizado) `
             -Configuracion ([pscustomobject]@{
                 ZonasUsuario = @($script:docsCons, $script:descCons)
                 MinimoDuplicadoMB = 0; MinimoMB = 0; DiasSinUso = 0; Admin = $true
                 Documentos = $script:docsCons; Imagenes = ''; Musica = ''; Videos = ''
                 Descargas = $script:descCons
             })
        $script:CandidatosCons = @($r.Candidatos)
    }

    AfterAll {
        Remove-Item -LiteralPath $script:raizCons -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'propone la copia de Descargas aunque sea la mas antigua' {
        $script:CandidatosCons.Count | Should -Be 1
        $script:CandidatosCons[0].Ruta | Should -Be $script:enDescargas
    }

    It 'los textos visibles no prometen conservar la mas antigua' {
        $script:CandidatosCons[0].Efecto | Should -Not -Match 'original, creado'
        $script:CandidatosCons[0].Efecto | Should -Match 'mejor situada'
        $script:ModuloDuplicados.Descripcion | Should -Not -Match 'siempre la copia m.s antigua'
        $script:ModuloDuplicados.Descripcion | Should -Match 'mejor situada'
    }
}
