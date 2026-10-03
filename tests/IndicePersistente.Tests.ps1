<#
    Pruebas de la persistencia del índice en disco.

      1. La ida y vuelta no pierde nada, incluidos los totales por carpeta:
         se guardan tres tablas porque volver a sumar las carpetas desde un
         millón de archivos cuesta más que recorrer el disco.
      2. Nada lanza ante un archivo inservible (truncado, alterado, de otra
         versión, vacío, basura o inexistente): se devuelve $null y quien
         llama recorre el disco de nuevo.
      3. La escritura es atómica: un corte a mitad no deja un archivo que
         se lea como bueno.
      4. Se registra cuánto tarda guardar y cargar 10.000 entradas.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    $script:Nucleo = Join-Path (Join-Path $script:Raiz 'src') 'Core'
    . (Join-Path $script:Nucleo 'Bootstrap.ps1')

    # Bootstrap.ps1 ya carga IndicePersistente.ps1; no se vuelve a cargar para
    # probarlo tal como lo carga el programa. La ruta es para las invariantes de texto.
    $script:RutaPersistente = Join-Path $script:Nucleo 'IndicePersistente.ps1'

    $script:Zona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-idxdisco-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Zona -Force | Out-Null

    function New-ArbolDeIndice {
        <#
        .SYNOPSIS
            Árbol pequeño con proporciones conocidas, para guardar un índice real.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo crea un arbol de prueba en una ruta temporal propia.')]
        [CmdletBinding()]
        param([Parameter(Mandatory)] [string] $Raiz)

        foreach ($c in @('grande/dentro', 'mediana', 'pequena')) {
            New-Item -ItemType Directory -Path (Join-Path $Raiz $c) -Force | Out-Null
        }
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'grande/dentro/a.bin'), [byte[]]::new(8000000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'grande/suelto.bin'),   [byte[]]::new(2000000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'mediana/b.bin'),       [byte[]]::new(4000000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'pequena/c.bin'),       [byte[]]::new(1500000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'pequena/menudo.bin'),  [byte[]]::new(1000))
    }

    function New-IndiceSintetico {
        <#
        .SYNOPSIS
            Índice con la misma forma que devuelve New-IndiceDisco, del tamaño
            pedido, para medir sin tocar el disco.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo compone un objeto en memoria.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [int] $Archivos,
            [Parameter(Mandatory)] [int] $Carpetas
        )

        $tablaCarpetas = [Collections.Generic.Dictionary[string, object]]::new(
                             [StringComparer]::OrdinalIgnoreCase)
        for ($i = 0; $i -lt $Carpetas; $i++) {
            # [int]($i / 20) redondea, no trunca: dejaría archivos en carpetas inexistentes.
            $ruta = 'C:\Sintetico\c{0}' -f $i
            $tablaCarpetas[$ruta] = [pscustomobject]@{
                Ruta     = $ruta
                Nombre   = 'c{0}' -f $i
                Nivel    = 1
                Bytes    = [double](1000 * ($i + 1))
                Propios  = [double](500 * ($i + 1))
                Archivos = $i
                Ultimo   = [datetime]'2026-09-01T10:00:00'
            }
        }

        $lista = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $Archivos; $i++) {
            $carpeta = 'C:\Sintetico\c{0}' -f ($i % [Math]::Max(1, $Carpetas))
            # Las cadenas se arman antes: dentro de .Add(...) la coma del -f se
            # interpreta como separador de argumentos del método.
            $nombre = 'archivo{0}.bin' -f $i
            $ruta = '{0}\{1}' -f $carpeta, $nombre
            $lista.Add([pscustomobject]@{
                Ruta      = $ruta
                Nombre    = $nombre
                Carpeta   = $carpeta
                Extension = '.bin'
                Bytes     = [double](1024 * $i)
                Ultimo    = [datetime]'2026-08-31T23:59:59'
            })
        }

        return [pscustomobject]@{
            Carpetas      = $tablaCarpetas
            Archivos      = $lista.ToArray()
            Raices        = @('C:\Sintetico')
            Bytes         = 123456789.0
            TotalArchivos = $Archivos
            Compartidos   = 3
            Inaccesibles  = 7
            UmbralArchivo = 1048576.0
        }
    }
}

