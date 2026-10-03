<#
    Pruebas de las seis funciones que consultan el sistema:
    Test-ProcesoAbierto, Get-CarpetaConocida, Get-GuidVolumen,
    Get-DestinoAccesoDirecto, Get-EstadoArranque y Get-BibliotecasSteam.
    Dependen del registro, WMI, COM o la instalación de Steam.

      1. Casi todas consultan y luego deciden. Se sustituye la consulta (con
         Mock, con el parámetro -Shell o con un árbol de archivos temporal)
         y se comprueba la decisión.
      2. En cualquier sistema se comprueba que no lanzan, que devuelven el
         tipo prometido y que fallan cerrado ante entradas vacías o basura.
      3. Lo que solo puede comprobarse en Windows va marcado con -Skip o con
         un comentario "Queda fuera" que explica el motivo.

    Notas:

      * Get-CimInstance no existe fuera de Windows y Pester no puede
        simularlo. Se sustituye con un alias de ámbito de script hacia una
        función propia: los alias se resuelven antes que los cmdlets. No se
        define una función Get-CimInstance porque el analizador prohíbe
        redefinir cmdlets del sistema.

      * $script:EsWindows se calcula en BeforeDiscovery: Pester evalúa -Skip
        durante el descubrimiento, antes de BeforeAll, y allí valdría $null
        (las pruebas se saltarían también en Windows). $IsWindows no existe
        en 5.1, que solo corre en Windows, así que $null cuenta como Windows.
#>

BeforeDiscovery {
    $script:EsWindows = ($IsWindows -or ($null -eq $IsWindows))
}

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    $script:EsWindows = ($IsWindows -or ($null -eq $IsWindows))

    # Carpeta temporal común; se borra en AfterAll.
    $script:Taller = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-consulta-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:Taller -Force)

    # Se fija USERPROFILE a una carpeta temporal para que la rama de
    # Descargas no dependa del entorno (fuera de Windows no existe). El caso
    # sin USERPROFILE tiene su propia prueba.
    $script:PerfilDelSistema = $env:USERPROFILE
    $env:USERPROFILE = Join-Path $script:Taller 'PerfilBase'
    [void](New-Item -ItemType Directory -Path $env:USERPROFILE -Force)
}

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
    $env:USERPROFILE = $script:PerfilDelSistema
    Remove-Item -LiteralPath $script:Taller -Recurse -Force -ErrorAction SilentlyContinue
}


# ---------------------------------------------------------------------
#  Test-ProcesoAbierto
# ---------------------------------------------------------------------
#
# Get-Process existe en Linux y Windows: se prueba también contra la tabla
# de procesos real.

Describe 'Test-ProcesoAbierto: contra el sistema de verdad' {

    It 'encuentra el proceso que esta ejecutando esta misma prueba' {
        # El resto del bloque usa Mock; esta comprueba la consulta real.
        $yo = [Diagnostics.Process]::GetCurrentProcess().ProcessName
        @(Test-ProcesoAbierto -Nombres @($yo)) | Should -Contain $yo
    }

    It 'un nombre que no puede existir no se da por abierto' {
        $inventado = 'cachivache-proceso-inventado-' + [guid]::NewGuid().ToString('N')
        @(Test-ProcesoAbierto -Nombres @($inventado)).Count | Should -Be 0
    }

    It 'cuando no encuentra nada, el resultado se recorre sin reventar' {
        # "return @()" asignado a una variable se desenvuelve a $null (5.1 y 7):
        # se exige que recorrerlo no lance y que @() cuente cero.
        $r = Test-ProcesoAbierto -Nombres @('cachivache-nada-de-nada')
        @($r).Count | Should -Be 0
        { foreach ($x in $r) { [void]$x } } | Should -Not -Throw
    }

    It 'una lista vacia o nula se responde en el acto, sin preguntar al sistema' {
        Mock Get-Process { throw 'no se debe consultar la tabla de procesos para una lista vacia' }
        @(Test-ProcesoAbierto -Nombres @()).Count   | Should -Be 0
        @(Test-ProcesoAbierto -Nombres $null).Count | Should -Be 0
        @(Test-ProcesoAbierto).Count                | Should -Be 0
        Should -Invoke Get-Process -Times 0 -Exactly
    }
}

