<#
    Pruebas de la validación de un índice guardado y de la aplicación de
    cambios sobre él. Un índice desfasado mostraría espacio que ya no existe,
    así que ante la duda se rechaza.

      1. Cada motivo de rechazo se comprueba por su código, y todos los casos
         parten de una cabecera que sí se acepta (hay una prueba que lo
         verifica): el rechazo solo puede venir del campo modificado.
      2. Lo que lee un It se construye en BeforeAll: el cuerpo de un Describe
         se evalúa en la fase de descubrimiento de Pester. Las tablas de
         -ForEach son literales.

    Las rutas se componen con Join-Path: Split-Path, del que depende la
    propagación, solo entiende el separador de su sistema.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
    # Se carga también de forma explícita; la ruta se usa en las invariantes de texto.
    $script:RutaFuente = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'IndiceIncremental.ps1'
    . $script:RutaFuente

    # --- Datos del disco actual, fijos para toda la suite -------------
    $script:VersionHoy = 3
    $script:SerieHoy   = 'A1B2-C3D4'
    $script:DiarioHoy  = '0x01d9f4a2b3c4d5e6'
    $script:PrimerUsn  = 1000
    $script:Ahora      = [datetime]'2026-09-01T12:00:00'

    function New-CabeceraDePrueba {
        <#
            Cabecera aceptada. Cada prueba de rechazo modifica un solo campo.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo compone un objeto en memoria.')]
        [CmdletBinding()]
        param()

        return [pscustomobject]@{
            Version      = $script:VersionHoy
            SerieVolumen = $script:SerieHoy
            IdDiario     = $script:DiarioHoy
            UsnCorte     = 250000
            Entradas     = 4
            Suma         = 'a1b2c3d4e5f6'
            Escrito      = $script:Ahora.AddDays(-1)
        }
    }

    function Test-CabeceraDePrueba {
        <#
            Llama a Test-IndiceUtilizable con los datos del disco actual.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [AllowNull()] $Cabecera,
            [AllowNull()] $EntradasLeidas = $null,
            [AllowNull()] $SumaCalculada  = $null
        )

        return Test-IndiceUtilizable -Cabecera $Cabecera `
                    -VersionEsperada $script:VersionHoy `
                    -SerieVolumen $script:SerieHoy `
                    -IdDiario $script:DiarioHoy `
                    -PrimerUsn $script:PrimerUsn `
                    -Ahora $script:Ahora `
                    -EntradasLeidas $EntradasLeidas `
                    -SumaCalculada $SumaCalculada
    }

    # --- El árbol de prueba -------------------------------------------
    #
    #   raiz/                 (nivel 0)
    #     rama/               (nivel 1)
    #       hoja/             (nivel 2)   sola.bin  1.000
    #     otra/               (nivel 1)   grande.bin 4.000 + chico.bin 500
    #
    # Dos ramas: al dejar una a cero, la otra debe conservar su valor.
    $script:RaizArbol = Join-Path ([IO.Path]::GetTempPath()) 'cachivache-indice-incremental'
    $script:Rama      = Join-Path $script:RaizArbol 'rama'
    $script:Hoja      = Join-Path $script:Rama      'hoja'
    $script:Otra      = Join-Path $script:RaizArbol 'otra'
    $script:Sola      = Join-Path $script:Hoja 'sola.bin'
    $script:Grande    = Join-Path $script:Otra 'grande.bin'
    $script:Chico     = Join-Path $script:Otra 'chico.bin'

    function New-IndiceDePrueba {
        <#
            El árbol anterior con los totales escritos a mano, no calculados
            por el código que se prueba.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Solo compone dos diccionarios en memoria.')]
        [CmdletBinding()]
        param()

        $carpetas = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $archivos = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)

        foreach ($par in @(
            @{ Ruta = $script:RaizArbol; Nivel = 0 }
            @{ Ruta = $script:Rama;      Nivel = 1 }
            @{ Ruta = $script:Hoja;      Nivel = 2 }
            @{ Ruta = $script:Otra;      Nivel = 1 }
        )) {
            $carpetas[$par.Ruta] = New-EntradaCarpeta -Ruta $par.Ruta -Nivel $par.Nivel
        }

        $archivos[$script:Sola]   = 1000.0
        $archivos[$script:Grande] = 4000.0
        $archivos[$script:Chico]  = 500.0

        $carpetas[$script:Hoja].Propios  = 1000.0
        $carpetas[$script:Hoja].Bytes    = 1000.0
        $carpetas[$script:Hoja].Archivos = 1

        $carpetas[$script:Rama].Bytes    = 1000.0
        $carpetas[$script:Rama].Archivos = 1

        $carpetas[$script:Otra].Propios  = 4500.0
        $carpetas[$script:Otra].Bytes    = 4500.0
        $carpetas[$script:Otra].Archivos = 2

        $carpetas[$script:RaizArbol].Bytes    = 5500.0
        $carpetas[$script:RaizArbol].Archivos = 3

        return [pscustomobject]@{
            Carpetas      = $carpetas
            Archivos      = $archivos
            Bytes         = 5500.0
            TotalArchivos = 3
        }
    }

    function Get-OraculoDeTotales {
        <#
            Oráculo: para cada carpeta, la suma de los archivos que cuelgan de
            ella, calculada desde cero sobre la tabla de archivos.

            Usa a propósito un algoritmo distinto y simple (prefijos de ruta,
            sin niveles ni cadenas de padres) para ser independiente de la
            propagación incremental.
        #>
        [CmdletBinding()]
        param([Parameter(Mandatory)] $Indice)

        $separador = [IO.Path]::DirectorySeparatorChar
        $oraculo = @{}

        foreach ($carpeta in @($Indice.Carpetas.Keys)) {
            $oraculo[$carpeta] = [pscustomobject]@{ Bytes = 0.0; Propios = 0.0; Archivos = 0 }
        }

        foreach ($ruta in @($Indice.Archivos.Keys)) {
            $bytes = [double]$Indice.Archivos[$ruta]
            $padre = [string](Split-Path $ruta -Parent)

            foreach ($carpeta in @($Indice.Carpetas.Keys)) {
                $prefijo = $carpeta.TrimEnd([char]'\', [char]'/') + $separador
                if ($ruta.StartsWith($prefijo, [StringComparison]::OrdinalIgnoreCase)) {
                    $oraculo[$carpeta].Bytes += $bytes
                    $oraculo[$carpeta].Archivos++
                }
                if ($padre.Equals($carpeta, [StringComparison]::OrdinalIgnoreCase)) {
                    $oraculo[$carpeta].Propios += $bytes
                }
            }
        }

        return $oraculo
    }

    function Get-DiferenciasConElOraculo {
        <#
            Carpetas cuyos totales no coinciden con el oráculo, identificadas
            por ruta.
        #>
        [CmdletBinding()]
        param([Parameter(Mandatory)] $Indice)

        $oraculo = Get-OraculoDeTotales -Indice $Indice
        $diferencias = [Collections.Generic.List[string]]::new()

        foreach ($carpeta in @($Indice.Carpetas.Keys)) {
            $tiene = $Indice.Carpetas[$carpeta]
            $debe  = $oraculo[$carpeta]
            if ([double]$tiene.Bytes -ne $debe.Bytes) {
                $diferencias.Add(('{0}: Bytes {1} y deberia ser {2}' -f $carpeta, $tiene.Bytes, $debe.Bytes))
            }
            if ([double]$tiene.Propios -ne $debe.Propios) {
                $diferencias.Add(('{0}: Propios {1} y deberia ser {2}' -f $carpeta, $tiene.Propios, $debe.Propios))
            }
            if ([int]$tiene.Archivos -ne $debe.Archivos) {
                $diferencias.Add(('{0}: Archivos {1} y deberia ser {2}' -f $carpeta, $tiene.Archivos, $debe.Archivos))
            }
        }

        return @($diferencias)
    }

    function Get-FuenteSinComentarios {
        <#
            El código de IndiceIncremental.ps1 sin comentarios, para que las
            búsquedas de texto no encuentren la documentación.

            Primero se quitan los bloques de comentario y después las líneas
            que empiezan por almohadilla; al revés, se perdería el cierre del
            bloque. (El cierre no se escribe aquí: dentro de un bloque lo cerraría.)
        #>
        [CmdletBinding()]
        param()

        $texto = [IO.File]::ReadAllText($script:RutaFuente)
        $texto = [regex]::Replace($texto, '(?s)<#.*?#>', ' ')
        $texto = [regex]::Replace($texto, '(?m)^\s*#.*$', ' ')
        return $texto
    }
}

Describe 'Get-CaducidadIndice' {

    It 'es un numero de dias positivo y razonable' {
        $dias = Get-CaducidadIndice
        $dias | Should -BeOfType ([int])
        $dias | Should -BeGreaterThan 0
        # Más de un mes: el diario USN habrá rotado varias veces.
        $dias | Should -BeLessOrEqual 31
    }

    It 'es la funcion la que manda: justo en el limite se acepta' {
        # El número se pide a la función, no se escribe aquí.
        $cabecera = New-CabeceraDePrueba
        $cabecera.Escrito = $script:Ahora.AddDays(-1 * (Get-CaducidadIndice))
        (Test-CabeceraDePrueba -Cabecera $cabecera).Utilizable | Should -BeTrue
    }

    It 'es la funcion la que manda: un dia mas y caduca' {
        $cabecera = New-CabeceraDePrueba
        $cabecera.Escrito = $script:Ahora.AddDays(-1 * ((Get-CaducidadIndice) + 1))
        $veredicto = Test-CabeceraDePrueba -Cabecera $cabecera
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be 'Caducado'
    }
}

Describe 'Test-IndiceUtilizable: la cabecera buena' {

    <#
        Control de todo el archivo: si la cabecera de partida no se aceptara,
        las pruebas de rechazo no comprobarían nada.
    #>

    It 'una cabecera que cuadra con el disco de hoy se acepta' {
        $veredicto = Test-CabeceraDePrueba -Cabecera (New-CabeceraDePrueba)
        $veredicto.Utilizable | Should -BeTrue
        $veredicto.Codigo     | Should -Be 'Utilizable'
        $veredicto.Motivo     | Should -BeNullOrEmpty
    }

    It 'se acepta tambien si el cuerpo leido cuadra con la cabecera' {
        $cabecera = New-CabeceraDePrueba
        $veredicto = Test-CabeceraDePrueba -Cabecera $cabecera `
                        -EntradasLeidas $cabecera.Entradas -SumaCalculada $cabecera.Suma
        $veredicto.Utilizable | Should -BeTrue
    }

    It 'una cabecera en tabla hash vale igual que en objeto' {
        # El lector del índice puede componerla de las dos formas.
        $veredicto = Test-CabeceraDePrueba -Cabecera @{
            Version      = $script:VersionHoy
            SerieVolumen = $script:SerieHoy
            IdDiario     = $script:DiarioHoy
            UsnCorte     = 250000
            Entradas     = 4
            Suma         = 'a1b2c3d4e5f6'
            Escrito      = $script:Ahora.AddDays(-1)
        }
        $veredicto.Utilizable | Should -BeTrue
    }

    It 'el corte justo en el primer USN disponible todavia vale' {
        # -lt y no -le: si el corte coincide con el primero disponible, no falta ningún registro.
        $cabecera = New-CabeceraDePrueba
        $cabecera.UsnCorte = $script:PrimerUsn
        (Test-CabeceraDePrueba -Cabecera $cabecera).Utilizable | Should -BeTrue
    }
}

