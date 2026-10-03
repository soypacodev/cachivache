<#
    Pruebas del modo consola (src/Cli).

    El modo consola orquesta el análisis, el informe, el historial y el
    borrado, y es el que usan la primera ejecución sin riesgo y las tareas
    programadas.

    Write-Host va al flujo de información, así que "6>&1" captura la salida
    de Invoke-CachivacheCli como texto.

    Los módulos son simulados, la carpeta de datos es temporal y el único
    borrado real ocurre sobre un archivo creado por la propia prueba.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent

    # Se carga con dot-source, igual que Cachivache.ps1, y no como módulo:
    # importarlo como módulo haría globales las funciones y ocultaría fallos
    # de ámbito (p. ej. un cierre con .GetNewClosure() no ve las funciones
    # del núcleo cargadas en ámbito de script).
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Cli')  'Cli.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Cli')  'Espacio.ps1')

    # Carpeta de datos temporal para historial, registro e informes.
    $script:Datos = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-cli-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:Datos -Force)
    [void](Initialize-Registro -CarpetaDatos $script:Datos)

    # Guardia con carpetas personales vacías: el veredicto depende solo de la
    # ruta del caso, no del equipo.
    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio = ''; Documentos = ''; Descargas = ''
        Imagenes   = ''; Musica     = ''; Videos     = ''; CarpetaDatos = ''
    })

    function script:New-ConfiguracionDePrueba {
        param([switch] $Admin, [string] $Perfil = 'equilibrado')
        return [pscustomobject]@{
            Equipo                = 'EQUIPO-PRUEBA'
            Perfil                = $Perfil
            Admin                 = [bool]$Admin
            Unidad                = 'C:'
            CarpetaDatos          = $script:Datos
            UnidadesSeleccionadas = @('C:')
            RutasExcluidas        = @()
            Permanente            = $false
            ZonasUsuario          = @()
        }
    }

    # Los módulos simulados emiten lo que haya en estas variables. Se usan
    # variables de script y no cierres: un cierre se ejecuta en un módulo
    # dinámico donde no se ven las funciones del núcleo.
    $script:EmisionA = @()
    $script:EmisionB = @()
    $script:ReventarB = $false

    $script:ModuloA = New-ModuloLimpieza -Id 'uno' -Orden 1 `
        -Nombre 'Modulo uno' -Descripcion 'Emite lo de EmisionA.' `
        -Buscar { param($Configuracion, $Sync) foreach ($c in $script:EmisionA) { $c } }

    $script:ModuloB = New-ModuloLimpieza -Id 'dos' -Orden 2 `
        -Nombre 'Modulo dos' -Descripcion 'Emite lo de EmisionB, o revienta.' `
        -Buscar {
            param($Configuracion, $Sync)
            if ($script:ReventarB) { throw 'el modulo dos ha reventado a proposito' }
            foreach ($c in $script:EmisionB) { $c }
        }

    $script:ModuloAdmin = New-ModuloLimpieza -Id 'tres' -Orden 3 `
        -Nombre 'Modulo de administrador' -Descripcion 'No deberia correr sin permisos.' `
        -RequiereAdmin -Buscar { param($Configuracion, $Sync) $script:EmisionA }

    # Informativo: exento de la guardia; pasa el embudo en cualquier sistema operativo.
    function script:New-CandidatoInformativo {
        param([string] $Nombre = 'informativo', [double] $Bytes = 100)
        return New-Candidato -ModuloId 'uno' -Categoria 'Pruebas' -Nombre $Nombre `
                             -Ruta ('C:\normal\' + $Nombre) -Bytes $Bytes `
                             -Metodo 'Informativo' -Raices @()
    }

    # Borrable y premarcado (riesgo bajo y sin aviso, como exige
    # Test-DebeVenirMarcado). La ruta real está en la carpeta temporal.
    function script:New-CandidatoBorrable {
        param([string] $Nombre, [double] $Bytes = 1024)
        $ruta = Join-Path $script:Datos $Nombre
        return New-Candidato -ModuloId 'uno' -Categoria 'Pruebas' -Nombre $Nombre `
                             -Ruta $ruta -Bytes $Bytes -Metodo 'Ruta' -Riesgo 'Bajo' `
                             -Raices @($script:Datos)
    }

    function script:Invoke-Cli {
        param([hashtable] $Argumentos = @{})
        if (-not $Argumentos.ContainsKey('Configuracion')) {
            $Argumentos['Configuracion'] = script:New-ConfiguracionDePrueba
        }
        if (-not $Argumentos.ContainsKey('Modulos')) {
            $Argumentos['Modulos'] = @($script:ModuloA, $script:ModuloB)
        }
        $Argumentos['Confirm'] = $false
        # $null absorbe el código de retorno para que no aparezca en la salida capturada.
        $salida = & { $null = Invoke-CachivacheCli @Argumentos } 6>&1
        return ($salida | ForEach-Object { [string]$_ }) -join "`n"
    }

    # La última entrada del historial: Add-EntradaHistorial añade al final,
    # así que [0] es la más antigua.
    function script:Get-UltimaEntradaHistorial {
        param([string] $Tipo = '')
        $todas = @(Get-Historial -CarpetaDatos $script:Datos)
        if ($Tipo) { $todas = @($todas | Where-Object { $_.Tipo -eq $Tipo }) }
        if ($todas.Count -eq 0) { return $null }
        return $todas[-1]
    }
}

