<#
    Pruebas de la vista de archivos: la capa de consulta sobre el índice.

    El índice es sintético, con la misma forma que devuelve
    New-IndiceDisco: se prueba la consulta, no el recorrido del disco (que
    tiene sus pruebas en tests/Indice.Tests.ps1).

    Se construye en un BeforeAll: lo asignado en el cuerpo del Describe se
    evalúa durante el descubrimiento de Pester y llega vacío a los It.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')


    function New-FilaFalsa {
        <#
        .SYNOPSIS
            Una fila de la lista Archivos del indice, con su misma forma.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo compone un objeto en memoria.')]
        [CmdletBinding()]
        param([string] $Nombre, [double] $Bytes, [string] $Carpeta = 'C:\datos')

        return [pscustomobject]@{
            # Concatenación y no Join-Path: en Linux Join-Path falla con la
            # unidad C:. Aquí la ruta es solo una etiqueta.
            Ruta      = ($Carpeta + '\' + $Nombre)
            Nombre    = $Nombre
            Carpeta   = $Carpeta
            Extension = ([IO.Path]::GetExtension($Nombre)).ToLowerInvariant()
            Bytes     = $Bytes
            Ultimo    = [datetime]'2026-01-15'
        }
    }

    function New-IndiceFalso {
        <#
        .SYNOPSIS
            Indice sintetico con la misma forma que New-IndiceDisco.
        .PARAMETER Filas
            Lo que va en Archivos. Vacio simula un disco sin nada por
            encima del umbral.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo compone un objeto en memoria.')]
        [CmdletBinding()]
        param(
            [AllowNull()] $Filas,
            [double] $UmbralArchivo = 1MB
        )

        return [pscustomobject]@{
            Carpetas      = [Collections.Generic.Dictionary[string, object]]::new()
            Archivos      = @($Filas)
            Raices        = @('C:\datos')
            Bytes         = 0.0
            TotalArchivos = @($Filas).Count
            Compartidos   = 0
            Inaccesibles  = 0
            UmbralArchivo = $UmbralArchivo
        }
    }

    # Tamaños elegidos para que el orden por bytes y el orden por el texto
    # formateado no coincidan: "9,52 GB" es alfabéticamente menor que
    # "980 MB".
    $script:FilasBase = @(
        (New-FilaFalsa -Nombre 'copia.iso'   -Bytes 10222739456)   #  9,52 GB
        (New-FilaFalsa -Nombre 'video.mkv'   -Bytes 1027604480)    #    980 MB
        (New-FilaFalsa -Nombre 'basura.tmp'  -Bytes 524288000)     #    500 MB
        (New-FilaFalsa -Nombre 'otro.tmp'    -Bytes 104857600)     #    100 MB
        (New-FilaFalsa -Nombre 'foto1.jpg'   -Bytes 5242880)       #      5 MB
        (New-FilaFalsa -Nombre 'foto2.jpg'   -Bytes 4194304)       #      4 MB
        (New-FilaFalsa -Nombre 'foto[1].jpg' -Bytes 3145728)       #      3 MB
        (New-FilaFalsa -Nombre 'anyo ñ.txt'  -Bytes 2097152)       #      2 MB
    )
}

