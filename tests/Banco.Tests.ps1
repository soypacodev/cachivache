<#
    Las decisiones del banco de pruebas.

    Se prueba Banco-Decisiones.ps1, no Banco-Pruebas.ps1: el segundo crea y
    borra archivos, y cargarlo con dot-source sería ejecutarlo.

    Test-DentroDeRaiz es lo único que impide que -Quitar borre fuera del
    banco (por ejemplo, la carpeta Documentos entera).
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:Raiz 'tools') 'Banco-Decisiones.ps1')

    # La guardia real, para comprobar que ningún cebo es invisible para el programa.
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Texto.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'FileSystem.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Guard.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Candidate.ps1')

    $script:Banco = 'C:\Users\quien\Documents\Banco-Cachivache'

    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio = 'C:\Users\quien\Desktop'
        Documentos = 'C:\Users\quien\Documents'
        Descargas  = 'C:\Users\quien\Downloads'
        Imagenes   = 'C:\Users\quien\Pictures'
        Musica     = 'C:\Users\quien\Music'
        Videos     = 'C:\Users\quien\Videos'
        CarpetaDatos = 'C:\Users\quien\AppData\Local\Cachivache'
    })
}

Describe 'Test-DentroDeRaiz: lo que impide que el banco borre fuera de si mismo' {

    It 'la propia raiz esta dentro' {
        Test-DentroDeRaiz -Ruta $script:Banco -Raiz $script:Banco | Should -BeTrue
    }

    It 'algo debajo esta dentro' {
        Test-DentroDeRaiz -Ruta "$script:Banco\01-temporales\uno.bak" -Raiz $script:Banco | Should -BeTrue
    }

    It 'la carpeta de encima NO esta dentro' {
        Test-DentroDeRaiz -Ruta 'C:\Users\quien\Documents' -Raiz $script:Banco | Should -BeFalse
    }

    It 'una carpeta hermana con el mismo principio NO esta dentro' {
        # Error clásico de comparar por prefijo.
        Test-DentroDeRaiz -Ruta 'C:\Users\quien\Documents\Banco-Cachivache-2\algo.txt' `
                          -Raiz $script:Banco | Should -BeFalse
        Test-DentroDeRaiz -Ruta 'C:\Users\quien\Documents\Banco-CachivacheViejo' `
                          -Raiz $script:Banco | Should -BeFalse
    }

    It 'otra unidad NO esta dentro' {
        Test-DentroDeRaiz -Ruta 'D:\Banco-Cachivache\algo.bak' -Raiz $script:Banco | Should -BeFalse
    }

    It 'las mayusculas no cambian el veredicto' {
        # Las rutas de Windows no distinguen mayúsculas.
        Test-DentroDeRaiz -Ruta 'C:\USERS\QUIEN\DOCUMENTS\BANCO-CACHIVACHE\uno.bak' `
                          -Raiz $script:Banco | Should -BeTrue
    }

    It 'el prefijo de ruta larga no cambia el veredicto' {
        # El banco crea la ruta larga con \\?\; sin normalizarlo parecería
        # estar fuera de su propia raíz.
        Test-DentroDeRaiz -Ruta "\\?\$script:Banco\02-ruta-larga\x.bak" -Raiz $script:Banco |
            Should -BeTrue
        Test-DentroDeRaiz -Ruta "$script:Banco\02-ruta-larga\x.bak" -Raiz "\\?\$script:Banco" |
            Should -BeTrue
    }

    It 'una barra final no cambia el veredicto' {
        Test-DentroDeRaiz -Ruta "$script:Banco\uno.bak" -Raiz "$script:Banco\" | Should -BeTrue
    }

    It 'con nulo o vacio dice que NO, y no lanza' {
        # Si un nulo diera "sí", el borrado seguiría.
        { Test-DentroDeRaiz -Ruta $null -Raiz $script:Banco } | Should -Not -Throw
        Test-DentroDeRaiz -Ruta $null -Raiz $script:Banco | Should -BeFalse
        Test-DentroDeRaiz -Ruta "$script:Banco\uno.bak" -Raiz $null | Should -BeFalse
        Test-DentroDeRaiz -Ruta '' -Raiz '' | Should -BeFalse
        Test-DentroDeRaiz -Ruta 'C:\lo-que-sea' -Raiz '   ' | Should -BeFalse
    }

    It 'una raiz que se queda en nada tras normalizar dice que NO' {
        # "\" recortado no es una raíz sino la unidad entera.
        Test-DentroDeRaiz -Ruta 'C:\Users\quien\algo' -Raiz '\' | Should -BeFalse
    }
}

Describe 'Get-MotivoNoQuitarBanco: los tres candados del borrado' {

    It 'con la raiz correcta y existiendo, no hay motivo' {
        Get-MotivoNoQuitarBanco -Raiz $script:Banco -Existe | Should -BeNullOrEmpty
    }

    It 'si la ruta no termina en el nombre del banco, se para' {
        # Por ejemplo, si el cálculo de la ruta acaba en Documentos.
        $motivo = Get-MotivoNoQuitarBanco -Raiz 'C:\Users\quien\Documents' -Existe
        $motivo | Should -Not -BeNullOrEmpty
        $motivo | Should -Match 'No se borra nada'
    }

    It 'si esta demasiado arriba, se para' -ForEach @(
        @{ Ruta = 'C:\' }, @{ Ruta = 'C:\Banco-Cachivache' }, @{ Ruta = '\' }
    ) {
        Get-MotivoNoQuitarBanco -Raiz $Ruta -Existe | Should -Not -BeNullOrEmpty
    }

    It 'si no existe, lo dice en vez de callarse' {
        Get-MotivoNoQuitarBanco -Raiz $script:Banco | Should -Match 'No hay ningun banco'
    }

    It 'con nulo o vacio se para, y no lanza' {
        { Get-MotivoNoQuitarBanco -Raiz $null -Existe } | Should -Not -Throw
        Get-MotivoNoQuitarBanco -Raiz $null -Existe | Should -Not -BeNullOrEmpty
        Get-MotivoNoQuitarBanco -Raiz '' -Existe    | Should -Not -BeNullOrEmpty
    }

    It 'el prefijo de ruta larga no despista al candado' {
        Get-MotivoNoQuitarBanco -Raiz "\\?\$script:Banco" -Existe | Should -BeNullOrEmpty
    }
}

Describe 'Get-MotivoNoMontarBanco: la red antes de crear nada' {

    It 'en una VM y con la carpeta libre, adelante' {
        Get-MotivoNoMontarBanco -PareceVirtual | Should -BeNullOrEmpty
    }

    It 'fuera de una VM se para y explica por que' {
        $motivo = Get-MotivoNoMontarBanco
        $motivo | Should -Match 'maquina virtual'
        $motivo | Should -Match 'AunqueNoSeaVirtual' -Because 'un "no" sin salida solo enseña a buscar rodeos'
    }

    It 'fuera de una VM pero forzado, adelante' {
        Get-MotivoNoMontarBanco -Forzado | Should -BeNullOrEmpty
    }

    It 'con un banco ya montado se para' {
        Get-MotivoNoMontarBanco -PareceVirtual -RaizOcupada | Should -Match 'Quitalo primero'
    }

    It 'si no es una VM Y ademas hay banco, manda el motivo de la VM' {
        # El primer motivo es el más grave: "no es una VM" pesa más que "ya hay una carpeta".
        Get-MotivoNoMontarBanco -RaizOcupada | Should -Match 'maquina virtual'
    }
}

Describe 'Test-PareceMaquinaVirtual' {

    It 'reconoce <Fabricante> / <Modelo>' -ForEach @(
        @{ Fabricante = 'innotek GmbH';          Modelo = 'VirtualBox' }
        @{ Fabricante = 'VMware, Inc.';          Modelo = 'VMware Virtual Platform' }
        @{ Fabricante = 'Microsoft Corporation'; Modelo = 'Virtual Machine' }
        @{ Fabricante = 'QEMU';                  Modelo = 'Standard PC' }
        @{ Fabricante = 'Parallels Software';    Modelo = 'Parallels Virtual Platform' }
    ) {
        Test-PareceMaquinaVirtual -Fabricante $Fabricante -Modelo $Modelo | Should -BeTrue
    }

    It 'un portatil normal no lo parece' {
        Test-PareceMaquinaVirtual -Fabricante 'LENOVO' -Modelo '20XW00ABSP' | Should -BeFalse
        Test-PareceMaquinaVirtual -Fabricante 'ASUSTeK COMPUTER INC.' -Modelo 'ROG Strix' | Should -BeFalse
    }

    It 'sin datos dice que NO' {
        # Sin datos no se puede afirmar: la red se cierra.
        Test-PareceMaquinaVirtual -Fabricante '' -Modelo ''     | Should -BeFalse
        Test-PareceMaquinaVirtual -Fabricante $null -Modelo $null | Should -BeFalse
    }

    It 'no lanza con nulos' {
        { Test-PareceMaquinaVirtual -Fabricante $null -Modelo $null } | Should -Not -Throw
    }
}

Describe 'Get-RutaRaizBanco' {

    It 'cuelga el banco de Documentos' {
        Get-RutaRaizBanco -Documentos 'C:\Users\quien\Documents' |
            Should -BeExactly 'C:\Users\quien\Documents\Banco-Cachivache'
    }

    It 'una barra final no cambia nada' {
        Get-RutaRaizBanco -Documentos 'C:\Users\quien\Documents\' |
            Should -BeExactly 'C:\Users\quien\Documents\Banco-Cachivache'
    }

    It 'sin Documentos devuelve vacio en vez de componer una ruta absurda' {
        # "\Banco-Cachivache" apuntaría a la raíz del disco. Get-MotivoNoQuitarBanco
        # también lo para, pero la primera defensa es no componer la ruta.
        Get-RutaRaizBanco -Documentos ''    | Should -BeNullOrEmpty
        Get-RutaRaizBanco -Documentos $null | Should -BeNullOrEmpty
    }

    It 'no lanza con nulo' {
        { Get-RutaRaizBanco -Documentos $null } | Should -Not -Throw
    }
}

# =====================================================================
#  Catálogo de cebos
# =====================================================================

Describe 'Get-CebosBanco: el catalogo' {

    BeforeAll {
        $script:Cebos = @(Get-CebosBanco -ArchivosDeSobra 300)
    }

    It 'la prueba tiene cebos que mirar: si no, no comprueba nada' {
        $script:Cebos.Count | Should -BeGreaterThan 5
    }

    It 'todos los identificadores son unicos' {
        # Son la clave de cruce del catálogo y aparecen en los mensajes de la CI.
        @($script:Cebos | ForEach-Object { $_.Id } | Select-Object -Unique).Count |
            Should -Be $script:Cebos.Count
    }

    It 'toda entrada trae los campos completos' {
        # En PowerShell leer una propiedad inexistente no lanza: un campo
        # olvidado daría $null en silencio.
        $campos = @('Id', 'Carpeta', 'Patron', 'Cuantos', 'KiloBytes', 'Relleno',
                    'EsCarpeta', 'EnlaceA', 'SubCarpetas', 'PatronSubCarpeta',
                    'Premarcado', 'EnAnalisis', 'EnLimpieza', 'MotivoFuera', 'Para')
        foreach ($cebo in $script:Cebos) {
            foreach ($campo in $campos) {
                $cebo.PSObject.Properties[$campo] | Should -Not -BeNullOrEmpty `
                    -Because "al cebo '$($cebo.Id)' le falta el campo $campo"
            }
        }
    }

    It 'todo cebo dice para que existe' {
        foreach ($cebo in $script:Cebos) {
            $cebo.Para | Should -Not -BeNullOrEmpty -Because "el cebo '$($cebo.Id)' no dice a que afirmacion sirve"
        }
    }

    It 'un cebo que NO se espera en el analisis o en la limpieza tiene que decir por que' {
        # EnAnalisis/EnLimpieza = $false desactivan una comprobación de la CI;
        # se exige el motivo por escrito para poder revisarlo.
        $sinMotivo = @($script:Cebos | Where-Object {
            (-not $_.EnAnalisis -or -not $_.EnLimpieza) -and [string]::IsNullOrWhiteSpace($_.MotivoFuera)
        })
        $sinMotivo | Should -BeNullOrEmpty
    }

    It 'el cebo de ruta larga SI se espera en el analisis' {
        # Los módulos recorren rutas de más de 260 caracteres.
        $larga = $script:Cebos | Where-Object { $_.Id -eq 'ruta-larga' }
        $larga             | Should -Not -BeNullOrEmpty
        $larga.EnAnalisis  | Should -BeTrue
        $larga.SubCarpetas | Should -BeGreaterThan 10 -Because 'sin las carpetas anidadas la ruta no es larga'
    }

    It 'el cebo de ruta larga NO se espera que desaparezca en la limpieza real' {
        # La fase windows ya lo borra antes del inventario previo, y la
        # papelera no admite rutas de más de 260 caracteres.
        $larga = $script:Cebos | Where-Object { $_.Id -eq 'ruta-larga' }
        $larga.EnLimpieza  | Should -BeFalse
        $larga.MotivoFuera | Should -Match 'papelera'
    }

    It 'el cebo comprimido existe, es grande y dice que hay que comprimirlo a mano' {
        # Es el único cebo que el guion no deja listo: "compact /C" solo existe
        # en Windows sobre NTFS. Sin la instrucción, el paso de comprobación
        # compararía dos cifras iguales sin haber comprimido nada.
        $comprimido = $script:Cebos | Where-Object { $_.Id -eq 'comprimido' }
        $comprimido | Should -Not -BeNullOrEmpty

        # 100 MB: un cebo pequeño no distinguiría una compresión de un redondeo.
        $comprimido.KiloBytes | Should -Be 102400
        $comprimido.Para      | Should -Match 'compact'
        $comprimido.Para      | Should -Match 'BANCO-PRUEBAS'

        # Sin comprimir es un .dmp más, y la CI lo trata como a cualquier otro.
        $comprimido.EnAnalisis | Should -BeTrue
        $comprimido.EnLimpieza | Should -BeTrue
    }

    It 'el numero de archivos de relleno es el que se pide' {
        $relleno = $script:Cebos | Where-Object { $_.Id -eq 'relleno' }
        $relleno.Cuantos | Should -Be 300
        (@(Get-CebosBanco -ArchivosDeSobra 0) | Where-Object { $_.Id -eq 'relleno' }).Cuantos | Should -Be 0
    }

    It 'un enlace duro apunta a otro cebo de su misma carpeta' {
        # Un destino inexistente haría fallar New-Item -ItemType HardLink, y
        # uno de otra carpeta no mediría lo que el cebo pretende medir.
        foreach ($cebo in @($script:Cebos | Where-Object { $_.EnlaceA })) {
            $destino = @($script:Cebos | Where-Object {
                $_.Carpeta -eq $cebo.Carpeta -and $_.Patron -eq $cebo.EnlaceA
            })
            $destino.Count | Should -Be 1 -Because "'$($cebo.Id)' enlaza a '$($cebo.EnlaceA)'"
        }
    }

    It 'el enlace duro se monta DESPUES de su destino' {
        # New-BancoPruebas recorre el catálogo en orden.
        $ids = @($script:Cebos | ForEach-Object { $_.Id })
        foreach ($cebo in @($script:Cebos | Where-Object { $_.EnlaceA })) {
            $destino = @($script:Cebos | Where-Object { $_.Patron -eq $cebo.EnlaceA })[0]
            $ids.IndexOf($destino.Id) | Should -BeLessThan $ids.IndexOf($cebo.Id)
        }
    }
}

