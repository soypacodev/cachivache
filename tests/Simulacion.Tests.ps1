BeforeAll {
    . (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Core') 'Format.ps1')
}

Describe 'La simulación tiene que decir lo que ha hecho' {
    <#
        El resultado de la simulación debe verse en la tabla de Resultados,
        no solo en el panel de Registro.
    #>

    It 'dice cuantos y cuanto' {
        $texto = Format-ResumenSimulacion -Simulados 33 -Liberado 10553584517
        $texto | Should -Match '33 elementos'
        $texto | Should -Match ([regex]::Escape((Format-Tamano 10553584517)))
    }

    It 'deja claro que NO se ha borrado nada' {
        # Debe leerse de un vistazo, antes que la cifra.
        $texto = Format-ResumenSimulacion -Simulados 33 -Liberado 1024
        $texto | Should -Match 'NO se ha borrado nada'
    }

    It 'dice que hacer ahora' {
        $texto = Format-ResumenSimulacion -Simulados 5 -Liberado 1024
        $texto | Should -Match 'Solo simular'
    }

    It 'cuenta los que no se habrian podido borrar' {
        # Callarlos sería prometer un espacio que no se libera.
        $texto = Format-ResumenSimulacion -Simulados 33 -Liberado 1024 -Bloqueados 4
        $texto | Should -Match '4 no se habrían borrado'
        $texto | Should -Match 'BLOQUEADO'
    }

    It 'y no los menciona cuando no hay ninguno' {
        $texto = Format-ResumenSimulacion -Simulados 33 -Liberado 1024 -Bloqueados 0
        $texto | Should -Not -Match 'BLOQUEADO'
    }

    It 'habla en singular cuando es uno' {
        $texto = Format-ResumenSimulacion -Simulados 1 -Liberado 1024 -Bloqueados 1
        $texto | Should -Match '1 elemento\b'
        $texto | Should -Not -Match '1 elementos'
        $texto | Should -Match '1 no se habría borrado'
    }

    It 'con cero marcados no promete nada' {
        $texto = Format-ResumenSimulacion -Simulados 0 -Liberado 0
        $texto | Should -Match 'no había nada que borrar'
        $texto | Should -Not -Match '0 elementos'
    }

    It 'nunca se queda un hueco de formato sin rellenar' {
        # '-f' tiene más precedencia que '+': 'texto {0}' + 'mas' -f $x
        # deja el {0} literal en pantalla.
        foreach ($caso in @(@(0,0,0), @(1,1024,0), @(33,99999,4))) {
            $texto = Format-ResumenSimulacion -Simulados $caso[0] -Liberado $caso[1] -Bloqueados $caso[2]
            $texto | Should -Not -Match '\{\d+\}'
        }
    }
}
