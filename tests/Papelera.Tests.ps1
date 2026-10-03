<#
    Pruebas de la papelera que en realidad borra para siempre.

    Windows borra permanentemente, sin avisar y devolviendo éxito, lo que
    no cabe en la papelera. Toda la decisión está en Test-CabeEnPapelera,
    cálculo puro que se prueba en Linux sin registro de Windows.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
}

Describe 'Test-CabeEnPapelera: los tres casos' {

    It 'lo que cabe, cabe' {
        $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes 10GB
        $r = Test-CabeEnPapelera -Bytes 1GB -Estado $estado
        $r.Cabe   | Should -BeTrue
        $r.Seguro | Should -BeTrue
    }

    It 'lo que supera la cuota NO cabe' {
        # El que no cabe es siempre el archivo más grande.
        $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes 10GB
        $r = Test-CabeEnPapelera -Bytes 11GB -Estado $estado
        $r.Cabe   | Should -BeFalse
        $r.Seguro | Should -BeTrue
    }

    It 'justo en el limite cabe, y un byte mas no' {
        $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes 1000
        (Test-CabeEnPapelera -Bytes 1000 -Estado $estado).Cabe | Should -BeTrue
        (Test-CabeEnPapelera -Bytes 1001 -Estado $estado).Cabe | Should -BeFalse
    }

    It 'si no hay papelera en ese volumen, nada cabe' {
        $estado = New-EstadoPapelera -Disponible $false -CapacidadBytes 0 `
                    -Motivo 'la papelera esta desactivada en D:'
        $r = Test-CabeEnPapelera -Bytes 1 -Estado $estado
        $r.Cabe   | Should -BeFalse
        $r.Motivo | Should -BeLike '*desactivada*'
    }

    It 'capacidad desconocida (-1) deja pasar, pero lo marca como no seguro' {
        # Tratar "no se sabe" como "no cabe" bloquearía borrados legítimos
        # donde no se pueda leer el registro y empujaría al usuario a usar
        # el borrado permanente.
        $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes -1
        $r = Test-CabeEnPapelera -Bytes 500GB -Estado $estado
        $r.Cabe   | Should -BeTrue
        $r.Seguro | Should -BeFalse -Because 'no se ha podido comprobar, y eso no se oculta'
    }

    It 'un estado nulo no revienta' {
        { Test-CabeEnPapelera -Bytes 10 -Estado $null } | Should -Not -Throw
        (Test-CabeEnPapelera -Bytes 10 -Estado $null).Seguro | Should -BeFalse
    }

    It 'el motivo dice los dos tamanos, no solo que no cabe' {
        # Sin cifras, el usuario no sabe si el problema es el archivo o su
        # configuración.
        $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes 5GB
        $r = Test-CabeEnPapelera -Bytes 20GB -Estado $estado
        $r.Motivo | Should -BeLike '*20*GB*'
        $r.Motivo | Should -BeLike '*5*GB*'
    }
}

Describe 'Test-IraAPapelera: rutas sin letra de unidad' {

    It 'una ruta de red no tiene papelera' {
        $r = Test-IraAPapelera -Ruta '\\servidor\comun\cosa.bin' -Bytes 10
        $r.Cabe   | Should -BeFalse
        $r.Motivo | Should -BeLike '*red*'
    }

    It 'una ruta sin letra ni UNC no bloquea nada' {
        # Las pruebas corren en Linux, sin letras ni papelera: bloquear
        # aquí impediría probar el borrado.
        $r = Test-IraAPapelera -Ruta '/tmp/lo/que/sea' -Bytes 10
        $r.Cabe | Should -BeTrue
    }
}

Describe 'Get-EstadoPapelera: se comporta fuera de Windows' {

    BeforeEach { Reset-CachePapelera }

    It 'no lanza aunque no haya registro de Windows' {
        { Get-EstadoPapelera -Unidad 'C:' } | Should -Not -Throw
    }

    It 'sin poder averiguarlo, responde desconocido y no cero' {
        # Cero significaría "no cabe nada" y bloquearía todos los borrados:
        # un fallo de lectura no debe parar el programa.
        $e = Get-EstadoPapelera -Unidad 'C:'

        # $IsWindows no existe en Windows PowerShell 5.1 (vale $null); 5.1
        # solo corre en Windows, así que $null cuenta como Windows.
        $esWindows = $IsWindows -or ($null -eq $IsWindows)
        if (-not $esWindows) {
            $e.CapacidadBytes | Should -Be -1
            $e.Disponible     | Should -BeTrue
        }
    }

    It 'la respuesta se cachea: la cuota no cambia mientras el programa esta abierto' {
        $a = Get-EstadoPapelera -Unidad 'C:'
        $b = Get-EstadoPapelera -Unidad 'C:'
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
    }

    It 'Reset-CachePapelera obliga a volver a preguntar' {
        $a = Get-EstadoPapelera -Unidad 'C:'
        Reset-CachePapelera
        $b = Get-EstadoPapelera -Unidad 'C:'
        [object]::ReferenceEquals($a, $b) | Should -BeFalse
    }
}

Describe 'el motor no borra lo que no iria a la papelera' {

    <#
        Sin una papelera llena real en Linux, se sigue el camino en el
        código: Invoke-EliminacionCandidato pregunta antes de borrar, solo
        si no se ha pedido borrado permanente, y se detiene.
    #>

    BeforeAll {
        $script:Motor = Get-Content -Raw -LiteralPath (
            Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core/Remove.ps1')
        $script:Codigo = (Get-Content -LiteralPath (
            Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core/Remove.ps1') |
            Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'el motor pregunta si algo iria de verdad a la papelera' {
        $script:Codigo | Should -Match 'Test-IraAPapelera'
    }

    It 'solo pregunta cuando NO se ha pedido borrado permanente' {
        # Con borrado permanente el usuario ya ha renunciado a la papelera.
        # La condición vive en Get-MotivoNoSeBorra, compartida con la
        # simulación.
        $script:Codigo | Should -Match 'if \(-not \$Permanente -and \$Candidato\.Metodo'
        $script:Codigo | Should -Match 'Get-MotivoNoSeBorra -Candidato \$Candidato .*-Permanente:\$permanenteEfectivo'
    }

    It 'cuando no cabe, se para: ni borra ni sigue al switch' {
        $i = $script:Codigo.IndexOf('Test-IraAPapelera')
        $f = $script:Codigo.IndexOf('switch ($Candidato.Metodo)')
        $i | Should -BeGreaterThan -1
        $f | Should -BeGreaterThan $i -Because 'la comprobacion va ANTES de repartir por metodo'

        $trozo = $script:Codigo.Substring($i, $f - $i)
        $trozo | Should -Match 'return \$false'
        $trozo | Should -Match 'Candidato\.Error'
    }

    It 'lo deja anotado en el registro, no solo en la fila' {
        $i = $script:Codigo.IndexOf('Test-IraAPapelera')
        $f = $script:Codigo.IndexOf('switch ($Candidato.Metodo)')
        $script:Codigo.Substring($i, $f - $i) | Should -Match "Write-Registro.*BLOQUEADO"
    }

    It 'el mensaje le dice al usuario que puede hacer' {
        # Un error sin salida deja al usuario sin opciones.
        $script:Motor | Should -Match 'marca el borrado permanente'
    }
}

Describe 'la simulacion predice lo mismo que hace el borrado real' {

    <#
        La simulación debe pasar por la misma comprobación de papelera que
        el borrado real: si no, puede prometer eliminar un archivo que la
        ejecución real rechazaría. La decisión vive en una sola función.
    #>

    BeforeAll {
        $script:Codigo2 = (Get-Content -LiteralPath (
            Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core/Remove.ps1') |
            Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'la decision vive en UNA funcion, no repetida' {
        $script:Codigo2 | Should -Match 'function Get-MotivoNoSeBorra'
        # Test-IraAPapelera solo se invoca desde ella, para que no
        # diverjan.
        @([regex]::Matches($script:Codigo2, 'Test-IraAPapelera')).Count |
            Should -Be 1 -Because 'solo Get-MotivoNoSeBorra decide, y los demas la llaman'
    }

    It 'la usan los DOS caminos: el borrado real y la simulacion' {
        @([regex]::Matches($script:Codigo2, 'Get-MotivoNoSeBorra -Candidato')).Count |
            Should -BeGreaterOrEqual 2
    }

    It 'la simulacion consulta ANTES de sumar el espacio' {
        # Si sumara primero, el total prometería espacio que no se libera.
        $i = $script:Codigo2.IndexOf('if ($Simular)')
        $consulta = $script:Codigo2.IndexOf('Get-MotivoNoSeBorra', $i)
        $suma     = $script:Codigo2.IndexOf('$liberado += $tamano', $i)

        $consulta | Should -BeGreaterThan -1
        $suma     | Should -BeGreaterThan $consulta
    }

    It 'lo rechazado se cuenta aparte y sale en el resultado' {
        # Sin contarlo, el resumen incluiría lo que no se habría tocado.
        $script:Codigo2 | Should -Match '\$bloqueados\+\+'
        $script:Codigo2 | Should -Match 'Bloqueados = \$bloqueados'
    }

    It 'el mensaje sale FORMATEADO, sin marcadores {0} a la vista' {
        <#
            '-f' tiene más precedencia que '+': en
            ('texto con {0}...' + 'mas texto' -f $motivo) solo se formatea
            la segunda cadena y el {0} llega a pantalla. Buscar un trozo
            fijo del texto no lo detecta: hay que comprobar el resultado.
        #>
        $estado = New-EstadoPapelera -Disponible $true -CapacidadBytes 5GB
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'grande.bin' `
                        -Ruta 'C:\zona\grande.bin' -Bytes 9GB -Metodo 'Ruta'

        # Se sustituye la consulta al disco por el estado de prueba.
        Mock Test-IraAPapelera { Test-CabeEnPapelera -Bytes $Bytes -Estado $estado }

        $motivo = Get-MotivoNoSeBorra -Candidato $candidato -Bytes 9GB

        $motivo | Should -Not -BeNullOrEmpty
        $motivo | Should -Not -Match '\{\d\}' -Because 'un marcador sin sustituir es texto roto en la cara del usuario'
        $motivo | Should -BeLike '*9*GB*' -Because 'tiene que decir CUANTO ocupa'
        $motivo | Should -BeLike '*5*GB*' -Because 'y cuanto admite la papelera'
    }

    It 'y lo dicen las dos interfaces, no solo el registro' {
        $raiz = Split-Path $PSScriptRoot -Parent
        $ventana = Get-Content -Raw -LiteralPath (Join-Path $raiz 'src/UI/Window.Eliminacion.ps1')
        $consola = Get-Content -Raw -LiteralPath (Join-Path $raiz 'src/Cli/Cli.ps1')

        $ventana | Should -Match 'se habrían quedado sin borrar'
        $consola | Should -Match 'NO se habrían borrado'
    }
}