Describe 'INVARIANTE: ningun cebo puede ser invisible para el analisis' {
    <#
        Un cebo cuyo nombre empieza por una palabra de Test-ArchivoPersonal
        ("copia", "documento") queda protegido por la guardia y ningún módulo
        lo propone, sin error ni aviso. Se consulta la guardia real de
        src/Core/Guard.ps1, no una copia de sus reglas.

        El bucle va dentro de un solo It y no en un -ForEach: -ForEach se
        evalúa en la fase de descubrimiento de Pester, antes de BeforeAll, y
        con el catálogo aún sin cargar generaría cero casos sin fallar.
    #>

    BeforeAll {
        $script:CebosVisibles = @(Get-CebosBanco -ArchivosDeSobra 3 | Where-Object { -not $_.EsCarpeta })
    }

    It 'hay cebos que mirar y la guardia esta lista: si no, esto no comprueba nada' {
        $script:CebosVisibles.Count | Should -BeGreaterThan 5
        Test-GuardiaLista | Should -BeTrue
        # Control: la guardia debe reconocer como personal un nombre que sí lo es.
        Test-ArchivoPersonal 'C:\Users\quien\Documents\copia-enorme.bak' | Should -BeTrue
    }

    It 'la guardia no confunde ningun cebo con trabajo del usuario' {
        $invisibles = @()
        foreach ($cebo in $script:CebosVisibles) {
            $ruta = Get-RutaCebo -Cebo $cebo -Raiz $script:Banco -Indice 1
            if (Test-ArchivoPersonal $ruta) { $invisibles += ('{0}: {1}' -f $cebo.Id, $cebo.Patron) }
        }
        $invisibles | Should -BeNullOrEmpty -Because (
            'si la guardia lo da por personal, Test-RutaSegura lo rechaza y NINGUN modulo lo propone: ' +
            'ese cebo no se puede comprobar ni en la maquina virtual ni en la integracion continua')
    }
}

