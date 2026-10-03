<#
    Qué se puede hacer con cada tipo de unidad.

    Los discos externos y las llaves USB se analizan, pero no se borra en
    ellos: una extraíble puede desconectarse a mitad de un borrado; medir
    no tiene ese problema.

    La invariante principal (último Describe): para toda clase de unidad
    que el código pueda devolver, si no es fija,
    Test-PuedeProducirCandidatoBorrable dice que no.

    La lista de clases se extrae del AST de src/Core/Extraibles.ps1, no se
    escribe a mano: así una clase nueva entra automáticamente en la
    invariante y en la comprobación de la tabla de respuestas. Se usa el
    AST y no una expresión regular para no contar menciones en
    comentarios.
#>

BeforeAll {
    $script:Raiz   = Split-Path $PSScriptRoot -Parent
    $script:Fuente = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Extraibles.ps1'

    # Solo este archivo y no Bootstrap.ps1: las funciones son cálculo puro
    # y cargar el núcleo ocultaría una dependencia nueva.
    . $script:Fuente

    # Literales de cadena dentro de un "return" de Get-ClaseDeUnidad; las
    # etiquetas del switch ('fixed', 'removable'...) son entradas, no
    # clases.
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:Fuente, [ref]$null, [ref]$null)

    $script:FuncionClase = $script:Ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Get-ClaseDeUnidad'
    }, $true)

    $script:Clases = @(
        $script:FuncionClase.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
        }, $true) |
        ForEach-Object {
            $_.FindAll({
                param($m) $m -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true)
        } |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique
    )

    # Respuestas esperadas. Una prueba exige que las claves coincidan
    # exactamente con las clases del código.
    $script:Esperado = @{
        'fija'        = @{ Analizable = $true;  Borrable = $true  }
        'extraible'   = @{ Analizable = $true;  Borrable = $false }
        'red'         = @{ Analizable = $false; Borrable = $false }
        'optica'      = @{ Analizable = $false; Borrable = $false }
        'desconocida' = @{ Analizable = $false; Borrable = $false }
    }
}

Describe 'la lista de clases sale del codigo, no de esta prueba' {

    It 'encuentra las cinco clases: si no, esta prueba no comprueba nada' {
        # Si el AST dejara de encontrarlas, las pruebas siguientes
        # recorrerían una lista vacía.
        $script:Clases.Count | Should -Be 5 -Because 'la invariante recorre esta lista'
        $script:Clases | Should -Contain 'fija'
    }

    It 'la tabla de respuestas de esta prueba cubre exactamente esas clases' {
        # En los dos sentidos: clase nueva sin respuesta, o respuesta para
        # una clase que ya no existe.
        $sinDecidir = @($script:Clases | Where-Object { -not $script:Esperado.ContainsKey($_) })
        $sinDecidir | Should -BeNullOrEmpty -Because 'una clase nueva tiene que decidir si se borra en ella'

        $sobran = @($script:Esperado.Keys | Where-Object { $_ -notin $script:Clases })
        $sobran | Should -BeNullOrEmpty -Because 'una respuesta para una clase que no existe engorda la tabla y no protege nada'
    }
}

Describe 'Get-ClaseDeUnidad traduce el numero de DriveType' {

    It 'DriveType <Tipo> es "<Clase>"' -ForEach @(
        @{ Tipo = 0; Clase = 'desconocida' }   # Unknown
        @{ Tipo = 1; Clase = 'desconocida' }   # NoRootDirectory: sin medio dentro
        @{ Tipo = 2; Clase = 'extraible' }     # Removable: la llave USB
        @{ Tipo = 3; Clase = 'fija' }          # Fixed / Local Disk
        @{ Tipo = 4; Clase = 'red' }           # Network
        @{ Tipo = 5; Clase = 'optica' }        # CDRom / Compact Disc
        @{ Tipo = 6; Clase = 'desconocida' }   # Ram: desaparece al reiniciar
    ) {
        Get-ClaseDeUnidad -Tipo $Tipo | Should -Be $Clase
    }

    It 'un numero que no es de la tabla ("<Tipo>") es desconocida' -ForEach @(
        @{ Tipo = 7 }
        @{ Tipo = 42 }
        @{ Tipo = -1 }
    ) {
        Get-ClaseDeUnidad -Tipo $Tipo | Should -Be 'desconocida'
    }

    It 'el numero tambien vale escrito como texto, que es como llega de CIM' {
        Get-ClaseDeUnidad -Tipo '3' | Should -Be 'fija'
        Get-ClaseDeUnidad -Tipo '2' | Should -Be 'extraible'
    }
}

