<#
    Pruebas directas de Test-Cancelacion, Set-Progreso,
    Invoke-BusquedaPorLista y Get-ReferenciaAnterior.

    Test-Cancelacion y Set-Progreso las usan todos los módulos de limpieza.
    Su contrato tolera $Sync nulo a propósito: en modo consola no hay tabla
    que sincronizar y el módulo no pregunta en qué modo está. Un
    [Parameter(Mandatory)] o quitar el "if ($null -eq $Sync)" rompería el
    modo consola.

    Invoke-BusquedaPorLista y Get-ReferenciaAnterior también se ejercitan
    de forma indirecta (BusquedaPorLista.Tests.ps1, Comparacion.Tests.ps1);
    aquí se prueban por sus límites: lista vacía, sin coincidencias,
    historial vacío y entradas malformadas.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # --- Disco simulado para Invoke-BusquedaPorLista -------------------
    #
    # Se monta una vez (los It solo leen). Las variables de entorno apuntan
    # aquí para que la guardia use este árbol, y se restauran en AfterAll:
    # Initialize-Guardia es estado global y el resto de la suite comparte runspace.
    $script:Obra   = Join-Path ([IO.Path]::GetTempPath()) ('progbus-' + [guid]::NewGuid().ToString('N'))
    $script:Dentro = Join-Path $script:Obra 'dentro'
    [void](New-Item -ItemType Directory -Path $script:Dentro -Force)

    $script:EntornoOriginal = @{
        SystemRoot   = $env:SystemRoot
        ProgramData  = $env:ProgramData
        LOCALAPPDATA = $env:LOCALAPPDATA
        APPDATA      = $env:APPDATA
        USERPROFILE  = $env:USERPROFILE
        SystemDrive  = $env:SystemDrive
    }

    $env:SystemRoot   = Join-Path $script:Obra 'Windows'
    $env:ProgramData  = Join-Path $script:Obra 'ProgramData'
    $env:USERPROFILE  = Join-Path $script:Obra 'Usuario'
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'Local'
    $env:APPDATA      = Join-Path $env:USERPROFILE 'Roaming'
    $env:SystemDrive  = $script:Obra

    $script:ConfiguracionGuardia = [pscustomobject]@{
        Escritorio = ''; Documentos = ''; Descargas = ''
        Imagenes   = ''; Musica     = ''; Videos     = ''
        CarpetaDatos = ''
    }
    Initialize-Guardia -Configuracion $script:ConfiguracionGuardia

    function script:New-CarpetaConPeso {
        param([string] $Ruta, [int] $Megas = 3)
        [void](New-Item -ItemType Directory -Path $Ruta -Force)
        $relleno = [byte[]]::new(1MB)
        for ($i = 0; $i -lt $Megas; $i++) {
            [IO.File]::WriteAllBytes((Join-Path $Ruta "relleno$i.bin"), $relleno)
        }
        return $Ruta
    }

    # Por encima del umbral de 1 MB por defecto de los módulos.
    $script:Grande = script:New-CarpetaConPeso (Join-Path $script:Dentro 'grande')
    $script:Otra   = script:New-CarpetaConPeso (Join-Path $script:Dentro 'otra')
    $script:Menor  = script:New-CarpetaConPeso (Join-Path $script:Dentro 'menor')
    # Existe y pesa, pero no cuelga de ninguna raíz autorizada.
    $script:Fuera  = script:New-CarpetaConPeso (Join-Path $script:Obra 'fuera')
    # Existe pero no llega al umbral.
    $script:Peque  = Join-Path $script:Dentro 'peque'
    [void](New-Item -ItemType Directory -Path $script:Peque -Force)
    [IO.File]::WriteAllBytes((Join-Path $script:Peque 'migaja.bin'), [byte[]]::new(1024))
    # No existe, y no se crea nunca.
    $script:NoExiste = Join-Path $script:Dentro 'esto-no-esta'

    # Parámetros comunes de los módulos de lista.
    $script:Comunes = @{
        ModuloId  = 'pruebas'
        Categoria = 'Cachés'
        Raices    = @($script:Dentro)
    }

    # Entrada de historial como las de Add-EntradaHistorial, construida a mano
    # porque se prueba la lectura de un archivo que cualquiera puede editar.
    function script:New-Apunte {
        param(
            [string] $Tipo = 'analisis',
            [string] $Id   = 'x',
            [double] $DiasAtras = 1
        )
        [pscustomobject]@{
            Marca     = $Id
            Tipo      = $Tipo
            Fecha     = (Get-Date).AddDays(-$DiasAtras).ToString('o')
            Perfil    = 'equilibrado'
            Modulos   = @('caches')
            Elementos = 890
            Bytes     = 3435973836.8
        }
    }
}

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
    foreach ($clave in @($script:EntornoOriginal.Keys)) {
        Set-Item -Path ("Env:$clave") -Value $script:EntornoOriginal[$clave] -ErrorAction SilentlyContinue
    }
    # Se reconstruye la guardia con el entorno real: es estado del proceso.
    Initialize-Guardia -Configuracion $script:ConfiguracionGuardia

    if ($script:Obra -and (Test-Path -LiteralPath $script:Obra)) {
        Remove-Item -LiteralPath $script:Obra -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
#  Test-Cancelacion
# =====================================================================

Describe 'Test-Cancelacion: el interruptor que consultan todos los modulos' {

    It 'con $Sync nulo dice que NO se cancela, y de eso vive el modo consola' {
        # Sin tabla, la respuesta es "sigue": los módulos preguntan en cada
        # vuelta sin comprobar el modo.
        Test-Cancelacion $null | Should -BeFalse
    }

    It 'y con $Sync nulo NO lanza, ni siquiera llamandola mil veces seguidas' {
        # Se llama una vez por elemento.
        {
            foreach ($i in 1..1000) { [void](Test-Cancelacion $null) }
        } | Should -Not -Throw
    }

    It 'con Cancelar a $true dice que si' {
        $sync = [hashtable]::Synchronized(@{ Cancelar = $true })
        Test-Cancelacion $sync | Should -BeTrue
    }

    It 'con Cancelar a $false dice que no' {
        $sync = [hashtable]::Synchronized(@{ Cancelar = $false })
        Test-Cancelacion $sync | Should -BeFalse
    }

    It 'devuelve un [bool] de verdad, no lo que hubiera en la propiedad' {
        # La tabla es compartida y puede contener cualquier valor; "if (cadena)"
        # es verdadero para cualquier texto. Hacen falta las dos aserciones.
        $sync = [hashtable]::Synchronized(@{ Cancelar = 'no' })
        $r = Test-Cancelacion $sync
        $r | Should -BeOfType [bool]
        $r | Should -BeTrue -Because 'una cadena no vacia convertida a bool es verdadera'

        $sync.Cancelar = ''
        $r2 = Test-Cancelacion $sync
        $r2 | Should -BeOfType [bool]
        $r2 | Should -BeFalse
    }

    It 'con $Sync nulo tambien devuelve un [bool], no un nulo disfrazado' {
        (Test-Cancelacion $null) | Should -BeOfType [bool]
    }

    It 'una tabla sin la clave Cancelar no cancela' {
        # Una tabla incompleta no puede significar "aborta".
        $sync = [hashtable]::Synchronized(@{ Mensaje = 'hola' })
        $r = Test-Cancelacion $sync
        $r | Should -BeOfType [bool]
        $r | Should -BeFalse
    }

    It 'sobre la tabla que el programa usa de verdad' {
        # Usa New-EstadoSincronizado: detecta cambios de forma que las tablas
        # construidas a mano no verían.
        $sync = New-EstadoSincronizado
        Test-Cancelacion $sync | Should -BeFalse -Because 'un estado recien creado no viene cancelado'

        $sync.Cancelar = $true
        Test-Cancelacion $sync | Should -BeTrue
    }
}

# =====================================================================
#  Set-Progreso
# =====================================================================

Describe 'Set-Progreso: el mensaje tiene que ACABAR en la tabla' {

    It 'el mensaje llega a la tabla, que es lo unico que hace esta funcion' {
        # La interfaz debe poder leer lo que escribe el hilo de trabajo.
        $sync = [hashtable]::Synchronized(@{ Mensaje = '' })
        Set-Progreso $sync 'Midiendo: Temporales del usuario'
        $sync.Mensaje | Should -Be 'Midiendo: Temporales del usuario'
    }

    It 'sobre la tabla que el programa usa de verdad' {
        $sync = New-EstadoSincronizado
        Set-Progreso $sync 'Analizando cachés'
        $sync.Mensaje | Should -Be 'Analizando cachés'
    }

    It 'el mensaje nuevo pisa al anterior' {
        # Es un indicador de estado, no un registro.
        $sync = New-EstadoSincronizado
        Set-Progreso $sync 'primero'
        Set-Progreso $sync 'segundo'
        $sync.Mensaje | Should -Be 'segundo'
    }

    It 'una cadena vacia BORRA el mensaje, no lo deja como estaba' {
        # Así se borra el texto al terminar el análisis.
        $sync = New-EstadoSincronizado
        Set-Progreso $sync 'Midiendo algo'
        Set-Progreso $sync ''
        $sync.Mensaje | Should -Be ''
    }

    It 'no toca ningun otro campo de la tabla' {
        # La tabla la comparten dos hilos: no se puede pisar Cancelar ni Terminado.
        $sync = New-EstadoSincronizado
        $sync.Cancelar  = $true
        $sync.Terminado = $false
        $cola = $sync.ColaRegistro

        Set-Progreso $sync 'Midiendo'

        $sync.Cancelar  | Should -BeTrue
        $sync.Terminado | Should -BeFalse
        [object]::ReferenceEquals($cola, $sync.ColaRegistro) |
            Should -BeTrue -Because 'la cola de registro la comparten los dos hilos: no se puede sustituir'
    }

    It 'con $Sync nulo NO lanza: es el modo consola' {
        # Mismo contrato tolerante que Test-Cancelacion.
        { Set-Progreso $null 'Midiendo algo' } | Should -Not -Throw
    }

    It 'y con $Sync nulo aguanta mil llamadas, como en un analisis de verdad' {
        {
            foreach ($i in 1..1000) { Set-Progreso $null ("Midiendo: elemento $i") }
        } | Should -Not -Throw
    }

    It 'con $Sync nulo tampoco lanza sin mensaje' {
        { Set-Progreso $null } | Should -Not -Throw
    }

    It 'no devuelve NADA por la tuberia, ni con tabla ni sin ella' {
        # Se llama dentro del bucle que emite candidatos: cualquier salida
        # acabaría como candidato.
        $sync = New-EstadoSincronizado
        @(Set-Progreso $sync 'Midiendo').Count | Should -Be 0
        @(Set-Progreso $null 'Midiendo').Count | Should -Be 0
    }
}

Describe 'Las dos juntas: un bucle de modulo sin tabla que sincronizar' {

    It 'un recorrido entero en modo consola no lanza ni se cree cancelado' {
        # Patrón de un módulo: preguntar, trabajar, anunciar.
        # El bucle no va dentro de Should -Not -Throw para que un fallo muestre
        # la excepción real. El contador usa $script: porque el scriptblock
        # tiene su propio ámbito.
        $script:VueltasConsola = 0
        foreach ($i in 1..200) {
            if (Test-Cancelacion $null) { break }
            Set-Progreso $null ("Midiendo: elemento $i")
            $script:VueltasConsola++
        }
        $script:VueltasConsola | Should -Be 200 -Because 'sin tabla, nadie ha cancelado nada'
    }
}

# =====================================================================
#  Invoke-BusquedaPorLista
# =====================================================================

Describe 'Invoke-BusquedaPorLista: el caso feliz y su forma' {

    It 'el arbol de mentira esta montado: si no, todo lo de abajo mira el vacio' {
        # Control: sin el árbol, las pruebas de "no propone nada" pasarían sin comprobar nada.
        Test-Path -LiteralPath $script:Grande | Should -BeTrue
        Test-Path -LiteralPath $script:Fuera  | Should -BeTrue
        (Measure-Ruta $script:Grande) | Should -BeGreaterThan 1MB
        (Measure-Ruta $script:Peque)  | Should -BeLessThan 1MB
    }

    It 'una entrada que existe y pesa sale como candidato, campo a campo' {
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                   @{ N = 'Temporales del usuario'; R = $script:Grande; E = 'se recrean solos' }))

        @($r).Count      | Should -Be 1
        $r[0].Nombre     | Should -Be 'Temporales del usuario'
        $r[0].Ruta       | Should -Be $script:Grande
        $r[0].Efecto     | Should -Be 'se recrean solos'
        $r[0].ModuloId   | Should -Be 'pruebas'
        $r[0].Categoria  | Should -Be 'Cachés'
        $r[0].Metodo     | Should -Be 'Contenido' -Because 'sin M, el metodo por defecto es Contenido'
        $r[0].Riesgo     | Should -Be 'Bajo'
        $r[0].Aviso      | Should -Be ''
        $r[0].Bytes      | Should -BeGreaterThan 1MB
        $r[0].Seleccionado | Should -BeTrue -Because 'riesgo bajo y sin aviso: la regla de New-Candidato lo marca'
        $r[0].ForzarPermanente | Should -BeFalse
        @($r[0].Raices)  | Should -Be @($script:Dentro)
    }

    It 'el Info por defecto se usa tal cual, y -Info lo sustituye' {
        $porDefecto = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                            @{ N = 'A'; R = $script:Grande; E = 'e' }))
        $porDefecto[0].Info | Should -Be 'se vacía el contenido, la carpeta se queda'

        $propio = @(Invoke-BusquedaPorLista @script:Comunes -Info 'se borra entera' -Entradas @(
                        @{ N = 'A'; R = $script:Grande; E = 'e' }))
        $propio[0].Info | Should -Be 'se borra entera'
    }

    It 'M y A de la entrada mandan sobre los valores por defecto' {
        # New-Candidato nunca marca lo que lleva aviso; perder A lo dejaría marcado.
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                   @{ N = 'Base de datos'; R = $script:Grande; E = 'e'
                      M = 'Ruta'; A = 'se borra el historial de actualizaciones' }))

        @($r).Count  | Should -Be 1
        $r[0].Metodo | Should -Be 'Ruta'
        $r[0].Aviso  | Should -Be 'se borra el historial de actualizaciones'
        $r[0].Seleccionado | Should -BeFalse -Because 'lo que lleva aviso no se marca nunca solo'
    }

    It '-ForzarPermanente llega hasta el candidato' {
        # Solo lo usan cachés genuinas; sin él irían a la papelera sin liberar espacio.
        $con = @(Invoke-BusquedaPorLista @script:Comunes -ForzarPermanente -Entradas @(
                     @{ N = 'A'; R = $script:Grande; E = 'e' }))
        $sin = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                     @{ N = 'A'; R = $script:Grande; E = 'e' }))

        $con[0].ForzarPermanente | Should -BeTrue
        $sin[0].ForzarPermanente | Should -BeFalse
    }

    It 'NotaExtra recibe LA ENTRADA como parametro y su texto se pega al Info' {
        # Se pasa como parámetro: el valor de $_ a través de & depende de la
        # versión de PowerShell.
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Info 'base' -Entradas @(
                   @{ N = 'Caché de npm'; R = $script:Grande; E = 'e' }) `
               -NotaExtra { param($entrada) ' [' + $entrada.N + ']' })

        $r[0].Info | Should -Be 'base [Caché de npm]'
    }

    It 'sin NotaExtra el Info sale sin cola' {
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Info 'base' -Entradas @(
                   @{ N = 'A'; R = $script:Grande; E = 'e' }))
        $r[0].Info | Should -Be 'base'
    }

    It 'varias entradas salen todas, y en el orden de la lista' {
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                   @{ N = 'Primera'; R = $script:Grande; E = 'e' },
                   @{ N = 'Segunda'; R = $script:Otra;   E = 'e' }))

        @($r).Count  | Should -Be 2
        $r[0].Nombre | Should -Be 'Primera'
        $r[1].Nombre | Should -Be 'Segunda'
    }
}

Describe 'Invoke-BusquedaPorLista: los limites, que es donde se rompe' {

    It 'una lista vacia no propone nada ni lanza' {
        { [void](Invoke-BusquedaPorLista @script:Comunes -Entradas @()) } | Should -Not -Throw
        @(Invoke-BusquedaPorLista @script:Comunes -Entradas @()).Count | Should -Be 0
    }

    It 'sin ninguna coincidencia: lo que no existe en disco no se propone' {
        # Lo normal es que la mayoría de las rutas de la lista no existan.
        @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
              @{ N = 'Fantasma'; R = $script:NoExiste; E = 'e' })).Count | Should -Be 0
    }

    It 'ni una sola de una lista entera de rutas que no existen' {
        $entradas = @(1..5 | ForEach-Object {
            @{ N = "Fantasma $_"; R = (Join-Path $script:Dentro "no-esta-$_"); E = 'e' }
        })
        @(Invoke-BusquedaPorLista @script:Comunes -Entradas $entradas).Count | Should -Be 0
    }

    It 'lo que no llega al umbral no se propone' {
        @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
              @{ N = 'Migaja'; R = $script:Peque; E = 'e' })).Count | Should -Be 0
    }

    It 'y el umbral es el que pide cada modulo, no uno unico' {
        # windowsupdate usa 10 MB; caches y logs, 1 MB.
        @(Invoke-BusquedaPorLista @script:Comunes -MinimoBytes 10MB -Entradas @(
              @{ N = 'Grande'; R = $script:Grande; E = 'e' })).Count |
            Should -Be 0 -Because 'la carpeta pesa 3 MB y el umbral pedido es 10'

        @(Invoke-BusquedaPorLista @script:Comunes -MinimoBytes 1MB -Entradas @(
              @{ N = 'Grande'; R = $script:Grande; E = 'e' })).Count | Should -Be 1
    }

    It 'una ruta que no cuelga de las raices la veta la guardia' {
        # Existe y pesa, pero está fuera de la lista blanca del módulo.
        Test-Path -LiteralPath $script:Fuera | Should -BeTrue
        @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
              @{ N = 'Fuera'; R = $script:Fuera; E = 'e' })).Count | Should -Be 0
    }

    It 'y la veta ANTES de medirla: no llega a anunciar que la esta midiendo' {
        # Medir cuesta segundos y consultar la guardia, un milisegundo. Invertir
        # el orden no cambia el resultado, solo el tiempo; el mensaje de
        # progreso es la única huella observable.
        $sync = New-EstadoSincronizado
        [void](Invoke-BusquedaPorLista @script:Comunes -Sync $sync -Entradas @(
                   @{ N = 'Fuera'; R = $script:Fuera; E = 'e' }))
        $sync.Mensaje | Should -Be '' -Because 'una ruta vetada no se llega a medir'
    }

    It 'las entradas Menor solo salen con -IncluirMenores' {
        @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
              @{ N = 'Menor'; R = $script:Menor; E = 'e'; Menor = $true })).Count |
            Should -Be 0

        @(Invoke-BusquedaPorLista @script:Comunes -IncluirMenores -Entradas @(
              @{ N = 'Menor'; R = $script:Menor; E = 'e'; Menor = $true })).Count |
            Should -Be 1
    }

    It '-IncluirMenores no cambia nada para las que no son menores' {
        foreach ($incluir in @($true, $false)) {
            $r = @(Invoke-BusquedaPorLista @script:Comunes -IncluirMenores:$incluir -Entradas @(
                       @{ N = 'Normal'; R = $script:Grande; E = 'e' }))
            @($r).Count | Should -Be 1 -Because "con -IncluirMenores:$incluir una entrada normal sale igual"
        }
    }

    It 'una entrada malformada no tumba el recorrido: la siguiente sigue saliendo' {
        # Una entrada rota no puede impedir las siguientes ni producir un
        # candidato sin ruta.
        #
        # En PowerShell 7, Test-Path con ruta nula escribe un error no
        # terminante; en 5.1 el enlazador de parámetros lanza y aborta el
        # bucle. Candidate.ps1 tiene una guarda explícita, y la prueba va sin
        # -ErrorAction para exigir además que no se escriba ningún error.
        # Quitar la guarda solo se detecta en el trabajo de PowerShell 5.1 de la CI.
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                   @{ N = 'Sin ruta'; E = 'e' },
                   @{ N = 'Buena'; R = $script:Grande; E = 'e' }))

        @($r).Count  | Should -Be 1
        $r[0].Nombre | Should -Be 'Buena'
    }

    It 'una entrada con la ruta en blanco tampoco' {
        # Misma guarda que el nulo: Test-Path con "" también lanza en 5.1.
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                   @{ N = 'Vacia'; R = ''; E = 'e' },
                   @{ N = 'Espacios'; R = '   '; E = 'e' },
                   @{ N = 'Buena'; R = $script:Grande; E = 'e' }))

        @($r).Count  | Should -Be 1
        $r[0].Nombre | Should -Be 'Buena'
    }

    It 'una entrada nula tampoco lo tumba' {
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
                   $null,
                   @{ N = 'Buena'; R = $script:Grande; E = 'e' }))

        @($r).Count  | Should -Be 1
        $r[0].Nombre | Should -Be 'Buena'
    }

    It 'una entrada suelta, sin envolver en lista, se recorre igual' {
        # En 5.1 una colección de un elemento se desenvuelve sola. La prueba
        # fija el comportamiento: el @($Entradas) del código no es lo que lo
        # garantiza, porque foreach sobre un hashtable ya lo recorre entero.
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Entradas @{ N = 'Sola'; R = $script:Grande; E = 'e' })
        @($r).Count  | Should -Be 1
        $r[0].Nombre | Should -Be 'Sola'
    }
}

Describe 'Invoke-BusquedaPorLista: progreso y cancelacion, sus dos vecinas' {

    It 'anuncia por Set-Progreso lo que esta midiendo, con el nombre de la entrada' {
        $sync = New-EstadoSincronizado
        [void](Invoke-BusquedaPorLista @script:Comunes -Sync $sync -Entradas @(
                   @{ N = 'Caché de npm'; R = $script:Grande; E = 'e' }))
        $sync.Mensaje | Should -Be 'Midiendo: Caché de npm'
    }

    It 'con $Sync nulo propone lo mismo: es como lo llama el modo consola' {
        # Llama a Test-Cancelacion y Set-Progreso en cada vuelta sin comprobar
        # si hay tabla: justifica el contrato tolerante con $Sync nulo.
        $conTabla = @(Invoke-BusquedaPorLista @script:Comunes -Sync (New-EstadoSincronizado) -Entradas @(
                          @{ N = 'A'; R = $script:Grande; E = 'e' }))
        $sinTabla = @(Invoke-BusquedaPorLista @script:Comunes -Sync $null -Entradas @(
                          @{ N = 'A'; R = $script:Grande; E = 'e' }))

        @($sinTabla).Count | Should -Be 1
        @($sinTabla).Count | Should -Be @($conTabla).Count
        $sinTabla[0].Ruta  | Should -Be $conTabla[0].Ruta
    }

    It 'sin -Sync tampoco: el parametro es opcional y su valor por defecto es nulo' {
        @(Invoke-BusquedaPorLista @script:Comunes -Entradas @(
              @{ N = 'A'; R = $script:Grande; E = 'e' })).Count | Should -Be 1
    }

    It 'cancelado de antemano no propone ni el primero' {
        $sync = New-EstadoSincronizado
        $sync.Cancelar = $true
        @(Invoke-BusquedaPorLista @script:Comunes -Sync $sync -Entradas @(
              @{ N = 'A'; R = $script:Grande; E = 'e' },
              @{ N = 'B'; R = $script:Otra;   E = 'e' })).Count | Should -Be 0
    }

    It 'cancelar a mitad corta ahi: sale lo ya propuesto y nada mas' {
        # Se consulta en cada vuelta, no solo al entrar.
        $script:SyncCorte = New-EstadoSincronizado
        $r = @(Invoke-BusquedaPorLista @script:Comunes -Sync $script:SyncCorte -Entradas @(
                   @{ N = 'Primera'; R = $script:Grande; E = 'e' },
                   @{ N = 'Segunda'; R = $script:Otra;   E = 'e' }) `
               -NotaExtra { param($entrada) $script:SyncCorte.Cancelar = $true; '' })

        @($r).Count  | Should -Be 1
        $r[0].Nombre | Should -Be 'Primera'
    }
}