Describe 'INVARIANTE: el premarcado del catalogo es el que decide el programa' {
    <#
        "-Consola -Ejecutar" borra lo que Test-DebeVenirMarcado marca, y la CI
        usa el campo Premarcado del catálogo para saber qué debe desaparecer
        tras una limpieza real. Ambos deben coincidir.

        50-Temporales asigna riesgo por extensión: .bak y .old son Medio y el
        resto Bajo. Los cebos tienen 400 días, así que nunca llevan el aviso
        de "creado hace menos de una semana".
    #>

    BeforeAll {
        $script:CebosArchivo = @(Get-CebosBanco -ArchivosDeSobra 3 | Where-Object { -not $_.EsCarpeta })
    }

    It 'hay cebos de las dos clases: si no, esto no comprueba nada' {
        # Con todos del mismo lado, la comparación no distinguiría nada.
        $script:CebosArchivo.Count | Should -BeGreaterThan 5
        @($script:CebosArchivo | Where-Object { $_.Premarcado }).Count      | Should -BeGreaterThan 0
        @($script:CebosArchivo | Where-Object { -not $_.Premarcado }).Count | Should -BeGreaterThan 0
    }

    It 'el catalogo y Test-DebeVenirMarcado dicen lo mismo de cada cebo' {
        $discrepan = @()
        foreach ($cebo in $script:CebosArchivo) {
            $extension = [IO.Path]::GetExtension($cebo.Patron).ToLowerInvariant()
            $riesgo = if ($extension -eq '.bak' -or $extension -eq '.old') { 'Medio' } else { 'Bajo' }
            $marca  = Test-DebeVenirMarcado -Riesgo $riesgo -Aviso '' -Metodo 'Ruta'

            if ($marca -ne [bool]$cebo.Premarcado) {
                $discrepan += ('{0} ({1}, riesgo {2}): el catalogo dice Premarcado={3} y el programa dice {4}' -f
                               $cebo.Id, $cebo.Patron, $riesgo, $cebo.Premarcado, $marca)
            }
        }
        $discrepan | Should -BeNullOrEmpty -Because (
            'la integracion continua da por hecho el campo Premarcado para saber que tiene que ' +
            'haber desaparecido despues de una limpieza real')
    }
}