Describe 'Test-CoincideComodin' {

    It 'un patron vacio casa con todo' {
        Test-CoincideComodin -Nombre 'lo que sea.bin' -Patron '' | Should -BeTrue
    }

    It 'un patron de solo espacios tambien casa con todo' {
        Test-CoincideComodin -Nombre 'lo que sea.bin' -Patron '   ' | Should -BeTrue
    }

    It 'un patron nulo casa con todo y no lanza' {
        { Test-CoincideComodin -Nombre 'algo.txt' -Patron $null } | Should -Not -Throw
        Test-CoincideComodin -Nombre 'algo.txt' -Patron $null | Should -BeTrue
    }

    It 'un nombre nulo no lanza y no casa con un patron concreto' {
        { Test-CoincideComodin -Nombre $null -Patron '*.tmp' } | Should -Not -Throw
        Test-CoincideComodin -Nombre $null -Patron '*.tmp' | Should -BeFalse
    }

    It 'los dos nulos a la vez no lanzan' {
        { Test-CoincideComodin -Nombre $null -Patron $null } | Should -Not -Throw
    }

    It '*.tmp casa con lo que acaba en .tmp y no con lo demas' {
        Test-CoincideComodin -Nombre 'basura.tmp'  -Patron '*.tmp' | Should -BeTrue
        Test-CoincideComodin -Nombre 'video.mkv'   -Patron '*.tmp' | Should -BeFalse
        # El punto es literal: sin escaparlo, "basuratmp" casaría.
        Test-CoincideComodin -Nombre 'basuratmp'   -Patron '*.tmp' | Should -BeFalse
    }

    It 'foto?.jpg casa con un caracter y solo uno' {
        Test-CoincideComodin -Nombre 'foto1.jpg'  -Patron 'foto?.jpg' | Should -BeTrue
        Test-CoincideComodin -Nombre 'foto2.jpg'  -Patron 'foto?.jpg' | Should -BeTrue
        Test-CoincideComodin -Nombre 'foto.jpg'   -Patron 'foto?.jpg' | Should -BeFalse
        Test-CoincideComodin -Nombre 'foto12.jpg' -Patron 'foto?.jpg' | Should -BeFalse
    }

    It 'los corchetes son texto, que es justo lo que -like no hace' {
        # Con -like, "foto[1].jpg" se interpreta como clase de caracteres:
        # encuentra foto1.jpg (que no se pidió) y no foto[1].jpg (que sí).
        Test-CoincideComodin -Nombre 'foto[1].jpg' -Patron 'foto[1].jpg' | Should -BeTrue
        Test-CoincideComodin -Nombre 'foto1.jpg'   -Patron 'foto[1].jpg' | Should -BeFalse

        # Comprueba que el defecto de -like existe: si dejara de existir,
        # la prueba anterior ya no comprobaría nada.
        ('foto1.jpg' -like 'foto[1].jpg') | Should -BeTrue -Because 'es el defecto que esta funcion evita'
    }

    It 'no distingue mayusculas de minusculas' {
        Test-CoincideComodin -Nombre 'BASURA.TMP' -Patron '*.tmp' | Should -BeTrue
        Test-CoincideComodin -Nombre 'basura.tmp' -Patron '*.TMP' | Should -BeTrue
    }

    It 'recorta los espacios sobrantes del patron' {
        Test-CoincideComodin -Nombre 'basura.tmp' -Patron ' *.tmp ' | Should -BeTrue
    }

    It 'anclado a los dos extremos: un patron sin comodines es el nombre entero' {
        Test-CoincideComodin -Nombre 'video.mkv'      -Patron 'video.mkv' | Should -BeTrue
        Test-CoincideComodin -Nombre 'mi video.mkv'   -Patron 'video.mkv' | Should -BeFalse
        Test-CoincideComodin -Nombre 'video.mkv.bak'  -Patron 'video.mkv' | Should -BeFalse
    }

    It 'trata como texto los demas caracteres con significado en expresiones regulares' {
        foreach ($nombre in @('a+b.txt', 'a(b).txt', 'a^b.txt', 'a$b.txt', 'a{2}.txt', 'a|b.txt', 'a\b.txt')) {
            Test-CoincideComodin -Nombre $nombre -Patron $nombre |
                Should -BeTrue -Because "«$nombre» tiene que valerse a si mismo"
        }
    }

    It 'muchos asteriscos seguidos no cuelgan ni cambian el resultado' {
        $largo = ('a' * 200) + '.txt'
        $reloj = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-CoincideComodin -Nombre $largo -Patron (('*' * 30) + 'zzz')
        $reloj.Stop()
        $r | Should -BeFalse
        $reloj.Elapsed.TotalSeconds | Should -BeLessThan 2
    }
}

