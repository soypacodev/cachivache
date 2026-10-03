<#
    Pruebas de la compresión NTFS.

    Un archivo comprimido por NTFS mide una cosa al leerlo y ocupa otra en
    disco; sin tenerlo en cuenta se promete liberar más espacio del real.

    La decisión (cuánto se promete) es aritmética pura y se prueba entera
    sin NTFS. De la medición real (kernel32) se comprueba lo que vale en
    cualquier sistema: que nunca lanza y que, si no sabe, devuelve $null y
    no cero.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')


    # Valores definidos por Windows, repetidos aquí a propósito para
    # detectar un cambio accidental en la constante del núcleo.
    $script:COMPRESSED   = 0x800
    $script:ARCHIVE      = 0x20
    $script:READONLY     = 0x1
    $script:HIDDEN       = 0x2
    $script:OFFLINE      = 0x1000
    $script:RECALL_DATA  = 0x400000

    # Criterio de aceptación, en bytes.
    $script:CIEN_MB      = 100MB
    $script:TREINTA_MB   = 30MB

    $script:EsWindows = ($IsWindows -or ($null -eq $IsWindows))
}

Describe 'Test-EstaComprimido' {

    It 'un archivo normal no lo esta' {
        Test-EstaComprimido -Atributos $script:ARCHIVE | Should -BeFalse
    }

    It 'reconoce la marca de NTFS' {
        Test-EstaComprimido -Atributos $script:COMPRESSED | Should -BeTrue
    }

    It 'con varios atributos a la vez sigue viendo el bit' {
        # Un archivo comprimido real llega con Archive y a menudo otros
        # atributos: hay que comprobar el bit, no la igualdad.
        $todos = $script:ARCHIVE -bor $script:READONLY -bor $script:HIDDEN -bor $script:COMPRESSED
        Test-EstaComprimido -Atributos $todos | Should -BeTrue
    }

    It 'no confunde la compresion con los atributos de la nube' {
        # Un falso positivo prometería de menos sobre archivos no
        # comprimidos y taparía el aviso de archivos en la nube.
        $nube = $script:ARCHIVE -bor $script:OFFLINE -bor $script:RECALL_DATA -bor $script:READONLY
        Test-EstaComprimido -Atributos $nube | Should -BeFalse
    }

    It 'cero no esta comprimido' {
        Test-EstaComprimido -Atributos 0 | Should -BeFalse
    }

    It 'un valor negativo no revienta y contesta por el bit' {
        # Attributes es un entero con signo: una máscara con el bit alto
        # llega negativa, y -1 significa "todos los bits".
        { Test-EstaComprimido -Atributos -1 }    | Should -Not -Throw
        Test-EstaComprimido -Atributos -1        | Should -BeTrue
        # -2049 es el complemento de 0x800: todos los bits menos ese.
        Test-EstaComprimido -Atributos -2049     | Should -BeFalse
    }

    It 'un nulo no revienta y responde que no' {
        # Un atributo ilegible llega como nulo. Responder que no es lo
        # seguro: como mucho, se promete de menos.
        { Test-EstaComprimido -Atributos $null } | Should -Not -Throw
        Test-EstaComprimido -Atributos $null     | Should -BeFalse
    }
}

