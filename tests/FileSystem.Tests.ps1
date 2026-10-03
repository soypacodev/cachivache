<#
    Pruebas de caracterización de Measure-Ruta y Measure-RutaDetalle, que
    recorren con una enumeración de .NET con pila propia en lugar de
    Get-ChildItem -Recurse. Fijan el resultado de la implementación basada
    en Get-ChildItem campo a campo, salvo una diferencia deliberada: no se
    siguen los puntos de reanálisis.

    Se ejecutan sobre árboles simulados en una carpeta temporal y funcionan
    también en Linux.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Implementación de referencia basada en Get-ChildItem, copiada literalmente.
    function Measure-RutaComoAntes {
        param([string] $Ruta)
        if ([string]::IsNullOrWhiteSpace($Ruta))  { return 0.0 }
        if (-not (Test-Path -LiteralPath $Ruta))  { return 0.0 }
        $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
        if ($null -eq $item)      { return 0.0 }
        if (Test-EsEnlace $item)  { return 0.0 }
        if (-not $item.PSIsContainer) { return [double]$item.Length }
        $suma = (Get-ChildItem -LiteralPath $Ruta -Recurse -Force -File -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        if ($null -eq $suma) { return 0.0 }
        return [double]$suma
    }

    function Measure-RutaDetalleComoAntes {
        param([string] $Ruta)
        $resultado = [pscustomobject]@{ Bytes = 0.0; Archivos = 0; Ultimo = [datetime]'1900-01-01' }
        if (-not (Test-Path -LiteralPath $Ruta)) { return $resultado }
        $archivos = @(Get-ChildItem -LiteralPath $Ruta -Recurse -Force -File -ErrorAction SilentlyContinue)
        if ($archivos.Count -eq 0) {
            $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
            if ($item) { $resultado.Ultimo = $item.LastWriteTime }
            return $resultado
        }
        $medida = $archivos | Measure-Object -Property Length -Sum
        $resultado.Bytes    = [double]$medida.Sum
        $resultado.Archivos = [int]$medida.Count
        $resultado.Ultimo   = ($archivos | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        return $resultado
    }

    function Initialize-ArbolDePrueba {
        param([string] $Base)
        # Tres niveles con archivos y fechas repartidas: el más reciente no es
        # el último escrito.
        $fecha = [datetime]'2021-03-04 10:00:00'
        foreach ($rama in @('', 'uno', 'uno/hondo', 'dos')) {
            $carpeta = if ($rama) { Join-Path $Base $rama } else { $Base }
            New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
            foreach ($n in 1..3) {
                $archivo = Join-Path $carpeta "a$n.bin"
                [IO.File]::WriteAllBytes($archivo, [byte[]]::new(100 * $n))
                [IO.File]::SetLastWriteTime($archivo, $fecha)
                $fecha = $fecha.AddHours(7)
            }
        }
        # Carpeta vacía: caso aparte en las dos funciones.
        New-Item -ItemType Directory -Path (Join-Path $Base 'sin-nada') -Force | Out-Null
    }
}

Describe 'Measure-Ruta coincide con la implementacion de referencia' {

    BeforeEach {
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fs_' + [Guid]::NewGuid())
        Initialize-ArbolDePrueba $script:Base
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'suma un arbol entero igual que Get-ChildItem -Recurse' {
        $antes = Measure-RutaComoAntes $script:Base
        $antes | Should -BeGreaterThan 0
        Measure-Ruta $script:Base | Should -Be $antes
    }

    It 'una subcarpeta cualquiera tambien coincide' {
        $sub = Join-Path $script:Base 'uno'
        Measure-Ruta $sub | Should -Be (Measure-RutaComoAntes $sub)
    }

    It 'un archivo suelto devuelve su tamaño' {
        $archivo = Join-Path $script:Base 'a1.bin'
        Measure-Ruta $archivo | Should -Be 100
    }

    It 'una carpeta vacia devuelve cero' {
        Measure-Ruta (Join-Path $script:Base 'sin-nada') | Should -Be 0
    }

    It 'lo que no existe, lo vacio y lo que ni siquiera es una ruta devuelven cero' -ForEach @(
        @{ Caso = 'no existe';       Ruta = 'zzz-no-existe-zzz' }
        @{ Caso = 'cadena vacia';    Ruta = '' }
        @{ Caso = 'solo espacios';   Ruta = '   ' }
        # El método Comando usa la orden como Ruta.
        @{ Caso = 'una orden';       Ruta = 'docker system prune' }
    ) {
        Measure-Ruta $Ruta | Should -Be 0
    }
}

Describe 'Measure-RutaDetalle coincide con la implementacion de referencia' {

    BeforeEach {
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fs_' + [Guid]::NewGuid())
        Initialize-ArbolDePrueba $script:Base
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'coinciden los tres campos sobre un arbol con subcarpetas' {
        $antes  = Measure-RutaDetalleComoAntes $script:Base
        $ahora  = Measure-RutaDetalle $script:Base

        $antes.Archivos | Should -Be 12
        $ahora.Bytes    | Should -Be $antes.Bytes
        $ahora.Archivos | Should -Be $antes.Archivos
        $ahora.Ultimo   | Should -Be $antes.Ultimo
    }

    It 'la fecha es la del archivo mas reciente, no la del ultimo que se recorre' {
        # Es un máximo sobre ticks; el archivo más nuevo está a mitad del recorrido.
        $tarde = Join-Path $script:Base 'uno/hondo/a2.bin'
        [IO.File]::SetLastWriteTime($tarde, [datetime]'2030-12-31 23:00:00')

        (Measure-RutaDetalle $script:Base).Ultimo | Should -Be ([datetime]'2030-12-31 23:00:00')
    }

    It 'una carpeta sin archivos devuelve cero y SU PROPIA fecha' {
        $vacia  = Join-Path $script:Base 'sin-nada'
        $antes  = Measure-RutaDetalleComoAntes $vacia
        $ahora  = Measure-RutaDetalle $vacia

        $ahora.Bytes    | Should -Be 0
        $ahora.Archivos | Should -Be 0
        $ahora.Ultimo   | Should -Be $antes.Ultimo
        $ahora.Ultimo   | Should -Not -Be ([datetime]'1900-01-01')
    }

    It 'un archivo suelto cuenta como un archivo, no como carpeta vacia' {
        $archivo = Join-Path $script:Base 'a3.bin'
        $antes   = Measure-RutaDetalleComoAntes $archivo
        $ahora   = Measure-RutaDetalle $archivo

        $ahora.Bytes    | Should -Be $antes.Bytes
        $ahora.Archivos | Should -Be $antes.Archivos
        $ahora.Ultimo   | Should -Be $antes.Ultimo
    }

    It 'lo que no existe devuelve el objeto vacio con la fecha centinela' {
        $r = Measure-RutaDetalle (Join-Path $script:Base 'zzz')
        $r.Bytes    | Should -Be 0
        $r.Archivos | Should -Be 0
        $r.Ultimo   | Should -Be ([datetime]'1900-01-01')
    }
}

Describe 'El recorrido no atraviesa puntos de reanalisis' {

    BeforeEach {
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fs_' + [Guid]::NewGuid())
        Initialize-ArbolDePrueba $script:Base
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un enlace dado como raiz devuelve cero' {
        $enlace = Join-Path ([IO.Path]::GetTempPath()) ('fs_enlace_' + [Guid]::NewGuid())
        $creado = New-Item -ItemType SymbolicLink -Path $enlace -Target $script:Base -ErrorAction SilentlyContinue
        # Sin permiso para crear enlaces no hay nada que comprobar aquí.
        if (-not $creado) { return }

        # Se borra con System.IO: en PowerShell 5.1, Remove-Item sobre un enlace
        # simbólico a carpeta lanza NullReferenceException, que -ErrorAction no
        # suprime. Directory::Delete con $false borra el enlace, no su destino.
        try {
            Measure-Ruta $enlace | Should -Be 0
        } finally {
            try {
                [IO.Directory]::Delete($enlace, $false)
            } catch {
                # Se informa: el enlace quedaría en la carpeta temporal.
                Write-Verbose "No se ha podido quitar el enlace de prueba: $($_.Exception.Message)"
            }
        }
    }

    It 'un enlace DENTRO del arbol no se sigue: su destino no se cuenta dos veces' {
        # Diferencia deliberada con Get-ChildItem -Recurse, que en PowerShell 5.1
        # entra en las junctions: contaría dos veces una carpeta hermana y
        # entraría en bucle con un ancestro.
        $solo   = Measure-Ruta $script:Base
        $enlace = Join-Path $script:Base 'atajo'
        $creado = New-Item -ItemType SymbolicLink -Path $enlace -Target (Join-Path $script:Base 'uno') -ErrorAction SilentlyContinue
        if (-not $creado) { return }

        Measure-Ruta $script:Base | Should -Be $solo
    }
}

Describe 'Las unidades y el nombre del sistema no se preguntan dos veces' {

    It 'Get-UnidadesAnalizables devuelve la forma que espera el resto del programa' {
        foreach ($unidad in @(Get-UnidadesAnalizables)) {
            $unidad.Letra    | Should -Not -BeNullOrEmpty
            # Se usa como $unidad.Letra + '\', así que no lleva separador final.
            # Solo es significativo en Windows: en Linux DriveInfo.Name devuelve
            # puntos de montaje ("/", "/boot").
            $unidad.Letra    | Should -Not -Match '\\$'
            $unidad.Etiqueta | Should -Not -BeNullOrEmpty
            $unidad.Total    | Should -BeOfType [double]
            $unidad.Libre    | Should -BeOfType [double]
        }
    }

    It 'Get-PropiedadUnidad devuelve cero ante una unidad que no existe' {
        Get-PropiedadUnidad -Unidad 'ZZ:' -Propiedad 'FreeSpace' | Should -Be 0
        Get-PropiedadUnidad -Unidad ''    -Propiedad 'Size'      | Should -Be 0
    }

    It 'Get-DescripcionSistema siempre responde algo y responde lo mismo' {
        $primera = Get-DescripcionSistema
        $primera | Should -Not -BeNullOrEmpty
        Get-DescripcionSistema | Should -Be $primera
    }
}

Describe 'una carpeta inaccesible no se lleva por delante lo que cuelga de ella' {

    <#
        Get-ResumenArbol usa un try para enumerar archivos y otro para
        subcarpetas: con uno solo, un fallo en los archivos saltaría también
        las subcarpetas y la rama entera faltaría en la suma, sin error visible.
    #>

    BeforeEach {
        $script:raizArbol = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-arbol-' + [guid]::NewGuid())
        $script:hija = Join-Path $script:raizArbol 'subcarpeta'
        New-Item -ItemType Directory -Path $script:hija -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:raizArbol 'raiz.dat') -Value ('x' * 1000) -NoNewline
        Set-Content -LiteralPath (Join-Path $script:hija 'hija.dat')      -Value ('x' * 5000) -NoNewline
    }

    AfterEach {
        Remove-Item -LiteralPath $script:raizArbol -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'suma el arbol entero cuando todo es accesible' {
        $resumen = Get-ResumenArbol -Carpeta (Get-Item -LiteralPath $script:raizArbol)
        $resumen.Bytes    | Should -Be 6000
        $resumen.Archivos | Should -Be 2
    }

    It 'los dos recorridos son independientes: cada uno tiene su propio try' {
        # Comprobación estructural: un acceso denegado no se puede simular de
        # forma portable. Se exigen dos bloques try separados, uno por enumeración.
        $ruta = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Core/FileSystem.ps1'
        $texto = Get-Content -LiteralPath $ruta -Raw

        # El corte termina en Get-ElementosDelArbol, la función siguiente, para
        # no contar los try de otra función.
        $cuerpo = $texto.Substring($texto.IndexOf('function Get-ResumenArbol'),
                                   $texto.IndexOf('function Get-ElementosDelArbol') - $texto.IndexOf('function Get-ResumenArbol'))

        @([regex]::Matches($cuerpo, '(?m)^\s*try\s*\{')).Count |
            Should -Be 2 -Because 'un try por enumeracion: si comparten uno, perder los archivos pierde las subcarpetas'
    }

    It 'el recorrido compartido tambien lleva un try por enumeracion' {
        # Lo mismo en Get-ElementosDelArbol, el recorrido de los módulos: una
        # carpeta sin permiso dejaría de proponer todo lo que cuelga de ella.
        $ruta = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Core/FileSystem.ps1'
        $texto = Get-Content -LiteralPath $ruta -Raw

        $desde = $texto.IndexOf('function Get-ElementosDelArbol')
        $hasta = $texto.IndexOf('function Measure-Ruta')
        $desde | Should -BeGreaterThan 0
        $hasta | Should -BeGreaterThan $desde

        $cuerpo = $texto.Substring($desde, $hasta - $desde)
        @([regex]::Matches($cuerpo, '(?m)^\s*try\s*\{')).Count |
            Should -Be 3 -Because 'uno para abrir la raiz y uno por cada enumeracion, archivos y subcarpetas'
    }
}

Describe 'Get-HuellaRapida como prefiltro de duplicados' {

    <#
        Contrato asimétrico: huellas distintas garantizan archivos distintos;
        huellas iguales no garantizan nada y obligan al hash completo.
    #>

    BeforeAll {
        $script:carpetaHuella = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-huella-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:carpetaHuella -Force | Out-Null

        function New-ArchivoDePrueba {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Solo crea un archivo de prueba en una ruta temporal propia.')]
            [CmdletBinding()]
            param([string] $Nombre, [byte[]] $Contenido)

            $ruta = Join-Path $script:carpetaHuella $Nombre
            [IO.File]::WriteAllBytes($ruta, $Contenido)
            return $ruta
        }

        # Archivos grandes con la misma cabecera que solo difieren al final
        # (p. ej. grabaciones de la misma cámara o imágenes de disco).
        $cabecera = New-Object byte[] (200KB)
        for ($i = 0; $i -lt $cabecera.Length; $i++) { $cabecera[$i] = 7 }

        $a = $cabecera.Clone(); $a[$a.Length - 1] = 1
        $b = $cabecera.Clone(); $b[$b.Length - 1] = 2
        $c = $cabecera.Clone(); $c[$c.Length - 1] = 1

        $script:rutaA = New-ArchivoDePrueba -Nombre 'a.bin' -Contenido $a
        $script:rutaB = New-ArchivoDePrueba -Nombre 'b.bin' -Contenido $b
        $script:rutaC = New-ArchivoDePrueba -Nombre 'c.bin' -Contenido $c
    }

    AfterAll {
        Remove-Item -LiteralPath $script:carpetaHuella -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'dos archivos identicos tienen la misma huella' {
        Get-HuellaRapida -Ruta $script:rutaA | Should -Be (Get-HuellaRapida -Ruta $script:rutaC)
    }

    It 'distingue archivos que solo se diferencian al FINAL' {
        # Requiere leer los últimos 64 KB.
        Get-HuellaRapida -Ruta $script:rutaA |
            Should -Not -Be (Get-HuellaRapida -Ruta $script:rutaB)
    }

    It 'el tamaño forma parte de la huella' {
        $corto = Join-Path $script:carpetaHuella 'corto.bin'
        [IO.File]::WriteAllBytes($corto, (New-Object byte[] 10))
        $largo = Join-Path $script:carpetaHuella 'largo.bin'
        [IO.File]::WriteAllBytes($largo, (New-Object byte[] 20))

        Get-HuellaRapida -Ruta $corto | Should -Not -Be (Get-HuellaRapida -Ruta $largo)
    }

    It 'funciona con archivos mas pequenos que el trozo que lee' {
        $mini = Join-Path $script:carpetaHuella 'mini.bin'
        [IO.File]::WriteAllBytes($mini, [byte[]]@(1, 2, 3))
        Get-HuellaRapida -Ruta $mini | Should -Not -BeNullOrEmpty
    }

    It 'devuelve vacio sin lanzar si el archivo no existe' {
        { Get-HuellaRapida -Ruta (Join-Path $script:carpetaHuella 'no-existe.bin') } | Should -Not -Throw
        Get-HuellaRapida -Ruta (Join-Path $script:carpetaHuella 'no-existe.bin') | Should -BeNullOrEmpty
    }

    It 'coincide consigo misma en dos lecturas seguidas' {
        Get-HuellaRapida -Ruta $script:rutaA | Should -Be (Get-HuellaRapida -Ruta $script:rutaA)
    }
}

Describe 'los enlaces duros se cuentan una sola vez' {

    <#
        Un enlace duro es otra entrada de directorio para el mismo contenido:
        dos rutas, unos solos bytes. Contarlo dos veces haría que duplicados
        propusiera borrar una copia sin liberar nada.

        Se usan enlaces duros reales; si el sistema de archivos no los
        admite, las pruebas se saltan.
    #>

    BeforeAll {
        $script:carpetaEnlaces = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-enlaces-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:carpetaEnlaces -Force | Out-Null

        $script:original = Join-Path $script:carpetaEnlaces 'original.bin'
        [IO.File]::WriteAllBytes($script:original, (New-Object byte[] 100000))

        $script:suelto = Join-Path $script:carpetaEnlaces 'suelto.bin'
        [IO.File]::WriteAllBytes($script:suelto, (New-Object byte[] 50000))

        # Dos banderas separadas: si el sistema de archivos admite enlaces duros
        # y si el programa sabe detectarlos.
        $script:enlace = Join-Path $script:carpetaEnlaces 'enlace.bin'
        $script:EnlaceCreado = $false
        $script:HayEnlaces   = $false
        try {
            if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                & cmd /c mklink /H "`"$script:enlace`"" "`"$script:original`"" 2>&1 | Out-Null
            } else {
                & ln $script:original $script:enlace 2>&1 | Out-Null
            }
            $script:EnlaceCreado = Test-Path -LiteralPath $script:enlace
            $script:HayEnlaces   = $script:EnlaceCreado -and
                                   ($null -ne (Get-IdentidadArchivo -Ruta $script:original))
        } catch {
            $script:EnlaceCreado = $false
            $script:HayEnlaces   = $false
        }

        # PowerShell 6 o superior.
        $script:EsPwsh7 = $PSVersionTable.PSVersion.Major -ge 6
    }

    AfterAll {
        Remove-Item -LiteralPath $script:carpetaEnlaces -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'el sistema de archivos admite enlaces duros' {
        $script:EnlaceCreado | Should -BeTrue -Because 'sin enlace creado no hay nada que medir'
    }

    It 'y el programa sabe verlos, salvo la degradacion conocida de PowerShell 7' {
        <#
            Limitación conocida: Get-IdentidadArchivo usa LinkType y Target de
            Get-Item. En PowerShell 5.1 (con el que arranca Cachivache.exe)
            funciona; en PowerShell 7, Target no se rellena para enlaces duros,
            la función devuelve $null y los enlaces duros se cuentan dos veces
            sin error. La prueba exige que la degradación se limite a
            PowerShell 7. La solución pasa por usar el número de serie del
            volumen y el índice del archivo.
        #>
        if ($script:HayEnlaces) { return }

        $script:EsPwsh7 | Should -BeTrue -Because (
            'en PowerShell 5.1 los enlaces duros sí se detectan. Que no se detecten ahí ' +
            'significa que la detección de enlaces duros está rota en la versión con la que corre el programa')
    }

    It 'un archivo con un solo enlace no tiene identidad compartida' {
        Get-IdentidadArchivo -Ruta $script:suelto |
            Should -BeNullOrEmpty -Because 'devolver $null en el caso normal es lo que lo hace barato'
    }

    It 'los dos enlaces al mismo contenido comparten identidad' {
        if (-not $script:HayEnlaces) { Set-ItResult -Skipped -Because 'el sistema no admite enlaces duros'; return }
        Get-IdentidadArchivo -Ruta $script:original |
            Should -Be (Get-IdentidadArchivo -Ruta $script:enlace)
    }

    It 'sin el modificador se siguen contando dos veces: el comportamiento de siempre' {
        if (-not $script:HayEnlaces) { Set-ItResult -Skipped -Because 'el sistema no admite enlaces duros'; return }
        $resumen = Get-ResumenArbol -Carpeta (Get-Item -LiteralPath $script:carpetaEnlaces)
        $resumen.Bytes | Should -Be 250000
    }

    It 'con el modificador se cuenta el contenido una sola vez' {
        if (-not $script:HayEnlaces) { Set-ItResult -Skipped -Because 'el sistema no admite enlaces duros'; return }
        $resumen = Get-ResumenArbol -Carpeta (Get-Item -LiteralPath $script:carpetaEnlaces) -ContarEnlacesDuros

        $resumen.Bytes       | Should -Be 150000 -Because 'los 100 KB compartidos se suman una vez, no dos'
        $resumen.Archivos    | Should -Be 3      -Because 'las entradas de directorio si son tres'
        $resumen.Compartidos | Should -Be 1
    }

    It 'el conjunto se crea de verdad: un if como expresion lo habria dejado en $null' {
        # "$x = if (...) { [HashSet]::new() }" pasa el resultado por la
        # canalización, que enumera las colecciones: un conjunto vacío da $null.
        # Solo se miran líneas de código: el comentario de src cita la forma incorrecta.
        $lineas = Get-Content -LiteralPath (
            Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core') 'FileSystem.ps1')
        $codigo = @($lineas | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        $codigo | Should -Not -Match '\$vistos\s*=\s*if\s*\('
        $codigo | Should -Match '\$vistos\s*=\s*\$null'
    }
}

Describe 'Get-ElementosDelArbol, el recorrido que usan los modulos' {

    <#
        Get-ChildItem -Recurse de PowerShell 5.1 se detiene en silencio en
        rutas de más de 260 caracteres; Get-ElementosDelArbol las recorre.
        Un fallo aquí no da error: hace que se proponga de menos o de más.

        El límite de 260 es de Windows. Aquí se comprueba que el recorrido
        soporta un árbol profundo y devuelve rutas limpias; el uso del
        prefijo es una invariante de texto y se prueba en Windows con el banco.
    #>

    BeforeEach {
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('cor08-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Base -Force | Out-Null

        # Un archivo arriba, otro en una subcarpeta, uno oculto y uno con otra extensión.
        [IO.File]::WriteAllText((Join-Path $script:Base 'arriba.tmp'), 'aaa')
        [IO.File]::WriteAllText((Join-Path $script:Base 'otro.lnk'), 'bb')
        New-Item -ItemType Directory -Path (Join-Path $script:Base 'sub') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Base 'sub/dentro.tmp'), 'cccc')
        [IO.File]::WriteAllText((Join-Path $script:Base 'sub/.oculto'), 'ddddd')

        # Rama real de más de 260 caracteres, con carpetas reales.
        $script:Hondo = $script:Base
        1..12 | ForEach-Object {
            $script:Hondo = Join-Path $script:Hondo ('carpeta-anidada-con-nombre-largo-numero-{0:00}' -f $_)
        }
        New-Item -ItemType Directory -Path $script:Hondo -Force | Out-Null
        $script:ArchivoHondo = Join-Path $script:Hondo 'volcado-antiguo.dmp'
        [IO.File]::WriteAllText($script:ArchivoHondo, 'x' * 28)
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'el arbol de prueba es hondo de verdad: si no, esta prueba no comprueba nada' {
        # Control: sin profundidad real, el resto no probaría nada.
        $script:ArchivoHondo.Length | Should -BeGreaterThan 260
    }

    It 'encuentra lo mismo que Get-ChildItem -Recurse -File -Force' {
        $mio  = @(Get-ElementosDelArbol -Ruta $script:Base | ForEach-Object { $_.FullName }) | Sort-Object
        $suyo = @(Get-ChildItem -LiteralPath $script:Base -Recurse -File -Force -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.FullName }) | Sort-Object

        @($suyo).Count | Should -BeGreaterThan 3
        ($mio -join '|') | Should -Be ($suyo -join '|')
    }

    It 'llega al archivo del fondo de la rama larga' {
        @(Get-ElementosDelArbol -Ruta $script:Base | Where-Object { $_.FullName -eq $script:ArchivoHondo }).Count |
            Should -Be 1
    }

    It 'ninguna ruta que sale lleva el prefijo de ruta larga' {
        # Seguridad: la ruta llega a la guardia, y "\\?\C:\Windows" no
        # coincidiría con "C:\Windows" en su lista negra.
        foreach ($elemento in @(Get-ElementosDelArbol -Ruta $script:Base -Que Todo)) {
            $elemento.FullName    | Should -Not -Match '\\\\\?\\'
            $elemento.DirectoryName | Should -Not -Match '\\\\\?\\'
        }
    }

    It 've los archivos ocultos, que es lo que hacia -Force' {
        # Varios módulos dependen de archivos ocultos (Thumbs.db, desktop.ini, papelera).
        $sinForce = @(Get-ChildItem -LiteralPath (Join-Path $script:Base 'sub') -File -ErrorAction SilentlyContinue).Count
        $conForce = @(Get-ChildItem -LiteralPath (Join-Path $script:Base 'sub') -File -Force -ErrorAction SilentlyContinue).Count
        if ($sinForce -eq $conForce) {
            Set-ItResult -Skipped -Because 'aqui no hay archivos ocultos que distingan una cosa de la otra'
            return
        }
        @(Get-ElementosDelArbol -Ruta $script:Base | Where-Object { $_.Name -eq '.oculto' }).Count | Should -Be 1
    }

    It 'trae las propiedades con las que deciden los modulos' {
        $archivo = @(Get-ElementosDelArbol -Ruta $script:Base | Where-Object { $_.Name -eq 'arriba.tmp' })[0]

        # Cada una la usa algún módulo; sin ella compararía contra $null sin error.
        $archivo.FullName      | Should -Be (Join-Path $script:Base 'arriba.tmp')
        $archivo.Name          | Should -Be 'arriba.tmp'
        $archivo.BaseName      | Should -Be 'arriba'
        $archivo.Extension     | Should -Be '.tmp'
        $archivo.Length        | Should -Be 3
        $archivo.DirectoryName | Should -Be $script:Base
        $archivo.EsCarpeta     | Should -BeFalse
        $archivo.LastWriteTime | Should -BeOfType [datetime]
        $archivo.LastAccessTime| Should -BeOfType [datetime]
        $archivo.CreationTime  | Should -BeOfType [datetime]
        [int]$archivo.Attributes | Should -BeGreaterThan 0
    }

    It 'el filtro lo resuelve la API y no cambia por donde se desciende' {
        $conFiltro = @(Get-ElementosDelArbol -Ruta $script:Base -Filtro '*.tmp' | ForEach-Object { $_.Name })
        $conFiltro | Should -Contain 'arriba.tmp'
        $conFiltro | Should -Contain 'dentro.tmp'
        $conFiltro | Should -Not -Contain 'otro.lnk'

        # El filtro no poda: el .dmp del fondo está tras doce carpetas que no casan.
        @(Get-ElementosDelArbol -Ruta $script:Base -Filtro '*.dmp').Count | Should -Be 1
    }

    It 'la barra final de la carpeta de partida no ensucia lo que sale' {
        # Evita separadores dobles: las rutas se comparan como texto en la
        # guardia, las exclusiones y el comprobador del banco.
        $conBarra = @(Get-ElementosDelArbol -Ruta ($script:Base + [IO.Path]::DirectorySeparatorChar) |
                      ForEach-Object { $_.FullName }) | Sort-Object
        $sinBarra = @(Get-ElementosDelArbol -Ruta $script:Base | ForEach-Object { $_.FullName }) | Sort-Object
        ($conBarra -join '|') | Should -Be ($sinBarra -join '|')
    }

    It 'lo que no existe, lo vacio y lo que ni siquiera es una ruta no lanzan' -ForEach @(
        @{ Caso = 'no existe';     Ruta = '/zzz-no-existe-zzz/tampoco' }
        @{ Caso = 'cadena vacia';  Ruta = '' }
        @{ Caso = 'solo espacios'; Ruta = '   ' }
        # El método Comando usa la orden como Ruta.
        @{ Caso = 'una etiqueta';  Ruta = 'docker system prune' }
    ) {
        { $null = @(Get-ElementosDelArbol -Ruta $Ruta) } | Should -Not -Throw
        @(Get-ElementosDelArbol -Ruta $Ruta).Count | Should -Be 0
    }

    It 'con Ruta a $null no lanza' {
        # Requiere [AllowNull()] en el parámetro Mandatory.
        { $null = @(Get-ElementosDelArbol -Ruta $null) } | Should -Not -Throw
    }

    It 'Que Carpetas devuelve carpetas y no archivos' {
        $carpetas = @(Get-ElementosDelArbol -Ruta $script:Base -Que Carpetas)
        @($carpetas | Where-Object { -not $_.EsCarpeta }).Count | Should -Be 0
        @($carpetas | Where-Object { $_.Name -eq 'sub' }).Count | Should -Be 1
        # Incluidas las doce de la rama profunda.
        @($carpetas).Count | Should -BeGreaterThan 12
    }

    It 'Que Todo devuelve las dos cosas' {
        $todo = @(Get-ElementosDelArbol -Ruta $script:Base -Que Todo)
        @($todo | Where-Object { $_.EsCarpeta }).Count       | Should -BeGreaterThan 0
        @($todo | Where-Object { -not $_.EsCarpeta }).Count  | Should -BeGreaterThan 0
    }

    It 'NoDescender poda la rama entera, no solo la carpeta' {
        $poda = { param($C) return ($C.Name -eq 'carpeta-anidada-con-nombre-largo-numero-01') }
        $rutas = @(Get-ElementosDelArbol -Ruta $script:Base -NoDescender $poda | ForEach-Object { $_.FullName })

        $rutas | Should -Not -Contain $script:ArchivoHondo
        $rutas | Should -Contain (Join-Path $script:Base 'arriba.tmp')
    }

    It 'Cancelado para el recorrido' {
        $veces = @{ N = 0 }
        # Se cancela en la segunda carpeta: importa que pare, no cuánto devuelve.
        $cancela = { $veces.N++; return ($veces.N -gt 2) }
        $antes = @(Get-ElementosDelArbol -Ruta $script:Base).Count
        $antes | Should -BeGreaterThan 3
        @(Get-ElementosDelArbol -Ruta $script:Base -Cancelado $cancela).Count | Should -BeLessThan $antes
    }
}

Describe 'los enlaces no se siguen, ni al recorrer ni al proponer' {

    BeforeAll {
        $script:BaseEnl = Join-Path ([IO.Path]::GetTempPath()) ('cor08e-' + [guid]::NewGuid())
        $script:Destino = Join-Path $script:BaseEnl 'destino'
        New-Item -ItemType Directory -Path $script:Destino -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Destino 'tesoro.tmp'), 'x' * 10)

        $script:HayEnlace = $false
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:BaseEnl 'atajo') `
                     -Target $script:Destino -ErrorAction Stop | Out-Null
            $script:HayEnlace = $true
        } catch {
            Write-Verbose "Sin enlaces simbolicos en este sistema: $($_.Exception.Message)"
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:BaseEnl -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un punto de reanalisis no se sigue: el contenido sale una sola vez' {
        if (-not $script:HayEnlace) { Set-ItResult -Skipped -Because 'el sistema no admite enlaces simbolicos'; return }
        # Si se siguiera, tesoro.tmp saldría dos veces.
        @(Get-ElementosDelArbol -Ruta $script:BaseEnl | Where-Object { $_.Name -eq 'tesoro.tmp' }).Count |
            Should -Be 1
    }

    It 'por defecto el enlace ni siquiera se devuelve' {
        if (-not $script:HayEnlace) { Set-ItResult -Skipped -Because 'el sistema no admite enlaces simbolicos'; return }
        @(Get-ElementosDelArbol -Ruta $script:BaseEnl -Que Carpetas | Where-Object { $_.Name -eq 'atajo' }).Count |
            Should -Be 0
    }

    It 'con -IncluirEnlaces se devuelve, pero sigue sin entrarse' {
        if (-not $script:HayEnlace) { Set-ItResult -Skipped -Because 'el sistema no admite enlaces simbolicos'; return }
        # Lo usa Remove-RutaSegura para buscar enlaces antes de un borrado recursivo.
        @(Get-ElementosDelArbol -Ruta $script:BaseEnl -Que Carpetas -IncluirEnlaces |
          Where-Object { $_.Name -eq 'atajo' }).Count | Should -Be 1
        @(Get-ElementosDelArbol -Ruta $script:BaseEnl -Que Todo -IncluirEnlaces |
          Where-Object { $_.Name -eq 'tesoro.tmp' }).Count | Should -Be 1
    }
}

Describe 'una carpeta sin permiso no puede abortar el recorrido' {

    BeforeAll {
        $script:BasePerm = Join-Path ([IO.Path]::GetTempPath()) ('cor08p-' + [guid]::NewGuid())
        $script:Cerrada  = Join-Path $script:BasePerm 'cerrada'
        New-Item -ItemType Directory -Path $script:Cerrada -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Cerrada 'dentro.tmp'), 'x')
        [IO.File]::WriteAllText((Join-Path $script:BasePerm 'hermano.tmp'), 'yy')

        # chmod no existe en Windows: si la carpeta sigue legible, la prueba se salta.
        $script:Cerro = $false
        try {
            & chmod 000 $script:Cerrada 2>$null
            $script:Cerro = -not (Test-Path -LiteralPath (Join-Path $script:Cerrada 'dentro.tmp') `
                                            -ErrorAction SilentlyContinue)
        } catch {
            Write-Verbose "No se ha podido cerrar la carpeta: $($_.Exception.Message)"
        }
    }

    AfterAll {
        & chmod 755 $script:Cerrada 2>$null
        Remove-Item -LiteralPath $script:BasePerm -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'se pierde esa carpeta y no el recorrido entero' {
        if (-not $script:Cerro) { Set-ItResult -Skipped -Because 'aqui no se puede cerrar una carpeta'; return }

        { $script:Salida = @(Get-ElementosDelArbol -Ruta $script:BasePerm) } | Should -Not -Throw
        $rutas = @($script:Salida | ForEach-Object { $_.Name })

        $rutas | Should -Contain 'hermano.tmp' -Because 'lo que si se puede leer se sigue devolviendo'
        $rutas | Should -Not -Contain 'dentro.tmp'
    }

    It 'con ErrorActionPreference en Stop -que es lo que pone el modo consola- sigue sin abortar' {
        if (-not $script:Cerro) { Set-ItResult -Skipped -Because 'aqui no se puede cerrar una carpeta'; return }

        # El modo consola usa ErrorActionPreference = 'Stop': un Write-Error en
        # el catch haría que una carpeta ilegible abortara el análisis.
        # No se usa -ErrorVariable: $Error registra excepciones de método
        # aunque las capture un try.
        $previo = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Stop'
            { $script:Duro = @(Get-ElementosDelArbol -Ruta $script:BasePerm) } | Should -Not -Throw
        } finally {
            $ErrorActionPreference = $previo
        }
        @($script:Duro | ForEach-Object { $_.Name }) | Should -Contain 'hermano.tmp'
    }
}

