<#
    Formato de las sumas SHA-256 que se publican.

    Las leen herramientas (`sha256sum -c`, winget, Scoop) que esperan una
    forma exacta. Cuatro descuidos la rompen sin verse a simple vista:
    mayúsculas, un solo espacio, saltos CRLF y el BOM. El BOM solo hace
    fallar la primera línea, que parece un paquete adulterado.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:Raiz 'tools') 'Sumas.ps1')

    # Hashes reales: cadenas cortas esconderían un recorte.
    $script:Uno = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
    $script:Dos = '9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08'

    $script:Entradas = @(
        @{ Nombre = 'Cachivache-v2.1.0.zip'; Hash = $script:Uno }
        @{ Nombre = 'Cachivache.exe';        Hash = $script:Dos }
    )
}

Describe 'Format-SumasSha256: la forma que espera sha256sum' {

    BeforeAll {
        $script:Texto  = Format-SumasSha256 -Entradas $script:Entradas
        $script:Lineas = $script:Texto.TrimEnd("`n") -split "`n"
    }

    It 'la prueba genera algo: si no, no comprueba nada' {
        $script:Texto.Length | Should -BeGreaterThan 100
        $script:Lineas.Count | Should -Be 2
    }

    It 'una linea por archivo, con su nombre' {
        $script:Lineas[0] | Should -BeLike '*Cachivache-v2.1.0.zip'
        $script:Lineas[1] | Should -BeLike '*Cachivache.exe'
    }

    It 'el hash va en minusculas' {
        # Get-FileHash devuelve mayúsculas y sha256sum escribe minúsculas.
        # Se miran solo los 64 primeros caracteres: el nombre del archivo
        # puede llevar mayúsculas.
        foreach ($linea in $script:Lineas) {
            $linea.Substring(0, 64) | Should -MatchExactly '^[0-9a-f]{64}$'
        }
        $script:Lineas[0] | Should -BeLike ($script:Uno.ToLowerInvariant() + '*')
    }

    It 'el separador son DOS espacios exactos' {
        foreach ($linea in $script:Lineas) {
            $linea | Should -Match '^[0-9a-f]{64}  \S'
            # El número exacto: "al menos dos" pasaría con tres.
            ($linea -replace '^[0-9a-f]{64}( +).*$', '$1').Length | Should -Be 2
        }
    }

    It 'no hay retornos de carro' {
        # Un \r sobrante queda dentro del nombre del archivo y ninguna
        # línea casa.
        $script:Texto | Should -Not -Match "`r"
    }

    It 'termina en salto de linea' {
        $script:Texto.EndsWith("`n") | Should -BeTrue -Because 'sha256sum se queja de una ultima linea sin terminar'
    }

    It 'sin entradas devuelve texto vacio, no lanza' {
        { Format-SumasSha256 -Entradas @() } | Should -Not -Throw
        Format-SumasSha256 -Entradas @()   | Should -BeNullOrEmpty
        Format-SumasSha256 -Entradas $null | Should -BeNullOrEmpty
    }

    It 'un nombre con ruta se rechaza' {
        # Se verifica desde la carpeta de la descarga: una ruta del runner
        # de la CI no existe allí y la línea no casaría nunca.
        { Format-SumasSha256 -Entradas @(@{ Nombre = 'D:\a\salida\Cachivache.exe'; Hash = $script:Uno }) } |
            Should -Throw -ExpectedMessage '*lleva ruta*'
    }

    It 'una entrada sin hash o sin nombre se rechaza' {
        { Format-SumasSha256 -Entradas @(@{ Nombre = 'x.zip'; Hash = '' }) } | Should -Throw
        { Format-SumasSha256 -Entradas @(@{ Nombre = '';      Hash = $script:Uno }) } | Should -Throw
    }
}

Describe 'Format-TablaSumas: las mismas sumas en el cuerpo de la version' {

    BeforeAll {
        $script:Tabla = Format-TablaSumas -Entradas $script:Entradas
    }

    It 'es una tabla de Markdown con cabecera' {
        $script:Tabla | Should -Match '\|\s*Archivo\s*\|'
        $script:Tabla | Should -Match '\|---\|---\|'
    }

    It 'lleva los dos archivos y sus dos sumas' {
        $script:Tabla | Should -BeLike '*Cachivache-v2.1.0.zip*'
        $script:Tabla | Should -BeLike '*Cachivache.exe*'
        $script:Tabla | Should -BeLike ('*' + $script:Uno.ToLowerInvariant() + '*')
        $script:Tabla | Should -BeLike ('*' + $script:Dos.ToLowerInvariant() + '*')
    }

    It 'dice lo mismo que el archivo de sumas' {
        # Dos representaciones del mismo dato: si divergen, la comprobación
        # a ojo y la de la herramienta llegarían a conclusiones opuestas.
        $texto = Format-SumasSha256 -Entradas $script:Entradas
        foreach ($e in $script:Entradas) {
            $suma = ([string]$e.Hash).ToLowerInvariant()
            $texto        | Should -BeLike ('*' + $suma + '*')
            $script:Tabla | Should -BeLike ('*' + $suma + '*')
        }
    }

    It 'sin entradas devuelve vacio, no lanza' {
        { Format-TablaSumas -Entradas $null } | Should -Not -Throw
        Format-TablaSumas -Entradas @() | Should -BeNullOrEmpty
    }
}

