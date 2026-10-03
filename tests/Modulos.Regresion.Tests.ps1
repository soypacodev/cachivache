<#
    Pruebas de regresión del comportamiento de módulos concretos.

    Modules.Tests.ps1 comprueba el contrato común (Id y Orden únicos,
    perfiles válidos...); aquí se fija que cada módulo decide lo que debe.
    Cada Describe cubre un fallo corregido; las regresiones nuevas de un
    módulo van aquí.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
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
}

Describe 'Modulo descargas: escala de riesgo' {

    BeforeEach {
        $script:carpetaDescargas = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-desc-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:carpetaDescargas -Force | Out-Null

        $script:modulo = Get-ModuloLimpieza -Id 'descargas' -Raiz $script:Raiz
        $script:sync = New-EstadoSincronizado
        $script:configuracion = [pscustomobject]@{
            Descargas  = $script:carpetaDescargas
            DiasSinUso = 30
            MinimoMB   = 0
            Admin      = $true
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:carpetaDescargas -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un instalador antiguo suelto es riesgo Bajo' {
        $archivo = Join-Path $script:carpetaDescargas 'instalador.exe'
        Set-Content -LiteralPath $archivo -Value ('x' * 100) -NoNewline
        (Get-Item -LiteralPath $archivo).LastWriteTime = (Get-Date).AddDays(-60)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 1
        $resultado.Candidatos[0].Riesgo | Should -Be 'Bajo'
    }

    It 'un comprimido antiguo sigue siendo riesgo Medio (puede contener cualquier cosa)' {
        $archivo = Join-Path $script:carpetaDescargas 'descarga.zip'
        Set-Content -LiteralPath $archivo -Value ('x' * 100) -NoNewline
        (Get-Item -LiteralPath $archivo).LastWriteTime = (Get-Date).AddDays(-60)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 1
        $resultado.Candidatos[0].Riesgo | Should -Be 'Medio'
    }

    It 'nunca premarca nada, sea cual sea el riesgo' {
        $archivo = Join-Path $script:carpetaDescargas 'instalador.exe'
        Set-Content -LiteralPath $archivo -Value ('x' * 100) -NoNewline
        (Get-Item -LiteralPath $archivo).LastWriteTime = (Get-Date).AddDays(-60)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos[0].Seleccionado | Should -BeFalse
    }
}

Describe 'Modulo temporales: no toca lo que puede estar en uso ahora mismo' {

    BeforeEach {
        $script:carpetaZona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-temp-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:carpetaZona -Force | Out-Null

        $script:modulo = Get-ModuloLimpieza -Id 'temporales' -Raiz $script:Raiz
        $script:sync = New-EstadoSincronizado
        $script:configuracion = [pscustomobject]@{
            ZonasUsuario = @($script:carpetaZona)
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:carpetaZona -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'NO propone un archivo de bloqueo de Office (~$) reciente' {
        $archivo = Join-Path $script:carpetaZona '~$documento.docx'
        Set-Content -LiteralPath $archivo -Value 'x' -NoNewline

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 0
    }

    It 'SI propone un archivo de bloqueo de Office (~$) con mas de 30 minutos' {
        $archivo = Join-Path $script:carpetaZona '~$documento.docx'
        Set-Content -LiteralPath $archivo -Value 'x' -NoNewline
        (Get-Item -LiteralPath $archivo -Force).LastWriteTime = (Get-Date).AddHours(-2)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 1
    }

    It 'NO propone una descarga a medias (.crdownload) reciente' {
        $archivo = Join-Path $script:carpetaZona 'pelicula.crdownload'
        Set-Content -LiteralPath $archivo -Value 'x' -NoNewline

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 0
    }

    It 'SI propone un .tmp antiguo' {
        $archivo = Join-Path $script:carpetaZona 'restos.tmp'
        Set-Content -LiteralPath $archivo -Value 'x' -NoNewline
        (Get-Item -LiteralPath $archivo -Force).LastWriteTime = (Get-Date).AddHours(-2)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 1
    }

    It 'no casa cualquier nombre con ".~" en cualquier posicion, solo la extension' {
        # Solo cuenta si la extensión empieza por ".~": '*.~*' casaría
        # también "informe.~final.docx".
        $archivoNormal = Join-Path $script:carpetaZona 'informe.~final.docx'
        Set-Content -LiteralPath $archivoNormal -Value 'x' -NoNewline
        (Get-Item -LiteralPath $archivoNormal -Force).LastWriteTime = (Get-Date).AddDays(-1)

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 0
    }
}

Describe 'Modulo carpetas vacias: comprobacion no recursiva' {

    BeforeEach {
        $script:carpetaZona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-vacias-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:carpetaZona -Force | Out-Null

        $script:modulo = Get-ModuloLimpieza -Id 'vacias' -Raiz $script:Raiz
        $script:sync = New-EstadoSincronizado
        $script:configuracion = [pscustomobject]@{ ZonasUsuario = @($script:carpetaZona) }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:carpetaZona -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'SIGUE proponiendo una carpeta hoja realmente vacia' {
        $vacia = Join-Path $script:carpetaZona 'vacia'
        New-Item -ItemType Directory -Path $vacia -Force | Out-Null

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 1
        $resultado.Candidatos[0].Ruta | Should -Be $vacia
    }

    It 'NO propone una carpeta que tiene un archivo dentro' {
        $conArchivo = Join-Path $script:carpetaZona 'con-archivo'
        New-Item -ItemType Directory -Path $conArchivo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $conArchivo 'algo.txt') -Value 'x' -NoNewline

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 0
    }

    It 'una cadena de carpetas vacias se propone UNA vez, por la mas alta' {
        # Se propone solo 'padre': borrarlo se lleva toda la cadena, en
        # una sola ejecución.
        $padre = Join-Path $script:carpetaZona 'padre'
        $hija  = Join-Path $padre 'hija'
        $nieta = Join-Path $hija 'nieta'
        New-Item -ItemType Directory -Path $nieta -Force | Out-Null

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $rutas = @($resultado.Candidatos | ForEach-Object { $_.Ruta })
        $rutas | Should -Contain $padre
        $rutas | Should -Not -Contain $hija -Because 'borrar el padre ya se la lleva'
        $rutas | Should -Not -Contain $nieta
        $rutas.Count | Should -Be 1
    }

    It 'un archivo en el fondo de la cadena salva a TODA la cadena' {
        # Se comprueba el subárbol entero: un archivo en el último nivel
        # salva a toda la cadena.
        $padre = Join-Path $script:carpetaZona 'padre'
        $hija  = Join-Path $padre 'hija'
        New-Item -ItemType Directory -Path $hija -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $hija 'importante.txt') -Value 'x' -NoNewline

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $resultado.Candidatos.Count | Should -Be 0
    }

    It 'una rama con archivos no impide proponer la rama vecina que si esta vacia' {
        $conArchivo = Join-Path $script:carpetaZona 'ocupada'
        New-Item -ItemType Directory -Path $conArchivo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $conArchivo 'algo.txt') -Value 'x' -NoNewline
        $vacia = Join-Path $script:carpetaZona 'libre'
        New-Item -ItemType Directory -Path (Join-Path $vacia 'dentro') -Force | Out-Null

        $resultado = Invoke-ModuloLimpieza -Modulo $script:modulo -Configuracion $script:configuracion -Sync $script:sync

        $rutas = @($resultado.Candidatos | ForEach-Object { $_.Ruta })
        $rutas | Should -Contain $vacia
        $rutas | Should -Not -Contain $conArchivo
    }
}

Describe 'Modulo restos de programas: no inventa entradas por valores binarios' {

    It 'Get-EjecutableDeComando nunca revienta con valores no-string' {
        # El filtro "$_.Value -isnot [string]" de 90-Arranque.ps1 evita
        # llamar aquí con un byte[]; la función sigue siendo solo de texto.
        { Get-EjecutableDeComando ([string]([byte[]]@(1,0,0))) } | Should -Not -Throw
    }
}

Describe 'Get-TemaDeWindows' {

    <#
        Solo se consulta en el primer arranque, antes de que exista ninguna
        ventana: una excepción impediría abrir el programa. Sin registro
        (las pruebas corren en Linux) debe responder igual.
    #>

    It 'devuelve siempre claro u oscuro, nunca nada mas' {
        Get-TemaDeWindows | Should -BeIn @('claro', 'oscuro')
    }

    It 'no lanza aunque no exista el registro' {
        { Get-TemaDeWindows } | Should -Not -Throw
    }

    It 'responde oscuro cuando no se puede leer la clave' {
        Mock Get-ItemProperty { throw 'no existe' }
        Get-TemaDeWindows | Should -Be 'oscuro' -Because 'es lo que el programa venia haciendo siempre'
    }

    It 'traduce el valor del registro: <Valor> -> <Esperado>' -ForEach @(
        @{ Valor = 1; Esperado = 'claro'  }
        @{ Valor = 0; Esperado = 'oscuro' }
    ) {
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = $Valor } }
        Get-TemaDeWindows | Should -Be $Esperado
    }

    It 'el primer arranque hereda el tema del sistema' {
        # Sin preferencias, el tema sale de Windows; con archivo, manda lo
        # guardado.
        $carpeta = Join-Path ([IO.Path]::GetTempPath()) ('pref_' + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 1 } }
        Mock Get-RutaPreferencias { Join-Path $carpeta 'preferencias.json' }
        try {
            (Import-Preferencias).Tema | Should -Be 'claro'
        } finally {
            Remove-Item -LiteralPath $carpeta -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Las preferencias del archivo se validan antes de usarse' {

    <#
        preferencias.json es texto plano en una carpeta escribible y sus
        valores van a controles tipados: un "MinimoMB": "diez" impediría
        abrir el programa. Lo que no encaja vuelve a su valor por defecto.
    #>

    BeforeEach {
        $script:CarpetaPref = Join-Path ([IO.Path]::GetTempPath()) ('pref_' + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:CarpetaPref -Force | Out-Null
        Mock Get-RutaPreferencias { Join-Path $script:CarpetaPref 'preferencias.json' }
        Mock Get-TemaDeWindows { 'oscuro' }
        # Un archivo ilegible se anota en el registro: aquí no se escribe.
        Mock Write-Registro { }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:CarpetaPref -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un tema inventado vuelve al valor por defecto' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "Tema": "fucsia" }'
        (Import-Preferencias).Tema | Should -Be 'oscuro'
    }

    It 'un perfil inventado vuelve al valor por defecto' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "Perfil": "destructor" }'
        (Import-Preferencias).Perfil | Should -Be 'equilibrado'
    }

    It 'un umbral que no es numero vuelve al valor por defecto' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "DiasSinUso": "ciento ochenta", "MinimoMB": [1,2] }'
        $p = Import-Preferencias
        $p.DiasSinUso | Should -Be 180
        $p.MinimoMB   | Should -Be 10
    }

    It 'un umbral fuera del rango del deslizador vuelve al valor por defecto' {
        # WPF lo recortaría al pintar y la preferencia dejaría de coincidir
        # con lo que se ve.
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "MinimoMB": 99999, "DiasSinUso": 2 }'
        $p = Import-Preferencias
        $p.MinimoMB   | Should -Be 10
        $p.DiasSinUso | Should -Be 180
    }

    It 'un umbral valido si se respeta' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "MinimoMB": 250, "DiasSinUso": 365 }'
        $p = Import-Preferencias
        $p.MinimoMB   | Should -Be 250
        $p.DiasSinUso | Should -Be 365
    }

    It 'una casilla que no es booleana vuelve al valor por defecto' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "IncluirMenores": "quiza", "Permanente": 1 }'
        $p = Import-Preferencias
        $p.IncluirMenores | Should -BeFalse
        # Un 1 no es $true: aceptar números como booleanos podría activar
        # el borrado permanente sin querer.
        $p.Permanente     | Should -BeFalse
    }

    It 'una casilla booleana de verdad si se respeta' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "Permanente": true }'
        (Import-Preferencias).Permanente | Should -BeTrue
    }

    It 'las listas se limpian elemento a elemento' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "ModulosActivos": ["caches", 42, null, "", "vacias"] }'
        $lista = @((Import-Preferencias).ModulosActivos)
        $lista.Count | Should -Be 2
        $lista       | Should -Contain 'caches'
        $lista       | Should -Contain 'vacias'
    }

    It 'un valor suelto donde se espera una lista se envuelve' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "UnidadesExcluidas": "D:" }'
        $lista = @((Import-Preferencias).UnidadesExcluidas)
        $lista.Count | Should -Be 1
        $lista[0]    | Should -Be 'D:'
    }

    It 'un archivo entero ilegible no impide arrancar' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ esto no es json'
        $p = $null
        { $p = Import-Preferencias } | Should -Not -Throw
        (Import-Preferencias).Perfil | Should -Be 'equilibrado'
    }

    It 'un archivo ilegible se copia aparte antes de que se guarde encima' {
        # Al cerrar se guardan los valores por defecto: sin copia, las
        # exclusiones del archivo roto se perderian sin aviso.
        $ruta = Join-Path $script:CarpetaPref 'preferencias.json'
        $roto = '{ "RutasExcluidas": ["C:\\proyectos\\vivo"], '
        Set-Content -LiteralPath $ruta -Value $roto -NoNewline
        Mock Write-Registro { }

        (Import-Preferencias).RutasExcluidas.Count | Should -Be 0
        $copia = "$ruta.corrupto"
        Test-Path -LiteralPath $copia | Should -BeTrue
        Get-Content -LiteralPath $copia -Raw | Should -Be $roto
        Should -Invoke Write-Registro -Times 1 -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensaje -match 'corrupto' }
    }

    It 'una segunda copia de un archivo ilegible no pisa la primera' {
        $ruta = Join-Path $script:CarpetaPref 'preferencias.json'
        Set-Content -LiteralPath "$ruta.corrupto" -Value 'primera' -NoNewline
        Set-Content -LiteralPath $ruta -Value '[1, 2' -NoNewline
        Mock Write-Registro { }

        $null = Import-Preferencias
        Get-Content -LiteralPath "$ruta.corrupto" -Raw | Should -Be 'primera'
        @(Get-ChildItem -LiteralPath $script:CarpetaPref -Filter 'preferencias.json.corrupto-*').Count | Should -Be 1
    }

    It 'un JSON valido que no es un objeto tambien se conserva aparte' {
        $ruta = Join-Path $script:CarpetaPref 'preferencias.json'
        Set-Content -LiteralPath $ruta -Value '[1, 2, 3]' -NoNewline
        Mock Write-Registro { }

        (Import-Preferencias).Perfil | Should -Be 'equilibrado'
        Test-Path -LiteralPath "$ruta.corrupto" | Should -BeTrue
    }

    It 'un numero suelto tampoco es un archivo de preferencias' {
        $ruta = Join-Path $script:CarpetaPref 'preferencias.json'
        Set-Content -LiteralPath $ruta -Value '42' -NoNewline

        (Import-Preferencias).Perfil | Should -Be 'equilibrado'
        Test-Path -LiteralPath "$ruta.corrupto" | Should -BeTrue
    }

    It 'Save-CopiaArchivoIlegible devuelve la ruta de la copia, o $null si no puede' {
        $ruta = Join-Path $script:CarpetaPref 'datos.json'
        Set-Content -LiteralPath $ruta -Value 'x' -NoNewline
        Save-CopiaArchivoIlegible -Ruta $ruta | Should -Be "$ruta.corrupto"
        Save-CopiaArchivoIlegible -Ruta (Join-Path $script:CarpetaPref 'no-existe.json') | Should -BeNullOrEmpty
    }

    It 'Write-AvisoArchivoIlegible anota un AVISO en el registro' {
        Mock Write-Registro { }
        Write-AvisoArchivoIlegible -Mensaje 'prueba de aviso'
        Should -Invoke Write-Registro -Times 1 -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensaje -eq 'prueba de aviso' }
    }

    It 'un archivo vacio no se toma por ilegible' {
        $ruta = Join-Path $script:CarpetaPref 'preferencias.json'
        Set-Content -LiteralPath $ruta -Value '' -NoNewline
        (Import-Preferencias).Perfil | Should -Be 'equilibrado'
        Test-Path -LiteralPath "$ruta.corrupto" | Should -BeFalse
    }

    It 'lo bueno sobrevive aunque lo demas sea basura' {
        Set-Content -LiteralPath (Join-Path $script:CarpetaPref 'preferencias.json') -Value '{ "Tema": "claro", "Perfil": "destructor", "MinimoMB": "x" }'
        $p = Import-Preferencias
        $p.Tema     | Should -Be 'claro'
        $p.Perfil   | Should -Be 'equilibrado'
        $p.MinimoMB | Should -Be 10
    }
}