Describe 'Get-VistaArchivos' {

    BeforeAll {
        $script:indice = New-IndiceFalso -Filas $script:FilasBase
    }

    It 'ordena por BYTES y no por el tamaño formateado' {
        $vista = @(Get-VistaArchivos -Indice $script:indice -Cuantos 3)
        # 9,52 GB delante de 980 MB: ordenar por el texto los invertiría.
        @($vista).Count | Should -Be 3
        $vista[0].Nombre | Should -Be 'copia.iso'
        $vista[1].Nombre | Should -Be 'video.mkv'
        $vista[2].Nombre | Should -Be 'basura.tmp'
    }

    It 'ordena por nombre cuando se le pide' {
        $vista = @(Get-VistaArchivos -Indice $script:indice -Cuantos 99 -Orden 'Nombre')
        @($vista).Count | Should -Be 8
        $vista[0].Nombre | Should -Be 'anyo ñ.txt'
        $vista[-1].Nombre | Should -Be 'video.mkv'
    }

    It 'recorta a los que se le piden' {
        @(Get-VistaArchivos -Indice $script:indice -Cuantos 1).Count | Should -Be 1
        @(Get-VistaArchivos -Indice $script:indice -Cuantos 8).Count | Should -Be 8
        # Pedir más de los que hay devuelve los que hay.
        @(Get-VistaArchivos -Indice $script:indice -Cuantos 500).Count | Should -Be 8
    }

    It 'cero o menos filas devuelve una lista vacia y no lanza' {
        @(Get-VistaArchivos -Indice $script:indice -Cuantos 0).Count  | Should -Be 0
        @(Get-VistaArchivos -Indice $script:indice -Cuantos -5).Count | Should -Be 0
    }

    It 'busca con comodines sobre el nombre' {
        $tmp = @(Get-VistaArchivos -Indice $script:indice -Buscar '*.tmp' -Cuantos 99)
        @($tmp).Count | Should -Be 2
        # Sigue ordenado por tamaño dentro del filtro.
        $tmp[0].Nombre | Should -Be 'basura.tmp'
        $tmp[1].Nombre | Should -Be 'otro.tmp'
    }

    It 'la busqueda de un nombre con corchetes encuentra ese archivo y solo ese' {
        $r = @(Get-VistaArchivos -Indice $script:indice -Buscar 'foto[1].jpg' -Cuantos 99)
        @($r).Count | Should -Be 1
        $r[0].Nombre | Should -Be 'foto[1].jpg'
    }

    It 'foto?.jpg encuentra las dos fotos numeradas y no la de corchetes' {
        $r = @(Get-VistaArchivos -Indice $script:indice -Buscar 'foto?.jpg' -Cuantos 99)
        @($r | ForEach-Object { $_.Nombre }) | Should -Be @('foto1.jpg', 'foto2.jpg')
    }

    It 'una busqueda vacia no filtra' {
        @(Get-VistaArchivos -Indice $script:indice -Buscar '' -Cuantos 99).Count | Should -Be 8
        @(Get-VistaArchivos -Indice $script:indice -Buscar $null -Cuantos 99).Count | Should -Be 8
    }

    It 'una busqueda sin coincidencias devuelve una lista vacia y no lanza' {
        @(Get-VistaArchivos -Indice $script:indice -Buscar '*.iso.no' -Cuantos 99).Count | Should -Be 0
    }

    It 'un indice nulo devuelve una lista vacia y no lanza' {
        { Get-VistaArchivos -Indice $null } | Should -Not -Throw
        @(Get-VistaArchivos -Indice $null).Count | Should -Be 0
    }

    It 'un indice sin lista de archivos devuelve una lista vacia y no lanza' {
        $vacio = New-IndiceFalso -Filas $null
        { Get-VistaArchivos -Indice $vacio } | Should -Not -Throw
        @(Get-VistaArchivos -Indice $vacio).Count | Should -Be 0

        $sinPropiedad = [pscustomobject]@{ Bytes = 0.0 }
        { Get-VistaArchivos -Indice $sinPropiedad } | Should -Not -Throw
        @(Get-VistaArchivos -Indice $sinPropiedad).Count | Should -Be 0
    }

    It 'las filas nulas dentro de la lista se saltan sin lanzar' {
        $conNulos = New-IndiceFalso -Filas @($script:FilasBase[0], $null, $script:FilasBase[1])
        { Get-VistaArchivos -Indice $conNulos -Cuantos 99 } | Should -Not -Throw
        @(Get-VistaArchivos -Indice $conNulos -Cuantos 99).Count | Should -Be 2
    }

    It 'rechaza un orden que no existe' {
        { Get-VistaArchivos -Indice $script:indice -Orden 'Inventado' } | Should -Throw
    }
}

