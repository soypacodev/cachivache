<#
    Pruebas del arnés de mutación (tools/Mutar.ps1).

    Idea central: no mutar nada debe ser ruidoso, porque una mutación que
    no se aplica produce el mismo resultado que una prueba impecable.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:Raiz 'tools') 'Mutar.ps1')
}

Describe 'Get-TextoMutado' {

    It 'sustituye cuando el texto aparece una vez' {
        Get-TextoMutado -Texto 'uno dos tres' -Buscar 'dos' -Poner 'DOS' | Should -Be 'uno DOS tres'
    }

    It 'LANZA si el texto no aparece' {
        # El caso principal que protege este archivo.
        { Get-TextoMutado -Texto 'uno dos tres' -Buscar 'cuatro' -Poner 'x' } |
            Should -Throw -ExpectedMessage '*no se ha mutado nada*'
    }

    It 'LANZA si el texto aparece mas de una vez' {
        # Mutar "la primera" sería mutar un sitio no elegido.
        { Get-TextoMutado -Texto 'dos y dos' -Buscar 'dos' -Poner 'x' } |
            Should -Throw -ExpectedMessage '*Aparece 2 veces*'
    }

    It 'admite BORRAR: poner cadena vacia es una mutacion valida' {
        # Quitar una línea entera ("¿qué prueba lo detecta si suprimo esta
        # comprobación?") es una de las mutaciones más útiles.
        Get-TextoMutado -Texto 'uno dos tres' -Buscar ' dos' -Poner '' | Should -Be 'uno tres'
    }

    It 'LANZA si la mutacion no cambia nada' {
        { Get-TextoMutado -Texto 'uno dos' -Buscar 'dos' -Poner 'dos' } |
            Should -Throw -ExpectedMessage '*no cambia nada*'
    }

    It 'compara literalmente, no como expresion regular' {
        # El código mutado está lleno de $, [, ] y (: tratarlo como
        # expresión regular obligaría a escapar cada mutación a mano.
        $codigo = 'if ($hojas.Count -lt 3) { return $null }'
        Get-TextoMutado -Texto $codigo -Buscar '$hojas.Count -lt 3' -Poner '$false' |
            Should -Be 'if ($false) { return $null }'
    }

    It 'no se le escapa una diferencia de mayusculas' {
        # Ordinal, no OrdinalIgnoreCase: en una prueba de texto sobre el
        # código, "casi lo encuentra" es no encontrarlo.
        { Get-TextoMutado -Texto 'return $Cual' -Buscar 'return $cual' -Poner 'x' } |
            Should -Throw -ExpectedMessage '*no se ha mutado nada*'
    }

    It 'con nulos o vacios LANZA, no devuelve el texto tal cual' {
        # Devolver el original sería una mutación que no muta y no avisa.
        { Get-TextoMutado -Texto $null -Buscar 'x' -Poner 'y' }  | Should -Throw
        { Get-TextoMutado -Texto 'algo' -Buscar $null -Poner 'y' } | Should -Throw
        { Get-TextoMutado -Texto 'algo' -Buscar '' -Poner 'y' }    | Should -Throw
    }
}

Describe 'Invoke-Mutacion' {

    BeforeEach {
        $script:Archivo = Join-Path ([IO.Path]::GetTempPath()) ("mutar-{0}.ps1" -f [guid]::NewGuid())
        [IO.File]::WriteAllText($script:Archivo, "uno`ndos`ntres`n", [Text.UTF8Encoding]::new($true))
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:Archivo) { Remove-Item -LiteralPath $script:Archivo -Force }
    }

    It 'el archivo esta mutado DENTRO del bloque' {
        # La caja es una tabla hash a propósito: el bloque se ejecuta en
        # otro ámbito y una variable asignada dentro no se vería fuera; una
        # tabla hash es una referencia.
        $caja = @{}
        $ruta = $script:Archivo

        Invoke-Mutacion -Ruta $ruta -Buscar 'dos' -Poner 'DOS' -Prueba {
            $caja.Texto = [IO.File]::ReadAllText($ruta)
        }.GetNewClosure()

        # Contenido exacto: -BeLike no distingue mayúsculas y aceptaría
        # "DOS" donde se espera "dos".
        $caja.Texto | Should -Be "uno`nDOS`ntres`n"
    }

    It 'y restaurado despues' {
        Invoke-Mutacion -Ruta $script:Archivo -Buscar 'dos' -Poner 'DOS' -Prueba { }
        [IO.File]::ReadAllText($script:Archivo) | Should -Be "uno`ndos`ntres`n"
    }

    It 'restaurado tambien si el bloque LANZA' {
        # Sin el finally, una prueba que lanza dejaría el repositorio
        # mutado y todo lo que se ejecute después mediría otra cosa.
        { Invoke-Mutacion -Ruta $script:Archivo -Buscar 'dos' -Poner 'DOS' -Prueba { throw 'ay' } } |
            Should -Throw
        [IO.File]::ReadAllText($script:Archivo) | Should -Be "uno`ndos`ntres`n"
    }

    It 'el BOM sobrevive a la mutacion' {
        # Si se perdiera el BOM, fallaría la invariante de codificación por
        # un motivo ajeno a la prueba.
        Invoke-Mutacion -Ruta $script:Archivo -Buscar 'dos' -Poner 'DOS' -Prueba {
            $b = [IO.File]::ReadAllBytes($script:Archivo)
            $b[0] | Should -Be 239
        }
        [IO.File]::ReadAllBytes($script:Archivo)[0] | Should -Be 239
    }

    It 'no toca el archivo si la mutacion no vale' {
        # Se valida antes de escribir: un texto que no aparece no puede
        # dejar el archivo a medias.
        { Invoke-Mutacion -Ruta $script:Archivo -Buscar 'cuatro' -Poner 'x' -Prueba { } } |
            Should -Throw -ExpectedMessage '*no se ha mutado nada*'
        [IO.File]::ReadAllText($script:Archivo) | Should -Be "uno`ndos`ntres`n"
    }

    It 'lanza si el archivo no existe' {
        { Invoke-Mutacion -Ruta 'C:\no\existe.ps1' -Buscar 'a' -Poner 'b' -Prueba { } } | Should -Throw
    }
}