Describe 'las carpetas vacias fuera de AppData no se premarcan' {

    <#
        En AppData una carpeta vacía es basura; en el Escritorio o en
        Documentos puede ser una carpeta recién creada para organizar.
    #>

    BeforeAll {
        $script:padreVacias = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-vacias-' + [guid]::NewGuid())
        $script:zonaUsuario = Join-Path $script:padreVacias 'Escritorio'
        New-Item -ItemType Directory -Path (Join-Path $script:zonaUsuario 'Proyecto Nuevo') -Force | Out-Null

        # En Windows la carpeta temporal está dentro de AppData\Local: se
        # apunta AppData a otro sitio para que el Escritorio de prueba quede
        # fuera, como el de verdad.
        $script:AppDataVacias = @{ Local = $env:LOCALAPPDATA; Roaming = $env:APPDATA; Datos = $env:ProgramData }
        $env:LOCALAPPDATA = Join-Path $script:padreVacias 'AppData\Local'
        $env:APPDATA      = Join-Path $script:padreVacias 'AppData\Roaming'
        $env:ProgramData  = Join-Path $script:padreVacias 'ProgramData'

        $modulo = Get-ModuloLimpieza -Id 'vacias' -Raiz (Split-Path $PSScriptRoot -Parent)
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
                     -Configuracion ([pscustomobject]@{
                         ZonasUsuario = @($script:zonaUsuario)
                         DiasSinUso = 30; MinimoMB = 0; Admin = $true
                     })
        $script:CandidatosVacias = @($resultado.Candidatos)
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:AppDataVacias.Local
        $env:APPDATA      = $script:AppDataVacias.Roaming
        $env:ProgramData  = $script:AppDataVacias.Datos
        Remove-Item -LiteralPath $script:padreVacias -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'propone la carpeta, porque esta vacia de verdad' {
        @($script:CandidatosVacias | Where-Object { $_.Ruta -like '*Proyecto Nuevo' }).Count |
            Should -Be 1
    }

    It 'pero NO la premarca: se creo hace un momento y esta fuera de AppData' {
        $c = $script:CandidatosVacias | Where-Object { $_.Ruta -like '*Proyecto Nuevo' }
        $c.Seleccionado | Should -BeFalse -Because 'puede ser una carpeta que el usuario acaba de crear para ordenar'
        $c.Aviso        | Should -Not -BeNullOrEmpty
    }
}

Describe 'vendor y target dejan de ser prueba suficiente' {

    <#
        En Go, vendor/ se versiona para compilar sin red: borrarlo rompe el
        proyecto. Y "target" es un nombre corriente fuera de Rust y Maven.
    #>

    BeforeAll {
        $script:padreProy = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-proy-' + [guid]::NewGuid())

        # Un "vendor" suelto, sin manifiesto de ningún ecosistema al lado.
        $sueltos = Join-Path $script:padreProy 'CarpetaCualquiera'
        New-Item -ItemType Directory -Path (Join-Path $sueltos 'vendor') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $sueltos 'vendor') 'a.bin') -Value ('x' * 4096) -NoNewline

        $modulo = Get-ModuloLimpieza -Id 'proyectos' -Raiz (Split-Path $PSScriptRoot -Parent)
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
                     -Configuracion ([pscustomobject]@{
                         RaicesProyecto = @($script:padreProy)
                         DiasSinUso = 0; MinimoMB = 0; Admin = $true
                     })
        $script:RutasProy = @($resultado.Candidatos | ForEach-Object { $_.Ruta })
    }

    AfterAll {
        Remove-Item -LiteralPath $script:padreProy -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'no propone un "vendor" sin manifiesto de su ecosistema al lado' {
        @($script:RutasProy | Where-Object { $_ -like '*vendor' }).Count |
            Should -Be 0 -Because 'en Go vendor/ se versiona y es necesario para compilar sin red'
    }
}

