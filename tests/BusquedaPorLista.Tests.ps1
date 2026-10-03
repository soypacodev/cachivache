<#
    Pruebas de caracterización de los módulos que recorren una lista de
    rutas conocidas (caches, logs, windowsupdate), que comparten el mismo
    bucle.

    Fijan el resultado campo a campo: mismos nombres, rutas, métodos,
    riesgos, avisos y marcado por defecto. Corren sobre un árbol falso en
    una carpeta temporal, con las variables de entorno apuntando ahí, así
    que no tocan el equipo y valen igual en Linux.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Carpeta con un archivo del tamaño pedido, para superar el umbral de
    # cada módulo.
    function Get-CarpetaConPeso {
        param([string] $Ruta, [int] $Megas = 2)
        New-Item -ItemType Directory -Path $Ruta -Force | Out-Null
        $relleno = [byte[]]::new(1MB)
        for ($i = 0; $i -lt $Megas; $i++) {
            [IO.File]::WriteAllBytes((Join-Path $Ruta "relleno$i.bin"), $relleno)
        }
    }

    # Retrato de un candidato: lo que ve el usuario o decide el borrado.
    # Excluye Bytes, que depende del relleno.
    function Get-RetratoCandidato {
        param($Candidato)
        return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f
            $Candidato.ModuloId, $Candidato.Categoria, $Candidato.Nombre,
            $Candidato.Metodo, $Candidato.Riesgo,
            $(if ($Candidato.Aviso) { 'con-aviso' } else { 'sin-aviso' }),
            $(if ($Candidato.Seleccionado) { 'marcado' } else { 'sin-marcar' }))
    }

    function Get-RetratoModulo {
        param([string] $Id, $Configuracion)
        $modulo = Get-ModuloLimpieza -Id $Id -Raiz $script:Raiz
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $Configuracion -Sync (New-EstadoSincronizado)
        return @($resultado.Candidatos | ForEach-Object { Get-RetratoCandidato $_ } | Sort-Object)
    }
}

