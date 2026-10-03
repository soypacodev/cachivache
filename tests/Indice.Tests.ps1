<#
    Pruebas del índice de disco y de la disposición del mapa de árbol.

    El mapa es cálculo puro a propósito: separar la geometría del dibujado
    permite probarlo sin ejecutar la interfaz.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    function New-ArbolDeEspacio {
        <#
        .SYNOPSIS
            Árbol con proporciones conocidas:
              grande/  10.000.000 bytes (8.000.000 dentro, 2.000.000 sueltos)
              mediana/  4.000.000 bytes
              pequena/  1.500.000 bytes + un archivo de 1.000

            Tamaños en bytes exactos: el umbral del índice es
            1MB = 1.048.576 bytes, así que "un millón" queda por debajo.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo crea un arbol de prueba en una ruta temporal propia.')]
        [CmdletBinding()]
        param([Parameter(Mandatory)] [string] $Raiz)

        foreach ($c in @('grande/dentro', 'mediana', 'pequena')) {
            New-Item -ItemType Directory -Path (Join-Path $Raiz $c) -Force | Out-Null
        }
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'grande/dentro/a.bin'), (New-Object byte[] 8000000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'grande/suelto.bin'),   (New-Object byte[] 2000000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'mediana/b.bin'),       (New-Object byte[] 4000000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'pequena/c.bin'),       (New-Object byte[] 1500000))
        # Uno por debajo del umbral: suma en su carpeta pero no entra en
        # la lista de archivos.
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'pequena/menudo.bin'),  (New-Object byte[] 1000))
    }
}

