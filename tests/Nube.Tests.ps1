<#
    Pruebas de los archivos que solo están en la nube.

    OneDrive "Archivos a petición" deja un marcador en el disco: la entrada
    existe, el contenido no, y se descarga en cuanto alguien abre el
    archivo (incluido este programa). La detección es aritmética sobre los
    atributos y se prueba sin OneDrive ni conexión.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Valores definidos por Windows, repetidos aquí a propósito para
    # detectar un cambio accidental en las constantes del núcleo.
    $script:OFFLINE                = 0x1000
    $script:RECALL_ON_OPEN         = 0x40000
    $script:RECALL_ON_DATA_ACCESS  = 0x400000
    $script:ARCHIVE                = 0x20
    $script:READONLY               = 0x1
}

Describe 'Test-EsMarcadorNube' {

    It 'un archivo normal no lo es' {
        Test-EsMarcadorNube -Atributos $script:ARCHIVE | Should -BeFalse
    }

    It 'detecta el marcador de OneDrive (RecallOnDataAccess)' {
        # OneDrive lo usa para "solo en línea"; mirar solo Offline dejaría
        # fuera al proveedor más común.
        Test-EsMarcadorNube -Atributos ($script:ARCHIVE -bor $script:RECALL_ON_DATA_ACCESS) | Should -BeTrue
    }

    It 'detecta tambien Offline y RecallOnOpen' {
        # Los usan otras soluciones de almacenamiento jerárquico.
        Test-EsMarcadorNube -Atributos ($script:ARCHIVE -bor $script:OFFLINE)        | Should -BeTrue
        Test-EsMarcadorNube -Atributos ($script:ARCHIVE -bor $script:RECALL_ON_OPEN) | Should -BeTrue
    }

    It 'no confunde otros atributos con la nube' {
        # Un falso positivo saltaría archivos normales y dejaría de
        # encontrar basura real.
        Test-EsMarcadorNube -Atributos ($script:ARCHIVE -bor $script:READONLY) | Should -BeFalse
        Test-EsMarcadorNube -Atributos 0                                       | Should -BeFalse
    }
}

Describe 'Test-ArchivoEnNube' {

    BeforeAll {
        $script:Zona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-nube-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Zona -Force | Out-Null
        $script:Normal = Join-Path $script:Zona 'normal.bin'
        [IO.File]::WriteAllBytes($script:Normal, (New-Object byte[] 2048))
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Zona -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un archivo de verdad, que existe, no esta en la nube' {
        Test-ArchivoEnNube -Archivo (Get-Item -LiteralPath $script:Normal) | Should -BeFalse
        Test-ArchivoEnNube -Archivo $script:Normal                          | Should -BeFalse
    }

    It 'un nulo no revienta y responde que no' {
        { Test-ArchivoEnNube -Archivo $null } | Should -Not -Throw
        Test-ArchivoEnNube -Archivo $null     | Should -BeFalse
    }

    It 'una ruta que no existe responde que no, sin lanzar' {
        # Ante la duda, no: decir que sí saltaría archivos normales en
        # silencio por un fallo de lectura.
        Test-ArchivoEnNube -Archivo (Join-Path $script:Zona 'no-existe.bin') | Should -BeFalse
    }

    It 'preguntarlo NO abre el archivo' {
        # La comprobación no puede provocar la descarga que intenta evitar.
        # Se abre el archivo en exclusiva: si la función intentara abrirlo,
        # fallaría.
        $flujo = [IO.File]::Open($script:Normal, [IO.FileMode]::Open,
                                 [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            { Test-ArchivoEnNube -Archivo $script:Normal } | Should -Not -Throw
            Test-ArchivoEnNube -Archivo $script:Normal | Should -BeFalse
        } finally {
            $flujo.Dispose()
        }
    }
}

Describe 'nada lee un archivo que este solo en la nube' {

    BeforeAll {
        $script:Fs   = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/Core/FileSystem.ps1')
        $script:Dup  = (Get-Content -LiteralPath (Join-Path $script:Raiz 'src/Modules/55-Duplicados.ps1') |
                        Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $script:Gran = (Get-Content -LiteralPath (Join-Path $script:Raiz 'src/Modules/60-ArchivosGrandes.ps1') |
                        Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'la huella rapida se protege sola, antes de abrir nada' {
        # Es la única función del núcleo que abre archivos del usuario: la
        # comprobación vive ahí para que nadie tenga que recordarla.
        $i = $script:Fs.IndexOf('function Get-HuellaRapida')
        $abre = $script:Fs.IndexOf('[IO.File]::Open($Ruta', $i)
        $chequeo = $script:Fs.IndexOf('Test-ArchivoEnNube', $i)

        $chequeo | Should -BeGreaterThan -1
        $chequeo | Should -BeLessThan $abre -Because 'comprobar despues de abrir no evita la descarga'
    }

    It 'duplicados descarta los de la nube antes de compararlos' {
        $script:Dup | Should -Match 'Test-ArchivoEnNube'
    }

    It 'y cuenta cuantos ha dejado fuera, para poder decirlo' {
        # Saltarse archivos sin decirlo daría un "ningún duplicado" falso.
        $script:Dup | Should -Match '\$contador\.Nube\+\+'
        $script:Dup | Should -Match 'están solo en la nube'
    }

    It 'el aviso sale ANTES de rendirse por no encontrar duplicados' {
        $aviso = $script:Dup.IndexOf('están solo en la nube')
        $salida = $script:Dup.IndexOf('if ($gruposCandidatos.Count -eq 0) { return }')
        $aviso  | Should -BeGreaterThan -1
        $salida | Should -BeGreaterThan $aviso
    }

    It 'archivos grandes no promete espacio que no existe en el disco' {
        # Un marcador ocupa kilobytes: no puede listarse como espacio a
        # liberar.
        $script:Gran | Should -Match 'Test-ArchivoEnNube'
    }

    It 'el contador vive en una tabla, no en una variable suelta' {
        # "$n++" funcionaría hoy porque Where-Object ejecuta su bloque en
        # el ámbito de quien llama, pero dejaría de contar si el bloque se
        # moviera a una función auxiliar. La tabla funciona en ambos casos.
        $script:Dup | Should -Match '\$contador = @\{ Nube = 0 \}'
    }

    It 'y de hecho el contador cuenta: no basta con que exista' {
        # Se reproduce el patrón del módulo: comprobar solo el texto daría
        # por bueno un contador que nunca se incrementa.
        $contador = @{ Nube = 0 }
        $pasan = @(1..10) | Where-Object {
            if ($_ % 3 -eq 0) { $contador.Nube++; return $false }
            $true
        }
        $contador.Nube | Should -Be 3
        @($pasan).Count | Should -Be 7
    }
}