Describe 'un informe de archivos grandes no pinta la lista de rojo' {

    It 'los archivos grandes son riesgo Medio, no Alto' {
        # El módulo solo informa: marcar en rojo un vídeo de 8 GB no aporta
        # nada y distorsiona el resumen.
        $texto = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Modules') '60-ArchivosGrandes.ps1')
        $texto | Should -Match "Metodo 'Informativo' -Raices \`$zonas -Riesgo 'Medio'"
    }
}

Describe 'el recorrido de carpetas vacias poda en vez de filtrar' {

    <#
        node_modules, .git, .svn y .hg no son candidatas y además cuentan
        como contenido de su carpeta padre. No se entra en ellas, pero el
        veredicto no cambia: una carpeta que solo contiene un .git no está
        vacía.
    #>

    BeforeAll {
        $script:padreNv = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-poda-' + [guid]::NewGuid())
        $zona = Join-Path $script:padreNv 'Zona'

        # Vacía de verdad.
        New-Item -ItemType Directory -Path (Join-Path $zona 'VaciaDeVerdad') -Force | Out-Null

        # Solo contiene un .git: no está vacía.
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $zona 'ConGit') '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $zona 'ConGit') '.git') 'HEAD') `
                    -Value 'ref: refs/heads/main' -NoNewline

        # Cadena de vacías anidadas: se propone solo la más alta.
        New-Item -ItemType Directory -Path (Join-Path (Join-Path (Join-Path $zona 'Cadena') 'b') 'c') -Force | Out-Null

        $modulo = Get-ModuloLimpieza -Id 'vacias' -Raiz (Split-Path $PSScriptRoot -Parent)
        $r = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
             -Configuracion ([pscustomobject]@{
                 ZonasUsuario = @($zona); DiasSinUso = 0; MinimoMB = 0; Admin = $true
             })
        $script:RutasNv = @($r.Candidatos | ForEach-Object { $_.Ruta })
    }

    AfterAll {
        Remove-Item -LiteralPath $script:padreNv -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'propone la carpeta que esta vacia de verdad' {
        @($script:RutasNv | Where-Object { $_ -like '*VaciaDeVerdad' }).Count | Should -Be 1
    }

    It 'NO propone la que solo contiene un .git' {
        @($script:RutasNv | Where-Object { $_ -like '*ConGit' }).Count |
            Should -Be 0 -Because 'una carpeta con un repositorio dentro no esta vacia'
    }

    It 'no propone el propio .git' {
        @($script:RutasNv | Where-Object { $_ -like '*.git*' }).Count | Should -Be 0
    }

    It 'de una cadena anidada propone solo la carpeta mas alta' {
        @($script:RutasNv | Where-Object { $_ -like '*Cadena*' }).Count | Should -Be 1
        @($script:RutasNv | Where-Object { $_ -like '*Cadena' }).Count  | Should -Be 1
    }
}