Describe 'Get-ClaseDeUnidad traduce el nombre de System.IO.DriveType' {

    It '"<Tipo>" es "<Clase>"' -ForEach @(
        @{ Tipo = 'Fixed';            Clase = 'fija' }
        @{ Tipo = 'Removable';        Clase = 'extraible' }
        @{ Tipo = 'Network';          Clase = 'red' }
        @{ Tipo = 'CDRom';            Clase = 'optica' }
        @{ Tipo = 'CD-ROM';           Clase = 'optica' }   # asi lo dice Get-Volume
        @{ Tipo = 'Ram';              Clase = 'desconocida' }
        @{ Tipo = 'Unknown';          Clase = 'desconocida' }
        @{ Tipo = 'NoRootDirectory';  Clase = 'desconocida' }
    ) {
        Get-ClaseDeUnidad -Tipo $Tipo | Should -Be $Clase
    }

    It 'no le afecta ni la caja ni los espacios de alrededor' {
        Get-ClaseDeUnidad -Tipo 'fixed'       | Should -Be 'fija'
        Get-ClaseDeUnidad -Tipo 'REMOVABLE'   | Should -Be 'extraible'
        Get-ClaseDeUnidad -Tipo '  Network  ' | Should -Be 'red'
    }

    It 'acepta el valor de la enumeracion tal cual, que es lo que da DriveInfo' {
        Get-ClaseDeUnidad -Tipo ([IO.DriveType]::Fixed)     | Should -Be 'fija'
        Get-ClaseDeUnidad -Tipo ([IO.DriveType]::Removable) | Should -Be 'extraible'
        Get-ClaseDeUnidad -Tipo ([IO.DriveType]::Network)   | Should -Be 'red'
        Get-ClaseDeUnidad -Tipo ([IO.DriveType]::CDRom)     | Should -Be 'optica'
    }

    It 'las dos formas de entrada dan la MISMA respuesta' {
        # Si no coincidieran, el veredicto dependería de por dónde se
        # pregunte.
        foreach ($par in @(
            @{ Numero = 2; Nombre = 'Removable' }
            @{ Numero = 3; Nombre = 'Fixed' }
            @{ Numero = 4; Nombre = 'Network' }
            @{ Numero = 5; Nombre = 'CDRom' }
            @{ Numero = 6; Nombre = 'Ram' }
        )) {
            (Get-ClaseDeUnidad -Tipo $par.Numero) |
                Should -Be (Get-ClaseDeUnidad -Tipo $par.Nombre) -Because ('DriveType {0}' -f $par.Nombre)
        }
    }

    It 'un tipo inventado es desconocida, no fija' {
        Get-ClaseDeUnidad -Tipo 'Holograma'      | Should -Be 'desconocida'
        Get-ClaseDeUnidad -Tipo 'FixedRemovable' | Should -Be 'desconocida'
        Get-ClaseDeUnidad -Tipo 'Fija'           | Should -Be 'desconocida'
    }

    It 'con nulo o vacio no revienta y contesta desconocida' {
        Get-ClaseDeUnidad -Tipo $null | Should -Be 'desconocida'
        Get-ClaseDeUnidad -Tipo ''    | Should -Be 'desconocida'
        Get-ClaseDeUnidad -Tipo '   ' | Should -Be 'desconocida'
    }
}

