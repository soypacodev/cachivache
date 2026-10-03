<#
    Pruebas del contrato de candidato.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
}

Describe 'New-Candidato' {

    It 'preselecciona lo de riesgo bajo y sin avisos' {
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\una\ruta\suficientemente\larga' -Riesgo 'Bajo'
        $candidato.Seleccionado | Should -BeTrue
    }

    It 'NO preselecciona nada que lleve aviso' {
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\una\ruta\suficientemente\larga' -Riesgo 'Bajo' -Aviso 'cuidado'
        $candidato.Seleccionado | Should -BeFalse
    }

    It 'NO preselecciona nada de riesgo medio o alto: <Riesgo>' -ForEach @(
        @{ Riesgo = 'Medio' }
        @{ Riesgo = 'Alto' }
    ) {
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\una\ruta\suficientemente\larga' -Riesgo $Riesgo
        $candidato.Seleccionado | Should -BeFalse
    }

    It 'NO preselecciona los elementos informativos' {
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\una\ruta\suficientemente\larga' -Metodo 'Informativo'
        $candidato.Seleccionado | Should -BeFalse
    }

    It 'respeta una preseleccion explicita' {
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\una\ruta\suficientemente\larga' -Riesgo 'Alto' -Preseleccionado $true
        $candidato.Seleccionado | Should -BeTrue
    }

    It 'rechaza un metodo de eliminacion desconocido' {
        { New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' -Ruta 'C:\x\y\z\larga' -Metodo 'Inventado' } |
            Should -Throw
    }

    It 'ForzarPermanente es falso por defecto: por defecto todo respeta la papelera' {
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\una\ruta\suficientemente\larga'
        $candidato.ForzarPermanente | Should -BeFalse
    }

    It 'ForzarPermanente se puede activar explicitamente' {
        $candidato = New-Candidato -ModuloId 'x' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\una\ruta\suficientemente\larga' -ForzarPermanente
        $candidato.ForzarPermanente | Should -BeTrue
    }
}

Describe 'la regla de premarcado y su explicacion no pueden discrepar' {

    <#
        El criterio de premarcado debe estar a la vista mientras se decide
        qué borrar. La explicación sale de la misma función que la
        decisión; estas pruebas garantizan que sigan coincidiendo.
    #>

    It 'la explicacion coincide con la decision en las 24 combinaciones' {
        # Se recorren todas: si cambia la regla y no el texto (o al revés),
        # falla aquí.
        $desacuerdos = @()
        foreach ($riesgo in @('Bajo', 'Medio', 'Alto')) {
            foreach ($aviso in @('', 'contiene una carpeta projects')) {
                foreach ($metodo in @('Ruta', 'Contenido', 'Comando', 'Informativo')) {
                    $marcado = Test-DebeVenirMarcado -Riesgo $riesgo -Aviso $aviso -Metodo $metodo
                    $motivo  = Get-MotivoPremarcado  -Riesgo $riesgo -Aviso $aviso -Metodo $metodo

                    $diceMarcado = $motivo.StartsWith('Marcado')
                    if ($marcado -ne $diceMarcado) {
                        $desacuerdos += ('{0}/{1}/{2}: decide {3} pero dice "{4}"' -f
                                         $riesgo, $(if ($aviso) { 'con aviso' } else { 'sin aviso' }),
                                         $metodo, $marcado, $motivo)
                    }
                }
            }
        }
        $desacuerdos | Should -BeNullOrEmpty -Because (
            'una explicacion que no coincide con lo que hizo el programa es peor que no explicar nada')
    }

    It 'New-Candidato usa la misma regla, no una copia' {
        foreach ($riesgo in @('Bajo', 'Medio', 'Alto')) {
            foreach ($aviso in @('', 'ojo')) {
                $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\x' `
                        -Riesgo $riesgo -Aviso $aviso
                $esperado = Test-DebeVenirMarcado -Riesgo $riesgo -Aviso $aviso -Metodo 'Ruta'
                $c.Seleccionado | Should -Be $esperado -Because "$riesgo / '$aviso'"
            }
        }
    }

    It 'el motivo nombra la causa QUE DECIDIO, no la primera que encaje' {
        # Un elemento puede cumplir dos motivos a la vez; mostrar el que no
        # decidió manda a mirar el sitio equivocado.
        $conLasDos = Get-MotivoPremarcado -Riesgo 'Alto' -Aviso 'contiene projects' -Metodo 'Ruta'
        $conLasDos | Should -BeLike '*aviso*'

        $soloRiesgo = Get-MotivoPremarcado -Riesgo 'Alto' -Aviso '' -Metodo 'Ruta'
        $soloRiesgo | Should -BeLike '*riesgo alto*'

        $informativo = Get-MotivoPremarcado -Riesgo 'Alto' -Aviso 'ojo' -Metodo 'Informativo'
        $informativo | Should -BeLike '*no borra nada*'
    }

    It 'lo que viene marcado lo dice en positivo' {
        (Get-MotivoPremarcado -Riesgo 'Bajo') | Should -BeLike 'Marcado:*'
        (Get-MotivoPremarcado -Riesgo 'Bajo') | Should -BeLike '*riesgo bajo*'
    }
}

Describe 'el resumen dice el criterio, no solo la cuenta' {

    BeforeAll {
        function Get-Cand3 {
            param([string] $Riesgo = 'Bajo', [string] $Aviso = '')
            New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\x' `
                -Riesgo $Riesgo -Aviso $Aviso
        }
    }

    It 'con una mezcla, dice cuantos y de quien es la decision' {
        $lote = @((Get-Cand3), (Get-Cand3), (Get-Cand3 -Riesgo 'Alto'))
        $t = Get-ResumenPremarcado -Candidatos $lote
        $t | Should -BeLike '*2 vienen marcados*'
        $t | Should -BeLike '*riesgo bajo y sin avisos*'
        $t | Should -BeLike '*los marcas tú*'
    }

    It 'cuando estan todos marcados no habla de los que no hay' {
        $t = Get-ResumenPremarcado -Candidatos @((Get-Cand3), (Get-Cand3))
        $t | Should -BeLike '*Los 2 vienen marcados*'
        $t | Should -Not -BeLike '*los marcas tú*'
    }

    It 'cuando no hay ninguno marcado lo dice, y dice de quien depende' {
        # Una lista entera sin marcar parece un programa que no ha
        # encontrado nada útil.
        $t = Get-ResumenPremarcado -Candidatos @((Get-Cand3 -Riesgo 'Alto'), (Get-Cand3 -Aviso 'ojo'))
        $t | Should -BeLike '*Ninguno viene marcado*'
        $t | Should -BeLike '*Los marcas tú*'
    }

    It 'con la lista vacia no dice nada, en vez de decir una obviedad' {
        Get-ResumenPremarcado -Candidatos @() | Should -Be ''
    }
}