Describe 'que se puede rescatar de la papelera y que no' {

    <#
        El programa usa la papelera por defecto y debe decirlo, pero sin
        prometer de más: anunciar como recuperable algo que no lo es es
        peor que callar.
    #>

    BeforeAll {
        function Get-Cand {
            param([string] $Metodo, [switch] $Forzar, [switch] $Hecho)
            $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\x\y' `
                    -Metodo $Metodo -ForzarPermanente:$Forzar
            $c.Hecho = [bool]$Hecho
            return $c
        }
    }

    It 'lo que va a la papelera se puede recuperar' {
        foreach ($m in @('Ruta', 'CarpetaVacia', 'Contenido', 'FirefoxCache', 'Miniaturas')) {
            Test-CandidatoRecuperable -Candidato (Get-Cand -Metodo $m) |
                Should -BeTrue -Because "el metodo $m manda a la papelera"
        }
    }

    It 'vaciar la papelera NO se puede deshacer' {
        # Vaciar la papelera no tiene papelera donde caer.
        Test-CandidatoRecuperable -Candidato (Get-Cand -Metodo 'Papelera') | Should -BeFalse
    }

    It 'un comando externo tampoco' {
        # DISM o "docker system prune" no dejan nada que rescatar.
        Test-CandidatoRecuperable -Candidato (Get-Cand -Metodo 'Comando') | Should -BeFalse
    }

    It 'lo informativo no se ha tocado siquiera' {
        Test-CandidatoRecuperable -Candidato (Get-Cand -Metodo 'Informativo') | Should -BeFalse
    }

    It 'el borrado permanente del usuario manda sobre todo' {
        Test-CandidatoRecuperable -Candidato (Get-Cand -Metodo 'Ruta') -Permanente | Should -BeFalse
    }

    It 'y ForzarPermanente de los modulos de cache tambien' {
        Test-CandidatoRecuperable -Candidato (Get-Cand -Metodo 'Contenido' -Forzar) | Should -BeFalse
    }

    It 'un candidato nulo no revienta y responde que no' {
        { Test-CandidatoRecuperable -Candidato $null } | Should -Not -Throw
        Test-CandidatoRecuperable -Candidato $null | Should -BeFalse
    }
}