# =====================================================================
#  Get-ReferenciaAnterior
# =====================================================================

Describe 'Get-ReferenciaAnterior: con que se compara un analisis' {

    It 'un historial nulo no da referencia' {
        # Primer arranque o historial.json ilegible.
        Get-ReferenciaAnterior -Historial $null | Should -BeNullOrEmpty
    }

    It 'un historial vacio tampoco' {
        Get-ReferenciaAnterior -Historial @() | Should -BeNullOrEmpty
    }

    It 'y ninguno de los dos lanza' {
        { [void](Get-ReferenciaAnterior -Historial $null) } | Should -Not -Throw
        { [void](Get-ReferenciaAnterior -Historial @()) }   | Should -Not -Throw
    }

    It 'un analisis si sirve de referencia, y se devuelve tal cual' {
        # Se devuelve la entrada original: quien llama lee Elementos, Bytes,
        # Fecha, Perfil, Modulos e Incompleto.
        $apunte = script:New-Apunte -Id 'unico'
        $r = Get-ReferenciaAnterior -Historial @($apunte)

        $r | Should -Not -BeNullOrEmpty
        $r.Marca     | Should -Be 'unico'
        $r.Elementos | Should -Be 890
        [object]::ReferenceEquals($apunte, $r) | Should -BeTrue
    }
}