Describe 'Get-TamanoEnDisco' {

    BeforeAll {
        $script:Zona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-compresion-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Zona -Force | Out-Null
        $script:Archivo = Join-Path $script:Zona 'datos.bin'
        [IO.File]::WriteAllBytes($script:Archivo, (New-Object byte[] 8192))
        $script:NoExiste = Join-Path $script:Zona 'no-existe.bin'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Zona -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'no lanza con nada de lo que le puede llegar' {
        # Se llama una vez por archivo en recorridos de cientos de miles:
        # una excepción tumbaría el análisis entero.
        { Get-TamanoEnDisco -Ruta $null }               | Should -Not -Throw
        { Get-TamanoEnDisco -Ruta '' }                  | Should -Not -Throw
        { Get-TamanoEnDisco -Ruta '   ' }               | Should -Not -Throw
        { Get-TamanoEnDisco -Ruta $script:NoExiste }    | Should -Not -Throw
        { Get-TamanoEnDisco -Ruta $script:Archivo }     | Should -Not -Throw
        { Get-TamanoEnDisco -Ruta 'docker system prune' } | Should -Not -Throw
    }

    It 'una ruta vacia o nula es "no lo se", que se dice $null' {
        ($null -eq (Get-TamanoEnDisco -Ruta $null)) | Should -BeTrue
        ($null -eq (Get-TamanoEnDisco -Ruta ''))    | Should -BeTrue
    }

    It 'lo que no se sabe se dice $null, nunca cero' {
        # Cero significa "no libera nada": si la medición falla debe
        # devolver $null para que Get-EspacioRecuperable use el tamaño
        # lógico.
        $r = Get-TamanoEnDisco -Ruta $script:NoExiste
        ($null -eq $r) | Should -BeTrue -Because 'un archivo que no esta no ocupa "cero", es que no se sabe'
        ($r -eq 0)     | Should -BeFalse
    }

    It 'mide de verdad donde hay API, y contesta $null donde no la hay' {
        # La suite corre en Linux y en Windows: la prueba se ramifica.
        $r = Get-TamanoEnDisco -Ruta $script:Archivo
        if ($script:EsWindows) {
            ($null -eq $r) | Should -BeFalse -Because 'en Windows GetCompressedFileSize contesta'
            $r | Should -BeGreaterOrEqual 0
        } else {
            ($null -eq $r) | Should -BeTrue -Because 'fuera de Windows no hay NTFS que preguntar'
        }
    }

    It 'preguntarlo NO abre el archivo' {
        # Medir no debe provocar la descarga de un archivo en la nube. Se
        # abre en exclusiva: si la función intentara abrirlo, fallaría.
        $flujo = [IO.File]::Open($script:Archivo, [IO.FileMode]::Open,
                                 [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            { Get-TamanoEnDisco -Ruta $script:Archivo } | Should -Not -Throw
        } finally {
            $flujo.Dispose()
        }
    }
}

Describe 'Get-EspacioRecuperable' {

    It 'criterio de aceptacion: 100 MB que ocupan 30 MB se prometen como 30' {
        Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB |
            Should -Be $script:TREINTA_MB
        Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB |
            Should -Not -Be $script:CIEN_MB
    }

    It 'un archivo sin comprimir promete lo mismo que antes' {
        # El caso normal: lógico y disco coinciden.
        Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:CIEN_MB |
            Should -Be $script:CIEN_MB
    }

    It 'cuando no se sabe lo que ocupa, se promete el tamaño logico' {
        # Sin medición se mantiene el comportamiento basado en el tamaño
        # lógico.
        Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco $null |
            Should -Be $script:CIEN_MB
    }

    It '"no lo se" y "cero" no son lo mismo' {
        # Tratar $null como 0 dejaría de prometer espacio al fallar la
        # medición; tratar 0 como $null prometería espacio inexistente.
        $sinSaber = Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco $null
        $enCero   = Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco 0
        $sinSaber | Should -Be $script:CIEN_MB
        $enCero   | Should -Be 0
        $sinSaber | Should -Not -Be $enCero
    }

    It 'con todo a cero promete cero' {
        Get-EspacioRecuperable -TamanoLogico 0 -TamanoEnDisco 0 | Should -Be 0
    }

    It 'los numeros negativos no producen promesas negativas' {
        # Un tamaño negativo es un dato roto: se trata como cero.
        Get-EspacioRecuperable -TamanoLogico -5 -TamanoEnDisco -5   | Should -Be 0
        Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco -5 | Should -Be 0
        Get-EspacioRecuperable -TamanoLogico -5 -TamanoEnDisco $null | Should -Be 0
    }

    It 'ni los nulos ni la basura revientan' {
        { Get-EspacioRecuperable -TamanoLogico $null -TamanoEnDisco $null } | Should -Not -Throw
        Get-EspacioRecuperable -TamanoLogico $null -TamanoEnDisco $null     | Should -Be 0
        { Get-EspacioRecuperable -TamanoLogico 'hola' -TamanoEnDisco @(1, 2) } | Should -Not -Throw
        Get-EspacioRecuperable -TamanoLogico $script:CIEN_MB -TamanoEnDisco 'hola' | Should -Be 0
    }

    It 'INVARIANTE: si se sabe lo que ocupa, nunca se promete mas que eso' {
        # La promesa nunca puede superar el espacio que ocupa en disco.
        $logicos = @(0, 1, 4096, 1MB, 100MB, 3GB, 12345678)
        $discos  = @(0, 1, 4096, 512KB, 30MB, 100MB, 3GB)

        $revisados = 0
        foreach ($logico in $logicos) {
            foreach ($disco in $discos) {
                $prometido = Get-EspacioRecuperable -TamanoLogico $logico -TamanoEnDisco $disco
                $prometido | Should -BeLessOrEqual $disco -Because (
                    ('con {0} logicos que ocupan {1} se prometio {2}' -f $logico, $disco, $prometido))
                $prometido | Should -BeGreaterOrEqual 0
                $revisados++
            }
        }
        # Comprueba que el bucle se ha recorrido entero.
        $revisados | Should -Be ($logicos.Count * $discos.Count)
    }
}

Describe 'Format-DetalleCompresion' {

    It 'criterio de aceptacion: se enseñan LAS DOS cifras' {
        # Mostrar solo la cifra pequeña dejaría sin explicar por qué una
        # carpeta de 100 MB libera 30.
        $texto = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB
        $texto | Should -BeLike ('*' + (Format-Tamano -Bytes $script:CIEN_MB) + '*')
        $texto | Should -BeLike ('*' + (Format-Tamano -Bytes $script:TREINTA_MB) + '*')
    }

    It 'y lo que promete liberar es 30, no 100' {
        $texto = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB
        $texto | Should -Match ('liberan\s+' + [regex]::Escape((Format-Tamano -Bytes $script:TREINTA_MB)))
        $texto | Should -Not -Match ('liberan\s+' + [regex]::Escape((Format-Tamano -Bytes $script:CIEN_MB)))
    }

    It 'INVARIANTE: la cifra del texto es la que decide Get-EspacioRecuperable' {
        # El texto y el motor no pueden dar cifras distintas.
        $casos = @(
            @{ Logico = 100MB; Disco = 30MB }
            @{ Logico = 4GB;   Disco = 1GB }
            @{ Logico = 8192;  Disco = 4096 }
        )
        foreach ($caso in $casos) {
            $texto     = Format-DetalleCompresion -TamanoLogico $caso.Logico -TamanoEnDisco $caso.Disco
            $prometido = Format-Tamano -Bytes (Get-EspacioRecuperable -TamanoLogico $caso.Logico -TamanoEnDisco $caso.Disco)
            $texto | Should -Match ('liberan\s+' + [regex]::Escape($prometido))
        }
        $casos.Count | Should -Be 3
    }

    It 'cuando no se sabe lo que ocupa en disco, se dice' {
        # Una cifra sin aviso se lee como una medición.
        $texto = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $null
        $texto | Should -BeLike ('*' + (Format-Tamano -Bytes $script:CIEN_MB) + '*')
        $texto | Should -Match 'disco'
        $texto | Should -Not -Match 'liberan'
    }

    It 'un archivo comprimido que no gana nada no dice "se liberan X, no X"' {
        # Ocurre con lo que ya venía comprimido (vídeo, .zip) y con
        # archivos diminutos, que ocupan un clúster entero.
        $texto = Format-DetalleCompresion -TamanoLogico 1KB -TamanoEnDisco 4KB
        $texto | Should -Not -Match 'liberan'
        $texto | Should -BeLike ('*' + (Format-Tamano -Bytes 4KB) + '*')
    }

    It 'nunca dice "1 elementos"' {
        # El número es casi siempre 1, así que el error sería visible.
        $uno    = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB -Archivos 1
        $varios = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB -Archivos 4

        $uno    | Should -BeLike '*1 archivo comprimido*'
        $uno    | Should -Not -BeLike '*1 archivos*'
        $varios | Should -BeLike '*4 archivos comprimidos*'
        $varios | Should -Not -BeLike '*4 archivo comprimidos*'
    }

    It 'sin contador habla de uno solo, sin inventarse un numero' {
        $texto = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB
        $texto | Should -BeLike 'Comprimido con NTFS*'
        $texto | Should -Not -Match '^\d'
    }

    It 'el texto de cara al usuario lleva tildes y eñes' {
        $conocido    = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB
        $desconocido = Format-DetalleCompresion -TamanoLogico $script:CIEN_MB -TamanoEnDisco $null

        $conocido    | Should -Match 'tamaño'
        $desconocido | Should -Match 'cuánto'
        $desconocido | Should -Match 'así'
    }

    It 'ni los nulos ni la basura revientan' {
        { Format-DetalleCompresion -TamanoLogico $null -TamanoEnDisco $null }     | Should -Not -Throw
        { Format-DetalleCompresion -TamanoLogico 'hola' -TamanoEnDisco 'adios' }  | Should -Not -Throw
        { Format-DetalleCompresion -TamanoLogico -1 -TamanoEnDisco -1 }           | Should -Not -Throw
        Format-DetalleCompresion -TamanoLogico $null -TamanoEnDisco $null | Should -Not -BeNullOrEmpty
    }
}

Describe 'el candidato lleva el tamaño en disco, y es ANULABLE' {

    <#
        Integración en New-Candidato. Las dos ramas se ejercitan pasando el
        tamaño a mano y no con Get-TamanoEnDisco: fuera de Windows la
        medición real siempre devuelve $null y la rama "conocido" nunca se
        ejecutaría.
    #>

    It 'criterio de aceptacion: 100 MB que ocupan 30 se proponen como 30' {
        $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' `
                           -Ruta 'C:\zona\comprimida\archivo.bak' `
                           -Bytes $script:CIEN_MB -TamanoEnDisco $script:TREINTA_MB

        $c.Bytes         | Should -Be $script:TREINTA_MB
        $c.Bytes         | Should -Not -Be $script:CIEN_MB
        $c.TamanoEnDisco | Should -Be $script:TREINTA_MB
    }

    It 'sin decir nada, el candidato promete lo mismo que ha prometido siempre' {
        # Ningún módulo pasa -TamanoEnDisco en el caso normal.
        $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' `
                           -Ruta 'C:\zona\normal\archivo.tmp' -Bytes $script:CIEN_MB

        $c.Bytes | Should -Be $script:CIEN_MB
    }

    It 'el campo nace a $null, NUNCA a cero' {
        # Con 0 por defecto, Get-EspacioRecuperable prometería cero para
        # todo candidato.
        $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\zona\normal\archivo.tmp' -Bytes 1MB

        ($null -eq $c.TamanoEnDisco) | Should -BeTrue -Because 'no preguntarlo es "no lo se", no "no ocupa nada"'
        ($c.TamanoEnDisco -eq 0)     | Should -BeFalse
        $c.Bytes                     | Should -Be 1MB
    }

    It 'un cero explicito SI es cero, y no se confunde con no saberlo' {
        # Un archivo que de verdad no ocupa nada (disperso o vacío) no
        # promete su tamaño lógico.
        $sinSaber = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\z\a' -Bytes $script:CIEN_MB
        $enCero   = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\z\a' `
                                  -Bytes $script:CIEN_MB -TamanoEnDisco 0

        $sinSaber.Bytes | Should -Be $script:CIEN_MB
        $enCero.Bytes   | Should -Be 0
    }

    It 'el campo del contrato existe siempre, se pase o no' {
        # En PowerShell leer una propiedad inexistente no lanza: devolvería
        # un $null indistinguible de una medición fallida.
        foreach ($c in @(
            (New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\z\a' -Bytes 1MB),
            (New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\z\a' -Bytes 1MB -TamanoEnDisco 4KB)
        )) {
            $c.PSObject.Properties['TamanoEnDisco'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'ni un nulo ni la basura revientan al construir el candidato' {
        # Requiere [AllowNull()] en los parámetros que admiten nulo.
        { New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\z\a' `
                        -Bytes 1MB -TamanoEnDisco $null } | Should -Not -Throw
        { New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\z\a' `
                        -Bytes 1MB -TamanoEnDisco 'hola' } | Should -Not -Throw
    }

    It 'INVARIANTE: teniendo el tamaño en disco, el candidato NUNCA promete el logico' {
        # Teniendo el tamaño en disco, nunca se promete el lógico. Se
        # compara contra Get-EspacioRecuperable y no contra una tabla
        # propia, para no mantener una segunda copia de la regla.
        $logicos = @(0, 1, 4096, 1MB, 100MB, 3GB, 12345678)
        $discos  = @(0, 1, 4096, 512KB, 30MB, 100MB, 3GB)

        $revisados = 0
        foreach ($logico in $logicos) {
            foreach ($disco in $discos) {
                $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\zona\comprimida\archivo.bak' `
                                   -Bytes $logico -TamanoEnDisco $disco

                $c.Bytes | Should -Be (Get-EspacioRecuperable -TamanoLogico $logico -TamanoEnDisco $disco) `
                    -Because ('el candidato tiene que prometer lo que decide Get-EspacioRecuperable, no una copia de la regla')
                $c.Bytes | Should -BeLessOrEqual $disco -Because (
                    ('con {0} logicos que ocupan {1} el candidato prometio {2}' -f $logico, $disco, $c.Bytes))

                # Si el disco tiene menos, el lógico no puede aparecer.
                if ($disco -lt $logico) { $c.Bytes | Should -Not -Be $logico }
                $revisados++
            }
        }
        # Comprueba que el bucle se ha recorrido entero.
        $revisados | Should -Be ($logicos.Count * $discos.Count)
    }

    It 'INVARIANTE: New-Candidato no calcula la promesa por su cuenta' {
        # Complementa la anterior: una copia literal de la regla dentro de
        # New-Candidato daría los mismos números. Debe haber un único sitio
        # que decida cuánto se promete.
        $ruta  = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Candidate.ps1'
        $texto = [IO.File]::ReadAllText($ruta)

        # Primero los bloques <# #> y después las líneas '#': al revés, el
        # primer paso se lleva la línea del #> y el bloque queda abierto.
        $sinBloques = [regex]::Replace($texto, '(?s)<#.*?#>', '')
        $codigo = @(($sinBloques -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        # Si el recorte eliminara la función, lo siguiente pasaría sin
        # encontrar nada.
        $codigo | Should -Match 'function New-Candidato'
        $codigo | Should -Match 'TamanoEnDisco'

        $codigo | Should -Match 'Bytes\s*=\s*Get-EspacioRecuperable -TamanoLogico \$Bytes -TamanoEnDisco \$TamanoEnDisco' `
            -Because 'quien decide cuanto se promete es Get-EspacioRecuperable, y el candidato tiene que pasar por ahi'
        $codigo | Should -Not -Match 'Bytes\s*=\s*\[double\]\$Bytes' `
            -Because 'con el tamaño en disco disponible, prometer el tamaño lógico exagera lo que se libera'
    }
}

Describe 'el recorrido compartido lee el atributo, y solo pregunta cuando toca' {

    <#
        El recorrido compartido ya recibe los atributos sin coste (vienen
        de WIN32_FIND_DATA). Mirar el bit de compresión es gratis; medir el
        tamaño en disco cuesta una llamada por archivo, así que solo se hace
        con lo que ya dice estar comprimido.

        Sin NTFS ningún archivo lleva la marca: se comprueba que la
        propiedad existe siempre, que sin pedirlo vale $null y, por texto,
        el orden de la condición.
    #>

    BeforeAll {
        $script:Zona08 = Join-Path ([IO.Path]::GetTempPath()) ('vis05-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Zona08 -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Zona08 'suelto.tmp'), 'aaa')
        New-Item -ItemType Directory -Path (Join-Path $script:Zona08 'sub') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Zona08 'sub/dentro.tmp'), 'bbbb')

        $script:RutaFs = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'FileSystem.ps1'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Zona08 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'todo lo que sale del recorrido trae la propiedad, archivos y carpetas' {
        $elementos = @(Get-ElementosDelArbol -Ruta $script:Zona08 -Que Todo)
        $elementos.Count | Should -BeGreaterThan 2

        foreach ($elemento in $elementos) {
            $elemento.PSObject.Properties['TamanoEnDisco'] | Should -Not -BeNullOrEmpty `
                -Because "a '$($elemento.Name)' le falta el campo"
        }
    }

    It 'sin pedirlo vale $null: no se paga y no se afirma nada' {
        foreach ($elemento in @(Get-ElementosDelArbol -Ruta $script:Zona08 -Que Todo)) {
            ($null -eq $elemento.TamanoEnDisco) | Should -BeTrue -Because (
                'sin -MedirEnDisco no se pregunta al sistema, y no preguntar es "no lo se"')
        }
    }

    It 'pedirlo no cambia lo que se encuentra ni revienta' {
        # Fuera de Windows Get-TamanoEnDisco siempre devuelve $null: se
        # comprueba que la rama no altera el recorrido.
        $sin = @(Get-ElementosDelArbol -Ruta $script:Zona08 | ForEach-Object { $_.FullName }) | Sort-Object
        $con = @(Get-ElementosDelArbol -Ruta $script:Zona08 -MedirEnDisco | ForEach-Object { $_.FullName }) | Sort-Object

        @($sin).Count      | Should -BeGreaterThan 1
        ($con -join '|')   | Should -Be ($sin -join '|')
    }

    It 'INVARIANTE: se pregunta por el bit ANTES de preguntarle al sistema' {
        # El orden determina el rendimiento: al revés se pagaría una
        # llamada al sistema por cada archivo del disco, sin fallo visible.
        $texto = [IO.File]::ReadAllText($script:RutaFs)
        $desde = $texto.IndexOf('function Get-ElementosDelArbol')
        $hasta = $texto.IndexOf('function Measure-Ruta')
        $desde | Should -BeGreaterThan 0
        $hasta | Should -BeGreaterThan $desde

        $sinBloques = [regex]::Replace($texto.Substring($desde, $hasta - $desde), '(?s)<#.*?#>', '')
        $cuerpo = @(($sinBloques -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        $cuerpo | Should -Match '\$MedirEnDisco -and \(Test-EstaComprimido' -Because (
            'primero el bit, que es gratis; la llamada al sistema solo para lo que ya dice estar comprimido')
        $cuerpo | Should -Match 'Get-TamanoEnDisco -Ruta'
    }
}
