<#
    Los dos cortes que impiden borrar en una unidad extraíble.

    Separado de Extraibles.Tests.ps1, que carga solo src/Core/Extraibles.ps1
    (cálculo puro): estas pruebas cubren la integración y necesitan el
    núcleo completo.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio = ''; Documentos = ''; Descargas = ''
        Imagenes   = ''; Musica     = ''; Videos     = ''; CarpetaDatos = ''
    })
}

Describe 'los dos cortes que impiden borrar en una extraible' {
    <#
        Una extraíble se analiza pero no se borra en ella. Hay dos cortes
        que se cubren mutuamente:

          - El del embudo usa la lista de unidades calculada al arrancar:
            barato y aplicado a todos los candidatos.
          - El del motor mira la ruta directamente y cubre un disco
            conectado después de arrancar.

        El índice, el mapa y el informe no se tocan: ahí la extraíble debe
        aparecer.
    #>

    BeforeAll {
        # C: fijo y E: llave USB, ambas elegidas, para que a E: la rechace
        # su propia regla.
        $script:CfgConLlave = [pscustomobject]@{
            Admin                 = $true
            UnidadesSeleccionadas = @('C:', 'E:')
            RutasExcluidas        = @()
            Unidades              = @(
                [pscustomobject]@{ Letra = 'C:'; Clase = 'fija';      Borrable = $true  }
                [pscustomobject]@{ Letra = 'E:'; Clase = 'extraible'; Borrable = $false }
            )
        }
    }

    It 'el contexto del embudo sabe en que letras no se puede borrar' {
        $contexto = New-ContextoEmbudo -Configuracion $script:CfgConLlave
        $contexto.NoBorrables.Contains('E:') | Should -BeTrue
        $contexto.NoBorrables.Contains('C:') | Should -BeFalse
    }

    It 'y no distingue mayusculas, porque las letras de unidad no las distinguen' {
        $contexto = New-ContextoEmbudo -Configuracion $script:CfgConLlave
        $contexto.NoBorrables.Contains('e:') | Should -BeTrue
    }

    It 'una configuracion sin lista de unidades no inventa prohibiciones' {
        # Ante lo desconocido, el comportamiento anterior: "todo prohibido"
        # impediría borrar con una configuración incompleta.
        $contexto = New-ContextoEmbudo -Configuracion ([pscustomobject]@{ Admin = $true })
        $contexto.NoBorrables.Count | Should -Be 0
        { New-ContextoEmbudo -Configuracion $null } | Should -Not -Throw
    }

    It 'la regla del embudo tira lo de la extraible y respeta lo del disco fijo' {
        $regla = @(Get-ReglasFiltroCandidato |
                   Where-Object { $_.Nombre -eq 'Unidad donde se puede borrar' })
        $regla.Count | Should -Be 1 -Because 'sin la regla esto no comprueba nada'

        $contexto = New-ContextoEmbudo -Configuracion $script:CfgConLlave
        $enLlave = New-Candidato -ModuloId 'p' -Categoria 'c' -Nombre 'en la llave' `
                                 -Ruta 'E:\fotos\x.tmp' -Bytes 10 -Metodo 'Ruta' -Raices @('E:\fotos')
        $enDisco = New-Candidato -ModuloId 'p' -Categoria 'c' -Nombre 'en el disco' `
                                 -Ruta 'C:\normal\x.tmp' -Bytes 10 -Metodo 'Informativo' -Raices @()

        (& $regla[0].Predicado $contexto $enLlave) | Should -BeFalse
        (& $regla[0].Predicado $contexto $enDisco) | Should -BeTrue
    }

    It 'lo que no tiene letra de unidad sobrevive a la regla' {
        # Comandos, papelera, informativos: si desaparecieran, se rompería
        # un módulo entero sin error.
        $regla = @(Get-ReglasFiltroCandidato |
                   Where-Object { $_.Nombre -eq 'Unidad donde se puede borrar' })
        $contexto = New-ContextoEmbudo -Configuracion $script:CfgConLlave
        $comando = New-Candidato -ModuloId 'p' -Categoria 'c' -Nombre 'prune' `
                                 -Ruta 'docker system prune' -Bytes 0 -Metodo 'Comando' `
                                 -Ejecutable 'docker' -Argumentos @('system', 'prune')
        (& $regla[0].Predicado $contexto $comando) | Should -BeTrue
    }

    It 'un candidato de papelera CON letra de unidad sobrevive a la regla' {
        # El candidato de comando sobrevive también por no tener letra; la
        # papelera sí la tiene (su Ruta es 'E:\') y solo la guarda de
        # SinRuta la deja pasar. Si el módulo debe tocarla o no se decide
        # en el propio módulo.
        $regla = @(Get-ReglasFiltroCandidato |
                   Where-Object { $_.Nombre -eq 'Unidad donde se puede borrar' })
        $contexto = New-ContextoEmbudo -Configuracion $script:CfgConLlave
        $papelera = New-Candidato -ModuloId 'papelera' -Categoria 'c' -Nombre 'Papelera de E:' `
                                  -Ruta 'E:\' -Bytes 100 -Metodo 'Papelera' -Raices @()
        (& $regla[0].Predicado $contexto $papelera) | Should -BeTrue -Because (
            'lo que no se borra por ruta no lo juzga esta regla')
    }

    It 'Get-TipoDeUnidad no lanza y responde "no lo se" con lo que no es una unidad' {
        # Fuera de Windows devuelve siempre $null; se llama desde el motor
        # de borrado y no debe lanzar.
        { Get-TipoDeUnidad -Ruta 'C:\algo\x.tmp' } | Should -Not -Throw
        { Get-TipoDeUnidad -Ruta $null }           | Should -Not -Throw
        Get-TipoDeUnidad -Ruta ''                        | Should -BeNullOrEmpty
        Get-TipoDeUnidad -Ruta 'docker system prune'     | Should -BeNullOrEmpty
        Get-TipoDeUnidad -Ruta '\\servidor\recurso\x'    | Should -BeNullOrEmpty
    }

    It 'el motor no rechaza nada cuando no sabe de que unidad se trata' {
        # En Linux Get-TipoDeUnidad siempre dice "no lo sé": el corte debe
        # callarse o no se podría borrar en equipos con discos sin
        # clasificar.
        $candidato = New-Candidato -ModuloId 'p' -Categoria 'c' -Nombre 'x' `
                                   -Ruta 'C:\normal\x.tmp' -Bytes 10 -Metodo 'Ruta' `
                                   -Raices @('C:\normal')
        $motivo = Get-MotivoNoSeBorra -Candidato $candidato -Bytes 10 -Permanente

        # Vacío, no solo "que no mencione las extraíbles": sin la guarda de
        # 'desconocida' el motor rechazaría todo con otro texto y un
        # -Not -Match seguiría pasando.
        $motivo | Should -BeNullOrEmpty -Because (
            'sin saber que clase de unidad es, el motor no puede objetar nada')
    }
}

Describe 'el modulo de la papelera, que la regla del embudo no puede proteger' {
    <#
        25-Papelera emite un candidato cuya Ruta es la primera unidad con
        contenido y vacía todas las letras que recibe. La regla del embudo
        solo ve esa ruta (C:), no la llave USB de la lista: el corte debe
        estar en el módulo.
    #>

    It 'no mide ni vacia la papelera de una unidad no borrable' {
        $modulo = Get-ModuloLimpieza -Id 'papelera' -Raiz $script:Raiz
        $modulo | Should -Not -BeNullOrEmpty -Because 'sin el modulo esto no comprueba nada'

        # La llave USB va primera a propósito: sin el filtro, sería la Ruta
        # del candidato.
        $cfg = [pscustomobject]@{
            Admin                 = $true
            UnidadesSeleccionadas = @()
            Unidades              = @(
                [pscustomobject]@{ Letra = 'E:'; Clase = 'extraible'; Borrable = $false }
                [pscustomobject]@{ Letra = 'C:'; Clase = 'fija';      Borrable = $true  }
            )
        }
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $cfg `
                                           -Sync (New-EstadoSincronizado)

        foreach ($candidato in @($resultado.Candidatos)) {
            $candidato.Ruta | Should -Not -Match '^[Ee]:' -Because (
                'la papelera de una unidad extraible no se toca')
        }
    }

    It 'y una unidad sin el campo Borrable no rompe el modulo' {
        # Compatibilidad: una configuración antigua o hecha a mano no debe
        # quedarse sin papelera por un campo ausente.
        $modulo = Get-ModuloLimpieza -Id 'papelera' -Raiz $script:Raiz
        $cfg = [pscustomobject]@{
            Admin                 = $true
            UnidadesSeleccionadas = @()
            Unidades              = @([pscustomobject]@{ Letra = 'C:' })
        }
        { Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $cfg `
                                -Sync (New-EstadoSincronizado) } | Should -Not -Throw
    }
}

Describe 'lo que no se puede ejecutar aqui, se ata por texto' {
    <#
        Tres de los cuatro cortes no se pueden ejercitar fuera de Windows:

          - El del motor necesita una extraíble real.
          - El del módulo de la papelera necesita un E:\$Recycle.Bin.
          - El filtro de Get-UnidadesAnalizables necesita una llave USB.

        La decisión se prueba en Extraibles.Tests.ps1; aquí solo se
        comprueba, por texto y sin comentarios, que los enganches siguen
        llamándola. Detecta que se borre un corte, no que funcione.
    #>

    BeforeAll {
        function script:Get-CodigoSinComentarios {
            param([string] $Ruta)
            $t = [regex]::Replace([IO.File]::ReadAllText($Ruta), '(?s)<#.*?#>', '')
            return (@($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        }
        $script:Motor    = script:Get-CodigoSinComentarios (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Remove.ps1')
        $script:Discos   = script:Get-CodigoSinComentarios (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'FileSystem.ps1')
        $script:Papelera = script:Get-CodigoSinComentarios (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Modules') '25-Papelera.ps1')
    }

    It 'los tres archivos se han leido de verdad' {
        # Sin contenido, las pruebas siguientes pasarían solas.
        $script:Motor.Length    | Should -BeGreaterThan 1000
        $script:Discos.Length   | Should -BeGreaterThan 1000
        $script:Papelera.Length | Should -BeGreaterThan 500
    }

    It 'el motor sigue preguntando por la clase de unidad antes de borrar' {
        $script:Motor | Should -Match 'Get-TipoDeUnidad'
        $script:Motor | Should -Match 'Test-PuedeProducirCandidatoBorrable'
        $script:Motor | Should -Match 'Get-MotivoNoBorrableEnUnidad'
    }

    It 'y sigue callandose cuando no sabe de que unidad se trata' {
        # Sin esta comparación, si la clasificación fallara se dejaría de
        # borrar todo en silencio.
        $script:Motor | Should -Match "desconocida"
    }

    It 'el descubrimiento de unidades ya no filtra por Fixed a mano' {
        # La decisión vive en Extraibles.ps1; un "-ne Fixed" aquí sería un
        # segundo criterio.
        $script:Discos | Should -Match 'Test-UnidadAnalizable'
        $script:Discos | Should -Not -Match '\-ne \[IO\.DriveType\]::Fixed'
    }

    It 'y cada unidad sale con su clase y con si en ella se puede borrar' {
        $script:Discos | Should -Match 'Clase\s+= \$clase'
        $script:Discos | Should -Match 'Borrable\s+= \(Test-PuedeProducirCandidatoBorrable'
    }

    It 'el modulo de la papelera sigue mirando el campo Borrable' {
        # La regla del embudo no protege este módulo (ver arriba): sin el
        # filtro, o se pierde la papelera de C: o se vacía la del disco
        # externo.
        $script:Papelera | Should -Match '\$_\.Borrable'
    }

    It 'Get-UnidadesAnalizables no puede contradecir a Extraibles.ps1' {
        # Se ejecuta sobre las unidades reales del equipo: comprueba que
        # las dos respuestas salen de la misma función.
        $unidades = @(Get-UnidadesAnalizables)
        foreach ($unidad in $unidades) {
            $unidad.Clase    | Should -Not -BeNullOrEmpty
            $unidad.Borrable | Should -BeOfType [bool]
            $unidad.Borrable | Should -Be (Test-PuedeProducirCandidatoBorrable -Clase $unidad.Clase) `
                -Because ('la unidad ' + $unidad.Letra + ' dice una cosa y la regla dice otra')
            (Test-UnidadAnalizable -Clase $unidad.Clase).Analizable | Should -BeTrue `
                -Because 'lo que sale de aqui es, por definicion, lo que se analiza'
        }
    }
}
