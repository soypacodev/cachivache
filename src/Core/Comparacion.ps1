<#
.SYNOPSIS
    Comparación del análisis actual con el análisis anterior.

.DESCRIPTION
    Añade al resumen del análisis las cifras del análisis anterior guardado
    en historial.json, sin presentar como equiparables cifras que no lo son:

    1. Solo se comparan entradas de Tipo 'analisis'. Los Elementos y Bytes
       de una limpieza miden lo borrado, no lo encontrado.
    2. Si el análisis anterior quedó incompleto, se compara igualmente pero
       se indica: encontró menos porque revisó menos.
    3. Si cambió el perfil o el conjunto de módulos, se muestran las cifras
       y se indica que no son equiparables.

    Si no hay análisis anterior no se dice nada. El tiempo transcurrido se
    formatea con Format-Antiguedad y Format-Duracion (Format.ps1) para que
    no haya dos formateadores de tiempos que discrepen.
#>

function Get-ReferenciaAnterior {
    <#
    .SYNOPSIS
        Devuelve la última entrada del historial que sirve como referencia
        de comparación para un análisis.

    .DESCRIPTION
        Solo considera entradas de Tipo 'analisis'; las limpiezas y los
        tipos desconocidos se ignoran.

        Se compara siempre con el análisis anterior, no con el mejor ni con
        el último completo: si no es equiparable se indica, no se sustituye.

        Se toma la última entrada de la lista y no la de Fecha mayor: el
        historial se escribe añadiendo al final, así que el orden del archivo
        es el orden real, mientras que la fecha puede faltar o estar mal.

    .PARAMETER Historial
        Lo que devuelve Get-Historial. Puede ser $null, estar vacío o
        contener entradas mal formadas (el archivo es editable a mano).
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Historial
    )

    if ($null -eq $Historial) { return $null }

    $referencia = $null
    foreach ($entrada in @($Historial)) {
        if ($null -eq $entrada) { continue }
        # Conversión a [string]: si Tipo fuera un array, -eq devolvería el
        # subconjunto coincidente, que es verdadero y dejaría pasar la entrada.
        if ([string]$entrada.Tipo -ne 'analisis') { continue }
        $referencia = $entrada
    }

    return $referencia
}

function Get-FraseMotivoComparacion {
    <#
    .SYNOPSIS
        Traduce un código de motivo de no equiparabilidad a texto.

    .DESCRIPTION
        Separada de Get-ComparacionAnalisis para poder probar los códigos
        ('incompleto', 'otro-perfil'...) independientemente de la redacción.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Motivo
    )

    switch ($Motivo) {
        'incompleto'    { return 'quedó incompleto' }
        'otro-perfil'   { return 'usó otro perfil' }
        'otros-modulos' { return 'miró otros módulos' }
        'no-consta'     { return 'no guardó con qué perfil y módulos se hizo' }
        default         { return '' }
    }
}

