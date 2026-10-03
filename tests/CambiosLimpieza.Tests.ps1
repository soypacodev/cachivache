<#
    Conversión de lo que se acaba de borrar en bajas del índice.

    El riesgo que se prueba es quitar del índice algo que sigue en el disco:
    ese archivo dejaría de ofrecerse. Quitar de menos solo hace que el
    índice sobreestime hasta el siguiente recorrido. Ante la duda, no se da
    de baja.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    function script:Nuevo {
        # El parámetro se llama Fallo y no Error (aunque el campo sí):
        # $Error es la variable automática de PowerShell y usarla como
        # parámetro la oculta dentro de la función.
        param(
            [string] $Ruta,
            [string] $Metodo = 'Ruta',
            [bool]   $Hecho  = $true,
            [string] $Fallo  = ''
        )
        [pscustomobject]@{ Ruta = $Ruta; Metodo = $Metodo; Hecho = $Hecho; Error = $Fallo }
    }

    # Índice falso con lo único que esta función mira: las claves de la
    # tabla de archivos.
    $script:Rutas = @(
        'C:\Temp\a.txt'
        'C:\Temp\sub\b.txt'
        'C:\Temp\sub\hondo\c.txt'
        'C:\Temporal\d.txt'      # NO cuelga de C:\Temp: la trampa del prefijo
        'C:\Otra\e.txt'
        'C:\suelto.bin'
    )
}