Describe 'Get-ReferenciaAnterior: lo que NO vale como termino de comparacion' {

    It 'una limpieza no vale, aunque sea el ultimo apunte' {
        # En una limpieza, Elementos y Bytes son lo borrado y liberado, no lo encontrado.
        Get-ReferenciaAnterior -Historial @(script:New-Apunte -Tipo 'limpieza' -Id 'L1') |
            Should -BeNullOrEmpty
    }

    It 'un historial de puras limpiezas no da referencia' {
        $h = @(
            script:New-Apunte -Tipo 'limpieza' -Id 'L1' -DiasAtras 5
            script:New-Apunte -Tipo 'limpieza' -Id 'L2' -DiasAtras 2
        )
        Get-ReferenciaAnterior -Historial $h | Should -BeNullOrEmpty
    }

    It 'un tipo que no se conoce tampoco vale' {
        # historial.json es editable: puede traer tipos futuros o inventados.
        Get-ReferenciaAnterior -Historial @(script:New-Apunte -Tipo 'limpieza-interrumpida' -Id 'R1') |
            Should -BeNullOrEmpty
    }

    It 'una entrada sin Tipo no cuela' {
        Get-ReferenciaAnterior -Historial @([pscustomobject]@{ Marca = 'S1'; Elementos = 3 }) |
            Should -BeNullOrEmpty
    }

    It 'un Tipo que llega como LISTA no cuela, ni siquiera si todo dentro es analisis' {
        # Motivo de [string]$entrada.Tipo: con una lista, la comparación sin
        # convertir devuelve una lista vacía (falso) y la entrada pasaría el filtro. Convertida, vale
        # "analisis analisis" y se descarta. Este caso falla si se quita el [string].
        Get-ReferenciaAnterior -Historial @([pscustomobject]@{ Tipo = @('analisis', 'analisis'); Marca = 'AR' }) |
            Should -BeNullOrEmpty

        Get-ReferenciaAnterior -Historial @([pscustomobject]@{ Tipo = @('analisis', 'limpieza'); Marca = 'AR2' }) |
            Should -BeNullOrEmpty
    }

    It 'basura suelta en la lista no cuela ni lanza' {
        # El archivo es editable: puede traer cadenas, números o nulos.
        { [void](Get-ReferenciaAnterior -Historial @('basura', 42, $null)) } | Should -Not -Throw
        Get-ReferenciaAnterior -Historial @('basura', 42, $null) | Should -BeNullOrEmpty
    }

    It 'un historial de puros nulos no da referencia' {
        Get-ReferenciaAnterior -Historial @($null, $null) | Should -BeNullOrEmpty
    }
}

