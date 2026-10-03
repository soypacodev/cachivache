<#
.SYNOPSIS
    El suelo de cobertura y el veredicto sobre si se ha bajado de él.
    Cálculo puro.

.DESCRIPTION
    Separado de Probar.ps1 para poder cargarlo y probarlo sin efectos: no
    mide ni ejecuta pruebas; recibe porcentajes ya medidos y devuelve una
    lista de motivos.

    El suelo es un trinquete (la cobertura solo puede subir), no una medida
    de calidad: lo que protege el proyecto son las invariantes y las
    pruebas de mutación. El suelo solo evita que una parte del programa
    quede sin ejecutar.

    Se fija por carpeta y no solo en total, para que no se compense una
    parte mal probada con pruebas fáciles de otra.

    src/UI tiene un suelo bajo porque sin WPF no hay nada que ejecutar; esa
    parte la cubren docs/PRUEBA-MANUAL.md, la CI en Windows y el banco de
    pruebas.
#>

function Get-SueloCobertura {
    <#
    .SYNOPSIS
        El mínimo exigible, en porcentaje, para el total y para cada
        carpeta de src.

    .DESCRIPTION
        Se expone como función para que lo usen igual quien mide y quien
        lo prueba.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    # Cada suelo es la menor de las medidas de Linux y Windows, redondeada
    # hacia abajo y con un punto de margen: algunas ramas solo se ejecutan
    # en un sistema o en una versión de PowerShell. Para subirlos hacen
    # falta las dos medidas; se anotan junto a cada valor.
    return @{
        'total'   = 65    # Linux 66,1   Windows 66,8
        'Core'    = 87    # Linux 88,6   Windows 89,4
        'Modules' = 64    # Linux 65,4   Windows 66,6
        'Cli'     = 88    # Linux 89,4   Windows 89,4
        'UI'      = 4     # Linux  5,1   Windows  5,1 - sin WPF; ver la cabecera
    }
}

function Test-CoberturaSuficiente {
    <#
    .SYNOPSIS
        Los motivos por los que la cobertura medida no basta. Vacío si basta.

    .PARAMETER Medido
        Tabla carpeta -> porcentaje, con una clave 'total'. Las claves
        siguen las mayúsculas de los nombres de carpeta.

    .OUTPUTS
        Lista de cadenas; vacía si todo está en orden.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [hashtable] $Medido
    )

    $suelo   = Get-SueloCobertura
    $motivos = [Collections.Generic.List[string]]::new()

    if ($null -eq $Medido -or $Medido.Count -eq 0) {
        # Sin medidas, la medición ha fallado: no puede contar como éxito.
        $motivos.Add('No hay ninguna medida de cobertura: la medicion no se ha llegado a hacer.')
        return $motivos.ToArray()
    }

    foreach ($clave in ($suelo.Keys | Sort-Object)) {
        if (-not $Medido.ContainsKey($clave)) {
            # Carpeta exigida sin medida (renombrada o borrada).
            $motivos.Add(("Falta la cobertura de '{0}', que el suelo exige. .Se ha renombrado o borrado?" -f $clave))
            continue
        }
        $valor = [double] $Medido[$clave]
        if ($valor -lt [double] $suelo[$clave]) {
            $motivos.Add(('{0}: {1:N1}% y el suelo es {2}%. La cobertura solo puede subir.' -f `
                          $clave, $valor, $suelo[$clave]))
        }
    }

    foreach ($clave in ($Medido.Keys | Sort-Object)) {
        if (-not $suelo.ContainsKey($clave)) {
            # Una carpeta nueva exige decidir explícitamente su suelo.
            $motivos.Add(("'{0}' no tiene suelo. Añádelo a Get-SueloCobertura con el valor medido." -f $clave))
        }
    }

    return $motivos.ToArray()
}