Describe 'que le hace al indice cada metodo de borrado' {

    It 'los ocho metodos del ValidateSet estan clasificados, y en una sola lista' {
        # Se pregunta si hay algún método sin clasificar. Se lee el
        # ValidateSet de New-Candidato en vez de copiarlo: una copia se queda
        # vieja al añadir un método, que caería en 'Incierto' sin que nadie
        # lo haya decidido.
        $texto = [IO.File]::ReadAllText((Join-Path (Join-Path $script:Raiz 'src') 'Core/Candidate.ps1'))
        $m = [regex]::Match($texto, "ValidateSet\('Contenido'[^)]*\)")
        $m.Success | Should -BeTrue -Because 'sin el ValidateSet no hay lista de verdad que comprobar'
        $delValidateSet = @([regex]::Matches($m.Value, "'([^']+)'") |
                            ForEach-Object { $_.Groups[1].Value })
        $delValidateSet.Count | Should -BeGreaterThan 4

        $clasificados = @($script:MetodosBorranSubarbol) +
                        @($script:MetodosNoTocanIndice) +
                        @($script:MetodosEfectoIncierto)

        $sinClasificar = @($delValidateSet | Where-Object { $_ -notin $clasificados })
        $sinClasificar -join ', ' | Should -BeNullOrEmpty -Because (
            'un metodo sin clasificar contesta Incierto por descarte, y eso es una decision tomada por nadie')

        $fantasmas = @($clasificados | Where-Object { $_ -notin $delValidateSet })
        $fantasmas -join ', ' | Should -BeNullOrEmpty -Because 'clasificar un metodo que no existe es mantener una mentira'

        $repetidos = @($clasificados | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $repetidos -join ', ' | Should -BeNullOrEmpty -Because 'en dos listas a la vez, gana la primera por casualidad'
    }

    It 'solo Ruta y Contenido borran el subarbol entero' {
        Get-EfectoEnIndice -Metodo 'Ruta'       | Should -Be 'Subarbol'
        Get-EfectoEnIndice -Metodo 'Contenido'  | Should -Be 'Subarbol'
    }

    It 'los metodos parciales y los opacos son inciertos, no "nada"' {
        # FirefoxCache y Miniaturas borran solo una parte; Papelera y Comando
        # no dicen qué han tocado. 'Nada' afirmaría que no había nada que
        # quitar.
        foreach ($m in 'FirefoxCache', 'Miniaturas', 'Papelera', 'Comando') {
            Get-EfectoEnIndice -Metodo $m | Should -Be 'Incierto' -Because "$m no dice que ha borrado"
        }
    }

    It 'un metodo desconocido contesta Incierto, nunca Nada' {
        # Un método nuevo sin clasificar debe comportarse de forma
        # prudente.
        Get-EfectoEnIndice -Metodo 'MetodoQueNadieHaEscritoTodavia' | Should -Be 'Incierto'
        Get-EfectoEnIndice -Metodo ''    | Should -Be 'Incierto'
        Get-EfectoEnIndice -Metodo $null | Should -Be 'Incierto'
    }
}

Describe 'cuando se puede afirmar que un subarbol ha desaparecido' {

    It 'con el metodo bueno, hecho y sin error, si' {
        Test-CandidatoBorroSuSubarbol -Candidato (script:Nuevo 'C:\Temp') | Should -BeTrue
    }

    It 'si no se hizo, no' {
        Test-CandidatoBorroSuSubarbol -Candidato (script:Nuevo 'C:\Temp' -Hecho $false) | Should -BeFalse
    }

    It 'HECHO CON ERROR NO BASTA: el resultado parcial no da de baja nada' {
        # Remove.ps1 deja Hecho a $true con Error relleno cuando quedaron
        # archivos en uso ("Quedan 600 MB"). Para la auditoría se hizo; para
        # el índice no, porque no se sabe qué ha sobrevivido.
        $c = script:Nuevo 'C:\Temp'
        $c.Error = 'Quedan 600 MB: archivos en uso por algún programa abierto.'
        Test-CandidatoBorroSuSubarbol -Candidato $c | Should -BeFalse
    }

    It 'con un metodo incierto, no, aunque haya ido perfecto' {
        Test-CandidatoBorroSuSubarbol -Candidato (script:Nuevo 'C:\Temp' -Metodo 'Comando')  | Should -BeFalse
        Test-CandidatoBorroSuSubarbol -Candidato (script:Nuevo 'C:\Temp' -Metodo 'Papelera') | Should -BeFalse
    }

    It 'sin ruta, no' {
        Test-CandidatoBorroSuSubarbol -Candidato (script:Nuevo '')    | Should -BeFalse
        Test-CandidatoBorroSuSubarbol -Candidato (script:Nuevo '   ') | Should -BeFalse
    }

    It 'con un candidato nulo, no, y no lanza' {
        { Test-CandidatoBorroSuSubarbol -Candidato $null } | Should -Not -Throw
        Test-CandidatoBorroSuSubarbol -Candidato $null | Should -BeFalse
    }
}

Describe 'de la limpieza a las bajas del indice' {

    It 'una carpeta limpiada da de baja todo lo que colgaba de ella' {
        $r = Get-CambiosDeLimpieza -Candidatos @(script:Nuevo 'C:\Temp' -Metodo 'Contenido') -RutasIndice $script:Rutas
        $bajas = @($r.Cambios | ForEach-Object { $_.Ruta })
        $bajas | Should -Contain 'C:\Temp\a.txt'
        $bajas | Should -Contain 'C:\Temp\sub\b.txt'
        $bajas | Should -Contain 'C:\Temp\sub\hondo\c.txt'
        @($r.Cambios).Count | Should -Be 3
        @($r.Cambios | Where-Object { $_.Tipo -ne 'Baja' }).Count | Should -Be 0
    }

    It 'NO se lleva por delante una carpeta que solo comparte el principio del nombre' {
        # C:\Temporal empieza por C:\Temp. Get-RaizQueContiene exige la
        # barra final; por eso la pertenencia se pregunta a la guardia y no
        # con un StartsWith.
        $r = Get-CambiosDeLimpieza -Candidatos @(script:Nuevo 'C:\Temp' -Metodo 'Contenido') -RutasIndice $script:Rutas
        @($r.Cambios | ForEach-Object { $_.Ruta }) | Should -Not -Contain 'C:\Temporal\d.txt'
    }

    It 'un archivo suelto se da de baja a si mismo' {
        # Get-RaizQueContiene no casa una ruta consigo misma; con el método
        # Ruta el candidato puede ser un archivo y necesita la comparación
        # extra.
        $r = Get-CambiosDeLimpieza -Candidatos @(script:Nuevo 'C:\suelto.bin') -RutasIndice $script:Rutas
        @($r.Cambios).Count | Should -Be 1
        $r.Cambios[0].Ruta | Should -Be 'C:\suelto.bin'
    }

    It 'no distingue mayusculas: Windows tampoco' {
        $r = Get-CambiosDeLimpieza -Candidatos @(script:Nuevo 'c:\temp\SUB' -Metodo 'Contenido') -RutasIndice $script:Rutas
        @($r.Cambios).Count | Should -Be 2
    }

    It 'un candidato incierto no aporta bajas Y NO ESTROPEA LAS DE LOS DEMAS' {
        # Casi toda limpieza vacía la papelera o lanza un comando: si un
        # incierto invalidara la tanda entera, el atajo no se aplicaría
        # nunca. Los inciertos se resuelven en el siguiente recorrido.
        $r = Get-CambiosDeLimpieza -RutasIndice $script:Rutas -Candidatos @(
            (script:Nuevo 'C:\Temp' -Metodo 'Contenido')
            (script:Nuevo 'Papelera de reciclaje' -Metodo 'Papelera')
            (script:Nuevo 'DISM' -Metodo 'Comando')
        )
        @($r.Cambios).Count | Should -Be 3
        $r.Ciertos   | Should -Be 1
        $r.Inciertos | Should -Be 2
    }

    It 'lo que fallo no da de baja nada' {
        $r = Get-CambiosDeLimpieza -RutasIndice $script:Rutas -Candidatos @(
            (script:Nuevo 'C:\Temp'  -Metodo 'Contenido' -Hecho $false)
            (script:Nuevo 'C:\Otra'  -Metodo 'Contenido' -Fallo 'Bloqueado por la guardia')
        )
        @($r.Cambios).Count | Should -Be 0
        $r.Omitidos | Should -Be 2
    }

    It 'sin raices no se recorre el indice, y sale vacio' {
        $r = Get-CambiosDeLimpieza -Candidatos @() -RutasIndice $script:Rutas
        @($r.Cambios).Count | Should -Be 0
        @($r.Raices).Count  | Should -Be 0
    }

    It 'no lanza con nulos por ningun lado' {
        { Get-CambiosDeLimpieza -Candidatos $null -RutasIndice $null } | Should -Not -Throw
        { Get-CambiosDeLimpieza -Candidatos @($null, $null) -RutasIndice $script:Rutas } | Should -Not -Throw
        { Get-CambiosDeLimpieza -Candidatos @(script:Nuevo 'C:\Temp') -RutasIndice @($null, '', '   ') } | Should -Not -Throw
    }

    It 'LA INVARIANTE: ninguna baja cae fuera de lo que se declaro borrado' {
        # Comprobación independiente del algoritmo: toda ruta dada de baja
        # debe ser una de las raíces o colgar de una de ellas.
        $candidatos = @(
            (script:Nuevo 'C:\Temp\sub' -Metodo 'Contenido')
            (script:Nuevo 'C:\suelto.bin')
            (script:Nuevo 'C:\Otra' -Metodo 'Comando')
        )
        $r = Get-CambiosDeLimpieza -Candidatos $candidatos -RutasIndice $script:Rutas
        @($r.Cambios).Count | Should -BeGreaterThan 0 -Because 'si no sale ninguna baja, esta prueba no comprueba nada'

        foreach ($cambio in $r.Cambios) {
            $dentro = $false
            foreach ($raiz in $r.Raices) {
                if ($cambio.Ruta.Equals($raiz, [StringComparison]::OrdinalIgnoreCase) -or
                    $cambio.Ruta.StartsWith($raiz + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $dentro = $true; break
                }
            }
            $dentro | Should -BeTrue -Because "$($cambio.Ruta) no cuelga de ninguna ruta que se declarara borrada"
        }
    }

    It 'LA OTRA MITAD: nada que siga en el disco se da de baja' {
        # El reverso: se limpia una sola carpeta y todo lo que queda fuera
        # debe seguir en el índice. Recorre el índice entero.
        $r = Get-CambiosDeLimpieza -Candidatos @(script:Nuevo 'C:\Temp\sub' -Metodo 'Contenido') -RutasIndice $script:Rutas
        $dadasDeBaja = @($r.Cambios | ForEach-Object { $_.Ruta })
        $supervivientes = @($script:Rutas | Where-Object { $_ -notlike 'C:\Temp\sub*' })
        foreach ($viva in $supervivientes) {
            $dadasDeBaja | Should -Not -Contain $viva -Because "$viva sigue en el disco y el indice la estaria perdiendo"
        }
    }
}