Describe 'Get-SumaCuerpoIndice' {

    It 'la misma secuencia de bytes da siempre la misma suma' {
        $a = [byte[]] @(1, 2, 3, 4, 5)
        $b = [byte[]] @(1, 2, 3, 4, 5)
        (Get-SumaCuerpoIndice -Bytes $a) | Should -Be (Get-SumaCuerpoIndice -Bytes $b)
    }

    It 'un solo byte distinto cambia la suma' {
        $a = [byte[]] @(1, 2, 3, 4, 5)
        $b = [byte[]] @(1, 2, 3, 4, 6)
        (Get-SumaCuerpoIndice -Bytes $a) | Should -Not -Be (Get-SumaCuerpoIndice -Bytes $b)
    }

    It 'un cuerpo truncado no da la misma suma que el entero' {
        $entero = [byte[]] @(9, 8, 7, 6, 5, 4)
        $medio  = [byte[]] @(9, 8, 7)
        (Get-SumaCuerpoIndice -Bytes $entero) | Should -Not -Be (Get-SumaCuerpoIndice -Bytes $medio)
    }

    It 'un cuerpo nulo no lanza y vale lo mismo que uno vacio' {
        { Get-SumaCuerpoIndice -Bytes $null } | Should -Not -Throw
        $vacio = Get-SumaCuerpoIndice -Bytes ([byte[]]::new(0))
        (Get-SumaCuerpoIndice -Bytes $null) | Should -Be $vacio
    }

    It 'la suma es hexadecimal en minusculas y siempre de la misma longitud' {
        $suma = Get-SumaCuerpoIndice -Bytes ([byte[]] @(1, 2, 3))
        $suma | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'Ida y vuelta con un indice de verdad' {

    BeforeAll {
        $script:ZonaArbol = Join-Path $script:Zona 'arbol'
        New-Item -ItemType Directory -Path $script:ZonaArbol -Force | Out-Null
        New-ArbolDeIndice -Raiz $script:ZonaArbol

        $script:Original = New-IndiceDisco -Rutas @($script:ZonaArbol) -MinimoArchivoBytes 1MB

        $script:Refs = [Collections.Generic.Dictionary[uint64, string]]::new()
        $script:Refs[[uint64]5] = $script:ZonaArbol
        $script:Refs[[uint64]1152921504606846976] = (Join-Path $script:ZonaArbol 'grande')

        $script:Escrito = [datetime]'2026-09-01T08:30:15'
        $script:RutaIndice = Join-Path $script:Zona 'indice.cachidx'
        $script:Guardado = Save-IndiceDisco -Indice $script:Original -Ruta $script:RutaIndice `
                             -SerieVolumen 'AABB-1234' -IdDiario '18446744073709551615' `
                             -UsnCorte 987654321 -Referencias $script:Refs -Escrito $script:Escrito

        $script:Leido = Read-IndiceDisco -Ruta $script:RutaIndice
        $script:Cabecera = Get-CabeceraIndice -Ruta $script:RutaIndice
    }

    It 'la prueba parte de un indice con contenido: si no, no comprueba nada' {
        $script:Guardado | Should -BeTrue
        @($script:Original.Carpetas.Values).Count | Should -BeGreaterThan 3
        @($script:Original.Archivos).Count | Should -BeGreaterThan 2
    }

    It 'se ha escrito el archivo y no ha quedado ningun temporal en medio' {
        Test-Path -LiteralPath $script:RutaIndice | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Zona -Filter '*.tmp').Count | Should -Be 0
    }

    It 'la cabecera trae los siete campos acordados, ni uno mas ni uno menos' {
        # Los nombres son un contrato con quien valida la cabecera.
        $campos = @($script:Cabecera.PSObject.Properties.Name) -join ','
        $campos | Should -Be 'Version,SerieVolumen,IdDiario,UsnCorte,Entradas,Suma,Escrito'
    }

    It 'la cabecera dice lo que se le paso al guardar' {
        $script:Cabecera.Version      | Should -Be 1
        $script:Cabecera.SerieVolumen | Should -Be 'AABB-1234'
        $script:Cabecera.IdDiario     | Should -Be '18446744073709551615'
        $script:Cabecera.UsnCorte     | Should -Be 987654321
        $script:Cabecera.Entradas     | Should -Be @($script:Original.Archivos).Count
        $script:Cabecera.Escrito      | Should -Be $script:Escrito
        $script:Cabecera.Suma         | Should -Match '^[0-9a-f]{64}$'
    }

    It 'la cabecera se lee sin cargar el cuerpo, y coincide con la del indice leido' {
        $script:Leido.Cabecera.Suma | Should -Be $script:Cabecera.Suma
    }

    It 'Read-CabeceraIndiceFlujo deja el flujo justo al principio del cuerpo' {
        # Lo comparten la lectura de solo cabecera y la completa; un byte de
        # desfase haría que la suma del cuerpo no cuadrara nunca.
        $flujo = [IO.File]::Open($script:RutaIndice, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                 [IO.FileShare]::ReadWrite)
        $lector = [IO.BinaryReader]::new($flujo, [Text.UTF8Encoding]::new($false))
        try {
            $cab = Read-CabeceraIndiceFlujo -Lector $lector
            $cab | Should -Not -BeNullOrEmpty
            $cab.Suma | Should -Be $script:Cabecera.Suma

            # Se retrocede sobre los ocho bytes de longitud del cuerpo: la suma los cubre.
            $flujo.Position | Should -BeGreaterThan 8
            $flujo.Position = $flujo.Position - 8
            $cuerpo = $lector.ReadBytes([int]($flujo.Length - $flujo.Position))
            (Get-SumaCuerpoIndice -Bytes $cuerpo) | Should -Be $script:Cabecera.Suma
        } finally {
            $lector.Dispose()
            $flujo.Dispose()
        }
    }

    It 'los totales generales sobreviven a la ida y vuelta' {
        $script:Leido.Bytes         | Should -Be $script:Original.Bytes
        $script:Leido.TotalArchivos | Should -Be $script:Original.TotalArchivos
        $script:Leido.Compartidos   | Should -Be $script:Original.Compartidos
        $script:Leido.Inaccesibles  | Should -Be $script:Original.Inaccesibles
        $script:Leido.UmbralArchivo | Should -Be $script:Original.UmbralArchivo
        (@($script:Leido.Raices) -join '|') | Should -Be (@($script:Original.Raices) -join '|')
    }

    It 'los totales POR CARPETA sobreviven, campo a campo' {
        # Sin esta tabla habría que volver a sumar todos los archivos al cargar.
        @($script:Leido.Carpetas.Keys).Count | Should -Be @($script:Original.Carpetas.Keys).Count
        $revisadas = 0
        foreach ($c in $script:Original.Carpetas.Values) {
            $script:Leido.Carpetas.ContainsKey($c.Ruta) | Should -BeTrue
            $v = $script:Leido.Carpetas[$c.Ruta]
            $v.Nombre   | Should -Be $c.Nombre
            $v.Nivel    | Should -Be $c.Nivel
            $v.Bytes    | Should -Be $c.Bytes
            $v.Propios  | Should -Be $c.Propios
            $v.Archivos | Should -Be $c.Archivos
            $v.Ultimo   | Should -Be $c.Ultimo
            $revisadas++
        }
        $revisadas | Should -BeGreaterThan 3 -Because 'sin carpetas esto no comprueba nada'
    }

    It 'la lista de archivos sobrevive entera, campo a campo y en el mismo orden' {
        $originales = @($script:Original.Archivos)
        $leidos = @($script:Leido.Archivos)
        $leidos.Count | Should -Be $originales.Count
        for ($i = 0; $i -lt $originales.Count; $i++) {
            $leidos[$i].Ruta      | Should -Be $originales[$i].Ruta
            $leidos[$i].Nombre    | Should -Be $originales[$i].Nombre
            $leidos[$i].Carpeta   | Should -Be $originales[$i].Carpeta
            $leidos[$i].Extension | Should -Be $originales[$i].Extension
            $leidos[$i].Bytes     | Should -Be $originales[$i].Bytes
            $leidos[$i].Ultimo    | Should -Be $originales[$i].Ultimo
        }
    }

    It 'la tabla de referencia de carpeta a ruta sobrevive, incluidos los numeros grandes' {
        # Las referencias de NTFS son de 64 bits sin signo; con signo saldrían negativas.
        @($script:Leido.Referencias.Keys).Count | Should -Be 2
        $script:Leido.Referencias[[uint64]5] | Should -Be $script:ZonaArbol
        $script:Leido.Referencias[[uint64]1152921504606846976] |
            Should -Be (Join-Path $script:ZonaArbol 'grande')
    }

    It 'lo leido se puede volver a guardar y a leer sin perder nada' {
        $segunda = Join-Path $script:Zona 'indice-2.cachidx'
        (Save-IndiceDisco -Indice $script:Leido -Ruta $segunda -Escrito $script:Escrito) |
            Should -BeTrue
        $otra = Read-IndiceDisco -Ruta $segunda
        $otra | Should -Not -BeNullOrEmpty
        $otra.Bytes | Should -Be $script:Original.Bytes
        @($otra.Archivos).Count | Should -Be @($script:Original.Archivos).Count
        @($otra.Carpetas.Keys).Count | Should -Be @($script:Original.Carpetas.Keys).Count
    }

    It 'las entradas se leen a DICCIONARIO y no a pscustomobject' {
        # Leer un millón de entradas como pscustomobject es unas doce veces más lento.
        @($script:Leido.Archivos).Count | Should -BeGreaterThan 0
        $script:Leido.Archivos[0] -is [Collections.IDictionary] | Should -BeTrue
        @($script:Leido.Carpetas.Values)[0] -is [Collections.IDictionary] | Should -BeTrue
    }

    It 'una entrada leida se deja usar igual que la que produce el recorrido' {
        # Se accede por propiedad, se ordena y se filtra igual.
        #
        # Límite: en PowerShell 5.1, "Sort-Object Bytes" sobre diccionarios no
        # ordena ni avisa. Se ordena con una expresión, como Get-VistaArchivos;
        # una invariante más abajo lo exige.
        $porBytes = { [double]$_.Bytes }
        $mayor = @($script:Leido.Archivos | Sort-Object $porBytes -Descending)[0]
        $mayorOriginal = @($script:Original.Archivos | Sort-Object $porBytes -Descending)[0]
        $mayor.Bytes | Should -Be $mayorOriginal.Bytes
        @($script:Leido.Carpetas.Values | Where-Object { $_.Bytes -gt 0 }).Count |
            Should -BeGreaterThan 0
        # Una propiedad inexistente se lee como $null, como en un pscustomobject.
        { $null -eq $script:Leido.Archivos[0].NoExiste } | Should -Not -Throw
    }
}

Describe 'Un indice vacio' {

    BeforeAll {
        $script:Vacio = [pscustomobject]@{
            Carpetas      = [Collections.Generic.Dictionary[string, object]]::new()
            Archivos      = @()
            Raices        = @()
            Bytes         = 0.0
            TotalArchivos = 0
            Compartidos   = 0
            Inaccesibles  = 0
            UmbralArchivo = 1048576.0
        }
        $script:RutaVacio = Join-Path $script:Zona 'vacio.cachidx'
        $script:GuardadoVacio = Save-IndiceDisco -Indice $script:Vacio -Ruta $script:RutaVacio
        $script:LeidoVacio = Read-IndiceDisco -Ruta $script:RutaVacio
    }

    It 'se guarda sin protestar' {
        $script:GuardadoVacio | Should -BeTrue
    }

    It 'se lee, y lo que sale esta vacio pero NO es $null' {
        # Cero entradas es una respuesta válida, distinta de "no se pudo leer" ($null).
        $script:LeidoVacio | Should -Not -BeNullOrEmpty
        @($script:LeidoVacio.Archivos).Count | Should -Be 0
        @($script:LeidoVacio.Carpetas.Keys).Count | Should -Be 0
        @($script:LeidoVacio.Referencias.Keys).Count | Should -Be 0
    }

    It 'su cabecera dice que trae cero entradas' {
        (Get-CabeceraIndice -Ruta $script:RutaVacio).Entradas | Should -Be 0
    }
}

Describe 'Ante la duda, no afirmar: nada lanza y todo devuelve $null' {

    BeforeAll {
        # En BeforeAll y no en el cuerpo del Describe: lo asignado ahí se evalúa
        # en la fase de descubrimiento de Pester y llega vacío a los It.
        $script:Sano = Join-Path $script:Zona 'sano.cachidx'
        $indice = New-IndiceSintetico -Archivos 50 -Carpetas 5
        [void](Save-IndiceDisco -Indice $indice -Ruta $script:Sano -SerieVolumen 'CCDD-5678')
        $bytes = [IO.File]::ReadAllBytes($script:Sano)

        $script:Malos = @{}

        # Truncado a la mitad: la cabecera sobrevive, el cuerpo no.
        $script:Malos['truncado'] = Join-Path $script:Zona 'truncado.cachidx'
        $mitad = [byte[]]::new([int]($bytes.Length / 2))
        [Array]::Copy($bytes, $mitad, $mitad.Length)
        [IO.File]::WriteAllBytes($script:Malos['truncado'], $mitad)

        # Un byte cambiado en el cuerpo: solo lo detecta la suma de comprobación.
        $script:Malos['alterado'] = Join-Path $script:Zona 'alterado.cachidx'
        $tocado = [byte[]]$bytes.Clone()
        $donde = $tocado.Length - 10
        $tocado[$donde] = [byte](($tocado[$donde] + 1) % 256)
        [IO.File]::WriteAllBytes($script:Malos['alterado'], $tocado)

        # Versión futura del formato: los cuatro bytes tras la firma.
        $script:Malos['futuro'] = Join-Path $script:Zona 'futuro.cachidx'
        $futuro = [byte[]]$bytes.Clone()
        $futuro[8] = 99
        [IO.File]::WriteAllBytes($script:Malos['futuro'], $futuro)

        $script:Malos['cero'] = Join-Path $script:Zona 'cero.cachidx'
        [IO.File]::WriteAllBytes($script:Malos['cero'], [byte[]]::new(0))

        $script:Malos['basura'] = Join-Path $script:Zona 'basura.cachidx'
        [IO.File]::WriteAllBytes($script:Malos['basura'],
            [Text.Encoding]::UTF8.GetBytes('esto no es un indice, es un texto cualquiera'))

        # Basura con la firma correcta: no basta con mirar los ocho primeros bytes.
        $script:Malos['firmado'] = Join-Path $script:Zona 'firmado.cachidx'
        $firmado = [byte[]]::new(200)
        [Array]::Copy($bytes, $firmado, 12)
        [IO.File]::WriteAllBytes($script:Malos['firmado'], $firmado)

        # Número de entradas de la cabecera cambiado: la suma solo cubre el
        # cuerpo, así que lo detecta la comparación con lo leído.
        # Desplazamiento: firma (8), versión (4), serie y diario con su
        # longitud int32 delante, y USN de corte (8). El diario está vacío.
        $script:Malos['entradas'] = Join-Path $script:Zona 'entradas.cachidx'
        $mentiroso = [byte[]]$bytes.Clone()
        $donde = 8 + 4 + (4 + ([Text.Encoding]::UTF8.GetBytes('CCDD-5678')).Length) + (4 + 0) + 8
        [Array]::Copy([BitConverter]::GetBytes([int]4242), 0, $mentiroso, $donde, 4)
        [IO.File]::WriteAllBytes($script:Malos['entradas'], $mentiroso)

        # Archivo correcto salvo el primer byte de la firma: es el único caso
        # que falla solo por la comprobación de firma.
        $script:Malos['firma'] = Join-Path $script:Zona 'firma.cachidx'
        $otraFirma = [byte[]]$bytes.Clone()
        $otraFirma[0] = [byte](($otraFirma[0] + 1) % 256)
        [IO.File]::WriteAllBytes($script:Malos['firma'], $otraFirma)

        $script:Malos['inexistente'] = Join-Path $script:Zona 'no-esta-aqui.cachidx'
        $script:Malos['carpeta'] = $script:Zona
    }

    It 'el archivo sano si se lee: si no, estas pruebas no comprobarian nada' {
        (Read-IndiceDisco -Ruta $script:Sano) | Should -Not -BeNullOrEmpty
        (Get-CabeceraIndice -Ruta $script:Sano).SerieVolumen | Should -Be 'CCDD-5678'
    }

    It 'Read-IndiceDisco no lanza y devuelve $null con un archivo <Caso>' -ForEach @(
        @{ Caso = 'truncado' }
        @{ Caso = 'alterado' }
        @{ Caso = 'futuro' }
        @{ Caso = 'cero' }
        @{ Caso = 'basura' }
        @{ Caso = 'firmado' }
        @{ Caso = 'firma' }
        @{ Caso = 'entradas' }
        @{ Caso = 'inexistente' }
        @{ Caso = 'carpeta' }
    ) {
        $ruta = $script:Malos[$Caso]
        $ruta | Should -Not -BeNullOrEmpty -Because 'sin ruta el caso no se estaria probando'
        { Read-IndiceDisco -Ruta $ruta } | Should -Not -Throw
        (Read-IndiceDisco -Ruta $ruta) | Should -BeNullOrEmpty
    }

    It 'Get-CabeceraIndice no lanza y devuelve $null con un archivo <Caso>' -ForEach @(
        @{ Caso = 'truncado' }
        @{ Caso = 'futuro' }
        @{ Caso = 'cero' }
        @{ Caso = 'basura' }
        @{ Caso = 'firmado' }
        @{ Caso = 'firma' }
        @{ Caso = 'inexistente' }
        @{ Caso = 'carpeta' }
    ) {
        # 'alterado' no está: su cabecera es válida y Get-CabeceraIndice no lee
        # el cuerpo. Lo detecta Read-IndiceDisco.
        $ruta = $script:Malos[$Caso]
        $ruta | Should -Not -BeNullOrEmpty -Because 'sin ruta el caso no se estaria probando'
        { Get-CabeceraIndice -Ruta $ruta } | Should -Not -Throw
        (Get-CabeceraIndice -Ruta $ruta) | Should -BeNullOrEmpty
    }

    It 'con las entradas cambiadas la cabecera si se lee: es el cuerpo el que no cuadra' {
        # Control del caso 'entradas': el archivo solo falla por el cuerpo.
        $cab = Get-CabeceraIndice -Ruta $script:Malos['entradas']
        $cab | Should -Not -BeNullOrEmpty
        $cab.Entradas | Should -Be 4242
    }

    It 'un cuerpo alterado deja la cabecera legible, pero el indice no se lee' {
        (Get-CabeceraIndice -Ruta $script:Malos['alterado']) | Should -Not -BeNullOrEmpty
        (Read-IndiceDisco -Ruta $script:Malos['alterado']) | Should -BeNullOrEmpty
    }

    It 'una ruta vacia o nula no lanza' {
        { Read-IndiceDisco -Ruta '' } | Should -Not -Throw
        { Get-CabeceraIndice -Ruta '' } | Should -Not -Throw
        { Read-IndiceDisco -Ruta $null } | Should -Not -Throw
        { Get-CabeceraIndice -Ruta $null } | Should -Not -Throw
        (Read-IndiceDisco -Ruta $null) | Should -BeNullOrEmpty
        (Get-CabeceraIndice -Ruta $null) | Should -BeNullOrEmpty
    }

    It 'guardar en una carpeta que no existe devuelve $false y no lanza' {
        $destino = Join-Path (Join-Path $script:Zona 'no-existe') 'x.cachidx'
        $indice = New-IndiceSintetico -Archivos 3 -Carpetas 2
        { Save-IndiceDisco -Indice $indice -Ruta $destino } | Should -Not -Throw
        (Save-IndiceDisco -Indice $indice -Ruta $destino) | Should -BeFalse
    }

    It 'guardar un indice nulo, o sin ruta, devuelve $false y no lanza' {
        { Save-IndiceDisco -Indice $null -Ruta (Join-Path $script:Zona 'nada.cachidx') } |
            Should -Not -Throw
        (Save-IndiceDisco -Indice $null -Ruta (Join-Path $script:Zona 'nada.cachidx')) |
            Should -BeFalse
        (Save-IndiceDisco -Indice (New-IndiceSintetico -Archivos 1 -Carpetas 1) -Ruta '') |
            Should -BeFalse
    }

    It 'una cadena de la cabecera que declara mas de lo que hay se para en seco' {
        # Read-CadenaIndice lanza y quien llama devuelve $null; evita reservar
        # memoria para una longitud absurda declarada por un archivo corrupto.
        $memoria = [IO.MemoryStream]::new([byte[]] @(0xFF, 0xFF, 0xFF, 0x7F, 1, 2, 3), $false)
        $lector = [IO.BinaryReader]::new($memoria, [Text.UTF8Encoding]::new($false))
        try {
            { Read-CadenaIndice -Lector $lector } | Should -Throw
        } finally {
            $lector.Dispose()
        }
    }

    It 'una cadena escrita por Write-CadenaIndice se lee tal cual, acentos incluidos' {
        # El carácter se construye por código para no depender de la codificación
        # del archivo. Comprueba que una ruta con eñe sobrevive al UTF-8 del formato.
        $conEnye = 'C:\Documentos\A' + [char]0xF1 + 'o ' + [char]0xE9 + 'poca'
        $memoria = [IO.MemoryStream]::new()
        $escritor = [IO.BinaryWriter]::new($memoria, [Text.UTF8Encoding]::new($false))
        Write-CadenaIndice -Escritor $escritor -Texto $conEnye
        Write-CadenaIndice -Escritor $escritor -Texto ''
        $escritor.Flush()
        $lector = [IO.BinaryReader]::new([IO.MemoryStream]::new($memoria.ToArray(), $false),
                                         [Text.UTF8Encoding]::new($false))
        try {
            (Read-CadenaIndice -Lector $lector) | Should -Be $conEnye
            (Read-CadenaIndice -Lector $lector) | Should -Be ''
        } finally {
            $lector.Dispose()
            $escritor.Dispose()
        }
    }
}

Describe 'La escritura tiene que ser atomica' {

    BeforeAll {
        # Se quitan los comentarios antes de buscar, primero los bloques y luego
        # las líneas con #; al revés, se perdería el cierre del bloque.
        $texto = [IO.File]::ReadAllText($script:RutaPersistente)
        $sinBloques = [regex]::Replace($texto, '(?s)<#.*?#>', '')
        $script:Codigo = (($sinBloques -split "`n" |
                           Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
    }

    It 'queda codigo despues de quitar los comentarios: si no, esto no comprueba nada' {
        $script:Codigo | Should -Match 'function Save-IndiceDisco'
        $script:Codigo | Should -Match 'function Read-IndiceDisco'
    }

    It 'se escribe a un temporal y se reemplaza con una sola operacion' {
        # Como Add-EntradaHistorial: un corte a mitad no deja el archivo truncado.
        $script:Codigo | Should -Match ([regex]::Escape('$temporal = "$Ruta.$PID.tmp"'))
        $script:Codigo | Should -Match ([regex]::Escape('[IO.File]::Open($temporal'))
        $script:Codigo | Should -Match 'Move-Item[^\n]*-Destination \$Ruta -Force'
    }

    It 'el archivo de destino no se abre nunca para escribir directamente' {
        $abrirDestino = [regex]::Escape('[IO.File]::Open($Ruta, [IO.FileMode]::Create')
        $script:Codigo | Should -Not -Match $abrirDestino
        $script:Codigo | Should -Not -Match ([regex]::Escape('Set-Content -LiteralPath $Ruta'))
    }

    It 'aqui no se borra nada: dentro del nucleo eso es cosa de Remove.ps1' {
        $script:Codigo | Should -Not -Match 'Remove-Item'
    }

    It 'de aqui no sale nada que se parezca a un candidato' {
        # Decisión de diseño: el índice guardado sirve para el mapa, nunca para
        # decidir qué se borra.
        $script:Codigo | Should -Not -Match 'Candidat'
        $script:Codigo | Should -Not -Match 'New-Candidato'
    }
}

Describe 'Cuanto tarda de verdad' {

    BeforeAll {
        $script:Grande = New-IndiceSintetico -Archivos 10000 -Carpetas 500
        $script:RutaGrande = Join-Path $script:Zona 'diez-mil.cachidx'
        $script:TGuardar = (Measure-Command {
            $script:OkGrande = Save-IndiceDisco -Indice $script:Grande -Ruta $script:RutaGrande
        }).TotalSeconds
        $script:TCargar = (Measure-Command {
            $script:LeidoGrande = Read-IndiceDisco -Ruta $script:RutaGrande
        }).TotalSeconds
        $script:TCabecera = (Measure-Command {
            $script:CabGrande = Get-CabeceraIndice -Ruta $script:RutaGrande
        }).TotalSeconds
    }

    It 'guardar y cargar 10.000 entradas da exactamente lo mismo' {
        $script:OkGrande | Should -BeTrue
        $script:LeidoGrande | Should -Not -BeNullOrEmpty
        @($script:LeidoGrande.Archivos).Count | Should -Be 10000
        @($script:LeidoGrande.Carpetas.Keys).Count | Should -Be 500
        $script:LeidoGrande.Archivos[9999].Bytes | Should -Be $script:Grande.Archivos[9999].Bytes
        $script:LeidoGrande.Archivos[9999].Ruta  | Should -Be $script:Grande.Archivos[9999].Ruta
    }

    It 'y deja constancia de lo que tarda' {
        $tamano = (Get-Item -LiteralPath $script:RutaGrande).Length
        # Los paréntesis son necesarios: -f tiene más precedencia que +.
        $linea = ('    Índice: 10.000 entradas + 500 carpetas: guardar {0:N2} s, ' +
                  'cargar {1:N2} s, solo cabecera {2:N4} s, {3:N0} bytes en disco') -f
                 $script:TGuardar, $script:TCargar, $script:TCabecera, $tamano
        Write-Host $linea

        # Límite holgado (máquinas compartidas): detecta, por ejemplo, una
        # llamada a función por entrada dentro de los bucles.
        $script:TGuardar | Should -BeLessThan 30
        $script:TCargar  | Should -BeLessThan 30
    }

    It 'leer solo la cabecera es MUCHO mas barato que cargar el indice' {
        # Get-CabeceraIndice permite decidir si el índice sirve antes de cargarlo.
        $script:CabGrande | Should -Not -BeNullOrEmpty
        $script:TCabecera | Should -BeLessThan $script:TCargar
    }
}

Describe 'Lo que se lee del indice se ordena con una EXPRESION, nunca por nombre de propiedad' {

    # Read-IndiceDisco devuelve diccionarios por rendimiento. En PowerShell
    # 5.1, "$indice.Archivos | Sort-Object Bytes -Descending" sobre
    # diccionarios no ordena ni avisa (en PowerShell 7 sí). Hay que ordenar
    # con una expresión, p. ej. { [double]$_.Bytes }.

    BeforeAll {
        $script:RaizInv = Split-Path $PSScriptRoot -Parent
        $script:Consumidores = @('VistaArchivos.ps1', 'IndiceIncremental.ps1', 'Indice.ps1', 'Mapa.ps1')
    }

    It 'los archivos que consumen el indice se han leido de verdad' {
        foreach ($nombre in $script:Consumidores) {
            $ruta = Join-Path (Join-Path (Join-Path $script:RaizInv 'src') 'Core') $nombre
            Test-Path -LiteralPath $ruta | Should -BeTrue -Because "$nombre tiene que existir"
        }
    }

    It 'ninguno ordena con un nombre de propiedad pelado' {
        $culpables = @()
        foreach ($nombre in $script:Consumidores) {
            $ruta = Join-Path (Join-Path (Join-Path $script:RaizInv 'src') 'Core') $nombre
            $n = 0
            foreach ($linea in (Get-Content -LiteralPath $ruta)) {
                $n++
                if ($linea -match '^\s*#') { continue }
                if ($linea -notmatch 'Sort-Object') { continue }
                # Vale una expresión ({ } o tabla con Expression); no "Sort-Object Bytes"
                # ni "Sort-Object -Property Bytes".
                if ($linea -match 'Sort-Object[^\{@]*$' -or
                    $linea -match 'Sort-Object\s+(-Property\s+)?[A-Za-z]') {
                    if ($linea -notmatch '\{' -and $linea -notmatch 'Expression') {
                        $culpables += ('{0}:{1}  {2}' -f $nombre, $n, $linea.Trim())
                    }
                }
            }
        }
        $culpables -join ' // ' | Should -BeNullOrEmpty -Because (
            'sobre diccionarios, en PowerShell 5.1 eso NO ordena y no avisa')
    }
}