Describe 'las rutas de los modulos no llevan tildes de la prosa' {

    It 'ninguna ruta R = "..." de un modulo contiene "caché" con tilde' {
        # Las carpetas reales de Windows y de los programas se llaman "Cache":
        # una ruta con "Caché" nunca existe en disco y el candidato no aparece.
        $modulos = Get-ChildItem -LiteralPath (Join-Path (Join-Path $script:Raiz 'src') 'Modules') -Filter '*.ps1'
        $conTilde = foreach ($archivo in $modulos) {
            $texto = Get-Content -LiteralPath $archivo.FullName -Raw -Encoding UTF8
            foreach ($m in [regex]::Matches($texto, '\bR\s*=\s*"([^"]*)"')) {
                if ($m.Groups[1].Value -match '(?i)caché') { '{0}: {1}' -f $archivo.Name, $m.Groups[1].Value }
            }
        }
        @($conTilde) | Should -BeNullOrEmpty
    }
}

Describe 'Modulo componentes: interpreta la salida inglesa de DISM' {

    BeforeAll {
        $script:tallerDism = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-dism-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tallerDism -Force | Out-Null
        $script:systemRootAnterior = $env:SystemRoot
        $env:SystemRoot = $script:tallerDism
        $script:dismFalso = Join-Path $script:tallerDism 'dism-falso.ps1'
    }

    AfterAll {
        $env:SystemRoot = $script:systemRootAnterior
        Remove-Item -LiteralPath $script:tallerDism -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'suma la linea "Cache and Temporary Data" aunque llegue con mayusculas' {
        Set-Content -LiteralPath $script:dismFalso -Value @(
            "Write-Output 'Number of Reclaimable Packages : 0'"
            "Write-Output 'Cache and Temporary Data : 300 MB'"
            "Write-Output 'Component Store Cleanup Recommended : No'"
        )
        Mock Resolve-EjecutableDeSistema { $script:dismFalso }

        $modulo = Get-ModuloLimpieza -Id 'componentes' -Raiz $script:Raiz
        $r = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
             -Configuracion ([pscustomobject]@{ DiasSinUso = 0; MinimoMB = 0; Admin = $true })

        @($r.Candidatos).Count | Should -Be 1
        $r.Candidatos[0].Metodo | Should -Be 'Comando'
        $r.Candidatos[0].Bytes  | Should -Be (300MB)
    }
}

Describe 'Modulo dockerwsl: detecta Docker con el mismo criterio que lo ejecuta' {

    BeforeAll {
        $script:EntornoDocker = @{ LA = $env:LOCALAPPDATA; RA = $env:APPDATA }
        $script:tallerDocker = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-docker-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tallerDocker -Force | Out-Null
        $env:LOCALAPPDATA = $script:tallerDocker
        $env:APPDATA      = $script:tallerDocker
        $script:moduloDocker = Get-ModuloLimpieza -Id 'dockerwsl' -Raiz $script:Raiz

        function script:Get-ComandosDocker {
            $r = Invoke-ModuloLimpieza -Modulo $script:moduloDocker -Sync (New-EstadoSincronizado) `
                 -Configuracion ([pscustomobject]@{ DiasSinUso = 0; MinimoMB = 0; Admin = $true })
            return @($r.Candidatos | Where-Object { $_.Metodo -eq 'Comando' })
        }
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:EntornoDocker.LA
        $env:APPDATA      = $script:EntornoDocker.RA
        Remove-Item -LiteralPath $script:tallerDocker -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un docker que solo esta en el PATH no se propone' {
        # La ejecución lo rechazaría: Resolve-EjecutablePermitido no mira el PATH.
        Mock Resolve-EjecutablePermitido { $null }
        Mock Get-Command { [pscustomobject]@{ Name = 'docker.exe'; Source = 'C:\Users\x\bin\docker.exe' } }

        @(script:Get-ComandosDocker).Count | Should -Be 0
    }

    It 'un docker en Archivos de programa si se propone' {
        Mock Resolve-EjecutablePermitido { 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' } `
             -ParameterFilter { $Ejecutable -eq 'docker' }

        $comandos = @(script:Get-ComandosDocker)
        $comandos.Count | Should -Be 1
        $comandos[0].Ejecutable | Should -Be 'docker'
    }
}

Describe 'Modulo papelera: cuenta solo los elementos de las unidades medidas' {
    <#
        La papelera solo existe en Windows: se simula el contenido de
        $Recycle.Bin. El recuento sale de los $I de cada unidad medida,
        uno por elemento borrado en la carpeta de cada usuario.
    #>

    BeforeAll {
        # Join-Path necesita que las unidades existan: fuera de Windows se
        # crean como unidades de PowerShell sobre una carpeta temporal.
        $script:tallerPap = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-pap-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tallerPap -Force | Out-Null
        $script:unidadesCreadas = @()
        foreach ($nombre in @('C', 'D')) {
            if (-not (Get-PSDrive -Name $nombre -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name $nombre -PSProvider FileSystem -Root $script:tallerPap -Scope Global | Out-Null
                $script:unidadesCreadas += $nombre
            }
        }

        # La carpeta $Recycle.Bin tiene que existir de verdad: en Windows
        # siempre está en C:\, y fuera de Windows se crea en el taller al que
        # apuntan las unidades simuladas. Así no hace falta simular Test-Path.
        New-Item -ItemType Directory -Path (Join-Path $script:tallerPap '$Recycle.Bin') -Force | Out-Null
        $modulo = Get-ModuloLimpieza -Id 'papelera' -Raiz $script:Raiz

        Mock Get-ElementosDelArbol {
            $sid = Join-Path $Ruta 'S-1-5-21-1'
            $n = if ($Ruta -like 'C:*') { 2 } else { 5 }
            foreach ($i in 1..$n) {
                [pscustomobject]@{ Name = ('$I00000{0}.txt' -f $i); Length = 100;   DirectoryName = $sid }
                [pscustomobject]@{ Name = ('$R00000{0}.txt' -f $i); Length = 600KB; DirectoryName = $sid }
            }
            # Un $I dentro de una carpeta borrada no es un elemento más.
            [pscustomobject]@{ Name = '$Iinterno.txt'; Length = 1; DirectoryName = (Join-Path $sid '$R000009') }
        }

        $r = Invoke-ModuloLimpieza -Modulo $modulo -Sync (New-EstadoSincronizado) `
             -Configuracion ([pscustomobject]@{
                 Admin = $true; UnidadesSeleccionadas = @(); Unidad = 'C:'
                 Unidades = @(
                     [pscustomobject]@{ Letra = 'C:'; Borrable = $true }
                     [pscustomobject]@{ Letra = 'D:'; Borrable = $false }
                 )
             })
        $script:CandidatosPap = @($r.Candidatos)
        $script:ResultadoPap  = $r
    }

    AfterAll {
        foreach ($nombre in $script:unidadesCreadas) { Remove-PSDrive -Name $nombre -Scope Global -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:tallerPap -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'el modulo termina sin error' {
        $script:ResultadoPap.Error | Should -BeNullOrEmpty
    }

    It 'propone vaciar la papelera de la unidad borrable' {
        $script:CandidatosPap.Count | Should -Be 1 -Because (
            'descartados por el embudo: {0}' -f $script:ResultadoPap.Descartados)
    }

    It 'el recuento no incluye los elementos de otras unidades ni los $I internos' {
        $script:CandidatosPap[0].Info | Should -Be '2 elementos'
    }
}

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
}