function Get-ComparacionAnalisis {
    <#
    .SYNOPSIS
        Construye el texto que compara el análisis actual con el anterior.

    .DESCRIPTION
        Devuelve un objeto con ocho campos:

          HayReferencia  si hay un análisis anterior con el que comparar
          Caso           'sin-referencia' | 'comparable' | 'no-equiparable'
          Motivos        códigos de por qué no es equiparable
          Fecha          la del análisis anterior, o $null si no se pudo leer
          Elementos      elementos que encontró aquel análisis
          Bytes          bytes recuperables que encontró aquel análisis
          Texto          la frase entre paréntesis, o cadena vacía
          Sufijo         Texto precedido de un espacio, o cadena vacía

        Sufijo permite concatenar sin condicionales: "$resumen += $c.Sufijo"
        es correcto también cuando no hay referencia.

        No calcula diferencias a propósito: elementos y bytes pueden moverse
        en sentidos opuestos (p. ej. al cambiar un umbral). Mostrar las dos
        cifras evita errores de signo.

    .PARAMETER Historial
        Lo que devuelve Get-Historial. Debe leerse ANTES de anotar el
        análisis actual; si no, se compararía consigo mismo.

    .PARAMETER Perfil
        Perfil del análisis actual.

    .PARAMETER Modulos
        Módulos revisados en el análisis actual (los mismos que se anotan en
        el historial).
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Historial,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Perfil,
        [Parameter(Mandatory)] [AllowNull()] $Modulos
    )

    $anterior = Get-ReferenciaAnterior -Historial $Historial

    if ($null -eq $anterior) {
        # Sin análisis anterior no se inventa un "0 elementos antes".
        return [pscustomobject]@{
            HayReferencia = $false
            Caso          = 'sin-referencia'
            Motivos       = @()
            Fecha         = $null
            Elementos     = 0
            Bytes         = 0.0
            Texto         = ''
            Sufijo        = ''
        }
    }

    # ConvertTo-DoubleSeguro en lugar de [int]/[double]: el JSON puede venir
    # de otra versión o editado a mano, y una excepción aquí rompería el
    # final del análisis.
    $elementos = [int](ConvertTo-DoubleSeguro $anterior.Elementos)
    $bytes     = ConvertTo-DoubleSeguro $anterior.Bytes
    if ($elementos -lt 0) { $elementos = 0 }
    if ($bytes -lt 0)     { $bytes = 0.0 }

    $fecha = $null
    $leida = [datetime]::MinValue
    if ([datetime]::TryParse([string]$anterior.Fecha,
                             [Globalization.CultureInfo]::InvariantCulture,
                             [Globalization.DateTimeStyles]::RoundtripKind,
                             [ref] $leida)) {
        $fecha = $leida
    }

    # Una fecha futura (reloj desajustado) o anterior a 1900 (campo vacío)
    # no se usa: se dice "el análisis anterior" sin indicar cuándo.
    $ahora    = Get-Date
    $hayCuando = $false
    $cuando    = ''
    if ($null -ne $fecha -and $fecha -gt [datetime]'1900-01-02' -and $fecha -le $ahora) {
        $transcurrido = $ahora - $fecha
        # Por debajo de un día Format-Antiguedad solo dice "hoy", que junto
        # a una cifra parece "ahora mismo"; se usa Format-Duracion.
        $cuando = if ($transcurrido.TotalDays -lt 1) {
            'hace ' + (Format-Duracion $transcurrido)
        } else {
            Format-Antiguedad -Fecha $fecha
        }
        $hayCuando = -not [string]::IsNullOrWhiteSpace($cuando)
    }

    $motivos = [Collections.Generic.List[string]]::new()

    # 1. Incompleto: va primero porque afecta a la propia medición.
    $incompleto = [bool]$anterior.Incompleto
    if ($incompleto) { $motivos.Add('incompleto') }

    $noConsta = $false

    # 2. Perfil: solo se declara distinto si constan los dos; si falta uno,
    #    el motivo es 'no-consta'.
    $perfilAntes = ([string]$anterior.Perfil).Trim()
    $perfilAhora = if ($null -ne $Perfil) { $Perfil.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($perfilAntes) -or [string]::IsNullOrWhiteSpace($perfilAhora)) {
        $noConsta = $true
    } elseif ($perfilAntes -ne $perfilAhora) {
        $motivos.Add('otro-perfil')
    }

    # 3. Módulos, comparados como conjunto (sin orden, repeticiones ni
    #    mayúsculas). No se comparan si el anterior quedó incompleto: anota
    #    solo los revisados y se repetiría el mismo motivo.
    if (-not $incompleto) {
        $modulosAntes = @(@($anterior.Modulos) |
                          Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } |
                          ForEach-Object { $_.Trim().ToLowerInvariant() } |
                          Select-Object -Unique | Sort-Object)
        $modulosAhora = @(@($Modulos) |
                          Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } |
                          ForEach-Object { $_.Trim().ToLowerInvariant() } |
                          Select-Object -Unique | Sort-Object)

        if ($modulosAntes.Count -eq 0 -or $modulosAhora.Count -eq 0) {
            $noConsta = $true
        } elseif (($modulosAntes -join '|') -ne ($modulosAhora -join '|')) {
            $motivos.Add('otros-modulos')
        }
    }

    if ($noConsta) { $motivos.Add('no-consta') }

    $caso = if ($motivos.Count -gt 0) { 'no-equiparable' } else { 'comparable' }

    # Concordancia en singular: "1 elemento", "era".
    $cuantos = if ($elementos -eq 1) { '1 elemento' } else { '{0} elementos' -f $elementos }
    $verbo   = if ($elementos -eq 1) { 'era' } else { 'eran' }

    $encabezado = if ($hayCuando) { ('{0} {1}' -f $cuando, $verbo) } else { 'el análisis anterior tenía' }

    $cola = ''
    if ($motivos.Count -gt 0) {
        $frases = @($motivos | ForEach-Object { Get-FraseMotivoComparacion -Motivo $_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $cola = ', pero no sirve para comparar: aquel análisis {0}' -f ($frases -join ' y ')
    }

    # Los paréntesis alrededor de la plantilla son necesarios: -f tiene más
    # precedencia que +.
    $texto = ('({0} {1} y {2}{3})' -f $encabezado, $cuantos, (Format-Tamano $bytes), $cola)
    # Va detrás de una frase terminada en punto: empieza en mayúscula.
    $texto = '(' + $texto.Substring(1, 1).ToUpper() + $texto.Substring(2)

    return [pscustomobject]@{
        HayReferencia = $true
        Caso          = $caso
        Motivos       = $motivos.ToArray()
        Fecha         = $fecha
        Elementos     = $elementos
        Bytes         = $bytes
        Texto         = $texto
        Sufijo        = (' ' + $texto)
    }
}