Describe 'Test-IndiceUtilizable: cada mentira tiene su motivo, y es el suyo' {

    <#
        La tabla es literal porque se evalúa en el descubrimiento de Pester.
        Cada fila modifica un campo y exige un código concreto, no solo
        "Utilizable = falso".
    #>

    It 'con <Caso> el motivo es <Esperado>' -ForEach @(
        @{ Caso = 'otra version del formato';        Campo = 'Version';      Valor = 99;                     Esperado = 'VersionDistinta' }
        @{ Caso = 'otro numero de serie';            Campo = 'SerieVolumen'; Valor = 'FFFF-0000';            Esperado = 'VolumenDistinto' }
        @{ Caso = 'otro identificador de diario';    Campo = 'IdDiario';     Valor = '0x0000000000000001';   Esperado = 'DiarioDistinto' }
        @{ Caso = 'el diario dado la vuelta';        Campo = 'UsnCorte';     Valor = 1;                      Esperado = 'DiarioDioLaVuelta' }
        @{ Caso = 'la version a nulo';               Campo = 'Version';      Valor = $null;                  Esperado = 'CampoAusente' }
        @{ Caso = 'la suma vacia';                   Campo = 'Suma';         Valor = '';                     Esperado = 'CampoAusente' }
        @{ Caso = 'la suma en blancos';              Campo = 'Suma';         Valor = '   ';                  Esperado = 'CampoAusente' }
        @{ Caso = 'una version que no es un numero'; Campo = 'Version';      Valor = 'tres';                 Esperado = 'ValorImposible' }
        @{ Caso = 'un corte negativo';               Campo = 'UsnCorte';     Valor = -5;                     Esperado = 'ValorImposible' }
        @{ Caso = 'entradas negativas';              Campo = 'Entradas';     Valor = -1;                     Esperado = 'ValorImposible' }
        @{ Caso = 'una fecha sin escribir';          Campo = 'Escrito';      Valor = ([datetime]::MinValue); Esperado = 'ValorImposible' }
        @{ Caso = 'una fecha que no es fecha';       Campo = 'Escrito';      Valor = 'ayer por la tarde';    Esperado = 'ValorImposible' }
    ) {
        $cabecera = New-CabeceraDePrueba
        $cabecera.$Campo = $Valor

        $veredicto = Test-CabeceraDePrueba -Cabecera $cabecera
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be $Esperado -Because 'el motivo tiene que ser el suyo, no otro que tambien rechace'
        $veredicto.Motivo     | Should -Not -BeNullOrEmpty -Because 'un rechazo mudo es indistinguible de un fallo del programa'
    }

    It 'si falta el campo <Campo> se dice que falta' -ForEach @(
        @{ Campo = 'Version' }
        @{ Campo = 'SerieVolumen' }
        @{ Campo = 'IdDiario' }
        @{ Campo = 'UsnCorte' }
        @{ Campo = 'Entradas' }
        @{ Campo = 'Suma' }
        @{ Campo = 'Escrito' }
    ) {
        # El campo no es nulo sino inexistente (índice escrito sin conocerlo).
        $cabecera = @{
            Version      = $script:VersionHoy
            SerieVolumen = $script:SerieHoy
            IdDiario     = $script:DiarioHoy
            UsnCorte     = 250000
            Entradas     = 4
            Suma         = 'a1b2c3d4e5f6'
            Escrito      = $script:Ahora.AddDays(-1)
        }
        $cabecera.Remove($Campo)

        $veredicto = Test-CabeceraDePrueba -Cabecera $cabecera
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be 'CampoAusente'
        $veredicto.Motivo     | Should -Match $Campo
    }

    It 'sin cabecera no hay nada que creer' {
        $veredicto = Test-CabeceraDePrueba -Cabecera $null
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be 'CabeceraAusente'
    }

    It 'una fecha en el futuro no es una fecha' {
        $cabecera = New-CabeceraDePrueba
        $cabecera.Escrito = $script:Ahora.AddDays(2)
        $veredicto = Test-CabeceraDePrueba -Cabecera $cabecera
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be 'ValorImposible'
    }

    It 'un ajuste de reloj de unos segundos no tira un indice bueno' {
        # El margen evita que una sincronización de hora invalide el índice.
        $cabecera = New-CabeceraDePrueba
        $cabecera.Escrito = $script:Ahora.AddSeconds(3)
        (Test-CabeceraDePrueba -Cabecera $cabecera).Utilizable | Should -BeTrue
    }

    It 'un cuerpo con otro numero de entradas esta truncado' {
        $cabecera = New-CabeceraDePrueba
        $veredicto = Test-CabeceraDePrueba -Cabecera $cabecera -EntradasLeidas ($cabecera.Entradas - 1)
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be 'CuerpoNoCuadra'
    }

    It 'un cuerpo con otra suma de comprobacion esta alterado' {
        $veredicto = Test-CabeceraDePrueba -Cabecera (New-CabeceraDePrueba) -SumaCalculada 'ffffffffffff'
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be 'CuerpoNoCuadra'
    }

    It 'sin el dato del disco <Dato> no se puede contrastar nada' -ForEach @(
        @{ Dato = 'VersionEsperada' }
        @{ Dato = 'SerieVolumen' }
        @{ Dato = 'IdDiario' }
        @{ Dato = 'PrimerUsn' }
        @{ Dato = 'Ahora' }
    ) {
        # Un índice que no se puede contrastar no se usa.
        $argumentos = @{
            Cabecera        = New-CabeceraDePrueba
            VersionEsperada = $script:VersionHoy
            SerieVolumen    = $script:SerieHoy
            IdDiario        = $script:DiarioHoy
            PrimerUsn       = $script:PrimerUsn
            Ahora           = $script:Ahora
        }
        $argumentos[$Dato] = $null

        $veredicto = Test-IndiceUtilizable @argumentos
        $veredicto.Utilizable | Should -BeFalse
        $veredicto.Codigo     | Should -Be 'DatosDelDiscoNoValidos'
    }

    It 'con todo a nulo no revienta: contesta que no' {
        # Requiere [AllowNull()] en los parámetros Mandatory que puedan recibir nulo.
        { Test-IndiceUtilizable -Cabecera $null -VersionEsperada $null -SerieVolumen $null `
              -IdDiario $null -PrimerUsn $null -Ahora $null } | Should -Not -Throw

        $veredicto = Test-IndiceUtilizable -Cabecera $null -VersionEsperada $null -SerieVolumen $null `
                        -IdDiario $null -PrimerUsn $null -Ahora $null
        $veredicto.Utilizable | Should -BeFalse
    }

    It 'cada motivo se explica con palabras distintas' {
        # Cada código tiene su propia frase.
        $motivos = [Collections.Generic.List[string]]::new()
        foreach ($caso in @(
            @{ Campo = 'Version';      Valor = 99 }
            @{ Campo = 'SerieVolumen'; Valor = 'FFFF-0000' }
            @{ Campo = 'IdDiario';     Valor = '0x01' }
            @{ Campo = 'UsnCorte';     Valor = 1 }
            @{ Campo = 'Entradas';     Valor = -1 }
        )) {
            $cabecera = New-CabeceraDePrueba
            $cabecera.($caso.Campo) = $caso.Valor
            $motivos.Add((Test-CabeceraDePrueba -Cabecera $cabecera).Motivo)
        }

        @($motivos).Count | Should -Be 5 -Because 'si no hay cinco motivos, esta prueba no compara nada'
        @($motivos | Select-Object -Unique).Count | Should -Be 5
    }
}

Describe 'Update-IndiceConCambios: el indice de partida' {

    It 'cuadra con el oraculo antes de tocar nada' {
        # Control: el índice de partida y el oráculo coinciden.
        Get-DiferenciasConElOraculo -Indice (New-IndiceDePrueba) | Should -BeNullOrEmpty
    }
}

Describe 'Update-IndiceConCambios: altas, bajas y cambios' {

    It 'un alta suma en su carpeta y en todas las de encima' {
        $indice = New-IndiceDePrueba
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Alta'; Ruta = (Join-Path $script:Hoja 'nuevo.bin'); Bytes = 300 }
        )

        $resultado.Aplicados | Should -Be 1
        $resultado.Altas     | Should -Be 1
        $resultado.Confiable | Should -BeTrue

        $indice.Carpetas[$script:Hoja].Propios      | Should -Be 1300.0
        $indice.Carpetas[$script:Hoja].Bytes        | Should -Be 1300.0
        $indice.Carpetas[$script:Rama].Bytes        | Should -Be 1300.0
        $indice.Carpetas[$script:RaizArbol].Bytes   | Should -Be 5800.0
        $indice.Carpetas[$script:RaizArbol].Archivos | Should -Be 4
        $indice.Bytes | Should -Be 5800.0
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'una baja resta en su carpeta y en todas las de encima' {
        $indice = New-IndiceDePrueba
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Chico }
        )

        $resultado.Bajas     | Should -Be 1
        $resultado.Confiable | Should -BeTrue

        $indice.Carpetas[$script:Otra].Propios     | Should -Be 4000.0
        $indice.Carpetas[$script:Otra].Bytes       | Should -Be 4000.0
        $indice.Carpetas[$script:Otra].Archivos    | Should -Be 1
        $indice.Carpetas[$script:RaizArbol].Bytes  | Should -Be 5000.0
        $indice.Archivos.ContainsKey($script:Chico) | Should -BeFalse
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'una modificacion de tamaño sube la diferencia, no el tamaño entero' {
        $indice = New-IndiceDePrueba
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Cambio'; Ruta = $script:Grande; Bytes = 6000 }
        )

        $resultado.Modificados | Should -Be 1
        $resultado.Altas       | Should -Be 0

        # Sumar el tamaño entero daría 10.500 en vez de 6.500.
        $indice.Carpetas[$script:Otra].Bytes      | Should -Be 6500.0
        $indice.Carpetas[$script:Otra].Archivos   | Should -Be 2
        $indice.Carpetas[$script:RaizArbol].Bytes | Should -Be 7500.0
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'una modificacion que encoge tambien resta hacia arriba' {
        $indice = New-IndiceDePrueba
        $null = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Cambio'; Ruta = $script:Grande; Bytes = 100 }
        )

        $indice.Carpetas[$script:Otra].Bytes      | Should -Be 600.0
        $indice.Carpetas[$script:RaizArbol].Bytes | Should -Be 1600.0
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'la fecha de la carpeta sube con un archivo mas nuevo' {
        $indice = New-IndiceDePrueba
        $cuando = [datetime]'2026-08-30T10:00:00'
        $null = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Alta'; Ruta = (Join-Path $script:Hoja 'reciente.bin'); Bytes = 10; Ultimo = $cuando }
        )

        $indice.Carpetas[$script:Hoja].Ultimo      | Should -Be $cuando
        $indice.Carpetas[$script:RaizArbol].Ultimo | Should -Be $cuando
    }

    It 'un alta en una carpeta nueva la cuelga de la que si esta, con su nivel' {
        $indice = New-IndiceDePrueba
        $nueva  = Join-Path (Join-Path $script:Rama 'reciente') 'honda'
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Alta'; Ruta = (Join-Path $nueva 'x.bin'); Bytes = 700 }
        )

        $resultado.Aplicados | Should -Be 1
        $resultado.Confiable | Should -BeTrue
        $indice.Carpetas.ContainsKey($nueva) | Should -BeTrue
        # rama está en el nivel 1, así que reciente es 2 y honda es 3.
        $indice.Carpetas[$nueva].Nivel            | Should -Be 3
        $indice.Carpetas[$script:Rama].Bytes      | Should -Be 1700.0
        $indice.Carpetas[$script:RaizArbol].Bytes | Should -Be 6200.0
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'una tanda entera deja el indice cuadrado con el oraculo' {
        $indice = New-IndiceDePrueba
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Alta';   Ruta = (Join-Path $script:Hoja 'a.bin'); Bytes = 111 }
            [pscustomobject]@{ Tipo = 'Cambio'; Ruta = $script:Grande;                   Bytes = 2222 }
            [pscustomobject]@{ Tipo = 'Baja';   Ruta = $script:Chico }
            [pscustomobject]@{ Tipo = 'Alta';   Ruta = (Join-Path $script:Otra 'b.bin'); Bytes = 33 }
            [pscustomobject]@{ Tipo = 'Baja';   Ruta = $script:Sola }
        )

        $resultado.Aplicados   | Should -Be 5
        $resultado.Confiable   | Should -BeTrue
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }
}