Describe 'New-IndiceDisco' {

    BeforeAll {
        $script:zona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-indice-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:zona -Force | Out-Null
        New-ArbolDeEspacio -Raiz $script:zona
        $script:indice = New-IndiceDisco -Rutas @($script:zona) -MinimoArchivoBytes 1MB
    }

    AfterAll {
        Remove-Item -LiteralPath $script:zona -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'suma el total exacto, incluidos los archivos por debajo del umbral' {
        $script:indice.Bytes | Should -Be 15501000
    }

    It 'cuenta todos los archivos, no solo los que guarda' {
        $script:indice.TotalArchivos | Should -Be 5
    }

    It 'guarda solo los archivos que superan el umbral' {
        @($script:indice.Archivos).Count | Should -Be 4 -Because 'el de 1.000 bytes suma en su carpeta pero no se lista'
    }

    It 'devuelve los archivos ordenados de mayor a menor' {
        $bytes = @($script:indice.Archivos | ForEach-Object { $_.Bytes })
        $bytes | Should -Be @($bytes | Sort-Object -Descending)
    }

    It 'propaga los totales hacia arriba: una carpeta incluye sus subcarpetas' {
        $grande = $script:indice.Carpetas[(Join-Path $script:zona 'grande')]
        $grande.Bytes   | Should -Be 10000000 -Because '8 MB de la subcarpeta mas 2 MB sueltos'
        $grande.Propios | Should -Be 2000000  -Because 'Propios es solo lo que cuelga directamente'
    }

    It 'la raiz suma todo el arbol' {
        $script:indice.Carpetas[$script:zona].Bytes | Should -Be 15501000
    }

    It 'cuenta los archivos de todo el subarbol en cada carpeta' {
        $script:indice.Carpetas[(Join-Path $script:zona 'grande')].Archivos | Should -Be 2
    }
}

Describe 'Get-HijasDirectas: lo que dibuja un nivel del mapa' {

    BeforeAll {
        $script:zona2 = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-hijas-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:zona2 -Force | Out-Null
        New-ArbolDeEspacio -Raiz $script:zona2
        $script:indice2 = New-IndiceDisco -Rutas @($script:zona2) -MinimoArchivoBytes 1MB
        $script:hijas = @(Get-HijasDirectas -Indice $script:indice2 -Ruta $script:zona2)
    }

    AfterAll {
        Remove-Item -LiteralPath $script:zona2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'devuelve solo las hijas inmediatas, no todo el subarbol' {
        $nombres = @($script:hijas | ForEach-Object { $_.Nombre })
        $nombres | Should -Contain 'grande'
        $nombres | Should -Not -Contain 'dentro' -Because 'dentro cuelga de grande, no de la raiz'
    }

    It 'las devuelve ordenadas de mayor a menor' {
        $bytes = @($script:hijas | ForEach-Object { $_.Bytes })
        $bytes | Should -Be @($bytes | Sort-Object -Descending)
    }

    It 'los archivos sueltos de la carpeta aparecen como un bloque mas' {
        # Sin esto el mapa no sumaría el 100%: una carpeta con 5 GB propios
        # y una subcarpeta de 1 GB parecería ocupar 1 GB.
        $conArchivos = Join-Path $script:zona2 'grande'
        $hijasGrande = @(Get-HijasDirectas -Indice $script:indice2 -Ruta $conArchivos)
        @($hijasGrande | Where-Object { $_.Nombre -like '*archivos de esta carpeta*' }).Count |
            Should -Be 1
    }

    It 'en una raiz de unidad tambien aparecen los archivos sueltos' {
        # La raiz se guarda como "C:\" y quitar la barra final dejaba "C:",
        # que no esta en el indice: el mapa de la unidad no sumaba el 100 %.
        $indiceUnidad = [pscustomobject]@{
            Carpetas = @{
                'C:\' = [pscustomobject]@{ Ruta = 'C:\'; Nombre = 'C:\'; Nivel = 0; Bytes = 30.0; Propios = 10.0; Archivos = 2; Ultimo = (Get-Date) }
            }
        }
        $hijas = @(Get-HijasDirectas -Indice $indiceUnidad -Ruta 'C:\')
        $propios = @($hijas | Where-Object { $_.Nombre -like '*archivos de esta carpeta*' })
        $propios.Count | Should -Be 1
        $propios[0].Bytes | Should -Be 10
    }

    It 'las hijas de un nivel suman el total de su carpeta' {
        $suma = 0.0
        foreach ($h in $script:hijas) { $suma += $h.Bytes }
        $suma | Should -Be $script:indice2.Carpetas[$script:zona2].Bytes
    }
}

Describe 'Get-DisposicionMapa: geometria del mapa de arbol' {

    BeforeAll {
        $script:elementos = @(
            [pscustomobject]@{ Nombre = 'A'; Bytes = 6 }
            [pscustomobject]@{ Nombre = 'B'; Bytes = 6 }
            [pscustomobject]@{ Nombre = 'C'; Bytes = 4 }
            [pscustomobject]@{ Nombre = 'D'; Bytes = 3 }
            [pscustomobject]@{ Nombre = 'E'; Bytes = 2 }
            [pscustomobject]@{ Nombre = 'F'; Bytes = 2 }
            [pscustomobject]@{ Nombre = 'G'; Bytes = 1 }
        )
        $script:mapa = @(Get-DisposicionMapa -Elementos $script:elementos -Ancho 600 -Alto 400 -MinimoLado 0)
    }

    It 'coloca todos los elementos' {
        $script:mapa.Count | Should -Be 7
    }

    It 'cubre el area entera, sin huecos' {
        $area = 0.0
        foreach ($r in $script:mapa) { $area += $r.Ancho * $r.Alto }
        $area | Should -BeGreaterThan 239990
        $area | Should -BeLessThan 240010
    }

    It 'el area de cada rectangulo es proporcional a su tamano' {
        # A vale 6 de 24: la cuarta parte de 240.000.
        $a = $script:mapa | Where-Object { $_.Elemento.Nombre -eq 'A' }
        ($a.Ancho * $a.Alto) | Should -BeGreaterThan 59900
        ($a.Ancho * $a.Alto) | Should -BeLessThan 60100
    }

    It 'ningun rectangulo se sale del area' {
        foreach ($r in $script:mapa) {
            ($r.X + $r.Ancho) | Should -BeLessOrEqual 600.01
            ($r.Y + $r.Alto)  | Should -BeLessOrEqual 400.01
            $r.X | Should -BeGreaterOrEqual -0.01
            $r.Y | Should -BeGreaterOrEqual -0.01
        }
    }

    It 'produce rectangulos legibles: mucho mejores que repartir a tiras' {
        # Razón del algoritmo cuadrado: a tiras, el elemento más pequeño
        # sale con proporción 16; así, por debajo de 4.
        $peor = 0.0
        foreach ($r in $script:mapa) {
            $p = [Math]::Max($r.Ancho, $r.Alto) / [Math]::Max([Math]::Min($r.Ancho, $r.Alto), 0.0001)
            if ($p -gt $peor) { $peor = $p }
        }
        $peor | Should -BeLessThan 4.0
    }

    It 'ordena de mayor a menor aunque le lleguen desordenados' {
        $desordenados = @(
            [pscustomobject]@{ Nombre = 'chico';  Bytes = 1 }
            [pscustomobject]@{ Nombre = 'grande'; Bytes = 100 }
        )
        $m = @(Get-DisposicionMapa -Elementos $desordenados -Ancho 100 -Alto 100 -MinimoLado 0)
        $m[0].Elemento.Nombre | Should -Be 'grande'
    }

    It 'descarta los rectangulos demasiado finos para verse o pulsarse' {
        $conMigaja = @(
            [pscustomobject]@{ Nombre = 'gordo';  Bytes = 1000000 }
            [pscustomobject]@{ Nombre = 'migaja'; Bytes = 1 }
        )
        $m = @(Get-DisposicionMapa -Elementos $conMigaja -Ancho 400 -Alto 300 -MinimoLado 3)
        @($m | Where-Object { $_.Elemento.Nombre -eq 'migaja' }).Count | Should -Be 0
    }

    It 'no lanza con lista vacia ni con area de cero' {
        { Get-DisposicionMapa -Elementos @() -Ancho 100 -Alto 100 } | Should -Not -Throw
        @(Get-DisposicionMapa -Elementos @() -Ancho 100 -Alto 100).Count | Should -Be 0
        @(Get-DisposicionMapa -Elementos $script:elementos -Ancho 0 -Alto 100).Count | Should -Be 0
    }

    It 'ignora los elementos de tamano cero o negativo' {
        $conCeros = @(
            [pscustomobject]@{ Nombre = 'vale';  Bytes = 10 }
            [pscustomobject]@{ Nombre = 'cero';  Bytes = 0 }
            [pscustomobject]@{ Nombre = 'menos'; Bytes = -5 }
        )
        $m = @(Get-DisposicionMapa -Elementos $conCeros -Ancho 200 -Alto 200 -MinimoLado 0)
        $m.Count | Should -Be 1
        $m[0].Elemento.Nombre | Should -Be 'vale'
    }
}

Describe 'el mapa dibujado en SVG' {

    <#
        El cálculo se prueba aparte; aquí, el dibujado. Se dibuja en SVG y
        no en WPF porque el SVG es texto verificable sin interfaz.
    #>

    BeforeAll {
        $script:zonaSvg = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-svg-' + [guid]::NewGuid())
        foreach ($c in @('Videos', 'Proyectos', 'Fotos')) {
            New-Item -ItemType Directory -Path (Join-Path $script:zonaSvg $c) -Force | Out-Null
        }
        [IO.File]::WriteAllBytes((Join-Path $script:zonaSvg 'Videos/peli.mp4'),   (New-Object byte[] 40000000))
        [IO.File]::WriteAllBytes((Join-Path $script:zonaSvg 'Proyectos/lib.tgz'), (New-Object byte[] 18000000))
        [IO.File]::WriteAllBytes((Join-Path $script:zonaSvg 'Fotos/album.zip'),   (New-Object byte[] 9000000))

        $script:indiceSvg = New-IndiceDisco -Rutas @($script:zonaSvg) -MinimoArchivoBytes 1MB
        $script:svg = Get-MapaSvg -Indice $script:indiceSvg -Ruta $script:zonaSvg -Ancho 900 -Alto 480
    }

    AfterAll {
        Remove-Item -LiteralPath $script:zonaSvg -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'produce un SVG bien formado' {
        { [xml]$script:svg } | Should -Not -Throw
    }

    It 'dibuja un rectangulo por carpeta' {
        @([regex]::Matches($script:svg, '<rect ')).Count | Should -Be 3
    }

    It 'los rectangulos cubren el area entera' {
        $area = 0.0
        foreach ($m in [regex]::Matches($script:svg,
                 '<rect x="[\d.]+" y="[\d.]+" width="([\d.]+)" height="([\d.]+)"')) {
            $area += [double]$m.Groups[1].Value * [double]$m.Groups[2].Value
        }
        $area | Should -BeGreaterThan 431000 -Because '900 x 480 son 432.000'
        $area | Should -BeLessThan 433000
    }

    It 'las coordenadas usan punto decimal aunque Windows este en castellano' {
        $svgEs = & {
            $previa = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('es-ES')
                Get-MapaSvg -Indice $script:indiceSvg -Ruta $script:zonaSvg -Ancho 900 -Alto 480
            } finally {
                [Threading.Thread]::CurrentThread.CurrentCulture = $previa
            }
        }
        $svgEs | Should -Not -Match '(x|y|width|height)="\d+,\d'
        { [xml]$svgEs } | Should -Not -Throw
    }

    It 'cada rectangulo lleva su titulo con nombre y tamano' {
        $script:svg | Should -Match '<title>Videos'
    }

    It 'escapa el contenido: un nombre con caracteres de marcado no rompe el SVG' {
        # < > y comillas están prohibidos en nombres de archivo de Windows.
        # El ampersand y el apóstrofo sí son legales, y el ampersand rompe
        # un XML si no se escapa: se prueba lo que un usuario puede crear.
        $zona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-svg2-' + [guid]::NewGuid())
        $mala = Join-Path $zona "a & b 'c'"
        try {
            New-Item -ItemType Directory -Path $mala -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $mala 'x.bin'), (New-Object byte[] 2000000))
            $i = New-IndiceDisco -Rutas @($zona) -MinimoArchivoBytes 1MB
            $s = Get-MapaSvg -Indice $i -Ruta $zona

            { [xml]$s } | Should -Not -Throw -Because 'el nombre de una carpeta lo elige quien la creo'
            $s | Should -Not -Match "<title>a & b"
            $s | Should -Match 'a &amp; b' -Because 'el ampersand tiene que salir escapado, no crudo'
        } finally {
            Remove-Item -LiteralPath $zona -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'no lanza con una carpeta vacia' {
        $vacia = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-svg3-' + [guid]::NewGuid())
        try {
            New-Item -ItemType Directory -Path $vacia -Force | Out-Null
            $i = New-IndiceDisco -Rutas @($vacia)
            { Get-MapaSvg -Indice $i -Ruta $vacia } | Should -Not -Throw
        } finally {
            Remove-Item -LiteralPath $vacia -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'El color dice que parte del espacio es recuperable' {

        It 'una carpeta sin candidatos se pinta en gris' {
            Get-ColorMapa | Should -Be '#3f4756'
        }

        It 'el color sube con el riesgo' {
            Get-ColorMapa -Riesgo 'Bajo'  | Should -Not -Be (Get-ColorMapa -Riesgo 'Alto')
            Get-ColorMapa -Riesgo 'Medio' | Should -Not -Be (Get-ColorMapa)
        }

        It 'una carpeta hereda el riesgo MAS ALTO de lo que tiene dentro' {
            $ruta = Join-Path $script:zonaSvg 'Videos'
            $candidatos = @(
                New-Candidato -ModuloId 'x' -Categoria 'x' -Nombre 'a' `
                    -Ruta (Join-Path $ruta 'peli.mp4') -Metodo 'Informativo' -Riesgo 'Bajo'
                New-Candidato -ModuloId 'x' -Categoria 'x' -Nombre 'b' `
                    -Ruta (Join-Path $ruta 'peli.mp4') -Metodo 'Informativo' -Riesgo 'Alto'
            )
            $destino = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.html')
            try {
                Export-InformeEspacio -Indice $script:indiceSvg -Ruta $destino `
                                      -Candidatos $candidatos -Confirm:$false
                $html = Get-Content -Raw -LiteralPath $destino
                $html | Should -Match ([regex]::Escape((Get-ColorMapa -Riesgo 'Alto'))) -Because (
                    'si dentro hay algo que conviene mirar, el mapa tiene que decirlo')
            } finally {
                Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