Describe 'INVARIANTE: el guion monta lo que dice el catalogo' {
    <#
        Get-CebosBanco es la única lista de cebos y New-BancoPruebas la
        recorre; un nombre escrito a mano en el guion no lo vería la CI.
        Se analiza el texto del guion sin sus comentarios.
    #>

    BeforeAll {
        $script:TextoMontaje = (Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path $script:Raiz 'tools') 'Banco-Pruebas.ps1'))
        # Quita los comentarios de línea y los bloques de ayuda.
        $script:CodigoMontaje = [regex]::Replace($script:TextoMontaje, '(?s)<#.*?#>', '')
        $script:CodigoMontaje = [regex]::Replace($script:CodigoMontaje, '(?m)^\s*#.*$', '')
    }

    It 'la prueba lee el guion de verdad: si no, no comprueba nada' {
        $script:CodigoMontaje | Should -Match 'function New-BancoPruebas'
        $script:CodigoMontaje | Should -Match 'Get-CebosBanco'
        $script:CodigoMontaje.Length | Should -BeGreaterThan 1000
    }

    It 'no hay ni un nombre de cebo escrito a mano en el guion' {
        $sueltos = @()
        foreach ($cebo in (Get-CebosBanco -ArchivosDeSobra 3)) {
            foreach ($trozo in @($cebo.Carpeta, $cebo.Patron)) {
                if ([string]::IsNullOrWhiteSpace($trozo)) { continue }
                if ($script:CodigoMontaje.Contains($trozo)) { $sueltos += ('{0}: {1}' -f $cebo.Id, $trozo) }
            }
        }
        $sueltos | Should -BeNullOrEmpty -Because 'los nombres tienen que salir del catalogo, no del guion'
    }

    It 'el guion no vuelve a recorrer con Get-ChildItem -Recurse' {
        # En PowerShell 5.1 Get-ChildItem -Recurse se detiene en silencio a los
        # 260 caracteres, y -Quitar no llegaría a las carpetas de la ruta larga.
        $script:CodigoMontaje | Should -Not -Match 'Get-ChildItem[^\r\n]*-Recurse'
    }
}