Describe 'Update-IndiceConCambios: el espacio que ya no esta tiene que desaparecer del mapa' {

    <#
        Si la propagación no resta, el mapa muestra espacio que ya no existe.
    #>

    It 'una baja que deja la carpeta a cero deja su total a cero' {
        $indice = New-IndiceDePrueba
        $null = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Sola }
        )

        $indice.Carpetas[$script:Hoja].Propios  | Should -Be 0.0
        $indice.Carpetas[$script:Hoja].Bytes    | Should -Be 0.0
        $indice.Carpetas[$script:Hoja].Archivos | Should -Be 0
    }

    It 'y el cero sube por toda la cadena hasta la raiz' {
        $indice = New-IndiceDePrueba
        $null = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Sola }
        )

        # rama no tenia archivos propios: todo lo suyo era de hoja.
        $indice.Carpetas[$script:Rama].Bytes    | Should -Be 0.0
        $indice.Carpetas[$script:Rama].Archivos | Should -Be 0
        # La raíz pierde exactamente esos 1.000 bytes.
        $indice.Carpetas[$script:RaizArbol].Bytes | Should -Be 4500.0
        $indice.Bytes | Should -Be 4500.0
    }

    It 'la otra rama sigue valiendo lo mismo' {
        # Control: poner todo a cero también pasaría la prueba anterior.
        $indice = New-IndiceDePrueba
        $null = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Sola }
        )

        $indice.Carpetas[$script:Otra].Bytes    | Should -Be 4500.0
        $indice.Carpetas[$script:Otra].Archivos | Should -Be 2
    }

    It 'quitandolo todo, el indice entero vale cero' {
        $indice = New-IndiceDePrueba
        $null = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Sola }
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Grande }
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Chico }
        )

        foreach ($carpeta in @($indice.Carpetas.Keys)) {
            $indice.Carpetas[$carpeta].Bytes    | Should -Be 0.0
            $indice.Carpetas[$carpeta].Propios  | Should -Be 0.0
            $indice.Carpetas[$carpeta].Archivos | Should -Be 0
        }
        $indice.Bytes         | Should -Be 0.0
        $indice.TotalArchivos | Should -Be 0
        @($indice.Archivos.Keys).Count | Should -Be 0
    }
}