Describe 'Measure-RutaLarga, la medicion de rutas largas' {

    <#
        Get-Item no resuelve rutas largas en PowerShell 5.1, y Measure-Ruta
        devolvería cero dejando el candidato bajo el mínimo.

        El camino de System.IO con prefijo solo existe en Windows
        (ConvertTo-RutaLarga no modifica rutas en otros sistemas). Aquí se
        comprueba que la función no actúa fuera de su caso ni lanza.
    #>

    It 'una ruta que no es larga devuelve cero sin mirar el disco' {
        Measure-RutaLarga -Ruta '/tmp' | Should -Be 0.0
    }

    It 'con nulo, vacio y una etiqueta no lanza' -ForEach @(
        @{ Caso = 'nulo';     Ruta = $null }
        @{ Caso = 'vacio';    Ruta = '' }
        @{ Caso = 'etiqueta'; Ruta = 'docker system prune' }
    ) {
        { Measure-RutaLarga -Ruta $Ruta } | Should -Not -Throw
        Measure-RutaLarga -Ruta $Ruta | Should -Be 0.0
    }

    It 'Measure-Ruta solo cae en ella cuando Get-Item no ha resuelto nada' {
        # Comprobación estructural (el camino real solo existe en Windows): la
        # llamada está en la rama del $null, así que no afecta a otros casos.
        $texto = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core') 'FileSystem.ps1')
        $codigo = @(($texto -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $codigo | Should -Match '\$null -eq \$item\s*\)\s*\{ return \(Measure-RutaLarga -Ruta \$Ruta\) \}'
    }
}