Describe 'Los modulos de lista proponen los candidatos esperados' {

    BeforeEach {
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('lista_' + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Base -Force | Out-Null

        $script:EntornoOriginal = @{
            SystemRoot   = $env:SystemRoot
            ProgramData  = $env:ProgramData
            LOCALAPPDATA = $env:LOCALAPPDATA
            APPDATA      = $env:APPDATA
            USERPROFILE  = $env:USERPROFILE
            SystemDrive  = $env:SystemDrive
        }

        $env:SystemRoot   = Join-Path $script:Base 'Windows'
        $env:ProgramData  = Join-Path $script:Base 'ProgramData'
        $env:USERPROFILE  = Join-Path $script:Base 'Usuario'
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
        $env:APPDATA      = Join-Path $env:USERPROFILE 'AppData\Roaming'
        $env:SystemDrive  = $script:Base

        foreach ($c in @($env:SystemRoot, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA)) {
            New-Item -ItemType Directory -Path $c -Force | Out-Null
        }

        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio = ''; Documentos = ''; Descargas = ''
            Imagenes   = ''; Musica     = ''; Videos    = ''
            CarpetaDatos = ''
        })

        $script:Configuracion = [pscustomobject]@{
            Admin          = $true
            IncluirMenores = $true
            MinimoMB       = 0
            DiasSinUso     = 30
            Unidad         = 'C:'
        }
    }

    AfterEach {
        foreach ($k in $script:EntornoOriginal.Keys) {
            Set-Item -Path ("Env:$k") -Value $script:EntornoOriginal[$k] -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'caches: las entradas presentes salen y las ausentes no' {
        Get-CarpetaConPeso (Join-Path $env:LOCALAPPDATA 'Temp')
        Get-CarpetaConPeso (Join-Path $env:LOCALAPPDATA 'CrashDumps')
        Get-CarpetaConPeso (Join-Path $env:LOCALAPPDATA 'npm-cache')

        $retrato = Get-RetratoModulo 'caches' $script:Configuracion

        $retrato | Should -Contain 'caches|Cachés|Temporales del usuario|Contenido|Bajo|sin-aviso|marcado'
        $retrato | Should -Contain 'caches|Cachés|Volcados de programas rotos|Contenido|Bajo|sin-aviso|marcado'
        $retrato | Should -Contain 'caches|Cachés|Caché de npm|Contenido|Bajo|sin-aviso|marcado'
        # Lo que no existe en disco no se propone.
        @($retrato | Where-Object { $_ -match 'Miniaturas' }) | Should -BeNullOrEmpty
    }

    It 'caches: una carpeta por debajo del umbral no se propone' {
        # El módulo exige 1 MB; se crea con menos.
        $ruta = Join-Path $env:LOCALAPPDATA 'CrashDumps'
        New-Item -ItemType Directory -Path $ruta -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ruta 'x.dmp') -Value 'poca cosa'

        $retrato = Get-RetratoModulo 'caches' $script:Configuracion
        @($retrato | Where-Object { $_ -match 'Volcados' }) | Should -BeNullOrEmpty
    }

    It 'caches: con IncluirMenores en falso desaparecen las entradas menores' {
        Get-CarpetaConPeso (Join-Path $env:LOCALAPPDATA 'CrashDumps')
        Get-CarpetaConPeso (Join-Path $env:LOCALAPPDATA 'Temp')

        $script:Configuracion.IncluirMenores = $false
        $retrato = Get-RetratoModulo 'caches' $script:Configuracion

        # CrashDumps esta marcado como "menor"; Temp no.
        @($retrato | Where-Object { $_ -match 'Volcados' })    | Should -BeNullOrEmpty
        @($retrato | Where-Object { $_ -match 'Temporales' })  | Should -Not -BeNullOrEmpty
    }

    It 'logs: las nueve entradas y el volcado de memoria se comportan igual' {
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'Logs\CBS')
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'Panther')
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'Prefetch')
        Get-CarpetaConPeso (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')

        $retrato = Get-RetratoModulo 'logs' $script:Configuracion

        $retrato | Should -Contain 'logs|Registros del sistema|Registros CBS|Contenido|Bajo|sin-aviso|marcado'
        $retrato | Should -Contain 'logs|Registros del sistema|Registros de instalación|Contenido|Bajo|sin-aviso|marcado'
        $retrato | Should -Contain 'logs|Registros del sistema|Caché de Prefetch|Contenido|Bajo|sin-aviso|marcado'
        $retrato | Should -Contain 'logs|Registros del sistema|Informes de error archivados|Contenido|Bajo|sin-aviso|marcado'
        @($retrato | Where-Object { $_ -match 'DISM' }) | Should -BeNullOrEmpty
    }

    It 'logs: MEMORY.DMP sale como candidato de metodo Ruta, no Contenido' {
        # Es un archivo suelto y se borra entero; no entra en el bucle de
        # la lista.
        $volcado = Join-Path $env:SystemRoot 'MEMORY.DMP'
        [IO.File]::WriteAllBytes($volcado, [byte[]]::new(12MB))

        $retrato = Get-RetratoModulo 'logs' $script:Configuracion
        $retrato | Should -Contain 'logs|Registros del sistema|Volcado completo de memoria (MEMORY.DMP)|Ruta|Bajo|sin-aviso|marcado'
    }

    It 'windowsupdate: el umbral propio de 10 MB se respeta' {
        # Este módulo usa 10 MB de umbral, no 1 MB como los otros dos.
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') -Megas 12
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'SoftwareDistribution\DataStore') -Megas 2

        $retrato = Get-RetratoModulo 'windowsupdate' $script:Configuracion

        $retrato | Should -Contain 'windowsupdate|Windows Update|Descargas de Windows Update|Contenido|Bajo|sin-aviso|marcado'
        @($retrato | Where-Object { $_ -match 'Base de datos' }) |
            Should -BeNullOrEmpty -Because 'con 2 MB no llega al umbral de 10 MB de este modulo'
    }

    It 'windowsupdate: la entrada con aviso NO viene marcada' {
        # La base de datos lleva aviso ("se borra el historial"), y su
        # -Preseleccionado depende de si hay aviso.
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'SoftwareDistribution\DataStore') -Megas 12

        $retrato = Get-RetratoModulo 'windowsupdate' $script:Configuracion
        $retrato | Should -Contain 'windowsupdate|Windows Update|Base de datos de Windows Update|Contenido|Bajo|con-aviso|sin-marcar'
    }

    It 'la cancelacion corta el recorrido en los tres modulos' {
        Get-CarpetaConPeso (Join-Path $env:LOCALAPPDATA 'Temp')
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'Logs\CBS')
        Get-CarpetaConPeso (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') -Megas 12

        foreach ($id in @('caches', 'logs', 'windowsupdate')) {
            $sync = New-EstadoSincronizado
            $sync.Cancelar = $true
            $modulo = Get-ModuloLimpieza -Id $id -Raiz $script:Raiz
            $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $script:Configuracion -Sync $sync
            @($resultado.Candidatos).Count |
                Should -Be 0 -Because "$id tiene que dejar de recorrer en cuanto se cancela"
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