Describe 'el resumen solo cuenta lo que de verdad se borro' {

    BeforeAll {
        function Get-Cand2 {
            param([string] $Metodo, [switch] $Hecho)
            $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\x\y' -Metodo $Metodo
            $c.Hecho = [bool]$Hecho
            return $c
        }
    }

    It 'separa lo rescatable de lo definitivo' {
        $lote = @(
            (Get-Cand2 -Metodo 'Ruta' -Hecho)
            (Get-Cand2 -Metodo 'Ruta' -Hecho)
            (Get-Cand2 -Metodo 'Comando' -Hecho)
        )
        $r = Get-ResumenRecuperable -Candidatos $lote
        $r.Recuperables | Should -Be 2
        $r.Definitivos  | Should -Be 1
    }

    It 'NO cuenta lo que no se llego a borrar' {
        # Lo que ni se tocó no se puede prometer como recuperable.
        $lote = @(
            (Get-Cand2 -Metodo 'Ruta' -Hecho)
            (Get-Cand2 -Metodo 'Ruta')          # fallo o quedo sin tocar
        )
        (Get-ResumenRecuperable -Candidatos $lote).Recuperables | Should -Be 1
    }

    It 'con borrado permanente no hay nada que rescatar' {
        $lote = @((Get-Cand2 -Metodo 'Ruta' -Hecho), (Get-Cand2 -Metodo 'Ruta' -Hecho))
        $r = Get-ResumenRecuperable -Candidatos $lote -Permanente
        $r.Recuperables | Should -Be 0
        $r.Definitivos  | Should -Be 2
    }

    It 'una lista vacia da ceros, no un error' {
        { Get-ResumenRecuperable -Candidatos @() } | Should -Not -Throw
        (Get-ResumenRecuperable -Candidatos @()).Recuperables | Should -Be 0
    }
}

