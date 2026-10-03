<#
    Pruebas del registro de actividad: la cola concurrente que evita
    perder líneas durante el borrado, y el volcado de diagnóstico.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
}

Describe 'Registro con cola concurrente' {

    BeforeEach {
        # Carpeta y archivo propios por prueba: $script:RutaRegistro es
        # estado de módulo compartido.
        $script:CarpetaRegistroPrueba = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:CarpetaRegistroPrueba -Force | Out-Null
        Initialize-Registro -CarpetaDatos $script:CarpetaRegistroPrueba | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:CarpetaRegistroPrueba -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'New-EstadoSincronizado incluye una ColaRegistro vacia' {
        $sync = New-EstadoSincronizado
        # -ActualValue en vez de tubería: una ConcurrentQueue vacía no
        # emite nada por la tubería y Should no recibiría el objeto.
        Should -ActualValue $sync.ColaRegistro -BeOfType [Collections.Concurrent.ConcurrentQueue[string]]
        $sync.ColaRegistro.IsEmpty | Should -BeTrue
    }

    It 'con -Sync, Write-Registro encola en vez de escribir al archivo' {
        $sync = New-EstadoSincronizado
        Write-Registro -Sync $sync -Nivel 'INFO' -Mensaje 'linea de prueba'

        $sync.ColaRegistro.IsEmpty | Should -BeFalse
        Get-Content -LiteralPath $script:RutaRegistro -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'sin -Sync, Write-Registro escribe al archivo al momento (modo consola)' {
        Write-Registro -Nivel 'INFO' -Mensaje 'linea directa'

        $contenido = Get-Content -LiteralPath $script:RutaRegistro
        $contenido | Should -Match 'linea directa'
    }

    It 'Invoke-VaciarColaRegistro vuelca las lineas encoladas, en orden, y vacia la cola' {
        $sync = New-EstadoSincronizado
        1..5 | ForEach-Object { Write-Registro -Sync $sync -Nivel 'BORRADO' -Mensaje "linea $_" }

        Invoke-VaciarColaRegistro -Sync $sync

        $sync.ColaRegistro.IsEmpty | Should -BeTrue
        $contenido = @(Get-Content -LiteralPath $script:RutaRegistro)
        $contenido.Count | Should -Be 5
        1..5 | ForEach-Object {
            $contenido[$_ - 1] | Should -Match "linea $_"
        }
    }

    It 'Invoke-VaciarColaRegistro no falla ni escribe nada con la cola vacia' {
        $sync = New-EstadoSincronizado
        { Invoke-VaciarColaRegistro -Sync $sync } | Should -Not -Throw
        Test-Path -LiteralPath $script:RutaRegistro | Should -BeFalse
    }

    It 'Invoke-VaciarColaRegistro ignora un $Sync que no es la tabla esperada' {
        { Invoke-VaciarColaRegistro -Sync ([pscustomobject]@{ Nada = $true }) } | Should -Not -Throw
        { Invoke-VaciarColaRegistro -Sync @{ SinColaRegistro = $true } } | Should -Not -Throw
    }

    It 'Write-CabeceraSesion encola una cabecera con el ID de sesion, version y perfil' {
        $sync = New-EstadoSincronizado
        Write-CabeceraSesion -Perfil 'equilibrado' -Admin $false -Sync $sync
        Invoke-VaciarColaRegistro -Sync $sync

        $contenido = Get-Content -LiteralPath $script:RutaRegistro -Raw
        $contenido | Should -Match ([regex]::Escape($script:IdSesion))
        $contenido | Should -Match 'equilibrado'
        $contenido | Should -Match 'Administrador: False'
    }

    It 'todas las lineas de una sesion llevan el mismo ID de sesion' {
        $sync = New-EstadoSincronizado
        Write-CabeceraSesion -Perfil 'conservador' -Admin $true -Sync $sync
        Write-Registro -Sync $sync -Nivel 'BORRADO' -Mensaje 'algo borrado'
        Invoke-VaciarColaRegistro -Sync $sync

        $lineasNoVacias = @(Get-Content -LiteralPath $script:RutaRegistro | Where-Object { $_.Trim() })
        foreach ($linea in $lineasNoVacias) {
            $linea | Should -Match ([regex]::Escape("[$script:IdSesion]"))
        }
    }
}

Describe 'Lo que se ve en el panel es lo que hay en el archivo' {

    <#
        El panel de Registro muestra exactamente lo que devuelve
        Invoke-VaciarColaRegistro, la misma función que escribe el archivo:
        "Copiar" da el mismo texto que hay en el archivo.
    #>

    BeforeEach {
        $script:CarpetaLog = Join-Path ([IO.Path]::GetTempPath()) ('log_' + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:CarpetaLog -Force | Out-Null
        Initialize-Registro -CarpetaDatos $script:CarpetaLog | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:CarpetaLog -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'devuelve exactamente las mismas lineas que acaba de escribir en el archivo' {
        $sync = New-EstadoSincronizado
        Write-Registro -Sync $sync -Nivel 'BORRADO'   -Mensaje 'C:\algo -> 10 MB'
        Write-Registro -Sync $sync -Nivel 'BLOQUEADO' -Mensaje 'comando rechazado'
        Write-Registro -Sync $sync -Nivel 'AVISO'     -Mensaje 'algo raro'

        $devueltas = @(Invoke-VaciarColaRegistro -Sync $sync)
        $enArchivo = @(Get-Content -LiteralPath $script:RutaRegistro)

        $devueltas.Count | Should -Be 3
        $enArchivo.Count | Should -Be 3
        for ($i = 0; $i -lt 3; $i++) {
            $devueltas[$i] | Should -BeExactly $enArchivo[$i] -Because 'la pantalla y el archivo no pueden divergir'
        }
    }

    It 'lo devuelto conserva el nivel' {
        # Con el nivel, un AVISO y un INFO se distinguen en pantalla.
        $sync = New-EstadoSincronizado
        Write-Registro -Sync $sync -Nivel 'BLOQUEADO' -Mensaje 'la guardia lo ha parado'

        $devueltas = @(Invoke-VaciarColaRegistro -Sync $sync)
        $devueltas[0] | Should -Match 'BLOQUEADO'
        $devueltas[0] | Should -Match 'la guardia lo ha parado'
    }

    It 'devuelve una lista vacia, y no $null, cuando no hay nada que volcar' {
        # La ventana hace @(...).Count en cada pasada del temporizador:
        # se promete una lista vacía, no $null.
        $sync = New-EstadoSincronizado
        @(Invoke-VaciarColaRegistro -Sync $sync).Count | Should -Be 0
        @(Invoke-VaciarColaRegistro -Sync ([pscustomobject]@{ Nada = $true })).Count | Should -Be 0
        @(Invoke-VaciarColaRegistro -Sync @{ SinColaRegistro = $true }).Count | Should -Be 0
    }

    It 'no devuelve dos veces la misma linea' {
        # Si no, el panel repetiría cada línea en cada pasada del
        # temporizador.
        $sync = New-EstadoSincronizado
        Write-Registro -Sync $sync -Mensaje 'una sola vez'

        @(Invoke-VaciarColaRegistro -Sync $sync).Count | Should -Be 1
        @(Invoke-VaciarColaRegistro -Sync $sync).Count | Should -Be 0
    }

    It 'devuelve las lineas aunque el archivo no se pueda escribir' {
        # Disco lleno o sin permisos: perder también la pantalla
        # convertiría un problema en dos.
        $sync = New-EstadoSincronizado
        Write-Registro -Sync $sync -Mensaje 'esto tiene que verse igual'

        $anterior = $script:RutaRegistro
        $script:RutaRegistro = Join-Path $script:CarpetaLog 'no/existe/este/camino.log'
        try {
            $devueltas = @(Invoke-VaciarColaRegistro -Sync $sync)
            $devueltas.Count | Should -Be 1
            $devueltas[0] | Should -Match 'esto tiene que verse igual'
        } finally {
            $script:RutaRegistro = $anterior
        }
    }
}

Describe 'Get-InformeDiagnostico' {

    BeforeEach {
        $script:CarpetaRegistroPrueba = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:CarpetaRegistroPrueba -Force | Out-Null
        Initialize-Registro -CarpetaDatos $script:CarpetaRegistroPrueba | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:CarpetaRegistroPrueba -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'incluye version del programa, PowerShell y administrador' {
        $informe = Get-InformeDiagnostico -Admin $true -CarpetaDatos $script:CarpetaRegistroPrueba
        $informe | Should -Match ([regex]::Escape((Get-VersionCachivache)))
        $informe | Should -Match ([regex]::Escape([string]$PSVersionTable.PSVersion))
        $informe | Should -Match 'Administrador\s*:\s*True'
    }

    It 'no revienta sin registro previo para este mes' {
        { Get-InformeDiagnostico -CarpetaDatos $script:CarpetaRegistroPrueba } | Should -Not -Throw
        $informe = Get-InformeDiagnostico -CarpetaDatos $script:CarpetaRegistroPrueba
        $informe | Should -Match 'todavía no existe registro'
    }

    It 'con -LineasRegistro 0 no incluye el bloque del registro' {
        Write-Registro -Nivel 'INFO' -Mensaje 'linea que no deberia aparecer'
        $informe = Get-InformeDiagnostico -CarpetaDatos $script:CarpetaRegistroPrueba -LineasRegistro 0
        $informe | Should -Not -Match 'linea que no deberia aparecer'
    }

    It 'incluye las ultimas N lineas del registro cuando existen' {
        1..5 | ForEach-Object { Write-Registro -Nivel 'INFO' -Mensaje "linea numero $_" }
        $informe = Get-InformeDiagnostico -CarpetaDatos $script:CarpetaRegistroPrueba -LineasRegistro 3

        $informe | Should -Match 'linea numero 5'
        $informe | Should -Match 'linea numero 3'
        $informe | Should -Not -Match 'linea numero 1'
    }

    It 'anonimiza el perfil, el usuario y el equipo en todo el texto' {
        $previo = @{ UP = $env:USERPROFILE; UN = $env:USERNAME; CN = $env:COMPUTERNAME }
        try {
            $env:USERPROFILE  = 'C:\Users\paco'
            $env:USERNAME     = 'paco'
            $env:COMPUTERNAME = 'PC-PACO'
            Write-Registro -Nivel 'INFO' -Mensaje 'Borrado c:\users\PACO\AppData\Local\Temp\x.tmp'
            Write-Registro -Nivel 'INFO' -Mensaje 'Copia en D:\Copias\paco'
            Write-Registro -Nivel 'INFO' -Mensaje 'Equipo pc-paco listo'
            $informe = Get-InformeDiagnostico -Admin $false -CarpetaDatos 'C:\Users\paco\AppData\Local\Cachivache'

            $informe | Should -Not -Match '(?i)paco'
            $informe | Should -Match ([regex]::Escape('<perfil>\AppData\Local\Cachivache'))
            $informe | Should -Match ([regex]::Escape('<perfil>\AppData\Local\Temp\x.tmp'))
            $informe | Should -Match ([regex]::Escape('D:\Copias\<usuario>'))
            $informe | Should -Match 'Equipo <equipo> listo'
        } finally {
            $env:USERPROFILE  = $previo.UP
            $env:USERNAME     = $previo.UN
            $env:COMPUTERNAME = $previo.CN
        }
    }

    It 'Get-DescripcionSistema nunca lanza, con o sin CIM disponible' {
        { Get-DescripcionSistema } | Should -Not -Throw
        Get-DescripcionSistema | Should -Not -BeNullOrEmpty
    }
}

Describe 'El historial se lee igual en PowerShell 5.1 que en 7' {

    <#
        ConvertFrom-Json no enumera igual en las dos versiones: en 5.1 un
        array JSON sale de la tubería como un único Object[]; desde la 6,
        enumerado. "@($texto | ConvertFrom-Json)" en 5.1 da una lista cuyo
        único elemento es la lista entera.

        Las pruebas corren en PowerShell 7, así que se reproduce esa forma
        (una lista dentro de otra) y se exige que Get-Historial la devuelva
        plana.
    #>

    BeforeEach {
        $script:CarpetaHist = Join-Path ([IO.Path]::GetTempPath()) ('hist_' + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:CarpetaHist -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:CarpetaHist -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'aplana una lista que contiene una lista, que es lo que devuelve 5.1' {
        # El JSON es idéntico; cambia cómo lo entrega ConvertFrom-Json. Se
        # simula devolviendo el array envuelto.
        $entradas = @(
            [pscustomobject]@{ Fecha = '2026-08-19T10:00:00'; Tipo = 'limpieza'; Bytes = 100.0; Elementos = 3; Perfil = 'equilibrado' }
            [pscustomobject]@{ Fecha = '2026-08-19T11:00:00'; Tipo = 'analisis'; Bytes = 200.0; Elementos = 7; Perfil = 'equilibrado' }
        )
        Set-Content -LiteralPath (Join-Path $script:CarpetaHist 'historial.json') -Value ($entradas | ConvertTo-Json -Depth 5)
        Mock ConvertFrom-Json { , $entradas }   # la coma fuerza "un solo objeto que es un array"

        $leidas = @(Get-Historial -CarpetaDatos $script:CarpetaHist)
        $leidas.Count | Should -Be 2 -Because 'la lista tiene que llegar plana, no anidada'
        $leidas[0].Tipo | Should -Be 'limpieza'
        $leidas[1].Bytes | Should -Be 200.0
    }

    It 'Get-ResumenHistorial no revienta con el historial anidado de 5.1' {
        # La entrada anidada pasaría el filtro y [double]$entrada.Bytes (un
        # array) lanzaría.
        $entradas = @(
            [pscustomobject]@{ Tipo = 'limpieza'; Bytes = 100.0 }
            [pscustomobject]@{ Tipo = 'limpieza'; Bytes = 250.0 }
        )
        Set-Content -LiteralPath (Join-Path $script:CarpetaHist 'historial.json') -Value ($entradas | ConvertTo-Json -Depth 5)
        Mock ConvertFrom-Json { , $entradas }

        { Get-ResumenHistorial -CarpetaDatos $script:CarpetaHist } | Should -Not -Throw
        $resumen = Get-ResumenHistorial -CarpetaDatos $script:CarpetaHist
        $resumen.Limpiezas    | Should -Be 2
        $resumen.BytesTotales | Should -Be 350.0
    }

    It 'con una sola entrada tambien funciona (el caso que NO fallaba)' {
        # ConvertTo-Json de un elemento escribe un objeto suelto, no un
        # array.
        $una = [pscustomobject]@{ Tipo = 'limpieza'; Bytes = 42.0 }
        Set-Content -LiteralPath (Join-Path $script:CarpetaHist 'historial.json') -Value ($una | ConvertTo-Json -Depth 5)

        @(Get-Historial -CarpetaDatos $script:CarpetaHist).Count | Should -Be 1
        (Get-ResumenHistorial -CarpetaDatos $script:CarpetaHist).BytesTotales | Should -Be 42.0
    }

    It 'un historial editado a mano con basura no impide leer el resto' {
        $texto = @'
[
  { "Tipo": "limpieza", "Bytes": 100 },
  { "Tipo": "limpieza", "Bytes": [1, 2, 3] },
  { "Tipo": "limpieza", "Bytes": "no soy un numero" },
  { "Tipo": "limpieza" },
  { "Tipo": "limpieza", "Bytes": 50 }
]
'@
        Set-Content -LiteralPath (Join-Path $script:CarpetaHist 'historial.json') -Value $texto

        { Get-ResumenHistorial -CarpetaDatos $script:CarpetaHist } | Should -Not -Throw
        $resumen = Get-ResumenHistorial -CarpetaDatos $script:CarpetaHist
        $resumen.Limpiezas    | Should -Be 5
        $resumen.BytesTotales | Should -Be 150.0 -Because 'lo ilegible cuenta como cero, pero lo bueno se suma'
    }

    It 'un JSON roto del todo devuelve lista vacia en vez de lanzar' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaHist 'historial.json') -Value '{ esto no es json'
        @(Get-Historial -CarpetaDatos $script:CarpetaHist).Count | Should -Be 0
        { Get-ResumenHistorial -CarpetaDatos $script:CarpetaHist } | Should -Not -Throw
    }
}

Describe 'ConvertTo-DoubleSeguro' {

    It 'convierte lo que es convertible: <Valor>' -ForEach @(
        @{ Valor = 5;        Esperado = 5.0 }
        @{ Valor = '12.5';   Esperado = 12.5 }
        @{ Valor = 0;        Esperado = 0.0 }
        @{ Valor = -3.5;     Esperado = -3.5 }
    ) {
        ConvertTo-DoubleSeguro $Valor | Should -Be $Esperado
    }

    It 'devuelve cero, sin lanzar, ante lo que no lo es' {
        ConvertTo-DoubleSeguro $null            | Should -Be 0.0
        ConvertTo-DoubleSeguro @(1, 2, 3)       | Should -Be 0.0
        ConvertTo-DoubleSeguro 'hola'           | Should -Be 0.0
        ConvertTo-DoubleSeguro ([pscustomobject]@{ a = 1 }) | Should -Be 0.0
        { ConvertTo-DoubleSeguro @() }          | Should -Not -Throw
    }

    It 'no intenta adivinar sumando ni tomando el primero de un array' {
        # Inventar un dato es peor que devolver cero: el cero se nota.
        ConvertTo-DoubleSeguro @(10, 20) | Should -Be 0.0
    }

    It 'un array de UN elemento tampoco es un numero' {
        # En PowerShell 7 [double]@(5) lanza igual que [double]@(1,2,3); se
        # fija por contrato para que la respuesta sea la misma en cualquier
        # versión.
        ConvertTo-DoubleSeguro @(5) | Should -Be 0.0
    }
}

Describe 'Get-DetalleExcepcion dice DONDE ha fallado' {

    <#
        Un mensaje como "Los tipos de argumentos no coinciden" sin tipo ni
        ubicación no permite saber qué archivo abrir. SECURITY.md pide
        adjuntar el registro al reportar un fallo.
    #>

    BeforeAll {
        $script:Raiz = Split-Path $PSScriptRoot -Parent
        . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

        # Un error real nacido en un archivo real, para que InvocationInfo
        # traiga archivo y línea: se comprueba que la función lee lo que
        # PowerShell rellena.
        $script:Guion = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-err-' + [guid]::NewGuid() + '.ps1')
        Set-Content -LiteralPath $script:Guion -Encoding UTF8 -Value @(
            'function Invoke-QueFalla {'
            '    [CmdletBinding()] param()'
            '    throw [InvalidOperationException]::new("algo se ha torcido")'
            '}')
        . $script:Guion

        $script:Capturado = $null
        try { Invoke-QueFalla } catch { $script:Capturado = $_ }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Guion -Force -ErrorAction SilentlyContinue
    }

    It 'la prueba ha capturado un error de verdad: si no, no prueba nada' {
        $script:Capturado | Should -Not -BeNullOrEmpty
        $script:Capturado.InvocationInfo.ScriptName | Should -Not -BeNullOrEmpty
    }

    It 'conserva el mensaje original' {
        Get-DetalleExcepcion -ErrorRecord $script:Capturado | Should -BeLike '*algo se ha torcido*'
    }

    It 'dice el TIPO de excepcion' {
        # El mismo texto puede venir de varias excepciones; el tipo acota.
        Get-DetalleExcepcion -ErrorRecord $script:Capturado | Should -BeLike '*InvalidOperationException*'
    }

    It 'dice el archivo y la linea' {
        $detalle = Get-DetalleExcepcion -ErrorRecord $script:Capturado
        $detalle | Should -BeLike ('*' + (Split-Path -Leaf $script:Guion) + ':*')
        $detalle | Should -Match ':\d+\]'
    }

    It 'solo añade la pila cuando se pide' {
        # En un cuadro de diálogo la pila estorba; en el registro es lo
        # que sirve.
        $corto = Get-DetalleExcepcion -ErrorRecord $script:Capturado
        $largo = Get-DetalleExcepcion -ErrorRecord $script:Capturado -ConPila

        $corto.Contains([Environment]::NewLine) | Should -BeFalse -Because 'sin -ConPila cabe en una linea'
        $largo.Length | Should -BeGreaterThan $corto.Length
        $largo | Should -BeLike '*Invoke-QueFalla*'
    }

    It 'no revienta con un error sin sitio ni con nulo' {
        # Los cierres de la ventana son scriptblocks creados al vuelo: su
        # InvocationInfo puede venir sin ScriptName.
        $sinSitio = $null
        try { & { throw 'suelto' } } catch { $sinSitio = $_ }

        { Get-DetalleExcepcion -ErrorRecord $sinSitio } | Should -Not -Throw
        Get-DetalleExcepcion -ErrorRecord $sinSitio | Should -BeLike '*suelto*'
        Get-DetalleExcepcion -ErrorRecord $null     | Should -Be '(error desconocido)'
    }
}

Describe 'guardar el informe y abrirlo son dos cosas distintas' {

    It 'un fallo al abrir el Explorador no puede decir que no se ha guardado' {
        # Si estuvieran en el mismo try, un fallo de Start-Process diría
        # "No se ha podido guardar el informe" con el archivo ya escrito.
        # Se quitan los comentarios antes de buscar.
        $lineas = Get-Content -LiteralPath (
            Join-Path (Split-Path $PSScriptRoot -Parent) 'src/UI/Window.Eventos.ps1')
        $texto = ($lineas | Where-Object { $_ -notmatch '^\s*#' }) -join [Environment]::NewLine

        $exportar = $texto.IndexOf('$exportar = {')
        $exportar | Should -BeGreaterThan -1

        # Dentro del cierre, Start-Process debe ir después del catch que
        # informa del guardado.
        $trozo   = $texto.Substring($exportar, 3000)
        $catch   = $trozo.IndexOf('No se ha podido guardar el informe')
        $abrir   = $trozo.IndexOf('Start-Process')

        $catch | Should -BeGreaterThan -1
        $abrir | Should -BeGreaterThan $catch -Because (
            'abrir el Explorador va en su propio try, despues del que guarda')
    }

    It 'los catch del informe usan Get-DetalleExcepcion, no el mensaje pelado' {
        $raiz = Split-Path $PSScriptRoot -Parent
        foreach ($archivo in @('src/UI/Window.Eventos.ps1',
                               'src/UI/Window.Analisis.ps1',
                               'src/UI/Window.Eliminacion.ps1')) {
            $texto = Get-Content -Raw -LiteralPath (Join-Path $raiz $archivo)
            if ($texto -match 'podido (guardar|generar) el informe') {
                $texto | Should -Match '(?s)podido (guardar|generar) el informe.{0,200}Get-DetalleExcepcion' -Because $archivo
            }
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
