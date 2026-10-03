<#
.SYNOPSIS
    Qué se puede hacer con cada tipo de unidad: analizarla y borrar en
    ella. Cálculo puro.

.DESCRIPTION
    Regla: las unidades extraíbles se analizan pero nunca producen
    candidatos borrables. Se pueden desconectar a mitad de un borrado y
    dejarlo a medias, sin posibilidad de deshacer; medir no tiene ese
    riesgo.

    La decisión vive en estas funciones, y no en comprobaciones repetidas,
    porque la necesitan varios sitios (listado de unidades, filtro de
    candidatos, motor de borrado e informe).

    Ante lo desconocido: ni analizable ni borrable.

    Fuera de alcance:
      - Unidades de red: disco de otro equipo; un recorrido completo puede
        tardar horas. La guardia las veta.
      - Móviles y cámaras por MTP: no tienen letra de unidad y requieren
        la API del Shell.
#>

function Get-ClaseDeUnidad {
    <#
    .SYNOPSIS
        Traduce el tipo de unidad del sistema a una clase del programa:
        fija, extraible, red, optica o desconocida.

    .DESCRIPTION
        Acepta las distintas fuentes del tipo de unidad, para que un
        cambio de fuente no degrade la respuesta a "desconocida" en silencio:

          - [IO.DriveInfo] ([System.IO.DriveType]: "Fixed", "Removable",
            "Network", "CDRom"), mucho más rápido que CIM.
          - Win32_LogicalDisk / Get-CimInstance (DriveType numérico; mismos
            valores, ambos salen de GetDriveType de Win32).
          - Get-Volume ("CD-ROM", con guion).

        Disco RAM (6) y sin raíz (1) se tratan como desconocida.

    .PARAMETER Tipo
        Número de DriveType, nombre o valor de System.IO.DriveType. Nulo
        devuelve "desconocida".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Tipo
    )

    if ($null -eq $Tipo) { return 'desconocida' }

    # [string] convierte la enumeración en su nombre y el entero en dígitos.
    $texto = ([string]$Tipo).Trim()
    if ([string]::IsNullOrEmpty($texto)) { return 'desconocida' }

    $numero = 0
    if ([int]::TryParse($texto, [ref]$numero)) {
        switch ($numero) {
            2 { return 'extraible' }
            3 { return 'fija' }
            4 { return 'red' }
            5 { return 'optica' }
            default { return 'desconocida' }
        }
    }

    # ToLowerInvariant: la cultura del sistema no debe influir en el veredicto.
    switch ($texto.ToLowerInvariant()) {
        'removable' { return 'extraible' }
        'fixed'     { return 'fija' }
        'network'   { return 'red' }
        # Las dos grafías: DriveType dice "CDRom" y Get-Volume "CD-ROM".
        'cdrom'     { return 'optica' }
        'cd-rom'    { return 'optica' }
        default     { return 'desconocida' }
    }
}

function Test-UnidadAnalizable {
    <#
    .SYNOPSIS
        Indica si se debe recorrer una unidad de esta clase y, si no, por qué.

    .DESCRIPTION
        Devuelve un objeto con el motivo para que una unidad omitida se
        pueda explicar al usuario y no parezca un fallo.

        Fijas y extraíbles sí. Ópticas no (no hay nada que liberar) y red
        tampoco (ver la cabecera del archivo).

    .PARAMETER Clase
        Una clase de Get-ClaseDeUnidad. Cualquier otro valor se trata como
        desconocida.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Clase
    )

    # [string] convierte $null en cadena vacía, que cae en el default.
    $normalizada = $Clase.Trim().ToLowerInvariant()

    switch ($normalizada) {
        'fija' {
            return [pscustomobject]@{ Analizable = $true; Clase = 'fija'; Motivo = '' }
        }
        'extraible' {
            return [pscustomobject]@{ Analizable = $true; Clase = 'extraible'; Motivo = '' }
        }
        'red' {
            return [pscustomobject]@{
                Analizable = $false
                Clase      = 'red'
                Motivo     = ('Es una unidad de red, o sea el disco de otro equipo. Cachivache no la ' +
                              'recorre: un análisis completo por la red puede tardar horas y molestar ' +
                              'a quien la comparte.')
            }
        }
        'optica' {
            return [pscustomobject]@{
                Analizable = $false
                Clase      = 'optica'
                Motivo     = ('Es una unidad óptica. Lo que hay grabado en ella no se puede quitar, ' +
                              'así que recorrerla no serviría para liberar ni un byte.')
            }
        }
        default {
            return [pscustomobject]@{
                Analizable = $false
                Clase      = 'desconocida'
                Motivo     = ('No se ha podido saber de qué tipo de unidad es, y ante la duda ' +
                              'Cachivache no la toca.')
            }
        }
    }
}