Describe 'la ventana ofrece la papelera solo cuando hay algo dentro' {

    BeforeAll {
        $script:Raiz2   = Split-Path $PSScriptRoot -Parent
        # Sin comentarios de línea ni de bloque: la prueba no debe
        # encontrar el texto en las explicaciones.
        $script:Cierre2 = [regex]::Replace(
            ((Get-Content -LiteralPath (Join-Path $script:Raiz2 'src/UI/Window.Eliminacion.ps1') |
              Where-Object { $_ -notmatch '^\s*#' }) -join "`n"), '(?s)<#.*?#>', '')
        $script:Eventos2 = [regex]::Replace(
            ((Get-Content -LiteralPath (Join-Path $script:Raiz2 'src/UI/Window.Eventos.ps1') |
              Where-Object { $_ -notmatch '^\s*#' }) -join "`n"), '(?s)<#.*?#>', '')
    }

    It 'el boton solo aparece si hay elementos recuperables' {
        # Se comprueba el orden, no una distancia en caracteres: un tope
        # fijo fallaría al cambiar la longitud de un mensaje.
        $condicion = $script:Cierre2.IndexOf('$rescate.Recuperables -gt 0')
        $boton     = $script:Cierre2.IndexOf("BtnAbrirPapelera.Visibility = 'Visible'")

        $condicion | Should -BeGreaterThan -1
        $boton     | Should -BeGreaterThan $condicion -Because (
            'el boton se enciende DENTRO de la condicion, no antes')
    }

    It 'se esconde al empezar la limpieza siguiente' {
        # La limpieza en curso aún no ha mandado nada a la papelera.
        $script:Eventos2 | Should -Match "BtnAbrirPapelera\.Visibility = 'Collapsed'"
    }

    It 'lo irreversible se dice, no se calla' {
        $script:Cierre2 | Should -Match 'no tiene vuelta atrás'
    }

    It 'la simulacion no ofrece rescatar nada' {
        # Sale por return antes: en simulación no hay nada en la papelera.
        $corte  = $script:Cierre2.IndexOf('if ($simulado)')
        $rescate = $script:Cierre2.IndexOf('Get-ResumenRecuperable')
        $rescate | Should -BeGreaterThan $corte
    }
}