Describe 'Test-ProcesoAbierto: la decision, con la consulta sustituida' {

    BeforeAll {
        # Nombres inventados: el resultado no depende de los procesos del equipo.
        Mock Get-Process {
            @(
                [pscustomobject]@{ ProcessName = 'chrome' }
                [pscustomobject]@{ ProcessName = 'Discord' }
                [pscustomobject]@{ ProcessName = 'steam' }
            )
        }
    }

    It 'separa los que estan de los que no' {
        $r = @(Test-ProcesoAbierto -Nombres @('chrome', 'firefox', 'steam'))
        $r.Count | Should -Be 2
        $r       | Should -Contain 'chrome'
        $r       | Should -Contain 'steam'
        $r       | Should -Not -Contain 'firefox'
    }

    It 'no distingue mayusculas: el modulo pide "Discord" y el sistema dice "discord"' {
        # El HashSet usa OrdinalIgnoreCase; sin ello el aviso de "cierra el
        # programa" fallaría a menudo.
        @(Test-ProcesoAbierto -Nombres @('DISCORD')).Count | Should -Be 1
        @(Test-ProcesoAbierto -Nombres @('cHrOmE')).Count  | Should -Be 1
    }

    It 'devuelve el nombre TAL COMO se pidio, no como lo escribe el sistema' {
        # El resultado se muestra en un aviso con el nombre que usa el módulo.
        Test-ProcesoAbierto -Nombres @('DISCORD') | Should -BeExactly 'DISCORD'
    }

    It 'conserva el orden en que se preguntaron' {
        $r = @(Test-ProcesoAbierto -Nombres @('steam', 'chrome'))
        $r[0] | Should -Be 'steam'
        $r[1] | Should -Be 'chrome'
    }

    It 'UNA sola consulta aunque se pregunten quince nombres' {
        # Cada Get-Process enumera la tabla de procesos entera; el módulo de
        # cachés pregunta por quince nombres a la vez.
        $quince = 1..15 | ForEach-Object { "programa$_" }
        [void](Test-ProcesoAbierto -Nombres @($quince))
        Should -Invoke Get-Process -Times 1 -Exactly
    }
}

Describe 'Test-ProcesoAbierto: si el sistema no contesta' {

    It 'sin tabla de procesos no acusa a nadie de estar abierto, y no lanza' {
        # Sin lista no se puede afirmar que ninguno esté abierto: se devuelve
        # vacío. Solo desaparece el aviso.
        Mock Get-Process { throw 'acceso denegado' }
        { Test-ProcesoAbierto -Nombres @('chrome') } | Should -Not -Throw
        @(Test-ProcesoAbierto -Nombres @('chrome')).Count | Should -Be 0
    }
}


# ---------------------------------------------------------------------
#  Get-CarpetaConocida
# ---------------------------------------------------------------------
#
# Cinco carpetas salen de [Environment]::GetFolderPath, que fuera de
# Windows devuelve cadena vacía. Descargas lee el registro, expande las
# variables de entorno y recurre al perfil; se prueba entera.

