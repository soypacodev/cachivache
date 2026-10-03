<#
    Configuracion de PSScriptAnalyzer. Cada regla excluida tiene su motivo;
    si deja de aplicarse, se quita de la lista y se corrige el codigo.
#>
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Nombres en castellano: el plural es correcto (Get-UnidadesFijas
        # devuelve varias unidades). La regla asume convenciones del ingles.
        'PSUseSingularNouns'

        # Todos los modulos reciben ($Configuracion, $Sync) por contrato del
        # registro de modulos, aunque alguno no use los dos.
        'PSReviewUnusedParameter'

        # El modo consola es una interfaz: Write-Host escribe con color.
        'PSAvoidUsingWriteHost'

        # Los archivos src/UI/Window.*.ps1 son partes del cuerpo de
        # Show-VentanaPrincipal, que los carga en su propio ambito: lo que
        # define uno lo usa otro, y el analizador, que mira cada archivo por
        # separado, lo da por no usado. Ver docs/ESTRUCTURA.md (seccion 3).
        'PSUseDeclaredVarsMoreThanAssignments'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
    }
}