AfterAll {
    if ($script:Datos -and (Test-Path -LiteralPath $script:Datos)) {
        Remove-Item -LiteralPath $script:Datos -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Write-Linea: el unico sitio por el que sale texto' {

    It 'el estilo <Estilo> escribe el texto tal cual' -ForEach @(
        @{ Estilo = 'normal' }, @{ Estilo = 'titulo' }, @{ Estilo = 'ok' }
        @{ Estilo = 'aviso'  }, @{ Estilo = 'error'  }, @{ Estilo = 'tenue' }
    ) {
        $salida = (& { Write-Linea 'hola que tal' $Estilo } 6>&1 | ForEach-Object { [string]$_ }) -join ''
        $salida | Should -Be 'hola que tal'
    }

    It 'un estilo que no existe se rechaza en vez de pintarse de cualquier color' {
        # Sin ValidateSet, un estilo mal escrito caería en "default" y un aviso
        # se pintaría como texto normal.
        { Write-Linea 'x' 'chillon' } | Should -Throw
    }

    It 'la cabecera subraya con el mismo ancho que el titulo' {
        $lineas = @(& { Write-Cabecera 'Analisis' } 6>&1 | ForEach-Object { [string]$_ })
        $subrayado = @($lineas | Where-Object { $_ -match '^\s*-+$' })
        $subrayado.Count | Should -Be 1
        $subrayado[0].Trim().Length | Should -Be 'Analisis'.Length
    }
}

Describe 'Invoke-CachivacheCli: el analisis' {
    # Cada prueba empieza con los módulos simulados en silencio.
    BeforeEach {
        $script:EmisionA  = @()
        $script:EmisionB  = @()
        $script:ReventarB = $false
    }


    It 'sin ningun modulo que ejecutar devuelve 1 y lo dice' {
        # Devolver 0 indicaría éxito a una tarea programada sin haber analizado nada.
        $cfg = script:New-ConfiguracionDePrueba
        $salida = script:Invoke-Cli @{ Configuracion = $cfg; Modulos = @(); Ids = @() }
        $salida | Should -Match 'No hay ningún módulo'
        Invoke-CachivacheCli -Configuracion $cfg -Modulos @() -Silencioso -Confirm:$false |
            Should -Be 1
    }

    It 'sin -Ejecutar avisa de que no ha borrado nada' {
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $salida = script:Invoke-Cli
        $salida | Should -Match 'solo un análisis'
        $salida | Should -Match '-Ejecutar'
    }

    It 'las dos primeras cifras del resumen hablan de lo mismo' {
        # "Elementos encontrados" y "Recuperable total" cuentan el mismo conjunto.
        $script:EmisionA = @(
            (script:New-CandidatoInformativo -Nombre 'info-1' -Bytes 10)
            (script:New-CandidatoInformativo -Nombre 'info-2' -Bytes 20)
        )
        # El archivo debe existir: el embudo descarta candidatos inexistentes.
        [IO.File]::WriteAllText((Join-Path $script:Datos 'borrable-1'), 'x' * 500)
        $script:EmisionB = @(script:New-CandidatoBorrable -Nombre 'borrable-1' -Bytes 500)
        $salida = script:Invoke-Cli

        $salida | Should -Match 'Elementos encontrados : 3 \(1 recuperables, 2 solo informativos\)'
    }

    It 'un modulo que revienta sale en el aviso de lista incompleta' {
        # La ventana lo muestra en una franja; la consola debe decir lo mismo.
        $script:EmisionA  = @(script:New-CandidatoInformativo)
        $script:ReventarB = $true
        $salida = script:Invoke-Cli

        $salida | Should -Match 'ATENCIÓN: esta lista está incompleta'
        $salida | Should -Match 'Modulo dos'
        $salida | Should -Match '1 módulo no se ha podido completar'
    }

    It 'el modulo que fallo NO se anota en el historial como revisado' {
        $script:EmisionA  = @(script:New-CandidatoInformativo)
        $script:ReventarB = $true
        [void](script:Invoke-Cli)

        $ultima = script:Get-UltimaEntradaHistorial -Tipo 'analisis'
        $ultima.Incompleto | Should -BeTrue
        $ultima.Modulos    | Should -Contain 'uno'
        $ultima.Modulos    | Should -Not -Contain 'dos'
        $ultima.Motivo     | Should -Match 'Modulo dos'
    }

    It 'con todo bien, el historial no dice que sea incompleto' {
        $script:EmisionA = @(script:New-CandidatoInformativo)
        [void](script:Invoke-Cli)
        $ultima = script:Get-UltimaEntradaHistorial -Tipo 'analisis'
        $ultima.Incompleto | Should -BeFalse
        $ultima.Modulos    | Should -Contain 'dos'
    }

    It '-Ids elige modulos por nombre y se salta el perfil' {
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $script:EmisionB = @(script:New-CandidatoInformativo -Nombre 'de-b')
        $salida = script:Invoke-Cli @{ Ids = @('uno') }
        $salida | Should -Match 'Modulo uno'
        $salida | Should -Not -Match 'Modulo dos'
    }

    It 'un modulo que necesita administrador no corre sin permisos' {
        $cfg = script:New-ConfiguracionDePrueba   # Admin a $false
        $salida = script:Invoke-Cli @{
            Configuracion = $cfg
            Modulos       = @($script:ModuloA, $script:ModuloAdmin)
            Ids           = @('uno', 'tres')
        }
        $salida | Should -Not -Match 'Modulo de administrador'
    }

    It '-Silencioso no escribe absolutamente nada' {
        # Pensado para tareas programadas.
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $salida = script:Invoke-Cli @{ Silencioso = $true }
        $salida | Should -BeNullOrEmpty
    }

    It 'nunca deja un hueco de formato sin rellenar' {
        # "-f" tiene más precedencia que "+": 'texto {0}' + 'más' -f $x deja el
        # {0} literal. Se revisa la salida entera con resultados, un fallo y un informe.
        $script:EmisionA  = @(
            (script:New-CandidatoInformativo -Nombre 'info' -Bytes 4096)
            (script:New-CandidatoBorrable -Nombre 'hueco-1' -Bytes 2048)
        )
        $script:ReventarB = $true
        $salida = script:Invoke-Cli @{ Informe = (Join-Path $script:Datos 'huecos.html') }

        $salida | Should -Not -Match '\{\d+[,:][^}]*\}'
        $salida | Should -Not -Match '\{\d+\}'
    }
}

Describe 'Invoke-CachivacheCli: el informe' {
    # Cada prueba empieza con los módulos simulados en silencio.
    BeforeEach {
        $script:EmisionA  = @()
        $script:EmisionB  = @()
        $script:ReventarB = $false
    }


    It 'la extension <Extension> produce un archivo' -ForEach @(
        @{ Extension = 'html' }, @{ Extension = 'csv' }, @{ Extension = 'json' }
    ) {
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $ruta = Join-Path $script:Datos ('informe-' + $Extension + '.' + $Extension)
        $salida = script:Invoke-Cli @{ Informe = $ruta }

        Test-Path -LiteralPath $ruta | Should -BeTrue
        $salida | Should -Match 'Informe guardado'
    }

    It 'sin extension se guarda como html, y se dice el nombre de verdad' {
        # El mensaje debe nombrar el archivo real ("informe.html").
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $ruta = Join-Path $script:Datos 'sin-extension'
        $salida = script:Invoke-Cli @{ Informe = $ruta }

        Test-Path -LiteralPath ($ruta + '.html') | Should -BeTrue
        $salida | Should -Match 'sin-extension\.html'
    }

    It 'si el informe no se puede guardar, se dice y el analisis sigue' {
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $carpetaQueNoExiste = Join-Path (Join-Path $script:Datos 'no-existe') 'tampoco'
        $salida = script:Invoke-Cli @{ Informe = (Join-Path $carpetaQueNoExiste 'x.html') }

        $salida | Should -Match 'No se ha podido guardar el informe'
        $salida | Should -Match 'Elementos encontrados'
    }
}

Describe 'Invoke-CachivacheCli: eliminar y simular' {
    # Cada prueba empieza con los módulos simulados en silencio.
    BeforeEach {
        $script:EmisionA  = @()
        $script:EmisionB  = @()
        $script:ReventarB = $false
    }


    It 'con -Ejecutar y nada marcado no borra ni promete nada' {
        # Solo informativos: no hay nada que se marque solo.
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $salida = script:Invoke-Cli @{ Ejecutar = $true }
        $salida | Should -Match 'No hay nada marcado'
    }

    It '-Simular habla en condicional y grita que no ha borrado nada' {
        $archivo = Join-Path $script:Datos 'simulado.tmp'
        [IO.File]::WriteAllText($archivo, 'x' * 500)
        $script:EmisionA = @(script:New-CandidatoBorrable -Nombre 'simulado.tmp' -Bytes 500)

        $salida = script:Invoke-Cli @{ Ejecutar = $true; Simular = $true }

        $salida | Should -Match 'Se habrían eliminado'
        $salida | Should -Match 'NO SE HA BORRADO NADA'
        $salida | Should -Not -Match 'Elementos eliminados'
        Test-Path -LiteralPath $archivo | Should -BeTrue -Because 'simular no borra'
    }

    It 'una simulacion NO se anota en el historial' {
        $archivo = Join-Path $script:Datos 'no-historial.tmp'
        [IO.File]::WriteAllText($archivo, 'x' * 300)
        $script:EmisionA = @(script:New-CandidatoBorrable -Nombre 'no-historial.tmp' -Bytes 300)

        [void](script:Invoke-Cli @{ Ejecutar = $true; Simular = $true })

        $limpiezas = @(Get-Historial -CarpetaDatos $script:Datos | Where-Object { $_.Tipo -eq 'limpieza' })
        $limpiezas.Count | Should -Be 0
    }

    It 'con -Ejecutar de verdad borra, lo dice, y lo anota' {
        # Único borrado real del archivo, sobre un archivo de la carpeta temporal.
        $archivo = Join-Path $script:Datos 'a-borrar.tmp'
        [IO.File]::WriteAllText($archivo, 'x' * 700)
        $script:EmisionA = @(script:New-CandidatoBorrable -Nombre 'a-borrar.tmp' -Bytes 700)

        # Permanente: la papelera usa Microsoft.VisualBasic.FileIO, que no existe
        # fuera de Windows. Aquí se prueba el camino del modo consola, no la papelera.
        $cfg = script:New-ConfiguracionDePrueba
        $cfg.Permanente = $true
        $salida = script:Invoke-Cli @{ Ejecutar = $true; Configuracion = $cfg }

        Test-Path -LiteralPath $archivo | Should -BeFalse
        $salida | Should -Match 'Elementos eliminados : 1'
        $salida | Should -Not -Match 'Se habrían eliminado'

        $limpiezas = @(Get-Historial -CarpetaDatos $script:Datos | Where-Object { $_.Tipo -eq 'limpieza' })
        $limpiezas.Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'invariante: un informe que no se puede escribir NO se anuncia como guardado' {
    BeforeEach {
        $script:EmisionA  = @()
        $script:EmisionB  = @()
        $script:ReventarB = $false
    }


    It 'NINGUNA escritura a disco de src/ se hace sin -ErrorAction Stop' {
        # Set-Content, Export-Csv y similares dan un error no terminante si la
        # carpeta no existe: sin -ErrorAction Stop el try/catch de quien llama
        # no se dispara y se anuncia como guardado un archivo inexistente.
        # Se comprueba por texto porque una ausencia no lanza nada, y sobre
        # todo src/ para cubrir cualquier escritura nueva.
        $cmdlets = 'Set-Content|Export-Csv|Out-File|Add-Content|Export-Clixml'
        $carpeta = Join-Path $script:Raiz 'src'
        $escrituras = @()
        foreach ($archivo in @(Get-ChildItem -LiteralPath $carpeta -Recurse -Force |
                               Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.ps1' })) {
            $n = 0
            foreach ($linea in @([IO.File]::ReadAllText($archivo.FullName) -split "`r?`n")) {
                $n++
                if ($linea -match '^\s*#')       { continue }
                if ($linea -notmatch $cmdlets)   { continue }
                # Solo cuentan las que escriben a un archivo (excluye texto de ayuda).
                if ($linea -notmatch '-(LiteralPath|Path|FilePath)\s') { continue }
                $escrituras += [pscustomobject]@{
                    Donde = '{0}:{1}' -f $archivo.Name, $n
                    Linea = $linea.Trim()
                }
            }
        }

        # Control: sin escrituras encontradas la prueba no comprobaría nada.
        # El suelo admite añadir escrituras sin tocar la prueba.
        @($escrituras).Count | Should -BeGreaterOrEqual 5 -Because (
            'si el barrido no encuentra las escrituras conocidas es que el barrido esta roto')

        $sinParar = @($escrituras | Where-Object { $_.Linea -notmatch '-ErrorAction\s+Stop' })
        (($sinParar | ForEach-Object { $_.Donde }) -join ', ') | Should -BeNullOrEmpty -Because (
            'sin -ErrorAction Stop el fallo es no terminante, el catch de quien llama ' +
            'no se entera y el programa anuncia como guardado algo que no existe')
    }

    It 'y el modo consola dice la verdad cuando el informe no se puede escribir' {
        # Ejecución real: la consola informa del fallo y no dice que lo guardó.
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $imposible = Join-Path (Join-Path $script:Datos 'no-existe') 'x.html'
        $salida = script:Invoke-Cli @{ Informe = $imposible }

        $salida | Should -Match 'No se ha podido guardar el informe'
        $salida | Should -Not -Match 'Informe guardado'
        Test-Path -LiteralPath $imposible | Should -BeFalse
    }

    It 'y no anota en el historial la ruta de un informe que no existe' {
        $script:EmisionA = @(script:New-CandidatoInformativo)
        $imposible = Join-Path (Join-Path $script:Datos 'tampoco-existe') 'y.html'
        [void](script:Invoke-Cli @{ Informe = $imposible })

        $ultima = script:Get-UltimaEntradaHistorial -Tipo 'analisis'
        $ultima.Informe | Should -BeNullOrEmpty
    }
}

Describe 'Show-InformeEspacio: el modo "donde se fue el espacio"' {

    BeforeAll {
        # Archivos reales por encima del umbral de 1 MB de Show-InformeEspacio,
        # con nombres cuyo orden por tamaño y por nombre no coincide.
        # "foto[1].jpg" junto a "foto1.jpg": con -like, buscar el primero
        # encuentra el segundo y no el primero.
        $script:CarpetaVista = Join-Path $script:Datos 'vista'
        [void](New-Item -ItemType Directory -Path $script:CarpetaVista -Force)
        foreach ($par in @(
            @{ Nombre = 'copia.iso';   Bytes = 4MB   }
            @{ Nombre = 'video.mkv';   Bytes = 3MB   }
            @{ Nombre = 'basura.tmp';  Bytes = 2560KB }
            @{ Nombre = 'otro.tmp';    Bytes = 2MB   }
            @{ Nombre = 'tercero.tmp'; Bytes = 1536KB }
            @{ Nombre = 'foto[1].jpg'; Bytes = 1280KB }
            @{ Nombre = 'foto1.jpg';   Bytes = 1200KB }
        )) {
            # WriteAllBytes: la ruta lleva corchetes, que New-Item leería como comodín.
            [IO.File]::WriteAllBytes((Join-Path $script:CarpetaVista $par.Nombre),
                                     [byte[]]::new([int]$par.Bytes))
        }
        $script:CuantosVista = 7

        function script:Get-SalidaEspacio {
            <#
            .SYNOPSIS
                La salida de Show-InformeEspacio sobre la carpeta de prueba, como texto.
            .DESCRIPTION
                Los argumentos se pasan en una tabla y no por un cierre: un
                cierre se ejecuta en un módulo dinámico donde no se ven las
                funciones del núcleo.
            #>
            param([hashtable] $Argumentos = @{})
            $Argumentos['Rutas'] = @($script:CarpetaVista)
            if (-not $Argumentos.ContainsKey('Profundidad')) { $Argumentos['Profundidad'] = 1 }
            $salida = & { Show-InformeEspacio @Argumentos } 6>&1
            return ($salida | ForEach-Object { [string]$_ }) -join "`n"
        }
    }

    It 'la barra se llena en proporcion, y nunca se sale del ancho' {
        (Write-BarraProporcion -Parte 0   -Total 100 -Ancho 10) | Should -Not -Match ([string][char]0x2588)
        (Write-BarraProporcion -Parte 100 -Total 100 -Ancho 10) | Should -Be ([string][char]0x2588 * 10)
        (Write-BarraProporcion -Parte 50  -Total 100 -Ancho 10).Length | Should -Be 10
        # Una parte mayor que el total no puede desbordar la línea.
        (Write-BarraProporcion -Parte 500 -Total 100 -Ancho 10) | Should -Be ([string][char]0x2588 * 10)
        (Write-BarraProporcion -Parte -5  -Total 100 -Ancho 10).Length | Should -Be 10
    }

    It 'con total cero devuelve espacios y no divide por cero' {
        $barra = Write-BarraProporcion -Parte 5 -Total 0 -Ancho 8
        $barra | Should -Be (''.PadRight(8))
    }

    It 'sin ninguna carpeta que mirar lo dice en vez de callarse' {
        $salida = (& { Show-InformeEspacio -Rutas @() } 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $salida | Should -Match 'No hay ninguna carpeta que analizar'
    }

    It 'una ruta que no existe no cuenta como carpeta' {
        $salida = (& { Show-InformeEspacio -Rutas @('C:\esto\no\existe\seguro') } 6>&1 |
                   ForEach-Object { [string]$_ }) -join "`n"
        $salida | Should -Match 'No hay ninguna carpeta que analizar'
    }

    It 'mide una carpeta de verdad y no propone borrar nada' {
        $carpeta = Join-Path $script:Datos 'espacio'
        [void](New-Item -ItemType Directory -Path $carpeta -Force)
        [IO.File]::WriteAllBytes((Join-Path $carpeta 'grande.bin'), [byte[]]::new(2MB))

        $salida = (& { Show-InformeEspacio -Rutas @($carpeta) -Profundidad 1 -Archivos 5 } 6>&1 |
                   ForEach-Object { [string]$_ }) -join "`n"

        $salida | Should -Match 'Dónde se fue el espacio'
        $salida | Should -Match 'grande\.bin'
        $salida | Should -Match 'no se ha propuesto ni borrado nada'
        $salida | Should -Not -Match '\{\d+\}'
    }

    It 'un filtro que no encuentra nada NO se ve igual que un disco vacio' {
        # Filtro sin coincidencias, disco vacío y carpeta inexistente se distinguen.
        $salida = script:Get-SalidaEspacio @{ Buscar = 'no-existe-*' }
        $salida | Should -Match ('Ninguno de los {0} archivos' -f $script:CuantosVista)
        $salida | Should -Match '«no-existe-\*»'
        $salida | Should -Not -Match 'Ningún archivo llega a'
    }

    It 'el resumen se escribe SIEMPRE, tambien cuando la lista trae filas' {
        # Distingue "esto es todo lo que hay" de "esto es lo que cabe".
        $salida = script:Get-SalidaEspacio @{ Archivos = 2 }
        $salida | Should -Match ('Se muestran los 2 mayores de {0} archivos' -f $script:CuantosVista)
        $salida | Should -Match 'quedan 5 más sin mostrar'
        $salida | Should -Match 'no se propone borrar nada'
    }

    It 'y sale tambien cuando hay filtro Y hay mas de los que caben' {
        # Con filtro, el resumen nombra las filas mostradas y las que coinciden.
        $salida = script:Get-SalidaEspacio @{ Buscar = '*.tmp'; Archivos = 2 }
        $salida | Should -Match 'Filtrando por: \*\.tmp'
        $salida | Should -Match 'Se muestran los 2 mayores de 3 archivos'
        $salida | Should -Match 'queda 1 más sin mostrar'
        # Concordancia en singular: no "quedan 1".
        $salida | Should -Not -Match 'quedan 1 '
    }

    It 'cuando caben todos lo dice, y no promete que haya mas' {
        $salida = script:Get-SalidaEspacio @{ Archivos = 50 }
        $salida | Should -Match ('Se muestran los {0} archivos' -f $script:CuantosVista)
        $salida | Should -Match 'todos'
        $salida | Should -Not -Match 'sin mostrar'
    }

    It 'buscar un nombre con corchetes encuentra ESE archivo y no el otro' {
        # -like leería [1] como "un carácter que sea 1".
        $salida = script:Get-SalidaEspacio @{ Buscar = 'foto[1].jpg'; Archivos = 50 }
        $salida | Should -Match ([regex]::Escape('foto[1].jpg'))
        $salida | Should -Not -Match 'foto1\.jpg'

        # Control: confirma que -like se comporta así; si no, lo anterior no probaría nada.
        ('foto1.jpg'   -like 'foto[1].jpg') | Should -BeTrue  -Because 'es la mitad que sobraba'
        ('foto[1].jpg' -like 'foto[1].jpg') | Should -BeFalse -Because 'es la mitad que faltaba'
    }

    It '-Orden Nombre cambia el orden de verdad, y el resumen lo cuenta' {
        # Se comparan posiciones en el texto. basura.tmp es el primero por
        # nombre y copia.iso por tamaño, así que el par se invierte.
        $porNombre = script:Get-SalidaEspacio @{ Orden = 'Nombre'; Archivos = 3 }
        $porTamano = script:Get-SalidaEspacio @{ Orden = 'Tamano'; Archivos = 3 }

        # Control: un IndexOf de -1 haría pasar la comparación sin mirar nada.
        foreach ($texto in @($porNombre, $porTamano)) {
            $texto | Should -Match 'basura\.tmp'
            $texto | Should -Match 'copia\.iso'
        }

        $porNombre.IndexOf('basura.tmp') | Should -BeLessThan $porNombre.IndexOf('copia.iso')
        $porTamano.IndexOf('copia.iso')  | Should -BeLessThan $porTamano.IndexOf('basura.tmp')

        # Ni el resumen ni la cabecera llaman "mayores" a una lista alfabética.
        $porNombre | Should -Match 'los 3 primeros por orden alfabético'
        $porNombre | Should -Match 'Archivos por nombre'
        $porNombre | Should -Not -Match 'mayores'
        $porTamano | Should -Match 'los 3 mayores'
        $porTamano | Should -Match 'Archivos mayores'
    }

    It 'rechaza un orden que no existe en vez de ordenar de cualquier manera' {
        { Show-InformeEspacio -Rutas @($script:CarpetaVista) -Orden 'Inventado' } | Should -Throw
    }

    It 'invariante: el modo consola NO vuelve a filtrar ni a resumir por su cuenta' {
        # El filtrado y el resumen viven solo en Get-VistaArchivos y
        # Get-ResumenVistaArchivos. Los bloques de comentario se quitan antes
        # que las líneas con #; al revés, se perdería el cierre del bloque.
        $ruta   = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Cli') 'Espacio.ps1'
        $codigo = [regex]::Replace([IO.File]::ReadAllText($ruta), '(?s)<#.*?#>', '')
        $codigo = [regex]::Replace($codigo, '(?m)^\s*#.*$', '')

        # Control: el código no puede quedar vacío tras quitar comentarios.
        $codigo | Should -Match 'function Show-InformeEspacio'
        $codigo | Should -Match 'Get-VistaArchivos'
        $codigo | Should -Match 'Get-ResumenVistaArchivos'
        $codigo | Should -Not -Match '\-like'
    }
}