Describe 'Get-CarpetaConocida: el conjunto cerrado de nombres' {

    It 'un nombre que no esta en la lista se rechaza antes de mirar nada' {
        # Falla cerrado: lanza en vez de devolver una carpeta por defecto.
        { Get-CarpetaConocida -Nombre 'Basura' }   | Should -Throw
        { Get-CarpetaConocida -Nombre '' }         | Should -Throw
        { Get-CarpetaConocida -Nombre 'desktop ' } | Should -Throw
    }

    It 'sin nombre no lanza: devuelve nulo' {
        { Get-CarpetaConocida } | Should -Not -Throw
        Get-CarpetaConocida | Should -BeNullOrEmpty
    }

    It 'ninguno de los seis nombres validos lanza: <Nombre>' -ForEach @(
        @{ Nombre = 'Desktop' }
        @{ Nombre = 'Documents' }
        @{ Nombre = 'Pictures' }
        @{ Nombre = 'Music' }
        @{ Nombre = 'Videos' }
        @{ Nombre = 'Downloads' }
    ) {
        { Get-CarpetaConocida -Nombre $Nombre } | Should -Not -Throw
    }

    It 'lo que devuelve es texto o nulo, nunca otra cosa: <Nombre>' -ForEach @(
        @{ Nombre = 'Desktop' }
        @{ Nombre = 'Documents' }
        @{ Nombre = 'Pictures' }
        @{ Nombre = 'Music' }
        @{ Nombre = 'Videos' }
        @{ Nombre = 'Downloads' }
    ) {
        $r = Get-CarpetaConocida -Nombre $Nombre
        if ($null -ne $r) { $r | Should -BeOfType [string] }
    }

    It 'las cinco carpetas de Environment devuelven una ruta que existe' -Skip:(-not $script:EsWindows) {
        # Solo en Windows: fuera, GetFolderPath devuelve cadena vacía y la
        # función devuelve $null para las cinco.
        # Este archivo cambia USERPROFILE a una carpeta temporal, y Windows
        # expande %USERPROFILE% al resolver estas carpetas: se restaura el
        # perfil real mientras dura la comprobación.
        $perfilPrueba = $env:USERPROFILE
        $env:USERPROFILE = $script:PerfilDelSistema
        try {
            $especiales = @{ Desktop = 'Desktop'; Documents = 'MyDocuments'; Pictures = 'MyPictures'; Music = 'MyMusic'; Videos = 'MyVideos' }
            foreach ($n in @('Desktop', 'Documents', 'Pictures', 'Music', 'Videos')) {
                $delSistema = [Environment]::GetFolderPath($especiales[$n])
                $r = Get-CarpetaConocida -Nombre $n
                $r | Should -Not -BeNullOrEmpty -Because (
                    "$n existe en cualquier Windows (GetFolderPath: '$delSistema', USERPROFILE: '$env:USERPROFILE')")
                $r | Should -Be $delSistema.TrimEnd('\')
                $r | Should -Not -Match '\\$' -Because 'la barra final se recorta'
            }
        } finally {
            $env:USERPROFILE = $perfilPrueba
        }
    }

    It 'Descargas devuelve $null -y no lanza- si el perfil del usuario no esta definido' {
        # Join-Path lanza con -Path nulo, así que la función comprueba
        # USERPROFILE. Se exige $null y además que no lance.
        #
        # En Windows el registro devuelve "%USERPROFILE%\Downloads", y
        # ExpandEnvironmentVariables deja intacta una variable inexistente:
        # la función descarta lo que siga conteniendo %...%. Esa rama solo se
        # ejecuta en Windows (trabajo "Pasada completa" de la CI).
        $previo = $env:USERPROFILE
        try {
            Remove-Item -Path 'Env:\USERPROFILE' -ErrorAction SilentlyContinue
            { Get-CarpetaConocida -Nombre 'Downloads' } | Should -Not -Throw
            Get-CarpetaConocida -Nombre 'Downloads' | Should -BeNullOrEmpty
        } finally {
            $env:USERPROFILE = $previo
        }
    }
}

Describe 'Get-CarpetaConocida: Descargas, que es la unica que decide' {

    BeforeAll {
        $script:GuidDescargas = '{374DE290-123F-4565-9164-39C4925E467B}'
        $script:PerfilPrevio  = $env:USERPROFILE
        $env:USERPROFILE      = Join-Path $script:Taller 'Perfil'
        [void](New-Item -ItemType Directory -Path $env:USERPROFILE -Force)
    }

    AfterAll {
        $env:USERPROFILE = $script:PerfilPrevio
        Remove-Item -Path 'Env:\CACHIVACHE_ZONA' -ErrorAction SilentlyContinue
    }

    It 'lee la redireccion del registro y expande las variables de entorno' {
        # El registro guarda "%USERPROFILE%\Downloads" sin expandir.
        $env:CACHIVACHE_ZONA = 'Z_ZONA_DE_PRUEBA'
        Mock Get-ItemProperty { [pscustomobject]@{ '{374DE290-123F-4565-9164-39C4925E467B}' = '%CACHIVACHE_ZONA%\Descargas' } }

        Get-CarpetaConocida -Nombre 'Downloads' | Should -Be 'Z_ZONA_DE_PRUEBA\Descargas'
    }

    It 'recorta la barra invertida final' {
        # El registro la incluye a veces; sin recortarla, la misma carpeta
        # parecería distinta al compararla como texto.
        Mock Get-ItemProperty { [pscustomobject]@{ '{374DE290-123F-4565-9164-39C4925E467B}' = 'Z_RAIZ\Descargas\' } }
        Get-CarpetaConocida -Nombre 'Downloads' | Should -Be 'Z_RAIZ\Descargas'
    }

    It 'sin valor en el registro cae al perfil del usuario' {
        Mock Get-ItemProperty { $null }
        Get-CarpetaConocida -Nombre 'Downloads' | Should -Be (Join-Path $env:USERPROFILE 'Downloads')
    }

    It 'un valor vacio en el registro tambien cae al perfil' {
        # Una ruta vacía, al recorrerla, sería la carpeta actual del proceso.
        Mock Get-ItemProperty { [pscustomobject]@{ '{374DE290-123F-4565-9164-39C4925E467B}' = '' } }
        Get-CarpetaConocida -Nombre 'Downloads' | Should -Be (Join-Path $env:USERPROFILE 'Downloads')
    }

    It 'una clave que no existe no lanza: el -ErrorAction se la traga' {
        # Se emula el error no terminante real de Get-ItemProperty, que
        # silencia -ErrorAction SilentlyContinue. Un error terminante sí se
        # propagaría: la función no tiene try/catch en esta rama.
        Mock Get-ItemProperty { Write-Error 'no existe' }
        { Get-CarpetaConocida -Nombre 'Downloads' } | Should -Not -Throw
        Get-CarpetaConocida -Nombre 'Downloads' | Should -Be (Join-Path $env:USERPROFILE 'Downloads')
    }

    It 'no pregunta al registro por las carpetas que resuelve Environment' {
        Mock Get-ItemProperty { throw 'Desktop no se lee del registro' }
        { Get-CarpetaConocida -Nombre 'Desktop' } | Should -Not -Throw
        Should -Invoke Get-ItemProperty -Times 0 -Exactly
    }
}


# ---------------------------------------------------------------------
#  Get-GuidVolumen
# ---------------------------------------------------------------------

Describe 'Get-GuidVolumen: sin WMI delante' {

    It 'no lanza aunque no exista ni el cmdlet: devuelve cadena vacia' {
        # Fuera de Windows salta CommandNotFoundException; el try/catch de la
        # función lo absorbe y devuelve texto.
        { Get-GuidVolumen -Unidad 'C:' } | Should -Not -Throw
        Get-GuidVolumen -Unidad 'C:' | Should -BeOfType [string]
    }

    It 'sin unidad falla cerrado' {
        # Parámetro obligatorio: una unidad vacía no puede devolver otro volumen.
        # No se llama sin -Unidad: abriría un prompt interactivo y bloquearía la CI.
        { Get-GuidVolumen -Unidad '' }    | Should -Throw
        { Get-GuidVolumen -Unidad $null } | Should -Throw
        (Get-Command Get-GuidVolumen).Parameters['Unidad'].Attributes |
            Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory } |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-GuidVolumen: la decision, con la consulta sustituida' {

    BeforeAll {
        # Alias en vez de Mock o función: ver la cabecera del archivo.
        function Get-VolumenesDePrueba {
            [CmdletBinding()]
            [OutputType([object[]])]
            param([string] $ClassName)

            if ($script:VolumenesLanzan) { throw 'WMI no responde' }
            return $script:Volumenes
        }
        Set-Alias -Name Get-CimInstance -Value Get-VolumenesDePrueba -Scope Script

        $script:VolumenesLanzan = $false
        $script:Volumenes = @(
            [pscustomobject]@{ DriveLetter = 'C:'; DeviceID = '\\?\Volume{aaaaaaaa-1111-2222-3333-444444444444}\' }
            [pscustomobject]@{ DriveLetter = 'D:'; DeviceID = '\\?\Volume{BBBBBBBB-5555-6666-7777-888888888888}\' }
            [pscustomobject]@{ DriveLetter = $null; DeviceID = '\\?\Volume{cccccccc-9999-0000-1111-222222222222}\' }
        )
    }

    AfterAll {
        Remove-Item -Path 'Alias:\Get-CimInstance' -Force -ErrorAction SilentlyContinue
    }

    BeforeEach { $script:VolumenesLanzan = $false }

    It 'saca el GUID de dentro del DeviceID, que es lo que guarda el registro' {
        # DeviceID llega como \\?\Volume{guid}\ y el registro de la papelera
        # indexa por {guid}.
        Get-GuidVolumen -Unidad 'C:' | Should -Be '{aaaaaaaa-1111-2222-3333-444444444444}'
    }

    It 'acepta el GUID en mayusculas' {
        Get-GuidVolumen -Unidad 'D:' | Should -Be '{BBBBBBBB-5555-6666-7777-888888888888}'
    }

    It 'normaliza la unidad: <Entrada> es la misma unidad que "C:"' -ForEach @(
        @{ Entrada = 'C:'   }
        @{ Entrada = 'C'    }
        @{ Entrada = 'C:\'  }
        @{ Entrada = 'C:/'  }
        @{ Entrada = 'C:\\' }
    ) {
        # La unidad llega en formatos distintos según su origen.
        Get-GuidVolumen -Unidad $Entrada | Should -Be '{aaaaaaaa-1111-2222-3333-444444444444}'
    }

    It 'una letra que no esta montada devuelve cadena vacia, no la del vecino' {
        Get-GuidVolumen -Unidad 'Z:' | Should -Be ''
    }

    It 'un volumen sin letra no se confunde con ninguna unidad' {
        # Volúmenes montados en carpeta y particiones de sistema tienen DriveLetter vacío.
        Get-GuidVolumen -Unidad ':' | Should -Be ''
    }

    It 'un DeviceID sin GUID dentro devuelve cadena vacia' {
        $script:Volumenes = @([pscustomobject]@{ DriveLetter = 'C:'; DeviceID = '\\?\HarddiskVolume4' })
        Get-GuidVolumen -Unidad 'C:' | Should -Be ''
        $script:Volumenes = @([pscustomobject]@{ DriveLetter = 'C:'; DeviceID = $null })
        Get-GuidVolumen -Unidad 'C:' | Should -Be ''
    }

    It 'si la consulta lanza, se devuelve cadena vacia y no se propaga' {
        $script:VolumenesLanzan = $true
        { Get-GuidVolumen -Unidad 'C:' } | Should -Not -Throw
        Get-GuidVolumen -Unidad 'C:' | Should -Be ''
    }

    It 'sin ningun volumen devuelve cadena vacia' {
        $script:Volumenes = @()
        Get-GuidVolumen -Unidad 'C:' | Should -Be ''
    }

    It 'nunca devuelve nulo: siempre texto' {
        # Se concatena en una ruta de registro: $null apuntaría a otra clave.
        $script:Volumenes = @()
        $r = Get-GuidVolumen -Unidad 'Q:'
        $null -eq $r | Should -BeFalse
        $r | Should -BeOfType [string]
    }
}


# ---------------------------------------------------------------------
#  Get-DestinoAccesoDirecto
# ---------------------------------------------------------------------
#
# La función acepta el parámetro -Shell para inyectar el objeto COM.

Describe 'Get-DestinoAccesoDirecto: con un shell inyectado' {

    BeforeAll {
        function New-ShellDePrueba {
            <#
            .SYNOPSIS
                Doble del objeto COM WScript.Shell. Anota la ruta que le
                pidieron para poder comprobar que se le pasa sin tocar.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'No cambia ningun estado: arma un objeto en memoria.')]
            [CmdletBinding()]
            [OutputType([psobject])]
            param([string] $Destino = 'C:\Juegos\juego.exe', [switch] $Lanza, [switch] $DevuelveNulo)

            $shell = [pscustomobject]@{
                Pedida       = $null
                Destino      = $Destino
                Lanza        = [bool]$Lanza
                DevuelveNulo = [bool]$DevuelveNulo
            }
            Add-Member -InputObject $shell -MemberType ScriptMethod -Name CreateShortcut -Value {
                param($Ruta)
                $this.Pedida = $Ruta
                if ($this.Lanza)        { throw 'el archivo .lnk esta corrupto' }
                if ($this.DevuelveNulo) { return $null }
                return [pscustomobject]@{ TargetPath = $this.Destino }
            }
            return $shell
        }
    }

    It 'devuelve el destino que dice el acceso directo' {
        $shell = New-ShellDePrueba -Destino 'D:\Programas\cosa.exe'
        Get-DestinoAccesoDirecto -Ruta 'C:\Menu\cosa.lnk' -Shell $shell | Should -Be 'D:\Programas\cosa.exe'
    }

    It 'le pasa la ruta al shell sin tocarla' {
        # Sin Resolve-Path ni normalización: el shell puede abrir rutas que el
        # proceso no resuelve.
        $shell = New-ShellDePrueba
        [void](Get-DestinoAccesoDirecto -Ruta 'C:\Con Espacios\a b.lnk' -Shell $shell)
        $shell.Pedida | Should -BeExactly 'C:\Con Espacios\a b.lnk'
    }

    It 'un acceso directo que no apunta a nada devuelve cadena vacia' {
        $shell = New-ShellDePrueba -Destino ''
        Get-DestinoAccesoDirecto -Ruta 'C:\Menu\roto.lnk' -Shell $shell | Should -Be ''
    }

    It 'si el shell lanza, se devuelve cadena vacia y no se propaga' {
        # Un .lnk corrupto no puede interrumpir el recorrido de entradas de arranque.
        $shell = New-ShellDePrueba -Lanza
        { Get-DestinoAccesoDirecto -Ruta 'C:\Menu\roto.lnk' -Shell $shell } | Should -Not -Throw
        Get-DestinoAccesoDirecto -Ruta 'C:\Menu\roto.lnk' -Shell $shell | Should -Be ''
    }

    It 'si el shell devuelve nulo, tampoco lanza' {
        # Leer una propiedad de $null no lanza (sin Set-StrictMode).
        $shell = New-ShellDePrueba -DevuelveNulo
        { Get-DestinoAccesoDirecto -Ruta 'C:\Menu\raro.lnk' -Shell $shell } | Should -Not -Throw
        Get-DestinoAccesoDirecto -Ruta 'C:\Menu\raro.lnk' -Shell $shell | Should -BeNullOrEmpty
    }

    It 'sin ruta falla cerrado, y sin llegar a molestar al shell' {
        $shell = New-ShellDePrueba
        # No se llama sin -Ruta: abriría un prompt interactivo.
        { Get-DestinoAccesoDirecto -Ruta '' -Shell $shell }    | Should -Throw
        { Get-DestinoAccesoDirecto -Ruta $null -Shell $shell } | Should -Throw
        $shell.Pedida | Should -BeNullOrEmpty
    }

    It 'reutiliza el shell que se le da: no crea uno por acceso directo' {
        # El módulo de arranque resuelve decenas de .lnk; crear un objeto COM
        # por cada uno costaría segundos.
        $shell = New-ShellDePrueba -Destino 'C:\a.exe'
        foreach ($i in 1..5) {
            Get-DestinoAccesoDirecto -Ruta "C:\Menu\p$i.lnk" -Shell $shell | Should -Be 'C:\a.exe'
        }
        $shell.Pedida | Should -BeExactly 'C:\Menu\p5.lnk'
    }
}

Describe 'Get-DestinoAccesoDirecto: sin shell, creandolo el mismo' {

    It 'un .lnk que no existe no lanza y no inventa un destino' {
        # Fuera de Windows falla al crear el objeto COM; en Windows,
        # CreateShortcut sobre un archivo inexistente devuelve TargetPath
        # vacío sin escribir en disco (solo .Save() escribe). Ambos dan vacío.
        $inventado = Join-Path $script:Taller ('no-existe-' + [guid]::NewGuid().ToString('N') + '.lnk')
        { Get-DestinoAccesoDirecto -Ruta $inventado } | Should -Not -Throw
        Get-DestinoAccesoDirecto -Ruta $inventado | Should -BeNullOrEmpty
        Test-Path -LiteralPath $inventado | Should -BeFalse -Because 'resolver un acceso directo no crea archivos'
    }

    # Queda fuera: resolver un .lnk real. Fabricarlo requiere WScript.Shell,
    # que solo existe en Windows; esta parte no tiene prueba automática.
}


# ---------------------------------------------------------------------
#  Get-EstadoArranque
# ---------------------------------------------------------------------

Describe 'Get-EstadoArranque: sin registro delante' {

    It 'no lanza y devuelve una tabla vacia cuando no hay ninguna clave' {
        Mock Get-ItemProperty { $null }
        { Get-EstadoArranque } | Should -Not -Throw
        $r = Get-EstadoArranque
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }

    It 'mira las cuatro claves de StartupApproved, no solo una' {
        # Run, Run32, StartupFolder y la de máquina.
        Mock Get-ItemProperty { $null }
        [void](Get-EstadoArranque)
        Should -Invoke Get-ItemProperty -Times 4 -Exactly
    }

    It 'no lanza contra el registro de verdad de esta maquina' {
        # Sin Mock: en Linux las consultas fallan en silencio y en Windows leen el registro.
        { Get-EstadoArranque } | Should -Not -Throw
        Get-EstadoArranque | Should -BeOfType [hashtable]
    }
}

Describe 'Get-EstadoArranque: la decision, con el registro sustituido' {

    BeforeAll {
        # Nombre -> byte[] como los guarda Windows. Solo responde la clave
        # pedida, lo que permite comprobar el orden de lectura.
        function New-ValoresArranque {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'No cambia ningun estado: arma un objeto en memoria.')]
            [CmdletBinding()]
            [OutputType([psobject])]
            param([hashtable] $Valores)

            $o = [pscustomobject]@{}
            foreach ($k in $Valores.Keys) {
                Add-Member -InputObject $o -NotePropertyName $k -NotePropertyValue $Valores[$k]
            }
            return $o
        }
    }

    It 'el bit 0 a cero es ACTIVADO y a uno es DESACTIVADO' {
        # Contraintuitivo: un cero significa que la entrada arranca.
        Mock Get-ItemProperty {
            New-ValoresArranque -Valores @{
                'Activada'   = [byte[]]@(0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                'Desactivada' = [byte[]]@(0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            }
        }
        $r = Get-EstadoArranque
        $r['Activada']    | Should -BeTrue
        $r['Desactivada'] | Should -BeFalse
    }

    It 'solo mira el bit 0: el resto del byte no cambia el veredicto' {
        # Windows usa los demás bits; comparar el byte entero con 2 falla con 0x06.
        Mock Get-ItemProperty {
            New-ValoresArranque -Valores @{
                'Cero'    = [byte[]]@(0x00)
                'Seis'    = [byte[]]@(0x06)
                'Siete'   = [byte[]]@(0x07)
                'Ochenta' = [byte[]]@(0x80)
            }
        }
        $r = Get-EstadoArranque
        $r['Cero']    | Should -BeTrue
        $r['Seis']    | Should -BeTrue
        $r['Ochenta'] | Should -BeTrue
        $r['Siete']   | Should -BeFalse
    }

    It 'ignora las propiedades PS* que anade el proveedor' {
        # PSPath, PSParentPath, etc. no son entradas de arranque.
        Mock Get-ItemProperty {
            New-ValoresArranque -Valores @{
                'PSPath'       = [byte[]]@(0x00)
                'PSParentPath' = [byte[]]@(0x00)
                'Programa'     = [byte[]]@(0x00)
            }
        }
        $r = Get-EstadoArranque
        $r.Count | Should -Be 1
        $r.ContainsKey('Programa') | Should -BeTrue
        $r.ContainsKey('PSPath')   | Should -BeFalse
    }

    It 'ignora lo que no sea byte[]' {
        Mock Get-ItemProperty {
            New-ValoresArranque -Valores @{
                'Texto'   = 'no soy un byte'
                'Numero'  = 3
                'Nada'    = $null
                'Buena'   = [byte[]]@(0x00)
            }
        }
        $r = Get-EstadoArranque
        $r.Count | Should -Be 1
        $r.ContainsKey('Buena') | Should -BeTrue
    }

    It 'un byte[] vacio no se lee: leerlo seria salirse del array' {
        Mock Get-ItemProperty { New-ValoresArranque -Valores @{ 'Vacia' = [byte[]]@() } }
        { Get-EstadoArranque } | Should -Not -Throw
        (Get-EstadoArranque).Count | Should -Be 0
    }

    It 'la clave de maquina se lee la ultima y gana sobre la del usuario' {
        # HKLM se lee la última y sobrescribe: lo que el administrador
        # desactiva para todo el equipo tiene prioridad.
        Mock Get-ItemProperty {
            if ($Path -like 'HKLM:*') {
                New-ValoresArranque -Valores @{ 'Compartida' = [byte[]]@(0x03) }
            } else {
                New-ValoresArranque -Valores @{ 'Compartida' = [byte[]]@(0x02) }
            }
        }
        (Get-EstadoArranque)['Compartida'] | Should -BeFalse -Because 'manda lo que dice HKLM, que se lee el ultimo'
    }

    It 'junta lo que encuentra en claves distintas' {
        Mock Get-ItemProperty {
            if ($Path -like '*StartupFolder*') {
                New-ValoresArranque -Valores @{ 'DesdeCarpeta' = [byte[]]@(0x00) }
            } elseif ($Path -like 'HKLM:*') {
                New-ValoresArranque -Valores @{ 'DesdeMaquina' = [byte[]]@(0x01) }
            } else {
                $null
            }
        }
        $r = Get-EstadoArranque
        $r.Count | Should -Be 2
        $r['DesdeCarpeta'] | Should -BeTrue
        $r['DesdeMaquina'] | Should -BeFalse
    }
}


# ---------------------------------------------------------------------
#  Get-BibliotecasSteam
# ---------------------------------------------------------------------
#
# Se fabrica una instalación de Steam en una carpeta temporal, con
# libraryfolders.vdf en sus dos ubicaciones, una biblioteca montada, otra
# declarada pero ausente (disco externo desconectado) y un archivo corrupto.
#
# El registro se sustituye siempre con Mock, también en Windows, para no
# leer la instalación real de Steam del equipo.

Describe 'Get-BibliotecasSteam: bibliotecas declaradas en el VDF' {

    BeforeAll {
        Mock Get-ItemProperty { $null }   # HKCU:\SOFTWARE\Valve\Steam no dice nada

        $script:Steam    = Join-Path (Join-Path $script:Taller 'PFX86') 'Steam'
        $script:AppsUno  = Join-Path $script:Steam 'steamapps'
        $script:Config   = Join-Path $script:Steam 'config'
        $script:LibB     = Join-Path $script:Taller 'DiscoD'
        $script:AppsDos  = Join-Path $script:LibB 'steamapps'
        $script:LibAusente = Join-Path $script:Taller 'DiscoExternoDesconectado'

        foreach ($d in @($script:AppsUno, $script:Config, $script:AppsDos, $script:LibAusente)) {
            [void](New-Item -ItemType Directory -Path $d -Force)
        }

        $script:PfPrevio    = $env:ProgramFiles
        $script:Pfx86Previo = ${env:ProgramFiles(x86)}
        ${env:ProgramFiles(x86)} = Join-Path $script:Taller 'PFX86'
        $env:ProgramFiles        = Join-Path $script:Taller 'PFvacio'
        [void](New-Item -ItemType Directory -Path $env:ProgramFiles -Force)

        function Set-Vdf {
            <#
            .SYNOPSIS
                Escribe un libraryfolders.vdf con las rutas indicadas, con
                las barras escapadas como las escribe Valve.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Solo escribe en la carpeta temporal de la propia prueba.')]
            [CmdletBinding()]
            param([string] $Carpeta, [string[]] $Rutas, [string] $Texto)

            $destino = Join-Path $Carpeta 'libraryfolders.vdf'
            if ($PSBoundParameters.ContainsKey('Texto')) {
                [IO.File]::WriteAllText($destino, $Texto)
                return
            }
            $lineas = [Collections.Generic.List[string]]::new()
            $lineas.Add('"libraryfolders"')
            $lineas.Add('{')
            $i = 0
            foreach ($r in @($Rutas)) {
                $lineas.Add(('    "{0}"' -f $i))
                $lineas.Add('    {')
                $lineas.Add(('        "path"        "{0}"' -f ($r -replace '\\', '\\')))
                $lineas.Add('    }')
                $i++
            }
            $lineas.Add('}')
            [IO.File]::WriteAllText($destino, (@($lineas) -join "`r`n"))
        }

        function Remove-Vdf {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Solo borra en la carpeta temporal de la propia prueba.')]
            [CmdletBinding()]
            param()
            foreach ($c in @($script:AppsUno, $script:Config)) {
                Remove-Item -LiteralPath (Join-Path $c 'libraryfolders.vdf') -Force -ErrorAction SilentlyContinue
            }
        }
    }

    AfterAll {
        $env:ProgramFiles        = $script:PfPrevio
        ${env:ProgramFiles(x86)} = $script:Pfx86Previo
    }

    BeforeEach { Remove-Vdf }

    It 'sin VDF devuelve solo la biblioteca de la instalacion' {
        $r = @(Get-BibliotecasSteam)
        $r.Count | Should -Be 1
        $r[0]    | Should -Be $script:AppsUno
    }

    It 'anade la biblioteca declarada en steamapps/libraryfolders.vdf' {
        Set-Vdf -Carpeta $script:AppsUno -Rutas @($script:LibB)
        $r = @(Get-BibliotecasSteam)
        $r.Count | Should -Be 2
        $r       | Should -Contain $script:AppsDos
    }

    It 'lee tambien la ubicacion historica config/libraryfolders.vdf' {
        # Según la antigüedad de la instalación, el archivo está en una u otra ubicación.
        Set-Vdf -Carpeta $script:Config -Rutas @($script:LibB)
        @(Get-BibliotecasSteam) | Should -Contain $script:AppsDos
    }

    It 'una biblioteca declarada cuyo disco NO esta montado se descarta' {
        # Un disco externo desconectado sigue declarado en el archivo.
        Set-Vdf -Carpeta $script:AppsUno -Rutas @($script:LibAusente)
        $r = @(Get-BibliotecasSteam)
        $r.Count | Should -Be 1 -Because 'la carpeta steamapps de esa biblioteca no existe'
        $r       | Should -Not -Contain (Join-Path $script:LibAusente 'steamapps')
    }

    It 'no repite una biblioteca declarada dos veces' {
        Set-Vdf -Carpeta $script:AppsUno -Rutas @($script:LibB, $script:LibB)
        Set-Vdf -Carpeta $script:Config  -Rutas @($script:LibB)
        $r = @(Get-BibliotecasSteam)
        $r.Count | Should -Be 2
        @($r | Where-Object { $_ -eq $script:AppsDos }).Count | Should -Be 1
    }

    It 'no repite la propia instalacion cuando el VDF la declara' {
        # El VDF real siempre declara la instalación como biblioteca "0".
        Set-Vdf -Carpeta $script:AppsUno -Rutas @($script:Steam, $script:LibB)
        $r = @(Get-BibliotecasSteam)
        $r.Count | Should -Be 2
        @($r | Where-Object { $_ -eq $script:AppsUno }).Count | Should -Be 1
    }

    It 'un VDF vacio no rompe nada' {
        Set-Vdf -Carpeta $script:AppsUno -Texto ''
        { Get-BibliotecasSteam } | Should -Not -Throw
        @(Get-BibliotecasSteam).Count | Should -Be 1
    }

    It 'un VDF corrupto no rompe nada' {
        # Steam lo reescribe al actualizarse y un corte puede dejarlo a medias.
        Set-Vdf -Carpeta $script:AppsUno -Texto "\x00\x01 no soy un VDF `"path`" sin cerrar {{{{ \x00"
        { Get-BibliotecasSteam } | Should -Not -Throw
        @(Get-BibliotecasSteam).Count | Should -Be 1
    }

    It 'un VDF a medio escribir, cortado por la mitad, tampoco' {
        Set-Vdf -Carpeta $script:AppsUno -Texto @"
"libraryfolders"
{
    "0"
    {
        "path"        "
"@
        { Get-BibliotecasSteam } | Should -Not -Throw
        @(Get-BibliotecasSteam).Count | Should -Be 1
    }

    It 'una ruta vacia dentro del VDF se ignora' {
        Set-Vdf -Carpeta $script:AppsUno -Texto @"
"libraryfolders"
{
    "0"
    {
        "path"        ""
    }
}
"@
        @(Get-BibliotecasSteam).Count | Should -Be 1
    }

    It 'devuelve rutas de carpetas que existen de verdad' {
        Set-Vdf -Carpeta $script:AppsUno -Rutas @($script:LibB, $script:LibAusente)
        foreach ($r in @(Get-BibliotecasSteam)) {
            Test-Path -LiteralPath $r | Should -BeTrue -Because "$r se ha devuelto como biblioteca"
        }
    }

    It 'lo que se devuelve son cadenas, y una lista aunque haya una sola' {
        $r = Get-BibliotecasSteam
        @($r).Count | Should -Be 1
        @($r)[0] | Should -BeOfType [string]
    }
}

Describe 'Get-BibliotecasSteam: cuando no hay Steam' {

    BeforeAll {
        Mock Get-ItemProperty { $null }

        $script:PfPrevio2    = $env:ProgramFiles
        $script:Pfx86Previo2 = ${env:ProgramFiles(x86)}
        $vacia = Join-Path $script:Taller 'SinSteam'
        [void](New-Item -ItemType Directory -Path $vacia -Force)
        ${env:ProgramFiles(x86)} = $vacia
        $env:ProgramFiles        = $vacia
    }

    AfterAll {
        $env:ProgramFiles        = $script:PfPrevio2
        ${env:ProgramFiles(x86)} = $script:Pfx86Previo2
    }

    It 'sin instalacion de Steam no se devuelve ninguna biblioteca' {
        # "return @()" se desenvuelve a $null al asignarlo; importa que un
        # foreach sobre el resultado no itere ni lance.
        $r = Get-BibliotecasSteam
        @($r).Count | Should -Be 0
        { foreach ($x in $r) { [void]$x } } | Should -Not -Throw
    }

    It 'no lanza' {
        { Get-BibliotecasSteam } | Should -Not -Throw
    }
}

Describe 'Get-BibliotecasSteam: el registro manda sobre las carpetas de programas' {

    BeforeAll {
        # Steam válido en ProgramFiles(x86) y el registro apuntando a una ruta
        # inexistente: un resultado vacío demuestra que la búsqueda por
        # carpetas es solo el último recurso.
        $script:SteamB   = Join-Path (Join-Path $script:Taller 'PFX86b') 'Steam'
        [void](New-Item -ItemType Directory -Path (Join-Path $script:SteamB 'steamapps') -Force)

        $script:PfPrevio3    = $env:ProgramFiles
        $script:Pfx86Previo3 = ${env:ProgramFiles(x86)}
        ${env:ProgramFiles(x86)} = Join-Path $script:Taller 'PFX86b'
        $env:ProgramFiles        = Join-Path $script:Taller 'PFX86b'

        Mock Get-ItemProperty { [pscustomobject]@{ SteamPath = 'Z:/ruta/que/no/existe/Steam' } }
    }

    AfterAll {
        $env:ProgramFiles        = $script:PfPrevio3
        ${env:ProgramFiles(x86)} = $script:Pfx86Previo3
    }

    It 'con SteamPath en el registro no se busca por ProgramFiles' {
        @(Get-BibliotecasSteam).Count | Should -Be 0 `
            -Because 'el registro dijo donde esta Steam, y ahi no hay nada; buscarlo ademas por carpetas inventaria una instalacion'
    }

    # Queda fuera: una SteamPath válida del registro. La función convierte
    # '/' en '\', y esa ruta no existe en Linux; solo se puede probar en Windows.
}