Describe 'El boton de confirmar no puede llamar definitivo a lo que va a la papelera' {

    # El destino se calcula, pero el rótulo del botón no puede decir
    # "Eliminar definitivamente" cuando lo borrado va a la papelera.

    It 'con la papelera, ni el destino ni el boton dicen que sea definitivo' {
        $t = Get-TextosDestinoBorrado
        $t.Destino | Should -Be 'Papelera de reciclaje'
        $t.Boton   | Should -Not -Match 'definitiv'
        $t.Boton   | Should -Match 'papelera'
    }

    It 'con borrado permanente, los dos lo dicen' {
        $t = Get-TextosDestinoBorrado -Permanente
        $t.Destino | Should -Be 'Borrado permanente'
        $t.Boton   | Should -Match 'definitiv'
    }

    It 'INVARIANTE: "definitivo" en el boton solo si el destino es permanente' {
        foreach ($permanente in @($true, $false)) {
            $t = Get-TextosDestinoBorrado -Permanente:$permanente
            $diceDefinitivo = $t.Boton -match 'definitiv|para siempre|irreversible'
            $diceDefinitivo | Should -Be $permanente -Because (
                'el rotulo del boton y el destino son la misma decision')
        }
    }

    It 'la palabra de confirmacion es mas dura cuando no hay vuelta atras' {
        (Get-TextosDestinoBorrado).Palabra             | Should -Be 'SI'
        (Get-TextosDestinoBorrado -Permanente).Palabra | Should -Be 'ELIMINAR'
    }

    It 'el rotulo de reserva del XAML existe y es NEUTRO' {
        # El botón necesita texto en el XAML (sin él queda mudo para un
        # lector de pantalla y lo prohíbe la invariante de accesibilidad),
        # pero ese texto no puede prometer un borrado definitivo, que
        # depende de una preferencia leída en ejecución. El rótulo real lo
        # pone Dialogs.ps1.
        $raiz = Split-Path $PSScriptRoot -Parent
        $xaml = [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $raiz 'src') 'UI') 'ConfirmDialog.xaml'))
        $sinComentarios = [regex]::Replace($xaml, '(?s)<!--.*?-->', '')

        $m = [regex]::Match($sinComentarios, '(?s)<Button[^>]*x:Name="BtnSi".*?/>')
        $m.Success | Should -BeTrue -Because 'si no se encuentra el boton, esta prueba no mira nada'

        $contenido = [regex]::Match($m.Value, 'Content="(?<t>[^"]*)"')
        $contenido.Success | Should -BeTrue -Because (
            'un botón sin texto se queda mudo para un lector de pantalla')
        $contenido.Groups['t'].Value | Should -Not -Match 'definitiv|para siempre|irreversible' -Because (
            'el XAML no sabe si el borrado sera permanente; decirlo aqui es mentir la mitad de las veces')
    }

    It 'y Dialogs.ps1 lo toma de esa funcion, no de un if suyo' {
        $raiz = Split-Path $PSScriptRoot -Parent
        $ps = [IO.File]::ReadAllText((Join-Path (Join-Path (Join-Path $raiz 'src') 'UI') 'Dialogs.ps1'))
        $codigo = ($ps -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $codigo | Should -Match 'Get-TextosDestinoBorrado'
        $codigo | Should -Match '\$btnSi\.Content\s*=\s*\$textos\.Boton'
        # Sin un segundo sitio que decida lo mismo.
        $codigo | Should -Not -Match "Destino\.Text\s*=\s*if"
    }
}