Describe 'Update-IndiceConCambios: no revienta con nada' {

    It 'con una lista vacia no hace nada y no protesta' {
        $indice = New-IndiceDePrueba
        { Update-IndiceConCambios -Indice (New-IndiceDePrueba) -Cambios @() } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @()

        $resultado.Aplicados   | Should -Be 0
        $resultado.Descartados | Should -Be 0
        $resultado.Confiable   | Should -BeTrue -Because 'que no haya cambiado nada no es motivo para desconfiar'
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'con la lista a nulo tampoco' {
        $indice = New-IndiceDePrueba
        { Update-IndiceConCambios -Indice (New-IndiceDePrueba) -Cambios $null } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios $null

        # @($null) es una lista con un nulo, no vacía: no debe contarse como
        # un cambio perdido.
        $resultado.Aplicados   | Should -Be 0
        $resultado.Descartados | Should -Be 0
        $resultado.Confiable   | Should -BeTrue
    }

    It 'con nulos dentro de la lista los descarta y lo dice' {
        $indice = New-IndiceDePrueba
        { Update-IndiceConCambios -Indice (New-IndiceDePrueba) -Cambios @($null, $null) } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @($null, $null)

        $resultado.Descartados | Should -Be 2
        $resultado.Confiable   | Should -BeFalse -Because 'un indice al que se le han caido cambios puede estar mintiendo'
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'con el indice a nulo no revienta y no se fia' {
        $cambios = @([pscustomobject]@{ Tipo = 'Alta'; Ruta = 'x'; Bytes = 1 })
        { Update-IndiceConCambios -Indice $null -Cambios $cambios } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $null -Cambios $cambios

        $resultado.Confiable | Should -BeFalse
        $resultado.Aplicados | Should -Be 0
        $resultado.Motivo    | Should -Not -BeNullOrEmpty
    }

    It 'con un indice sin las dos tablas no aplica nada' {
        # Sin la tabla de carpetas habría que volver a sumar todas las entradas,
        # lo que cuesta más que recorrer el disco.
        $medias  = [pscustomobject]@{ Archivos = @{}; Carpetas = $null }
        $cambios = @([pscustomobject]@{ Tipo = 'Alta'; Ruta = 'x'; Bytes = 1 })
        { Update-IndiceConCambios -Indice $medias -Cambios $cambios } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $medias -Cambios $cambios

        $resultado.Confiable   | Should -BeFalse
        $resultado.Descartados | Should -Be 1
    }

    It 'una baja de algo que no existia no es un fallo' {
        $indice  = New-IndiceDePrueba
        $cambios = @([pscustomobject]@{ Tipo = 'Baja'; Ruta = (Join-Path $script:Hoja 'jamas.bin') })
        { Update-IndiceConCambios -Indice (New-IndiceDePrueba) -Cambios $cambios } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios $cambios

        # El archivo pudo crearse y borrarse entre dos pasadas.
        $resultado.Ignorados   | Should -Be 1
        $resultado.Descartados | Should -Be 0
        $resultado.Confiable   | Should -BeTrue
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'un cambio sobre una carpeta que ya no esta se descarta ENTERO' {
        $indice = New-IndiceDePrueba
        $forastero = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'otro-arbol-distinto') 'z.bin'

        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Alta'; Ruta = $forastero; Bytes = 900 })

        $resultado.Descartados | Should -Be 1
        $resultado.Confiable   | Should -BeFalse
        # Nunca medio cambio: las dos tablas deben quedar coherentes.
        $indice.Archivos.ContainsKey($forastero) | Should -BeFalse
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'una baja sin carpeta conocida no quita el archivo de la tabla' {
        # Quitar el archivo sin corregir su carpeta dejaría espacio fantasma.
        $indice = New-IndiceDePrueba
        $suelto = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'arbol-que-no-esta') 'y.bin'
        $indice.Archivos[$suelto] = 50.0

        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $suelto })

        $resultado.Descartados | Should -Be 1
        $resultado.Confiable   | Should -BeFalse
        $indice.Archivos.ContainsKey($suelto) | Should -BeTrue
    }

    It 'un cambio con <Caso> se descarta sin tocar el indice' -ForEach @(
        @{ Caso = 'un tipo que no existe'; Tipo = 'Renombrado'; Bytes = 10 }
        @{ Caso = 'el tipo vacio';         Tipo = '';           Bytes = 10 }
        @{ Caso = 'un tamaño negativo';    Tipo = 'Alta';       Bytes = -10 }
        @{ Caso = 'un tamaño que no es un número'; Tipo = 'Alta'; Bytes = 'mucho' }
        @{ Caso = 'un tamaño a nulo';      Tipo = 'Alta';       Bytes = $null }
    ) {
        $indice  = New-IndiceDePrueba
        $cambios = @([pscustomobject]@{ Tipo = $Tipo; Ruta = (Join-Path $script:Hoja 'raro.bin'); Bytes = $Bytes })
        { Update-IndiceConCambios -Indice (New-IndiceDePrueba) -Cambios $cambios } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios $cambios

        $resultado.Aplicados   | Should -Be 0
        $resultado.Descartados | Should -Be 1
        $resultado.Confiable   | Should -BeFalse
        Get-DiferenciasConElOraculo -Indice $indice | Should -BeNullOrEmpty
    }

    It 'un cambio sin ruta se descarta' {
        $indice  = New-IndiceDePrueba
        $cambios = @([pscustomobject]@{ Tipo = 'Alta'; Ruta = $null; Bytes = 10 })
        { Update-IndiceConCambios -Indice (New-IndiceDePrueba) -Cambios $cambios } | Should -Not -Throw
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios $cambios

        $resultado.Descartados | Should -Be 1
        $resultado.Confiable   | Should -BeFalse
    }

    It 'el tipo vale igual en mayusculas' {
        $indice = New-IndiceDePrueba
        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'BAJA'; Ruta = $script:Chico })

        $resultado.Bajas | Should -Be 1
    }

    It 'un total que saldria negativo se recorta a cero y se cuenta' {
        # Un índice ya descuadrado no puede mostrar tamaños negativos. Se
        # recorta a cero y se contabiliza, no en silencio.
        $indice = New-IndiceDePrueba
        $indice.Carpetas[$script:Otra].Propios = 0.0
        $indice.Carpetas[$script:Otra].Bytes   = 0.0

        $resultado = Update-IndiceConCambios -Indice $indice -Cambios @(
            [pscustomobject]@{ Tipo = 'Baja'; Ruta = $script:Grande })

        $indice.Carpetas[$script:Otra].Bytes   | Should -Be 0.0
        $indice.Carpetas[$script:Otra].Propios | Should -Be 0.0
        $resultado.Recortes | Should -BeGreaterThan 0
        $resultado.Confiable | Should -BeFalse
    }
}