Describe 'Lo que sale de la vista NO es un candidato' {

    <#
        Esta vista muestra el disco, no lo limpia. Una fila con Seleccionado
        es una fila que la ventana sabe marcar, y marcar es el primer paso
        de borrar: la propiedad no debe existir en lo que se devuelve.
    #>

    BeforeAll {
        # Índice hostil: sus filas ya llevan propiedades de candidato. Si
        # Get-VistaArchivos las devolviera tal cual, llegarían a la tabla.
        $script:hostil = New-IndiceFalso -Filas @(
            [pscustomobject]@{
                Ruta = 'C:\datos\trampa.iso'; Nombre = 'trampa.iso'; Carpeta = 'C:\datos'
                Extension = '.iso'; Bytes = 999999999.0; Ultimo = [datetime]'2026-01-15'
                Seleccionado = $true; Riesgo = 'Bajo'; Metodo = 'Ruta'; ModuloId = 'inventado'
                ClaveExclusion = 'x'; Hecho = $false; Aviso = ''; Efecto = ''
            }
        )
        $script:filaHostil = @(Get-VistaArchivos -Indice $script:hostil -Cuantos 9)[0]
        $script:propsHostil = @($script:filaHostil.PSObject.Properties.Name)
    }

    It 'ninguna fila devuelta trae las propiedades que hacen borrable a un candidato' {
        foreach ($prohibida in @('Seleccionado', 'Riesgo', 'Metodo', 'ModuloId',
                                 'ClaveExclusion', 'Hecho', 'Aviso', 'Efecto',
                                 'BytesLiberados', 'ForzarPermanente')) {
            $script:propsHostil | Should -Not -Contain $prohibida `
                -Because 'una fila informativa que se parece a un candidato acaba marcada'
        }
    }

    It 'devuelve exactamente los campos de mostrar, ni uno mas' {
        # Si esta lista quedara vacía, la prueba anterior no comprobaría
        # nada.
        @($script:propsHostil).Count | Should -Be 6
        foreach ($esperada in @('Ruta', 'Nombre', 'Carpeta', 'Extension', 'Bytes', 'Ultimo')) {
            $script:propsHostil | Should -Contain $esperada
        }
    }

    It 'y aun asi conserva los datos que hay que enseñar' {
        $script:filaHostil.Nombre | Should -Be 'trampa.iso'
        $script:filaHostil.Bytes  | Should -Be 999999999.0
    }
}

Describe 'Get-ResumenVistaArchivos: las tres situaciones' {

    <#
        Tres situaciones que sin esto se verían iguales; la tercera haría
        creer que el análisis falló.
    #>

    BeforeAll {
        $script:indice = New-IndiceFalso -Filas $script:FilasBase
    }

    It '(a) sin nada por encima del umbral lo dice, y dice que el analisis fue bien' {
        $texto = Get-ResumenVistaArchivos -Indice (New-IndiceFalso -Filas @() -UmbralArchivo 1MB)
        $texto | Should -Match 'Ningún archivo llega a'
        # Se compara con Format-Tamano y no con '1,0 MB': el separador
        # decimal depende de la cultura.
        $texto | Should -Match ([regex]::Escape((Format-Tamano 1MB)))
        $texto | Should -Match 'pequeños'
        $texto | Should -Not -Match 'coincide'
    }

    It '(b) con archivos pero sin coincidencias culpa a la busqueda, no al analisis' {
        $texto = Get-ResumenVistaArchivos -Indice $script:indice -Buscar '*.iso.no'
        $texto | Should -Match 'Ninguno de los 8 archivos'
        $texto | Should -Match '«\*\.iso\.no»'
        $texto | Should -Not -Match 'Ningún archivo llega a'
    }

    It '(c) con mas de los que se enseñan nombra los DOS numeros' {
        $texto = Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 3
        $texto | Should -Match 'Se muestran los 3 mayores de 8 archivos'
        $texto | Should -Match 'quedan 5 más sin mostrar'
    }

    It 'las tres situaciones dan tres textos DISTINTOS' {
        # Si dos coincidieran, tres causas distintas volverían a verse
        # igual.
        $a = Get-ResumenVistaArchivos -Indice (New-IndiceFalso -Filas @())
        $b = Get-ResumenVistaArchivos -Indice $script:indice -Buscar '*.iso.no'
        $c = Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 3
        @($a, $b, $c) | Should -Not -Contain ''
        (@($a, $b, $c) | Select-Object -Unique).Count | Should -Be 3
    }

    It 'cuando se enseña todo no promete que haya mas' {
        $texto = Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 99
        $texto | Should -Match 'todos'
        $texto | Should -Not -Match 'sin mostrar'
    }

    It 'nunca escribe "1 elementos" ni "1 archivos" ni "queda 1 más" en plural' {
        $uno = New-IndiceFalso -Filas @($script:FilasBase[0])

        $solo = Get-ResumenVistaArchivos -Indice $uno -Cuantos 99
        $solo | Should -Match 'el único archivo'
        $solo | Should -Not -Match '1 archivos'

        $sinCoincidir = Get-ResumenVistaArchivos -Indice $uno -Buscar '*.zzz'
        $sinCoincidir | Should -Match 'El único archivo'
        $sinCoincidir | Should -Not -Match 'Ninguno de los 1'

        $dos = New-IndiceFalso -Filas @($script:FilasBase[0], $script:FilasBase[1])
        $cola = Get-ResumenVistaArchivos -Indice $dos -Cuantos 1
        $cola | Should -Match 'queda 1 más sin mostrar'
        $cola | Should -Not -Match 'quedan 1'
        $cola | Should -Match 'Se muestra el mayor de 2 archivos'
        $cola | Should -Not -Match 'los 1 '

        $ninguno = Get-ResumenVistaArchivos -Indice $uno -Cuantos 0
        $ninguno | Should -Match 'Hay 1 archivo'
        $ninguno | Should -Not -Match '1 archivos'
    }

    It 'dice el orden que se ha aplicado, no uno inventado' {
        $porTamano = Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 3 -Orden 'Tamano'
        $porNombre = Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 3 -Orden 'Nombre'
        $porTamano | Should -Match 'mayores'
        $porNombre | Should -Match 'orden alfabético'
        $porNombre | Should -Not -Match 'mayores'
    }

    It 'lleva tildes y eñes de verdad' {
        $texto = Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 3
        # Un archivo guardado sin BOM llenaría los textos de símbolos raros.
        $texto | Should -Match '[áéíóúñ]'
        $texto | Should -Not -Match 'Ã'
    }

    It 'un indice nulo no lanza y no dice que el analisis fallara' {
        { Get-ResumenVistaArchivos -Indice $null } | Should -Not -Throw
        $texto = Get-ResumenVistaArchivos -Indice $null
        [string]::IsNullOrWhiteSpace($texto) | Should -BeFalse
    }

    It 'un indice sin lista de archivos no lanza' {
        { Get-ResumenVistaArchivos -Indice (New-IndiceFalso -Filas $null) } | Should -Not -Throw
        { Get-ResumenVistaArchivos -Indice ([pscustomobject]@{ Bytes = 0.0 }) } | Should -Not -Throw
    }

    It 'pedir cero filas se dice, no se calla' {
        $texto = Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 0
        $texto | Should -Match 'no se está mostrando ninguno'
    }

    It 'ningun texto propone borrar nada' {
        $textos = @(
            (Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 3)
            (Get-ResumenVistaArchivos -Indice $script:indice -Cuantos 99)
            (Get-ResumenVistaArchivos -Indice $script:indice -Buscar '*.tmp' -Cuantos 1)
        )
        foreach ($t in $textos) {
            $t | Should -Match 'no se propone borrar nada'
        }
    }
}

Describe 'La vista y su resumen no pueden divergir' {

    <#
    <#
        La lista de órdenes está copiada en tres ValidateSet (la consulta,
        el resumen y -Orden de Show-InformeEspacio): PowerShell no admite
        llamadas a función dentro de un atributo. La copia es inevitable;
        que diverjan sin aviso, no.
    #>

    BeforeAll {
        $script:ordenes = @(Get-OrdenesVistaArchivos)
        $script:archivoFuente = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'VistaArchivos.ps1'

        # Show-InformeEspacio vive en el modo consola; solo se miran sus
        # metadatos, cargarlo no ejecuta nada.
        . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Cli') 'Espacio.ps1')

        # Los tres sitios que deben coincidir. Un cuarto sitio debe añadirse
        # aquí para quedar protegido.
        $script:ConOrden = @('Get-VistaArchivos', 'Get-ResumenVistaArchivos', 'Show-InformeEspacio')
    }

    It 'Get-OrdenesVistaArchivos dice algo' {
        @($script:ordenes).Count | Should -BeGreaterThan 1
    }

    It 'las tres funciones que hablan de orden estan cargadas' {
        # Si Espacio.ps1 dejara de cargarse, la prueba siguiente fallaría
        # por el motivo equivocado o dejaría de mirar un sitio.
        foreach ($nombre in $script:ConOrden) {
            @(Get-Command $nombre -ErrorAction SilentlyContinue).Count |
                Should -Be 1 -Because "$nombre tiene que existir para poder mirarle el ValidateSet"
        }
    }

    It 'las tres funciones aceptan exactamente los mismos ordenes' {
        foreach ($nombre in $script:ConOrden) {
            $atributo = @((Get-Command $nombre).Parameters['Orden'].Attributes |
                          Where-Object { $_ -is [ValidateSet] })
            @($atributo).Count | Should -Be 1 -Because "$nombre tiene que validar el orden"
            $valores = @($atributo[0].ValidValues | Sort-Object)
            ($valores -join ',') | Should -Be (($script:ordenes | Sort-Object) -join ',') `
                -Because "$nombre no puede aceptar un orden que la lista no conoce"
        }
    }

    It 'el archivo del nucleo no usa -like para los comodines' {
        # Sin comentarios: primero los bloques <# #> y después las líneas
        # '#' (al revés, el primer paso se lleva la línea del #>).
        $texto = [IO.File]::ReadAllText($script:archivoFuente)
        $codigo = [regex]::Replace($texto, '(?s)<#.*?#>', '')
        $codigo = [regex]::Replace($codigo, '(?m)^\s*#.*$', '')

        # Si el recorte se comiera el archivo, la prueba pasaría sin mirar.
        $codigo | Should -Match 'function Test-CoincideComodin'
        $codigo | Should -Match 'regex\]::Escape'
        $codigo | Should -Not -Match '\-like'
    }
}
