<#
    Pruebas de rutas de más de 260 caracteres (MAX_PATH).

    En este dominio se desborda con facilidad (node_modules anidados, caché
    de Gradle, .next\cache\webpack). Sin prefijo, EnumerateFiles lanza, la
    carpeta cuenta como "inaccesible", se mide y se borra de menos, y el
    usuario recibe un mensaje falso de "archivos en uso".

    La decisión es transformación de texto y se prueba en Linux sin rutas
    largas reales.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
}

Describe 'ConvertTo-RutaLarga' {

    It 'antepone el prefijo a una ruta con letra de unidad' {
        ConvertTo-RutaLarga -Ruta 'C:\Users\x\proyecto' | Should -Be '\\?\C:\Users\x\proyecto'
    }

    It 'una ruta de red va a la forma UNC, no a barras dobles' {
        # "\\?\\\servidor\..." no es valido: la API exige "\\?\UNC\".
        ConvertTo-RutaLarga -Ruta '\\servidor\comun\cosa' | Should -Be '\\?\UNC\servidor\comun\cosa'
    }

    It 'no lo pone dos veces' {
        $ya = '\\?\C:\Windows'
        ConvertTo-RutaLarga -Ruta $ya | Should -Be $ya
    }

    It 'respeta los dispositivos \\.\ ' {
        ConvertTo-RutaLarga -Ruta '\\.\PhysicalDrive0' | Should -Be '\\.\PhysicalDrive0'
    }

    It 'normaliza las barras, porque con el prefijo la API ya no lo hace' {
        ConvertTo-RutaLarga -Ruta 'C:/Users/x' | Should -Be '\\?\C:\Users\x'
    }

    It 'no toca una ruta relativa' {
        # Con el prefijo la API no resuelve nada: una relativa daría una
        # ruta inexistente en vez de un error.
        ConvertTo-RutaLarga -Ruta 'carpeta\sub' | Should -Be 'carpeta\sub'
    }

    It 'no toca una ruta con . o .. como segmento' {
        # Se buscarían literalmente carpetas llamadas "." y "..".
        ConvertTo-RutaLarga -Ruta 'C:\Users\..\Windows' | Should -Be 'C:\Users\..\Windows'
        ConvertTo-RutaLarga -Ruta 'C:\Users\.\x'        | Should -Be 'C:\Users\.\x'
    }

    It 'no toca lo que no es una ruta de Windows' {
        # Algunos candidatos usan Ruta para etiquetas.
        ConvertTo-RutaLarga -Ruta 'docker system prune' | Should -Be 'docker system prune'
        ConvertTo-RutaLarga -Ruta '/tmp/x'              | Should -Be '/tmp/x'
    }

    It 'aguanta el vacio y el nulo' {
        { ConvertTo-RutaLarga -Ruta '' }    | Should -Not -Throw
        { ConvertTo-RutaLarga -Ruta $null } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-RutaLarga: lo que sale vuelve a ser normal' {

    It 'quita el prefijo de una unidad' {
        ConvertFrom-RutaLarga -Ruta '\\?\C:\Users\x' | Should -Be 'C:\Users\x'
    }

    It 'devuelve la forma UNC original' {
        ConvertFrom-RutaLarga -Ruta '\\?\UNC\servidor\comun' | Should -Be '\\servidor\comun'
    }

    It 'no toca lo que no lo lleva' {
        ConvertFrom-RutaLarga -Ruta 'C:\Users\x' | Should -Be 'C:\Users\x'
    }

    It 'ida y vuelta devuelve exactamente lo mismo' {
        # Si la vuelta no fuera exacta, la guardia compararía contra una
        # ruta distinta de la que ve el usuario.
        foreach ($r in @('C:\Users\x\y', '\\servidor\comun\z', 'C:\Windows')) {
            ConvertFrom-RutaLarga -Ruta (ConvertTo-RutaLarga -Ruta $r) | Should -Be $r
        }
    }
}

Describe 'Test-RutaDemasiadoLarga' {

    It 'una ruta normal no lo es' {
        Test-RutaDemasiadoLarga -Ruta 'C:\Users\x\proyecto' | Should -BeFalse
    }

    It 'a partir de 260 caracteres si' {
        $larga = 'C:\' + ('a' * 300)
        Test-RutaDemasiadoLarga -Ruta $larga | Should -BeTrue
    }

    It 'mide SIN el prefijo: si no, toda ruta pareceria 4 caracteres mas larga' {
        $justa = 'C:\' + ('a' * 250)   # 253 caracteres, cabe
        Test-RutaDemasiadoLarga -Ruta $justa | Should -BeFalse
        Test-RutaDemasiadoLarga -Ruta (ConvertTo-RutaLarga -Ruta $justa) | Should -BeFalse
    }

    It 'el limite esta en 260, contando el terminador' {
        Test-RutaDemasiadoLarga -Ruta ('C:\' + ('a' * 256)) | Should -BeFalse  # 259
        Test-RutaDemasiadoLarga -Ruta ('C:\' + ('a' * 257)) | Should -BeTrue   # 260
    }
}

Describe 'el prefijo no puede escaparse de las llamadas al sistema' {

    <#
        Si "\\?\" llegara a la Ruta de un candidato, "\\?\C:\Windows" no
        coincidiría con "C:\Windows" en la lista negra de la guardia.
    #>

    BeforeAll {
        # Mismo entorno simulado que Guard.Tests.ps1: en Linux no hay
        # unidad C: ni variables de Windows.
        $env:SystemRoot    = 'C:\Windows'
        $env:ProgramFiles  = 'C:\Program Files'
        $env:ProgramData   = 'C:\ProgramData'
        $env:USERPROFILE   = 'C:\Users\prueba'
        $env:LOCALAPPDATA  = 'C:\Users\prueba\AppData\Local'

        Initialize-Guardia -Configuracion ([pscustomobject]@{
            Escritorio   = 'C:\Users\prueba\Desktop'
            Documentos   = 'C:\Users\prueba\Documents'
            Descargas    = 'C:\Users\prueba\Downloads'
            Imagenes     = 'C:\Users\prueba\Pictures'
            Musica       = 'C:\Users\prueba\Music'
            Videos       = 'C:\Users\prueba\Videos'
            CarpetaDatos = 'C:\Users\prueba\AppData\Local\Cachivache'
        })
    }

    It 'la guardia da el MISMO veredicto lleve o no el prefijo' {
        # Se exige el mismo motivo, no solo el rechazo: con el prefijo, la
        # guardia podría rechazar por "recurso de red" (las dos barras
        # iniciales) y bloquear después rutas legítimas por ese motivo.
        foreach ($ruta in @('C:\Windows',
                            'C:\Windows\System32',
                            'C:\Users\prueba\AppData\Local\Temp\basura')) {
            $sin = Get-MotivoIntocable -Ruta $ruta
            $con = Get-MotivoIntocable -Ruta (ConvertTo-RutaLarga -Ruta $ruta)
            $con | Should -Be $sin -Because "el prefijo no puede cambiar el juicio sobre $ruta"
        }
    }

    It 'y con el prefijo no confunde el disco local con un recurso de red' {
        # Una ruta local con prefijo no puede vetarse como si estuviera en
        # un servidor.
        $motivo = Get-MotivoIntocable -Ruta '\\?\C:\Users\prueba\AppData\Local\Temp\basura'
        $motivo | Should -Not -BeLike '*recurso de red*'
    }

    It 'una ruta de red DE VERDAD sigue detectandose, con prefijo y sin el' {
        # Quitar el prefijo no puede perder la detección legítima:
        # "\\?\UNC\servidor\..." vuelve a ser "\\servidor\...".
        Get-MotivoIntocable -Ruta '\\servidor\comun\x'       | Should -BeLike '*recurso de red*'
        Get-MotivoIntocable -Ruta '\\?\UNC\servidor\comun\x' | Should -BeLike '*recurso de red*'
    }

    It 'New-Candidato no recibe rutas con prefijo desde los modulos' {
        # Se comprueba el código: ningún módulo puede pasar el resultado de
        # ConvertTo-RutaLarga como -Ruta.
        $culpables = @()
        foreach ($archivo in @(Get-ChildItem (Join-Path $script:Raiz 'src/Modules') -Filter '*.ps1')) {
            $texto = Get-Content -Raw -LiteralPath $archivo.FullName
            if ($texto -match '-Ruta\s+[^\r\n]*ConvertTo-RutaLarga') {
                $culpables += $archivo.Name
            }
            if ($texto -match "New-Candidato[\s\S]{0,400}'\\\\\?\\\\") {
                $culpables += $archivo.Name
            }
        }
        $culpables | Should -BeNullOrEmpty
    }

    It 'el recorrido usa el prefijo, y lo hace en UN solo sitio' {
        # Una regla repartida en muchos sitios acaba olvidándose en uno:
        # Get-ResumenArbol la aplica para todos.
        $fs = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/Core/FileSystem.ps1')
        $fs | Should -Match 'Get-CarpetaParaRecorrer -Carpeta \$Carpeta'

        $usos = @([regex]::Matches($fs, 'Get-CarpetaParaRecorrer')).Count
        $usos | Should -BeLessOrEqual 3 -Because 'definicion, llamada y a lo sumo una mencion'
    }
}

Describe 'el borrado distingue las dos APIs' {

    BeforeAll {
        $script:Motor = (Get-Content -LiteralPath (Join-Path $script:Raiz 'src/Core/Remove.ps1') |
                         Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'una ruta larga que va a la papelera se rechaza, no se borra a la brava' {
        # VisualBasic.FileIO no admite el prefijo. Borrar permanentemente
        # en su lugar destruiría lo que el usuario quiere poder recuperar.
        $script:Motor | Should -Match '\$esLarga -and -not \$Permanente'
        $script:Motor | Should -Match 'Marca el borrado permanente'
    }

    It 'el borrado permanente de una ruta larga usa System.IO, no el proveedor' {
        $script:Motor | Should -Match '\[IO\.Directory\]::Delete\(\$larga, \$true\)'
        $script:Motor | Should -Match '\[IO\.File\]::Delete\(\$larga\)'
    }

    It 'las rutas normales siguen usando Remove-Item' {
        # Remove-Item entiende de proveedores y de rutas relativas.
        $script:Motor | Should -Match 'Remove-Item -LiteralPath \$Ruta -Recurse -Force'
    }
}

Describe 'medir sigue funcionando igual en lo de siempre' {

    <#
        El prefijo se aplica a todo recorrido: no puede romper la medición
        de las carpetas normales.
    #>

    BeforeAll {
        $script:Zona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-largo-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:Zona 'sub') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $script:Zona 'a.bin'), (New-Object byte[] 4096))
        [IO.File]::WriteAllBytes((Join-Path (Join-Path $script:Zona 'sub') 'b.bin'), (New-Object byte[] 2048))
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Zona -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'mide el arbol entero, subcarpetas incluidas' {
        Measure-Ruta $script:Zona | Should -Be 6144
    }

    It 'no cuenta nada como inaccesible' {
        # Si el prefijo rompiera la enumeración, este contador subiría y el
        # tamaño bajaría en silencio.
        $r = Get-ResumenArbol -Carpeta ([IO.DirectoryInfo]::new($script:Zona))
        $r.Inaccesibles | Should -Be 0
        $r.Archivos     | Should -Be 2
    }
}

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
}
