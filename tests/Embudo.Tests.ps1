<#
    El embudo de Invoke-ModuloLimpieza como lista de reglas.

    Invoke-ModuloLimpieza es el único punto por el que pasan todos los
    candidatos, y recorre la lista que devuelve Get-ReglasFiltroCandidato.
    Una regla que deja de aplicarse no lanza ni deja rastro: simplemente se
    propone de más. Por eso se exige:

      1. Regla a regla: para cada regla hay un candidato que solo ella
         rechaza.
      2. Toda regla de la lista tiene su caso; añadir una sin caso falla.
      3. El resultado no depende del orden de las reglas.
      4. El coste sí: van de barata a cara, y el disco no se consulta para
         un candidato que una regla de texto ya ha descartado.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Carpetas personales vacías: el veredicto de la guardia depende solo
    # de la ruta del caso.
    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio = ''; Documentos = ''; Descargas = ''
        Imagenes   = ''; Musica     = ''; Videos     = ''; CarpetaDatos = ''
    })

    # Configuración de referencia: una unidad elegida y una carpeta
    # excluida, para que cada regla tenga algo que rechazar.
    $script:Cfg = [pscustomobject]@{
        Admin                 = $true
        UnidadesSeleccionadas = @('C:', 'E:')
        RutasExcluidas        = @('C:\excluida')
        # C: es un disco fijo y E: una llave USB, y ambas están elegidas:
        # el caso de la extraíble solo puede rechazarlo su propia regla.
        Unidades              = @(
            [pscustomobject]@{ Letra = 'C:'; Clase = 'fija';      Borrable = $true  }
            [pscustomobject]@{ Letra = 'E:'; Clase = 'extraible'; Borrable = $false }
        )
    }

    # Aplica una regla suelta exactamente como lo hace el embudo; si el
    # embudo cambia la forma de invocarlas, esta función debe cambiar con
    # él.
    function Invoke-ReglaSuelta {
        param($Regla, $Candidatos, $Contexto)
        return @(@($Candidatos) | Where-Object { & $Regla.Predicado $Contexto $_ })
    }

    # Cada candidato está construido para que lo rechace una sola regla.
    function Get-CandidatoDeCaso {
        param([string] $Caso)

        switch ($Caso) {
            # Informativo (exento de la guardia), en C: y fuera de lo
            # excluido: no lo rechaza ninguna regla.
            'control' {
                return New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'control' `
                                     -Ruta 'C:\normal\cosa' -Bytes 100 -Metodo 'Informativo' -Raices @()
            }
            # Unidad D:, no elegida.
            'otra unidad' {
                return New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'en D' `
                                     -Ruta 'D:\algo\en-d' -Bytes 90 -Metodo 'Informativo' -Raices @()
            }
            # Dentro de la carpeta excluida.
            'excluido' {
                return New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'excluido' `
                                     -Ruta 'C:\excluida\cosa' -Bytes 80 -Metodo 'Informativo' -Raices @()
            }
            # Ruta del sistema: solo la guardia la rechaza, y lo hace sin
            # tocar el disco (fragmento "\system32\"), igual en Windows y en
            # Linux.
            'vetado por la guardia' {
                return New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'system32' `
                                     -Ruta 'C:\Windows\System32' -Bytes 70 -Metodo 'Ruta' `
                                     -Raices @('C:\Windows')
            }
            # En la llave USB elegida y sin objeciones de la guardia: solo
            # su regla puede rechazarlo.
            'en extraible' {
                return New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'en la llave' `
                                     -Ruta 'E:\fotos\cosa.tmp' -Bytes 60 -Metodo 'Ruta' `
                                     -Raices @('E:\fotos')
            }
            default { throw "Caso desconocido: $Caso" }
        }
    }

    # Módulo falso que emite lo que haya en $script:Emision. No se usa un
    # cierre: se ejecutaría en un módulo dinámico sin acceso a las
    # funciones del núcleo.
    $script:Emision = @()
    $script:ModuloFalso = New-ModuloLimpieza -Id 'prueba' -Orden 99 `
        -Nombre 'Modulo de prueba' -Descripcion 'Emite lo que se le deje preparado.' `
        -Buscar {
            param($Configuracion, $Sync)
            foreach ($c in $script:Emision) { $c }
        }

    function Get-ClavesOrdenadas {
        param($Lista)
        return @(@($Lista) | Where-Object { $null -ne $_ } |
                 ForEach-Object { $_.ClaveExclusion } | Sort-Object)
    }
}

Describe 'la lista de reglas es el contrato del embudo' {

    It 'hay al menos las cuatro reglas de hoy, y cada una tiene nombre, coste y predicado' {
        $reglas = @(Get-ReglasFiltroCandidato)

        $reglas.Count | Should -BeGreaterOrEqual 4 -Because 'sin reglas el embudo no filtra nada'

        foreach ($regla in $reglas) {
            $regla.Nombre    | Should -Not -BeNullOrEmpty
            $regla.Predicado | Should -BeOfType [scriptblock]
            $regla.Coste     | Should -BeOfType [int]
        }
    }

    It 'los nombres no se repiten: son la clave con la que las prueba todo esto' {
        $nombres = @(Get-ReglasFiltroCandidato | ForEach-Object { $_.Nombre })
        @($nombres | Select-Object -Unique).Count | Should -Be $nombres.Count
    }

    It 'la lista no depende de la configuracion: se puede pedir sin nada montado' {
        # Las reglas son estáticas; lo que varía es el contexto.
        { Get-ReglasFiltroCandidato } | Should -Not -Throw
    }
}

Describe 'regla a regla, cada una rechaza lo suyo y respeta el resto' {
    <#
        Nivel de regla, sin embudo: cada caso comprueba que la regla
        rechaza lo suyo y deja pasar el control.
    #>

    It "la regla '<Regla>' rechaza el candidato '<Caso>' y deja pasar el control" -ForEach @(
        @{ Regla = 'Unidad seleccionada';     Caso = 'otra unidad' }
        @{ Regla = 'Exclusiones del usuario'; Caso = 'excluido' }
        @{ Regla = 'Guardia de rutas';        Caso = 'vetado por la guardia' }
        @{ Regla = 'Unidad donde se puede borrar'; Caso = 'en extraible' }
    ) {
        # $elegida y no $regla: PowerShell no distingue mayúsculas en los
        # nombres de variable y pisaría el $Regla del -ForEach.
        $elegida = @(Get-ReglasFiltroCandidato | Where-Object { $_.Nombre -eq $Regla })
        $elegida.Count | Should -Be 1 -Because "sin la regla '$Regla' este caso no comprueba nada"

        $contexto = New-ContextoEmbudo -Configuracion $script:Cfg
        $malo     = Get-CandidatoDeCaso -Caso $Caso
        $bueno    = Get-CandidatoDeCaso -Caso 'control'

        # Sin cebos, la primera comprobación pasaría por el motivo
        # equivocado.
        $malo  | Should -Not -BeNullOrEmpty -Because 'sin cebo no hay nada que rechazar'
        $bueno | Should -Not -BeNullOrEmpty -Because 'sin control no se puede ver que la regla no pasa de largo'

        # El @( ) exterior es necesario: una lista de un elemento se
        # desenvuelve, y .Count sobre un PSCustomObject suelto vale 1 en
        # PowerShell 7 pero $null en 5.1.
        @(Invoke-ReglaSuelta -Regla $elegida[0] -Candidatos $malo  -Contexto $contexto).Count |
            Should -Be 0 -Because "'$Regla' existe para rechazar esto"
        @(Invoke-ReglaSuelta -Regla $elegida[0] -Candidatos $bueno -Contexto $contexto).Count |
            Should -Be 1 -Because "'$Regla' no puede llevarse por delante un candidato legitimo"
    }

    It 'ningun predicado lee el candidato de $_' {
        # Con el candidato en $_, el predicado depende de que la variable
        # automática del Where-Object atraviese el operador "&", lo que
        # varía entre versiones; si no llega, el embudo descarta todos los
        # candidatos sin error. Se analiza el código fuente (sin
        # comentarios) porque el fallo solo se da en otra versión.
        $ruta  = Join-Path (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Core') 'ModuleRegistry.ps1'
        $texto = [regex]::Replace([IO.File]::ReadAllText($ruta), '(?s)<#.*?#>', '')
        $texto = (@($texto -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")

        $bloques = [regex]::Matches($texto, '(?s)Predicado\s*=\s*\{(.*?)\n\s*\}\)')
        # Si el patrón dejara de encontrar predicados, pasaría sin mirar.
        $bloques.Count | Should -BeGreaterOrEqual 3 -Because 'hay al menos tres predicados de varias lineas'

        foreach ($b in $bloques) {
            $b.Groups[1].Value | Should -Not -Match '\$_' -Because (
                'el candidato tiene que llegar como parametro, no en $_: ver la cabecera de Get-ReglasFiltroCandidato')
        }

        # Los de una sola línea, que el patrón anterior no captura.
        ($texto -split "`n" | Where-Object { $_ -match 'Predicado\s*=\s*\{.*\}' }) |
            Should -Not -Match '\$_'
    }

    It 'la regla del candidato nulo tira el nulo y solo el nulo' {
        # No se puede probar por el embudo, que ya descarta los nulos antes
        # de las reglas: es defensa en profundidad.
        $regla = @(Get-ReglasFiltroCandidato | Where-Object { $_.Nombre -eq 'Candidato existente' })
        $regla.Count | Should -Be 1

        $contexto = New-ContextoEmbudo -Configuracion $script:Cfg

        # Los nulos van mezclados con un candidato real: @($null) pasado a
        # un parámetro sin tipo llega como $null y el filtro no se
        # ejecutaría.
        $mezcla = @($null, (Get-CandidatoDeCaso -Caso 'control'), $null)
        $mezcla.Count | Should -Be 3 -Because 'si la lista llega colapsada, este caso no comprueba nada'

        # El @( ) exterior, por el mismo motivo que en la prueba anterior.
        $vivos = @(Invoke-ReglaSuelta -Regla $regla[0] -Candidatos $mezcla -Contexto $contexto)
        $vivos.Count | Should -Be 1
        $vivos[0].ClaveExclusion | Should -Be 'C:\normal\cosa'
    }

    It 'toda regla de la lista tiene su caso aqui: añadir una sin probarla hace fallar esto' {
        # Una regla nueva sin caso hace fallar esta prueba y dice cuál
        # falta.
        $conCaso = @(
            'Candidato existente'
            'Unidad seleccionada'
            'Exclusiones del usuario'
            'Guardia de rutas'
            'Unidad donde se puede borrar'
        )
        $sinCaso = @(Get-ReglasFiltroCandidato |
                     Where-Object { $_.Nombre -notin $conCaso } |
                     ForEach-Object { $_.Nombre })

        $sinCaso | Should -BeNullOrEmpty -Because (
            'una regla sin caso es una regla que puede dejar de aplicarse sin que nadie se entere')
    }
}

Describe 'el embudo aplica TODAS las reglas, no las que le apetezca' {
    <#
        Lo mismo de punta a punta, por Invoke-ModuloLimpieza: detecta que se
        recorra media lista o se cablee un filtro aparte.
    #>

    BeforeEach {
        $script:Emision = @(
            (Get-CandidatoDeCaso -Caso 'control')
            (Get-CandidatoDeCaso -Caso 'otra unidad')
            (Get-CandidatoDeCaso -Caso 'excluido')
            (Get-CandidatoDeCaso -Caso 'vetado por la guardia')
        )
    }

    It "el embudo tira '<Caso>', que es lo que rechaza la regla '<Regla>'" -ForEach @(
        @{ Regla = 'Unidad seleccionada';     Caso = 'otra unidad';           Clave = 'D:\algo\en-d' }
        @{ Regla = 'Exclusiones del usuario'; Caso = 'excluido';              Clave = 'C:\excluida\cosa' }
        @{ Regla = 'Guardia de rutas';        Caso = 'vetado por la guardia'; Clave = 'C:\Windows\System32' }
    ) {
        $r = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $script:Cfg

        $claves = Get-ClavesOrdenadas $r.Candidatos
        $claves | Should -Not -BeNullOrEmpty -Because 'si no sobrevive nada, esta prueba no distingue nada'
        $claves | Should -Contain 'C:\normal\cosa' -Because 'el control tiene que seguir vivo'
        $claves | Should -Not -Contain $Clave -Because "la regla '$Regla' ha dejado de aplicarse: se propone de mas"
    }

    It 'de los cuatro candidatos sobrevive exactamente el control' {
        $r = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $script:Cfg
        $r.Candidatos.Count | Should -Be 1
        $r.Descartados      | Should -Be 3 -Because 'lo que tira el embudo se sigue contando'
    }
}

Describe 'el ORDEN de las reglas no cambia el resultado' {
    <#
        Los predicados son puros e independientes: lo que sobrevive es la
        intersección, que no depende del orden. Es lo que permite ordenar
        las reglas por coste; una regla con estado rompería esta prueba.
    #>

    BeforeEach {
        $script:Emision = @(
            (Get-CandidatoDeCaso -Caso 'control')
            (Get-CandidatoDeCaso -Caso 'otra unidad')
            (Get-CandidatoDeCaso -Caso 'excluido')
            (Get-CandidatoDeCaso -Caso 'vetado por la guardia')
        )
    }

    It 'el embudo, las reglas al derecho, las reglas al reves y las reglas por separado dan lo mismo' {
        $contexto = New-ContextoEmbudo -Configuracion $script:Cfg
        $reglas   = @(Get-ReglasFiltroCandidato)
        $todos    = @($script:Emision)

        $delEmbudo = Get-ClavesOrdenadas (Invoke-ModuloLimpieza -Modulo $script:ModuloFalso `
                                                                -Configuracion $script:Cfg).Candidatos

        $enOrden = $todos
        foreach ($regla in $reglas) {
            $enOrden = Invoke-ReglaSuelta -Regla $regla -Candidatos $enOrden -Contexto $contexto
        }

        $alReves = $todos
        foreach ($regla in ($reglas[($reglas.Count - 1)..0])) {
            $alReves = Invoke-ReglaSuelta -Regla $regla -Candidatos $alReves -Contexto $contexto
        }

        # Por separado: cada candidato frente a cada regla, sin filtrado
        # previo.
        $porSeparado = @()
        foreach ($candidato in $todos) {
            $loAceptanTodas = $true
            foreach ($regla in $reglas) {
                if ((Invoke-ReglaSuelta -Regla $regla -Candidatos $candidato -Contexto $contexto).Count -eq 0) {
                    $loAceptanTodas = $false
                }
            }
            if ($loAceptanTodas) { $porSeparado += $candidato }
        }

        # Con todo vacío las listas serían iguales sin comprobar nada.
        $delEmbudo.Count | Should -BeGreaterThan 0
        $todos.Count     | Should -BeGreaterThan $delEmbudo.Count

        (Get-ClavesOrdenadas $enOrden)     | Should -Be $delEmbudo
        (Get-ClavesOrdenadas $alReves)     | Should -Be $delEmbudo -Because 'el resultado no puede depender del orden'
        (Get-ClavesOrdenadas $porSeparado) | Should -Be $delEmbudo -Because 'ninguna regla puede depender de otra'
    }
}

Describe 'el COSTE si depende del orden, y por eso van de barata a cara' {
    <#
        La guardia es la única regla que consulta el disco (un Get-Item por
        candidato y por nivel en Test-CadenaSinEnlaces). Va la última para
        no consultar candidatos que otra regla ya descarta; sigue siendo
        obligatoria, como fija el Describe anterior.
    #>

    It 'los costes declarados no decrecen' {
        $reglas = @(Get-ReglasFiltroCandidato)

        # Si todas costaran lo mismo, "no decrece" sería trivialmente
        # cierto.
        @($reglas | ForEach-Object { $_.Coste } | Select-Object -Unique).Count |
            Should -BeGreaterThan 1 -Because 'sin costes distintos no hay orden que proteger'

        for ($i = 1; $i -lt $reglas.Count; $i++) {
            $reglas[$i].Coste | Should -BeGreaterOrEqual $reglas[$i - 1].Coste -Because (
                ("la regla '{0}' cuesta menos que la anterior '{1}': el embudo esta pagando " +
                 'el filtro caro para candidatos que el barato ya iba a tirar') -f
                $reglas[$i].Nombre, $reglas[$i - 1].Nombre)
        }
    }

    It 'la unica regla que toca el disco es la mas cara de la lista' {
        $reglas  = @(Get-ReglasFiltroCandidato)
        $guardia = @($reglas | Where-Object { $_.Nombre -eq 'Guardia de rutas' })
        $guardia.Count | Should -Be 1

        $maximo = @($reglas | ForEach-Object { $_.Coste } | Measure-Object -Maximum).Maximum
        $guardia[0].Coste | Should -Be $maximo
    }

    Context 'y se nota: al disco no se le pregunta por lo que ya estaba descartado' {

        BeforeAll {
            # Método 'Ruta', no exento de la guardia: solo otra regla puede
            # evitar la consulta al disco.
            function Get-CandidatoEnUnidad {
                param([string] $Unidad)
                return New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'algo' `
                                     -Ruta ($Unidad + '\carpeta\cosa') -Bytes 10 -Metodo 'Ruta' `
                                     -Raices @($Unidad + '\carpeta')
            }
        }

        It 'un candidato de una unidad no elegida no llega a la guardia' {
            Mock Test-RutaSegura { return $true }
            $script:Emision = @(Get-CandidatoEnUnidad -Unidad 'D:')

            $null = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $script:Cfg

            Should -Invoke Test-RutaSegura -Times 0 -Exactly -Because (
                'la regla de unidad cuesta una comparacion de texto y la guardia, varias lecturas de disco')
        }

        It 'pero a un candidato que llega hasta ella si se le pregunta' {
            # Sin esta, un embudo que nunca llamara a la guardia pasaría la
            # anterior.
            Mock Test-RutaSegura { return $true }
            $script:Emision = @(Get-CandidatoEnUnidad -Unidad 'C:')

            $null = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $script:Cfg

            Should -Invoke Test-RutaSegura -Times 1 -Exactly
        }
    }
}

Describe 'el contexto del embudo se calcula una vez y aguanta lo raro' {

    It 'sin configuracion no revienta y no inventa exclusiones' {
        # [AllowNull] en un parámetro Mandatory: el modo consola y varias
        # pruebas llaman así.
        { New-ContextoEmbudo -Configuracion $null } | Should -Not -Throw

        $contexto = New-ContextoEmbudo -Configuracion $null
        $contexto.Excluidas.Count | Should -Be 0
        $contexto.SinRuta         | Should -Contain 'Informativo'
    }

    It 'una configuracion sin RutasExcluidas se comporta como antes de existir la funcion' {
        $contexto = New-ContextoEmbudo -Configuracion ([pscustomobject]@{ Admin = $true })
        $contexto.Excluidas.Count | Should -Be 0
    }

    It 'las reglas saben responder con un contexto sin configuracion' {
        # New-ContextoEmbudo admite nulo a propósito; una regla que no lo
        # tolerara tumbaría el análisis.
        $contexto = New-ContextoEmbudo -Configuracion $null
        $control  = Get-CandidatoDeCaso -Caso 'control'

        foreach ($regla in @(Get-ReglasFiltroCandidato)) {
            { Invoke-ReglaSuelta -Regla $regla -Candidatos $control -Contexto $contexto } |
                Should -Not -Throw -Because "la regla '$($regla.Nombre)' tiene que aguantar un contexto vacio"
        }
    }

    It 'el embudo, en cambio, EXIGE configuracion: sin ella no hay analisis que valga' {
        # Un contexto sin configuración significa "nada que excluir"; un
        # embudo sin configuración es un error de quien llama y debe
        # fallar, no filtrar a medias.
        $script:Emision = @(Get-CandidatoDeCaso -Caso 'control')
        { Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $null } | Should -Throw
    }

    It 'un modulo que emite nulos no produce candidatos fantasma' {
        $script:Emision = @($null, (Get-CandidatoDeCaso -Caso 'control'), $null)
        $r = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $script:Cfg
        $r.Candidatos.Count | Should -Be 1
        $r.Candidatos[0].ClaveExclusion | Should -Be 'C:\normal\cosa'
    }
}
