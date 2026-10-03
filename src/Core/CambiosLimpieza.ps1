<#
.SYNOPSIS
    Efecto de una limpieza sobre el índice de disco. Cálculo puro: no toca
    el disco ni el reloj.

.DESCRIPTION
    Convierte el resultado de una limpieza en la lista de bajas que
    Update-IndiceConCambios sabe aplicar, para que un nuevo análisis
    justo después no tenga que recorrer el disco entero. No depende del
    diario de NTFS: funciona sin administrador y en FAT32, exFAT o red.

    Ante la duda se conservan entradas: un archivo que ya no existe solo
    sobreestima lo ocupado (al borrarlo se informa de que la ruta no
    existe), mientras que quitar uno que sigue ahí lo ocultaría para
    siempre. Por eso no hay invalidación global: un candidato de efecto
    incierto simplemente no aporta bajas.

    Efecto de cada método de New-Candidato:

      Ruta, Contenido            -> desaparece todo lo que colgaba de Ruta.
      CarpetaVacia, Informativo  -> no había archivos en el índice.
      FirefoxCache, Miniaturas   -> borran solo una parte; inciertos.
      Papelera, Comando          -> API del shell o ejecutable externo;
                                    inciertos.

    La clasificación vive en tres listas para que una prueba exija que
    cada método del ValidateSet esté en exactamente una.

    Además del método, se exige Hecho y Error vacío: Remove.ps1 marca
    Hecho también en resultados parciales (p. ej. archivos en uso), y en
    ese caso no se sabe qué ha sobrevivido.
#>

# La unión de las tres listas debe ser exactamente el ValidateSet de
# -Metodo en New-Candidato; una invariante lo comprueba.
$script:MetodosBorranSubarbol = @('Contenido', 'Ruta')
$script:MetodosNoTocanIndice  = @('CarpetaVacia', 'Informativo')
$script:MetodosEfectoIncierto = @('FirefoxCache', 'Miniaturas', 'Papelera', 'Comando')

function Get-EfectoEnIndice {
    <#
    .SYNOPSIS
        Efecto de un método de borrado sobre el índice. Decisión pura.

    .OUTPUTS
        'Subarbol'    todo lo que colgaba de la ruta ha desaparecido
        'Nada'        no había nada que el índice conociera
        'Incierto'    no se sabe qué ha tocado; el índice no se modifica

    .NOTES
        Un método desconocido devuelve 'Incierto', nunca 'Nada'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Metodo)

    $m = ''
    if ($null -ne $Metodo) { $m = $Metodo.Trim() }
    if ($script:MetodosBorranSubarbol -contains $m) { return 'Subarbol' }
    if ($script:MetodosNoTocanIndice  -contains $m) { return 'Nada' }
    return 'Incierto'
}

function Test-CandidatoBorroSuSubarbol {
    <#
    .SYNOPSIS
        Indica si se puede afirmar que todo lo que colgaba de la ruta del
        candidato ha desaparecido. Decisión pura.

    .DESCRIPTION
        Condiciones:

        1. El método borra el subárbol entero.
        2. Hecho es $true.
        3. Error está vacío (no fue un resultado parcial).
        4. Ruta no está vacía: una cadena vacía como prefijo coincidiría
           con todo el índice.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [AllowNull()] $Candidato)

    if ($null -eq $Candidato) { return $false }
    if ((Get-EfectoEnIndice -Metodo ([string]$Candidato.Metodo)) -ne 'Subarbol') { return $false }
    if (-not $Candidato.Hecho) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$Candidato.Error)) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Candidato.Ruta)) { return $false }
    return $true
}

function Get-CambiosDeLimpieza {
    <#
    .SYNOPSIS
        Convierte el resultado de una limpieza en las bajas que
        Update-IndiceConCambios sabe aplicar. Cálculo puro, nunca lanza.

    .PARAMETER Candidatos
        Los candidatos después de limpiar, con Hecho, Error y Metodo
        rellenados por Remove.ps1.

    .PARAMETER RutasIndice
        Las rutas que conoce el índice (claves de su tabla de archivos).
        Se recorren una sola vez.

    .OUTPUTS
        Cambios      las bajas, en la forma {Tipo; Ruta} que espera
                     Update-IndiceConCambios
        Raices       las rutas cuyo subárbol se ha dado de baja
        Ciertos      candidatos que han aportado bajas
        Inciertos    candidatos limpiados de efecto desconocido; sus
                     archivos se quedan en el índice
        Omitidos     candidatos sin nada que aportar (no se hicieron o
                     su método no toca el índice)

    .NOTES
        Sin raíces no se recorre el índice.

        La pertenencia la decide Get-RaizQueContiene (Guard.ps1), que
        normaliza y compara de forma ordinal; no duplicar esa lógica aquí.

        La propia raíz se compara aparte: Get-RaizQueContiene exige la
        barra final y no casa una ruta consigo misma, pero con el método
        Ruta el candidato puede ser un archivo suelto.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Candidatos,
        [Parameter(Mandatory)] [AllowNull()] $RutasIndice
    )

    $cambios = [Collections.Generic.List[object]]::new()
    $raices  = [Collections.Generic.List[object]]::new()
    $ciertos = 0; $inciertos = 0; $omitidos = 0

    # @($null) es una lista con un nulo, no una lista vacía.
    $lista = @()
    if ($null -ne $Candidatos) { $lista = @($Candidatos | Where-Object { $null -ne $_ }) }

    foreach ($c in $lista) {
        if (Test-CandidatoBorroSuSubarbol -Candidato $c) {
            $raices.Add([string]$c.Ruta)
            $ciertos++
            continue
        }
        # "No se sabe" y "no había nada" se cuentan por separado: los
        # inciertos quedan pendientes del siguiente recorrido completo.
        $limpiado = $c.Hecho -and [string]::IsNullOrWhiteSpace([string]$c.Error)
        if ($limpiado -and (Get-EfectoEnIndice -Metodo ([string]$c.Metodo)) -eq 'Incierto') {
            $inciertos++
        } else {
            $omitidos++
        }
    }

    if ($raices.Count -gt 0 -and $null -ne $RutasIndice) {
        $comoArray = @($raices.ToArray())
        foreach ($ruta in @($RutasIndice)) {
            if ([string]::IsNullOrWhiteSpace([string]$ruta)) { continue }
            $texto = [string]$ruta
            $dentro = -not [string]::IsNullOrEmpty((Get-RaizQueContiene -Ruta $texto -Raices $comoArray))
            if (-not $dentro) {
                # La raíz consigo misma: el candidato era un archivo suelto.
                foreach ($r in $comoArray) {
                    if ($texto.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { $dentro = $true; break }
                }
            }
            if ($dentro) {
                $cambios.Add([pscustomobject]@{ Tipo = 'Baja'; Ruta = $texto })
            }
        }
    }

    return [pscustomobject]@{
        Cambios   = $cambios.ToArray()
        Raices    = $raices.ToArray()
        Ciertos   = $ciertos
        Inciertos = $inciertos
        Omitidos  = $omitidos
    }
}
