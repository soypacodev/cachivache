<#
    Pruebas de los perfiles de limpieza.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Configuración mínima con los mismos campos de umbral que
    # New-Configuracion, que consulta unidades y carpetas reales.
    function Get-ConfiguracionDePrueba {
        return [pscustomobject]@{
            Perfil            = ''
            DiasSinUso        = 0
            MinimoMB          = 0
            MinimoGrandeMB    = 0
            MinimoDuplicadoMB = 0
            IncluirMenores    = $false
            Permanente        = $false
        }
    }
}

Describe 'Perfiles' {

    It 'ofrece los cuatro perfiles' {
        @(Get-PerfilesLimpieza).Count | Should -Be 4
    }

    It 'devuelve equilibrado cuando el identificador no existe' {
        (Get-PerfilLimpieza 'inventado').Id | Should -Be 'equilibrado'
    }

    It 'aplica los umbrales del perfil' {
        $configuracion = Get-ConfiguracionDePrueba
        $resultado = Set-PerfilConfiguracion -Configuracion $configuracion -Perfil 'conservador'
        $resultado.DiasSinUso | Should -Be 365
        $resultado.MinimoMB   | Should -Be 50
    }

    It 'no sobreescribe nada en el perfil personalizado' {
        $configuracion = Get-ConfiguracionDePrueba
        $configuracion.DiasSinUso = 42
        $configuracion.MinimoMB   = 7
        $resultado = Set-PerfilConfiguracion -Configuracion $configuracion -Perfil 'personalizado'
        $resultado.DiasSinUso | Should -Be 42
        $resultado.MinimoMB   | Should -Be 7
    }
}

Describe 'Todo umbral declarado por un perfil se aplica de verdad' {
    <#
        Cada umbral que declara un perfil debe llegar a la configuración,
        incluidos MinimoGrandeMB y MinimoDuplicadoMB.
    #>

    It 'el perfil <Id> escribe todos sus umbrales en la configuracion' -ForEach @(
        @{ Id = 'conservador' }, @{ Id = 'equilibrado' }, @{ Id = 'agresivo' }
    ) {
        $perfil = Get-PerfilLimpieza $Id
        $resultado = Set-PerfilConfiguracion -Configuracion (Get-ConfiguracionDePrueba) -Perfil $Id

        # Todo campo del perfil que exista en la configuración debe
        # copiarse, salvo los de presentación.
        $soloPresentacion = @('Id', 'Nombre', 'Resumen', 'Descripcion', 'Color')
        foreach ($campo in ($perfil.PSObject.Properties.Name | Where-Object { $_ -notin $soloPresentacion })) {
            if ($null -eq $resultado.PSObject.Properties[$campo]) { continue }
            $resultado.$campo | Should -Be $perfil.$campo -Because "el perfil $Id declara $campo y debe aplicarlo"
        }
    }

    It 'Exhaustivo cumple su promesa de bajar los umbrales frente a Equilibrado' {
        $equilibrado = Get-PerfilLimpieza 'equilibrado'
        $exhaustivo  = Get-PerfilLimpieza 'agresivo'

        $exhaustivo.MinimoMB       | Should -BeLessThan $equilibrado.MinimoMB
        $exhaustivo.DiasSinUso     | Should -BeLessThan $equilibrado.DiasSinUso
        $exhaustivo.MinimoGrandeMB | Should -BeLessThan $equilibrado.MinimoGrandeMB
    }

    It 'ningun perfil baja el umbral de duplicados por debajo de 1 MB' {
        # Duplicados es el único módulo que levanta el veto por extensión
        # personal: cuanto más bajo el umbral, más archivos del usuario
        # entran en la lista.
        foreach ($perfil in Get-PerfilesLimpieza) {
            $perfil.MinimoDuplicadoMB | Should -BeGreaterOrEqual 1 -Because "$($perfil.Id) no debe exponer archivos personales pequeños"
        }
    }

    It 'ningun perfil activa el borrado permanente por su cuenta' {
        # El borrado permanente solo puede venir de una decisión explícita
        # del usuario (-Permanente o la casilla de ajustes).
        foreach ($perfil in Get-PerfilesLimpieza) {
            $perfil.Permanente | Should -BeFalse -Because "$($perfil.Id) no debe saltarse la papelera sin que el usuario lo pida"
        }
    }
}