Describe 'Test-UnidadAnalizable' {

    It 'devuelve los tres campos que hacen falta' {
        # Si el objeto cambiara de forma, las pruebas siguientes
        # compararían $null contra $null y pasarían.
        $r = Test-UnidadAnalizable -Clase 'fija'
        foreach ($campo in @('Analizable', 'Clase', 'Motivo')) {
            $r.PSObject.Properties.Name | Should -Contain $campo
        }
    }

    It 'contesta lo que dice la tabla, para cada clase que el codigo devuelve' {
        # foreach dentro del It y no -ForEach: una lista construida en
        # BeforeAll no existe durante el descubrimiento de Pester y
        # generaría cero casos.
        foreach ($clase in $script:Clases) {
            (Test-UnidadAnalizable -Clase $clase).Analizable |
                Should -Be $script:Esperado[$clase].Analizable -Because ('la clase ' + $clase)
        }
    }

    It 'las fijas y las extraibles se analizan; la red y las opticas no' {
        # Escrito a mano a propósito: la prueba anterior compara el código
        # con una tabla, y cambiar ambas a la vez la dejaría pasar.
        (Test-UnidadAnalizable -Clase 'fija').Analizable      | Should -BeTrue
        (Test-UnidadAnalizable -Clase 'extraible').Analizable | Should -BeTrue
        (Test-UnidadAnalizable -Clase 'red').Analizable       | Should -BeFalse
        (Test-UnidadAnalizable -Clase 'optica').Analizable    | Should -BeFalse
    }

    It 'todo "no" viene con un motivo legible, y todo "si" sin el' {
        foreach ($clase in $script:Clases) {
            $r = Test-UnidadAnalizable -Clase $clase
            if ($r.Analizable) {
                $r.Motivo | Should -BeNullOrEmpty -Because ('un si no tiene nada que explicar: ' + $clase)
            } else {
                # Longitud mínima: un motivo de tres letras no sirve.
                $r.Motivo.Length | Should -BeGreaterThan 20 -Because ('hay que decir por que no: ' + $clase)
            }
        }
    }

    It 'los motivos se escriben en castellano de verdad, con sus tildes' {
        foreach ($clase in $script:Clases) {
            $r = Test-UnidadAnalizable -Clase $clase
            if (-not $r.Analizable) {
                $r.Motivo | Should -Match '[áéíóúñÁÉÍÓÚÑ]' -Because ('lo lee el usuario: ' + $clase)
            }
        }
    }

    It 'con nulo, vacio o una clase inventada no revienta y dice que no' {
        foreach ($entrada in @($null, '', '   ', 'Holograma', 'Fixed', '3')) {
            $r = Test-UnidadAnalizable -Clase $entrada
            $r.Analizable | Should -BeFalse -Because 'ante lo desconocido, la respuesta segura'
            $r.Clase      | Should -Be 'desconocida'
            $r.Motivo     | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'solo las unidades fijas pueden producir un candidato borrable' {

    It 'en una unidad fija si' {
        Test-PuedeProducirCandidatoBorrable -Clase 'fija' | Should -BeTrue
    }

    It 'LA INVARIANTE: ninguna clase que no sea fija puede producirlo' {
        # Recorre las clases que devuelve el código: una clase nueva queda
        # cubierta automáticamente. foreach dentro del It por el motivo ya
        # indicado.
        $script:Clases.Count | Should -BeGreaterThan 1 -Because 'sin clases esta invariante no comprueba nada'

        foreach ($clase in $script:Clases) {
            if ($clase -eq 'fija') { continue }
            Test-PuedeProducirCandidatoBorrable -Clase $clase |
                Should -BeFalse -Because ('una unidad ' + $clase + ' nunca puede producir un candidato borrable')
        }
    }

    It 'y coincide con la tabla de respuestas esperadas' {
        foreach ($clase in $script:Clases) {
            Test-PuedeProducirCandidatoBorrable -Clase $clase |
                Should -Be $script:Esperado[$clase].Borrable -Because ('la clase ' + $clase)
        }
    }

    It 'una extraible se analiza PERO no se borra: las dos cosas a la vez' {
        # Detecta tanto hacerla borrable como sacarla del análisis.
        (Test-UnidadAnalizable -Clase 'extraible').Analizable        | Should -BeTrue
        Test-PuedeProducirCandidatoBorrable -Clase 'extraible'       | Should -BeFalse
    }

    It 'con nulo, vacio, una clase inventada o un DriveType sin traducir dice que no' {
        # 'Fixed' y '3' son el tipo del sistema, no la clase del programa:
        # deben pasar antes por Get-ClaseDeUnidad. Ante la duda, no se
        # borra.
        foreach ($entrada in @($null, '', '   ', 'Holograma', 'Fixed', '3', 'FIJAS')) {
            Test-PuedeProducirCandidatoBorrable -Clase $entrada |
                Should -BeFalse -Because ('entrada: [' + $entrada + ']')
        }
    }

    It 'pero no se pone tiquismiquis con la caja ni con los espacios' {
        Test-PuedeProducirCandidatoBorrable -Clase 'Fija'    | Should -BeTrue
        Test-PuedeProducirCandidatoBorrable -Clase '  fija ' | Should -BeTrue
    }
}

Describe 'Get-MotivoNoBorrableEnUnidad explica lo que la otra funcion decide' {

    It 'en una unidad fija no hay nada que explicar' {
        Get-MotivoNoBorrableEnUnidad -Clase 'fija' | Should -BeNullOrEmpty
    }

    It 'LA INVARIANTE: hay texto exactamente cuando no se puede borrar' {
        # La función que decide y la que explica no pueden divergir: una
        # fila que no se puede marcar sin explicación parece un fallo.
        foreach ($clase in $script:Clases) {
            $motivo = Get-MotivoNoBorrableEnUnidad -Clase $clase
            if (Test-PuedeProducirCandidatoBorrable -Clase $clase) {
                $motivo | Should -BeNullOrEmpty -Because ('se puede borrar: ' + $clase)
            } else {
                $motivo.Length | Should -BeGreaterThan 20 -Because ('no se puede borrar: ' + $clase)
            }
        }
    }

    It 'el texto que lee el usuario lleva tildes y eñes' {
        foreach ($clase in $script:Clases) {
            $motivo = Get-MotivoNoBorrableEnUnidad -Clase $clase
            if ($motivo) {
                $motivo | Should -Match '[áéíóúñÁÉÍÓÚÑ]' -Because ('lo lee el usuario: ' + $clase)
            }
        }
    }

    It 'el de la extraible dice las dos cosas: que se ha medido y que no se borra' {
        # Medir sin borrar es el comportamiento previsto.
        $motivo = Get-MotivoNoBorrableEnUnidad -Clase 'extraible'
        $motivo | Should -Match 'medido'
        $motivo | Should -Match 'extraíble'
    }

    It 'nombra la unidad cuando se le dice cual es' {
        # Con varios discos, "esta unidad" obliga a adivinar. Se busca
        # 'la unidad D:' y no 'D:': -Match no distingue mayúsculas y 'D:'
        # casaría con "unidad: es una...".
        $conLetra = Get-MotivoNoBorrableEnUnidad -Clase 'extraible' -Letra 'D:'
        $conLetra | Should -Match 'la unidad D:'

        $sinLetra = Get-MotivoNoBorrableEnUnidad -Clase 'extraible'
        $sinLetra | Should -Not -Match 'la unidad D:'
        $sinLetra | Should -Match 'esta unidad'
    }

    It 'con nulo, vacio o una clase inventada no revienta y explica algo' {
        foreach ($entrada in @($null, '', '   ', 'Holograma')) {
            $motivo = Get-MotivoNoBorrableEnUnidad -Clase $entrada
            $motivo.Length | Should -BeGreaterThan 20 -Because ('entrada: [' + $entrada + ']')
        }
        # La letra nula tampoco debe romper.
        (Get-MotivoNoBorrableEnUnidad -Clase 'extraible' -Letra $null).Length |
            Should -BeGreaterThan 20
    }
}