function Test-PuedeProducirCandidatoBorrable {
    <#
    .SYNOPSIS
        Indica si en una unidad de esta clase se puede proponer algo para
        borrar. Solo en las fijas.

    .DESCRIPTION
        Es la decisión crítica del archivo. Es una lista blanca de un solo
        elemento ("fija"): cualquier clase nueva queda excluida hasta que
        se decida expresamente. tests/Extraibles.Tests.ps1 recorre todas
        las clases que devuelve el código.

        Solo acepta la clase, no el tipo del sistema: la traducción se hace
        siempre en Get-ClaseDeUnidad.

    .PARAMETER Clase
        Una de las clases que devuelve Get-ClaseDeUnidad.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Clase
    )

    # [string] convierte $null en cadena vacía, que no es 'fija'.
    return ($Clase.Trim().ToLowerInvariant() -eq 'fija')
}

function Get-MotivoNoBorrableEnUnidad {
    <#
    .SYNOPSIS
        Explicación para el usuario de por qué no se puede borrar en una
        unidad. Cadena vacía si se puede.

    .DESCRIPTION
        Complementa a Test-PuedeProducirCandidatoBorrable. Una invariante
        exige que toda clase no borrable tenga texto, para que una fila que
        no se puede marcar siempre se explique.

    .PARAMETER Clase
        Una de las clases que devuelve Get-ClaseDeUnidad.
    .PARAMETER Letra
        La unidad concreta ("D:"), si se conoce, para nombrarla en el texto.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Clase,
        [AllowNull()] [AllowEmptyString()] [string] $Letra = ''
    )

    if (Test-PuedeProducirCandidatoBorrable -Clase $Clase) { return '' }

    $sujeto = if ([string]::IsNullOrWhiteSpace($Letra)) {
        'esta unidad'
    } else {
        'la unidad {0}' -f $Letra.Trim()
    }

    $normalizada = $Clase.Trim().ToLowerInvariant()

    # Paréntesis alrededor de la concatenación: -f tiene más precedencia que
    # +, y sin ellos el {0} del primer trozo quedaría sin sustituir.
    switch ($normalizada) {
        'extraible' {
            return (('Se ha medido, pero no se borra nada en {0}: es una unidad extraíble y se puede ' +
                     'desconectar en mitad del borrado, que quedaría a medias sobre un disco que ya ' +
                     'no está. Sale en el mapa y en el informe; para vaciarla, hazlo tú.') -f $sujeto)
        }
        'red' {
            return (('Se ha medido, pero no se borra nada en {0}: es una unidad de red, o sea el disco ' +
                     'de otro equipo, y ahí Cachivache no borra nada.') -f $sujeto)
        }
        'optica' {
            return (('No se borra nada en {0}: es una unidad óptica y lo que hay grabado en ella no se ' +
                     'puede quitar desde aquí.') -f $sujeto)
        }
        default {
            return (('No se borra nada en {0}: no se ha podido saber de qué tipo de unidad es, y ante ' +
                     'la duda Cachivache no borra.') -f $sujeto)
        }
    }
}