Describe 'ConvertTo-NumeroIndice y Resolve-CarpetaIndice: las dos piezas de abajo' {

    It 'un numero escrito como texto se lee' {
        ConvertTo-NumeroIndice -Valor ' 4200 ' | Should -Be 4200
    }

    It 'no se redondea un numero con decimales: se rechaza' {
        # El cast de PowerShell redondearía a 4.
        ConvertTo-NumeroIndice -Valor '3.7' | Should -BeNullOrEmpty
        ConvertTo-NumeroIndice -Valor 3.7   | Should -BeNullOrEmpty
    }

    It 'un booleano no es un numero' {
        # [long]$true vale 1 sin error.
        ConvertTo-NumeroIndice -Valor $true | Should -BeNullOrEmpty
    }

    It 'lo que no es un numero devuelve nulo en vez de lanzar' -ForEach @(
        @{ Valor = $null }
        @{ Valor = '' }
        @{ Valor = '   ' }
        @{ Valor = 'catorce' }
    ) {
        { ConvertTo-NumeroIndice -Valor $Valor } | Should -Not -Throw
        ConvertTo-NumeroIndice -Valor $Valor | Should -BeNullOrEmpty
    }

    It 'Resolve-CarpetaIndice no inventa una carpeta que no cuelga de nada' {
        $indice = New-IndiceDePrueba
        $lejos  = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'ni-de-lejos') 'aqui'
        Resolve-CarpetaIndice -Carpetas $indice.Carpetas -Ruta $lejos -Crear | Should -BeNullOrEmpty
        $indice.Carpetas.ContainsKey($lejos) | Should -BeFalse
    }

    It 'Resolve-CarpetaIndice sin -Crear no crea nada' {
        $indice = New-IndiceDePrueba
        $nueva  = Join-Path $script:Rama 'todavia-no'
        Resolve-CarpetaIndice -Carpetas $indice.Carpetas -Ruta $nueva | Should -BeNullOrEmpty
        $indice.Carpetas.ContainsKey($nueva) | Should -BeFalse
    }

    It 'Resolve-CarpetaIndice y Update-CadenaCarpetas aguantan nulos' {
        { Resolve-CarpetaIndice -Carpetas $null -Ruta $null } | Should -Not -Throw
        { Update-CadenaCarpetas -Carpetas $null -Ruta $null }  | Should -Not -Throw
        Update-CadenaCarpetas -Carpetas $null -Ruta $null | Should -Be 0
    }

    It 'Update-CadenaCarpetas no se pierde con un antepasado que falta' {
        # La cadena no se corta: el total del abuelo sí contiene ese archivo.
        $indice = New-IndiceDePrueba
        $null = $indice.Carpetas.Remove($script:Rama)

        $null = Update-CadenaCarpetas -Carpetas $indice.Carpetas -Ruta $script:Hoja -DeltaBytes -1000.0
        $indice.Carpetas[$script:RaizArbol].Bytes | Should -Be 4500.0
    }
}