Describe 'Test-PerfilAjeno: lo que no puede salir en un analisis' {

    BeforeAll {
        $script:Usuarios = 'C:\Users'
        $script:Propio   = 'C:\Users\quien'
    }

    It 'el perfil de otro usuario es ajeno' {
        Test-PerfilAjeno -Ruta 'C:\Users\otro\Documents\algo.bak' `
                         -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeTrue
        Test-PerfilAjeno -Ruta 'C:\Users\Public\Downloads\x.tmp' `
                         -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeTrue
    }

    It 'el perfil propio NO es ajeno' {
        Test-PerfilAjeno -Ruta 'C:\Users\quien\Documents\Banco-Cachivache\a.tmp' `
                         -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeFalse
    }

    It 'un perfil que solo comparte el principio del nombre SI es ajeno' {
        # Comparar por prefijo daría "no es ajeno" y ocultaría un fallo real.
        Test-PerfilAjeno -Ruta 'C:\Users\quien2\Documents\algo.bak' `
                         -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeTrue
    }

    It 'la propia carpeta de perfiles no es "de otro usuario"' {
        Test-PerfilAjeno -Ruta 'C:\Users' -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio |
            Should -BeFalse
    }

    It 'lo que esta fuera de los perfiles no es ajeno' {
        Test-PerfilAjeno -Ruta 'C:\Windows\Temp\x.tmp' `
                         -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeFalse
        Test-PerfilAjeno -Ruta 'D:\datos\x.tmp' `
                         -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeFalse
    }

    It 'las mayusculas no cambian el veredicto' {
        Test-PerfilAjeno -Ruta 'C:\USERS\QUIEN\Documents\a.bak' `
                         -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeFalse
    }

    It 'con nulos o vacios dice que NO, y no lanza' {
        # Sin poder comprobarlo no se marca el trabajo de la CI en rojo.
        { Test-PerfilAjeno -Ruta $null -CarpetaUsuarios $null -PerfilPropio $null } | Should -Not -Throw
        Test-PerfilAjeno -Ruta $null -CarpetaUsuarios $script:Usuarios -PerfilPropio $script:Propio | Should -BeFalse
        Test-PerfilAjeno -Ruta 'C:\Users\otro\x' -CarpetaUsuarios '' -PerfilPropio $script:Propio | Should -BeFalse
    }

    It 'sin saber cual es el perfil propio, cualquiera de C:\Users es ajeno' {
        # Se conoce la carpeta de perfiles pero no el propio: dar por propio
        # lo que no se identifica dejaría pasar lo que se vigila.
        Test-PerfilAjeno -Ruta 'C:\Users\quien\x.bak' -CarpetaUsuarios $script:Usuarios -PerfilPropio '' |
            Should -BeTrue
    }
}

Describe 'Get-RutaCebo' {

    It 'compone la ruta de una familia de uno solo' {
        $cebo = Get-CebosBanco -ArchivosDeSobra 3 | Where-Object { $_.Id -eq 'mas-grande' }
        Get-RutaCebo -Cebo $cebo -Raiz $script:Banco |
            Should -BeExactly "$script:Banco\03-mas-grande-que-la-papelera\volcado-enorme.dmp"
    }

    It 'numera las familias de varios' {
        $cebo = Get-CebosBanco -ArchivosDeSobra 3 | Where-Object { $_.Id -eq 'relleno' }
        Get-RutaCebo -Cebo $cebo -Raiz $script:Banco -Indice 7 |
            Should -BeExactly "$script:Banco\07-muchas-filas\sobra-00007.tmp"
    }

    It 'el cebo de ruta larga pasa de 260 caracteres' {
        # Si la anidación se quedara corta, el cebo no probaría nada.
        $cebo = Get-CebosBanco -ArchivosDeSobra 3 | Where-Object { $_.Id -eq 'ruta-larga' }
        (Get-RutaCebo -Cebo $cebo -Raiz $script:Banco).Length | Should -BeGreaterThan 260
    }

    It 'siempre con barra invertida, tambien cuando la prueba corre en Linux' {
        # Se comparan como texto con las rutas de Windows; Join-Path en Linux usaría '/'.
        $cebo = Get-CebosBanco -ArchivosDeSobra 3 | Where-Object { $_.Id -eq 'duplicados' }
        (Get-RutaCebo -Cebo $cebo -Raiz $script:Banco -Indice 1) | Should -Not -Match '/'
    }

    It 'una barra final en la raiz no duplica el separador' {
        $cebo = Get-CebosBanco -ArchivosDeSobra 3 | Where-Object { $_.Id -eq 'mas-grande' }
        Get-RutaCebo -Cebo $cebo -Raiz "$script:Banco\" |
            Should -BeExactly "$script:Banco\03-mas-grande-que-la-papelera\volcado-enorme.dmp"
    }

    It 'con nulos devuelve vacio y no lanza' {
        { Get-RutaCebo -Cebo $null -Raiz $script:Banco } | Should -Not -Throw
        Get-RutaCebo -Cebo $null -Raiz $script:Banco | Should -BeNullOrEmpty
        $cebo = Get-CebosBanco -ArchivosDeSobra 3 | Select-Object -First 1
        Get-RutaCebo -Cebo $cebo -Raiz $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-RutasFueraDelBanco: lo que decide si una limpieza real toco lo que no debia' {

    It 'lo que esta dentro no sale' {
        Get-RutasFueraDelBanco -Raiz $script:Banco -Rutas @(
            "$script:Banco\07-muchas-filas\sobra-00001.tmp"
            "$script:Banco\01-temporales\salida-1.bak"
        ) | Should -BeNullOrEmpty
    }

    It 'lo que esta fuera sale, aunque se parezca' {
        $fuera = Get-RutasFueraDelBanco -Raiz $script:Banco -Rutas @(
            "$script:Banco\07-muchas-filas\sobra-00001.tmp"
            'C:\Users\quien\Documents\tesis.tmp'
            'C:\Users\quien\Documents\Banco-Cachivache-2\x.tmp'
        )
        $fuera.Count | Should -Be 2
        $fuera | Should -Contain 'C:\Users\quien\Documents\tesis.tmp'
    }

    It 'una ruta repetida se cuenta una vez' {
        # El mismo archivo puede llegar del informe y del disco.
        (Get-RutasFueraDelBanco -Raiz $script:Banco -Rutas @('C:\otra\x.tmp', 'C:\otra\x.tmp')).Count |
            Should -Be 1
    }

    It 'con la raiz vacia TODO esta fuera' {
        # Una raíz sin calcular no puede dar "todo dentro".
        (Get-RutasFueraDelBanco -Raiz '' -Rutas @('C:\lo\que\sea.tmp')).Count | Should -Be 1
    }

    It 'con nulos y listas vacias no lanza' {
        { Get-RutasFueraDelBanco -Raiz $script:Banco -Rutas @() }   | Should -Not -Throw
        { Get-RutasFueraDelBanco -Raiz $script:Banco -Rutas $null } | Should -Not -Throw
        Get-RutasFueraDelBanco -Raiz $script:Banco -Rutas @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-ResumenCebos: cuantos ha encontrado el analisis' {

    BeforeAll {
        $script:TresCebos = @(Get-CebosBanco -ArchivosDeSobra 3)
        $script:Relleno   = $script:TresCebos | Where-Object { $_.Id -eq 'relleno' }
    }

    It 'con todo propuesto no falta nada' {
        $todas = @()
        foreach ($cebo in $script:TresCebos) {
            for ($n = 1; $n -le $cebo.Cuantos; $n++) {
                $todas += (Get-RutaCebo -Cebo $cebo -Raiz $script:Banco -Indice $n)
            }
        }
        $resumen = Get-ResumenCebos -Cebos $script:TresCebos -Raiz $script:Banco -Propuestas $todas
        @($resumen | Where-Object { $_.Falta -gt 0 }) | Should -BeNullOrEmpty
    }

    It 'cuenta lo que falta y muestra un ejemplo' {
        $resumen = Get-ResumenCebos -Cebos @($script:Relleno) -Raiz $script:Banco -Propuestas @(
            (Get-RutaCebo -Cebo $script:Relleno -Raiz $script:Banco -Indice 2)
        )
        $resumen[0].Encontrados | Should -Be 1
        $resumen[0].Falta       | Should -Be 2
        $resumen[0].Ejemplos    | Should -Contain "$script:Banco\07-muchas-filas\sobra-00001.tmp"
    }

    It 'no muestra más de cinco ejemplos' {
        # Un fallo en 07-muchas-filas imprimiría miles de rutas.
        $muchos = @(Get-CebosBanco -ArchivosDeSobra 3000) | Where-Object { $_.Id -eq 'relleno' }
        $resumen = Get-ResumenCebos -Cebos @($muchos) -Raiz $script:Banco -Propuestas @()
        $resumen[0].Falta            | Should -Be 3000
        @($resumen[0].Ejemplos).Count | Should -Be 5
    }

    It 'las mayusculas de la ruta propuesta no cambian el veredicto' {
        # Windows devuelve las mayúsculas del disco, no las que puso el banco.
        $resumen = Get-ResumenCebos -Cebos @($script:Relleno) -Raiz $script:Banco -Propuestas @(
            (Get-RutaCebo -Cebo $script:Relleno -Raiz $script:Banco -Indice 1).ToUpperInvariant()
            (Get-RutaCebo -Cebo $script:Relleno -Raiz $script:Banco -Indice 2)
            (Get-RutaCebo -Cebo $script:Relleno -Raiz $script:Banco -Indice 3)
        )
        $resumen[0].Falta | Should -Be 0
    }

    It 'conserva EnAnalisis y su motivo, que es con lo que se decide' {
        # Se usa el cebo de carpetas vacías porque tiene EnAnalisis = $false.
        $filas = Get-ResumenCebos -Cebos $script:TresCebos -Raiz $script:Banco -Propuestas @()

        $fuera = $filas | Where-Object { $_.Id -eq 'carpetas-vacias' }
        $fuera.EnAnalisis  | Should -BeFalse
        $fuera.MotivoFuera | Should -Not -BeNullOrEmpty

        $larga = $filas | Where-Object { $_.Id -eq 'ruta-larga' }
        $larga.EnAnalisis  | Should -BeTrue -Because 'el recorrido llega hasta la ruta larga'
    }

    It 'con nulos y vacios no lanza' {
        { Get-ResumenCebos -Cebos $null -Raiz $script:Banco -Propuestas $null } | Should -Not -Throw
        { Get-ResumenCebos -Cebos $script:TresCebos -Raiz '' -Propuestas @() }  | Should -Not -Throw
    }
}

Describe 'Get-ContenidoBanco: no sale del banco por un enlace' {
    <#
        Se cargan solo las dos funciones desde el AST: cargar el guion
        entero sería ejecutarlo. Fuera de Windows se recorre sin el prefijo
        de ruta larga.
    #>

    BeforeAll {
        $guion = Join-Path (Join-Path $script:Raiz 'tools') 'Banco-Pruebas.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($guion, [ref]$null, [ref]$null)
        foreach ($nombre in @('ConvertFrom-PrefijoLargo', 'Get-ContenidoBanco')) {
            $definicion = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $nombre }, $true)
            . ([scriptblock]::Create($definicion.Extent.Text))
        }

        $script:TallerEnlace = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-banco-' + [guid]::NewGuid())
        $script:BancoEnlace  = Join-Path $script:TallerEnlace 'Banco-Cachivache'
        $script:Fuera        = Join-Path $script:TallerEnlace 'Fuera'
        New-Item -ItemType Directory -Path (Join-Path $script:BancoEnlace 'cebo') -Force | Out-Null
        New-Item -ItemType Directory -Path $script:Fuera -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $script:BancoEnlace 'cebo') 'a.tmp') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:Fuera 'personal.txt') -Value 'no se toca'

        $script:Enlace = Join-Path $script:BancoEnlace 'enlace'
        $script:HayEnlace = $false
        try {
            New-Item -ItemType SymbolicLink -Path $script:Enlace -Target $script:Fuera -ErrorAction Stop | Out-Null
            $script:HayEnlace = $true
        } catch { $script:HayEnlace = $false }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Enlace) { [IO.Directory]::Delete($script:Enlace, $false) }
        Remove-Item -LiteralPath $script:TallerEnlace -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'devuelve el enlace pero no lo que hay al otro lado' {
        if (-not $script:HayEnlace) { Set-ItResult -Skipped -Because 'no se pueden crear enlaces simbolicos aqui'; return }
        $contenido = @(Get-ContenidoBanco -Raiz $script:BancoEnlace -Prefijo '')
        $contenido | Should -Contain $script:Enlace
        $contenido | Should -Contain (Join-Path (Join-Path $script:BancoEnlace 'cebo') 'a.tmp')
        @($contenido | Where-Object { $_ -like '*personal.txt' }).Count | Should -Be 0
    }

    It 'Remove-BancoPruebas no cambia atributos ni recurre a traves de un enlace' {
        $texto = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $script:Raiz 'tools') 'Banco-Pruebas.ps1')
        $cuerpo = $texto.Substring($texto.IndexOf('function Remove-BancoPruebas'))
        $cuerpo | Should -Match 'ReparsePoint'
        $cuerpo | Should -Not -Match 'Delete\([^)]*\$true\)'
    }
}