Describe 'Get-ReferenciaAnterior: cual de todos los analisis' {

    It 'el ULTIMO analisis, saltandose las limpiezas que vengan detras' {
        # Una limpieza posterior no invalida el último análisis.
        $h = @(
            script:New-Apunte -Tipo 'analisis' -Id 'A1' -DiasAtras 9
            script:New-Apunte -Tipo 'analisis' -Id 'A2' -DiasAtras 5
            script:New-Apunte -Tipo 'limpieza' -Id 'L1' -DiasAtras 1
        )
        (Get-ReferenciaAnterior -Historial $h).Marca | Should -Be 'A2'
    }

    It 'las entradas nulas de en medio se saltan sin perder la buena' {
        $h = @($null, (script:New-Apunte -Id 'A1'), $null)
        (Get-ReferenciaAnterior -Historial $h).Marca | Should -Be 'A1'
    }

    It 'el ULTIMO del archivo, no el de Fecha mayor' {
        # El historial se añade al final, así que el orden del archivo es el de
        # ejecución; la fecha puede faltar, estar corrupta o venir de un reloj desajustado.
        $h = @(
            script:New-Apunte -Id 'la-de-fecha-mas-nueva' -DiasAtras 0
            script:New-Apunte -Id 'la-ultima-del-archivo' -DiasAtras 400
        )
        (Get-ReferenciaAnterior -Historial $h).Marca |
            Should -Be 'la-ultima-del-archivo' -Because 'manda el orden del archivo, no la fecha'
    }

    It 'una fecha ausente o ilegible no impide elegir referencia' {
        # Una fecha rota no puede dejar sin comparación para siempre.
        $h = @(
            [pscustomobject]@{ Tipo = 'analisis'; Marca = 'sin-fecha'; Elementos = 12 }
            [pscustomobject]@{ Tipo = 'analisis'; Marca = 'fecha-rota'; Fecha = 'ni-fecha-ni-nada'; Elementos = 7 }
        )
        (Get-ReferenciaAnterior -Historial $h).Marca | Should -Be 'fecha-rota'
    }

    It 'un historial que no es lista sino una entrada suelta tambien vale' {
        # Con un único apunte, Get-Historial devuelve un objeto suelto (en 5.1
        # una colección de uno se desenvuelve). Es el caso del segundo análisis.
        (Get-ReferenciaAnterior -Historial (script:New-Apunte -Id 'sola')).Marca | Should -Be 'sola'
    }

    It 'devuelve UNA entrada, no una lista de todas las que valian' {
        # Quien llama usa $anterior.Elementos, que debe ser un solo número.
        $h = @(
            script:New-Apunte -Id 'A1' -DiasAtras 9
            script:New-Apunte -Id 'A2' -DiasAtras 5
            script:New-Apunte -Id 'A3' -DiasAtras 1
        )
        @(Get-ReferenciaAnterior -Historial $h).Count | Should -Be 1
    }
}