Describe 'El indice guardado pinta el mapa; no decide que se borra' {

    <#
        Decisión de diseño: Cachivache solo borra a partir de lo analizado en
        la ejecución actual. Si el índice se equivoca, el peor caso es un
        rectángulo mal dibujado, nunca un archivo borrado por error.
    #>

    BeforeAll {
        $script:Fuente = Get-FuenteSinComentarios
        $script:Funciones = @([regex]::Matches($script:Fuente, '(?m)^function\s+([A-Za-z]+-[A-Za-z0-9]+)') |
                              ForEach-Object { $_.Groups[1].Value })
    }

    It 'la prueba encuentra las funciones: si no, no comprueba nada' {
        @($script:Funciones).Count | Should -BeGreaterOrEqual 5
    }

    It 'quitar los comentarios deja codigo, no un archivo vacio' {
        # Control: el código no puede quedar vacío tras quitar comentarios.
        $script:Fuente | Should -Match 'Test-IndiceUtilizable'
        $script:Fuente.Length | Should -BeGreaterThan 2000
    }

    It 'ninguna funcion suena a decidir que se borra' {
        @($script:Funciones | Where-Object { $_ -match 'Candidat|Borr|Elimin|Limpi' }) | Should -BeNullOrEmpty
    }

    It 'el codigo no nombra el contrato de candidato ni el motor de borrado' {
        # El archivo no conoce el contrato de candidato ni las funciones de borrado.
        foreach ($prohibido in @('Candidato', 'Remove-RutaSegura', 'Invoke-EliminacionCandidato',
                                 'New-Candidato', 'Get-MotivoNoSeBorra')) {
            $script:Fuente | Should -Not -Match $prohibido
        }
    }

    It 'lo que se devuelve son numeros y veredictos, no rutas para actuar' {
        # El veredicto no lleva rutas: solo indica si el índice es fiable.
        $veredicto = Test-CabeceraDePrueba -Cabecera (New-CabeceraDePrueba)
        @($veredicto.PSObject.Properties.Name | Sort-Object) | Should -Be @('Codigo', 'Motivo', 'Utilizable')
    }
}
