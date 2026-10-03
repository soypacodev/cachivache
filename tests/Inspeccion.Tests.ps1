<#
    Pruebas de la inspección de carpetas: ver qué hay dentro antes de
    decidir si se borra.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    function New-ArbolDePrueba {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Crea un arbol en una ruta temporal propia.')]
        [CmdletBinding()]
        param([Parameter(Mandatory)] [string] $Raiz)

        New-Item -ItemType Directory -Path (Join-Path $Raiz 'sub/hondo') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'grande.bin'),        (New-Object byte[] 900000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'mediano.bin'),       (New-Object byte[] 400000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'sub/pequeno.bin'),   (New-Object byte[] 1000))
        [IO.File]::WriteAllBytes((Join-Path $Raiz 'sub/hondo/hoja.bin'),(New-Object byte[] 50))
    }
}

Describe 'Get-DetalleCarpeta: de que esta hecha una carpeta' {

    BeforeAll {
        $script:Zona = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-insp-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Zona -Force | Out-Null
        New-ArbolDePrueba -Raiz $script:Zona
        $script:D = Get-DetalleCarpeta -Ruta $script:Zona
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Zona -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'cuenta todos los archivos, incluidos los del fondo del arbol' {
        $script:D.Archivos | Should -Be 4
    }

    It 'cuenta las subcarpetas' {
        $script:D.Carpetas | Should -Be 2
    }

    It 'suma los bytes exactos' {
        $script:D.Bytes | Should -Be 1301050
    }

    It 'devuelve los mayores ordenados de mayor a menor' {
        # Es lo que el usuario quiere saber: qué es lo que ocupa.
        $nombres = @($script:D.Mayores | ForEach-Object { $_.Nombre })
        $nombres[0] | Should -Be 'grande.bin'
        $nombres[1] | Should -Be 'mediano.bin'
    }

    It 'no devuelve mas de los pedidos' {
        (Get-DetalleCarpeta -Ruta $script:Zona -Cuantos 2).Mayores.Count | Should -Be 2
    }

    It 'sabe cual es el cambio mas reciente' {
        $script:D.Ultimo | Should -Not -BeNullOrEmpty
        $script:D.Ultimo | Should -BeOfType [datetime]
    }

    It 'no marca truncado cuando ha podido mirarlo todo' {
        $script:D.Truncado | Should -BeFalse
    }
}

Describe 'Get-DetalleCarpeta: casos que no son una carpeta llena' {

    BeforeAll {
        $script:Zona2 = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-insp2-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Zona2 -Force | Out-Null
        $script:Suelto = Join-Path $script:Zona2 'solo.bin'
        [IO.File]::WriteAllBytes($script:Suelto, (New-Object byte[] 2048))
        $script:Vacia = Join-Path $script:Zona2 'vacia'
        New-Item -ItemType Directory -Path $script:Vacia -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Zona2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un archivo suelto es su propio detalle' {
        # "Cero archivos" sobre un archivo sería técnicamente cierto y
        # prácticamente falso.
        $d = Get-DetalleCarpeta -Ruta $script:Suelto
        $d.Archivos | Should -Be 1
        $d.Bytes    | Should -Be 2048
        $d.Mayores[0].Nombre | Should -Be 'solo.bin'
    }

    It 'una carpeta vacia lo dice sin inventarse nada' {
        $d = Get-DetalleCarpeta -Ruta $script:Vacia
        $d.Archivos | Should -Be 0
        @($d.Mayores).Count | Should -Be 0
    }

    It 'una ruta que no existe devuelve el detalle vacio, sin lanzar' {
        { Get-DetalleCarpeta -Ruta (Join-Path $script:Zona2 'no-existe') } | Should -Not -Throw
        (Get-DetalleCarpeta -Ruta (Join-Path $script:Zona2 'no-existe')).Archivos | Should -Be 0
    }

    It 'una ruta vacia o nula tampoco revienta' {
        { Get-DetalleCarpeta -Ruta '' }    | Should -Not -Throw
        { Get-DetalleCarpeta -Ruta $null } | Should -Not -Throw
    }

    It 'todos los caminos devuelven la MISMA forma' {
        # Una forma única evita que quien lo muestre tenga que comprobar
        # cada campo.
        $esperados = @('Archivos', 'Carpetas', 'Bytes', 'Ultimo', 'Mayores',
                       'EnNube', 'Inaccesibles', 'Truncado')
        foreach ($ruta in @($script:Suelto, $script:Vacia, 'no-existe', '')) {
            $d = Get-DetalleCarpeta -Ruta $ruta
            foreach ($campo in $esperados) {
                $d.PSObject.Properties.Name | Should -Contain $campo -Because "ruta: $ruta"
            }
        }
    }
}

Describe 'no abre archivos, y por tanto no descarga nada' {

    BeforeAll {
        $script:Codigo = (Get-Content -LiteralPath (
            Join-Path $script:Raiz 'src/Core/Inspeccion.ps1') |
            Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'no hay ni una apertura de archivo en todo el modulo' {
        # Abrir un marcador de posición de OneDrive lo descarga; mirar una
        # carpeta no debe consumir datos.
        $script:Codigo | Should -Not -Match '\[IO\.File\]::Open'
        $script:Codigo | Should -Not -Match 'Get-FileHash'
        $script:Codigo | Should -Not -Match 'Get-Content'
        $script:Codigo | Should -Not -Match 'ReadAll'
    }

    It 'usa el recorrido con prefijo de ruta larga' {
        $script:Codigo | Should -Match 'Get-CarpetaParaRecorrer'
    }

    It 'y quita el prefijo de todo lo que devuelve' {
        # El prefijo no debe llegar a lo que ve el usuario ni a lo que
        # compara la guardia.
        $script:Codigo | Should -Match 'ConvertFrom-RutaLarga -Ruta \$archivo\.FullName'
    }

    It 'no sigue puntos de reanalisis' {
        # Seguirlos podría recorrer medio disco o entrar en un ciclo.
        $script:Codigo | Should -Match 'ReparsePoint'
    }

    It 'dos try independientes, uno por bucle' {
        # Con uno solo, un acceso denegado al enumerar archivos cortaría
        # también el recorrido de las subcarpetas.
        @([regex]::Matches($script:Codigo, '\btry\b')).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Format-DetalleCarpeta: lo que se le cuenta al usuario' {

    It 'responde a las tres preguntas: cuantos, de cuando y que ocupa' {
        $d = New-DetalleCarpeta
        $d.Archivos = 1203
        $d.Carpetas = 47
        $d.Bytes    = 1.2GB
        $d.Ultimo   = (Get-Date).AddDays(-200)
        $d.Mayores  = @([pscustomobject]@{ Nombre = 'blob.bin'; Bytes = 800MB; EnNube = $false })

        $t = Format-DetalleCarpeta -Detalle $d
        $t | Should -BeLike '*1203*'
        $t | Should -BeLike '*47*'
        $t | Should -BeLike '*GB*'
        $t | Should -BeLike '*blob.bin*'
    }

    It 'cuando el recorrido quedo a medias, LO DICE' {
        # Los mayores calculados sobre medio árbol parecen un dato cierto,
        # pero el más grande puede estar en la parte no recorrida.
        $d = New-DetalleCarpeta
        $d.Archivos = 300000
        $d.Truncado = $true
        $d.Mayores  = @([pscustomobject]@{ Nombre = 'x'; Bytes = 1; EnNube = $false })

        $t = Format-DetalleCarpeta -Detalle $d
        $t | Should -BeLike '*no se han mirado todos*'
    }

    It 'y cuando no, no asusta con avisos que no tocan' {
        $d = New-DetalleCarpeta
        $d.Archivos = 3
        $d.Mayores  = @([pscustomobject]@{ Nombre = 'x'; Bytes = 1; EnNube = $false })
        (Format-DetalleCarpeta -Detalle $d) | Should -Not -BeLike '*no se han mirado todos*'
    }

    It 'avisa de lo que no ocupa espacio de verdad' {
        $d = New-DetalleCarpeta
        $d.Archivos = 10
        $d.EnNube   = 4
        $d.Mayores  = @([pscustomobject]@{ Nombre = 'nube.bin'; Bytes = 1GB; EnNube = $true })

        $t = Format-DetalleCarpeta -Detalle $d
        $t | Should -BeLike '*solo en la nube*'
        $t | Should -BeLike '*(en la nube)*'
    }

    It 'avisa de lo que no ha podido leer' {
        # Callarlo haría parecer completo un total que no lo es.
        $d = New-DetalleCarpeta
        $d.Archivos     = 5
        $d.Inaccesibles = 2
        $d.Mayores      = @([pscustomobject]@{ Nombre = 'x'; Bytes = 1; EnNube = $false })
        (Format-DetalleCarpeta -Detalle $d) | Should -BeLike '*no está contado*'
    }

    It 'una carpeta vacia se cuenta como vacia, no como un error' {
        (Format-DetalleCarpeta -Detalle (New-DetalleCarpeta)) | Should -BeLike '*ni un archivo*'
    }

    It 'un detalle nulo no revienta' {
        { Format-DetalleCarpeta -Detalle $null } | Should -Not -Throw
    }
}