Describe 'Test-SumaSha256Valida' {

    It 'acepta un SHA-256 de verdad' {
        Test-SumaSha256Valida -Suma $script:Uno | Should -BeTrue
        Test-SumaSha256Valida -Suma $script:Uno.ToLowerInvariant() | Should -BeTrue
    }

    It 'rechaza <Que>' -ForEach @(
        @{ Que = 'uno corto';        Suma = 'e3b0c442' }
        @{ Que = 'uno largo';        Suma = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855a' }
        @{ Que = 'algo no hex';      Suma = 'z3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        @{ Que = 'con un espacio';   Suma = 'e3b0c442 8fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        @{ Que = 'una cadena vacia'; Suma = '' }
        @{ Que = 'uno con salto de linea final'; Suma = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`n" }
    ) {
        Test-SumaSha256Valida -Suma $Suma | Should -BeFalse
    }

    It 'con nulo dice que no, y no lanza' {
        # Publicar una suma errónea es peor que no publicarla: parece un
        # paquete adulterado.
        { Test-SumaSha256Valida -Suma $null } | Should -Not -Throw
        Test-SumaSha256Valida -Suma $null | Should -BeFalse
    }
}

Describe 'el flujo de publicacion firma lo que sube' {
    <#
        Tres formas de quedarse a medias sin que falle nada: calcular las
        sumas y no adjuntarlas, calcularlas antes de armar el paquete, o no
        verificarlas nunca.
    #>

    BeforeAll {
        $script:Flujo = Get-Content -Raw -LiteralPath (
            Join-Path (Split-Path $PSScriptRoot -Parent) '.github/workflows/publicar.yml')
    }

    It 'la prueba lee el flujo de verdad: si no, no comprueba nada' {
        $script:Flujo.Length | Should -BeGreaterThan 1000
        $script:Flujo | Should -Match 'action-gh-release'
    }

    It 'las sumas se calculan y ademas se adjuntan a la version' {
        # Calcularlas y no subirlas deja un paso verde que no publica nada.
        $script:Flujo | Should -Match 'Publicar-Sumas\.ps1'
        $script:Flujo | Should -Match 'SHA256SUMS\.txt'
    }

    It 'se calculan DESPUES de armar el paquete' {
        # Antes serían las sumas de un zip inexistente o de la ejecución
        # anterior.
        $posPaquete = $script:Flujo.IndexOf('Compress-Archive')
        $posSumas   = $script:Flujo.IndexOf('Publicar-Sumas.ps1')

        $posPaquete | Should -BeGreaterThan 0
        $posSumas   | Should -BeGreaterThan $posPaquete
    }

    It 'y ANTES de adjuntar nada' {
        $posSumas    = $script:Flujo.IndexOf('Publicar-Sumas.ps1')
        $posAdjuntar = $script:Flujo.IndexOf('action-gh-release')

        $posAdjuntar | Should -BeGreaterThan $posSumas
    }

    It 'el archivo de sumas se escribe SIN BOM y sin traducir los saltos' {
        # Format-SumasSha256 devuelve una cadena correcta; quien la escribe
        # puede estropearla:
        #   - UTF8Encoding($true) pone BOM y falla la primera línea.
        #   - Out-File traduce los saltos a CRLF en Windows.
        #
        # Aunque el proyecto exige BOM en todo .ps1 y .xaml, aquí el $false
        # es deliberado.
        $guion = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools') 'Publicar-Sumas.ps1')

        $guion | Should -Match '\[Text\.UTF8Encoding\]::new\(\$false\)' -Because 'con BOM falla la primera linea, y solo la primera'
        $guion | Should -Not -Match 'Out-File\s+.*Destino' -Because 'Out-File traduce los saltos a CRLF'
    }

    It 'el propio flujo verifica las sumas con la herramienta de verdad' {
        # Un archivo con BOM, CRLF o un solo espacio se lee bien pero no
        # valida: hay que ejecutar sha256sum -c en la publicación.
        $script:Flujo | Should -Match 'sha256sum -c'
    }

    It 'y lo verifica con --strict' {
        # Sin --strict, un archivo con BOM da "WARNING: 1 line is improperly
        # formatted", verifica el resto y sale con código 0.
        $script:Flujo | Should -Match 'sha256sum -c --strict'
    }
}
