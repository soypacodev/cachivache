<#
.SYNOPSIS
    Decide si un índice guardado se puede creer y le aplica los cambios.

.DESCRIPTION
    Principio de diseño: el índice guardado sirve para pintar el mapa, nunca
    para decidir qué se borra. Los borrados se deciden siempre sobre lo
    recorrido en la ejecución actual, así que un índice erróneo como mucho
    dibuja mal un rectángulo. Ninguna función de este archivo devuelve nada
    parecido a un candidato, y una prueba lo exige.

    Aun así, un índice que muestra espacio inexistente destruye la confianza
    en el programa. De ahí las dos partes del archivo:

      * Test-IndiceUtilizable   - ¿se puede creer lo que hay guardado?
      * Update-IndiceConCambios - aplica los cambios del diario USN sin que
        los totales por carpeta queden desfasados.

    Ante cualquier duda (campo ausente, nulo, fecha absurda) el índice se
    rechaza: volver a recorrer cuesta segundos. Todo rechazo lleva un motivo
    legible para el registro.

    Cabecera del índice (nombres exactos, compartidos con quien lo escribe):

        Version       (int)      versión del formato
        SerieVolumen  (string)   número de serie del volumen
        IdDiario      (string)   identificador del diario USN
        UsnCorte      (long)     USN hasta donde se leyó
        Entradas      (int)      número de entradas del cuerpo
        Suma          (string)   suma de comprobación del cuerpo
        Escrito       (datetime) fecha de escritura

    Forma del índice en memoria que espera Update-IndiceConCambios (se
    carga en diccionarios y no como objetos, que es un orden de magnitud
    más lento):

        Indice.Archivos - IDictionary  ruta -> entrada (con Bytes) o bytes
        Indice.Carpetas - IDictionary  ruta -> entrada de New-EntradaCarpeta
                                       (Ruta, Nombre, Nivel, Bytes, Propios,
                                        Archivos, Ultimo)

        Propios - bytes de los archivos que están directamente en la carpeta.
        Bytes   - bytes de todo lo que cuelga de ella, a cualquier
                  profundidad; es lo que dibuja el mapa.

    La tabla de carpetas se guarda también porque recalcularla recorriendo
    todos los archivos cuesta más que recorrer el disco. Por el mismo motivo,
    aquí todo trabajo es proporcional al número de cambios.
#>

function Get-CaducidadIndice {
    <#
    .SYNOPSIS
        Días durante los que un índice guardado se considera fresco.

    .DESCRIPTION
        Es una función para que Test-IndiceUtilizable y las pruebas usen el
        mismo valor.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    # Siete días, por tres motivos:
    #   1. Los cambios hechos con el diario desactivado (arranque dual, otro
    #      sistema que monta el disco) no los detecta ninguna cabecera; la
    #      caducidad es la única red barata contra ellos.
    #   2. Pasada una semana de uso normal, el camino incremental ya apenas
    #      ahorra frente a un recorrido completo.
    #   3. Con el tamaño por omisión, el diario suele haber dado la vuelta en
    #      ese plazo; la caducidad cubre el caso de diarios grandes.
    # Un plazo de un día haría que el índice casi nunca llegara a usarse.
    return 7
}

function ConvertTo-NumeroIndice {
    <#
    .SYNOPSIS
        Convierte un valor a entero, o devuelve $null si no es creíble.

    .DESCRIPTION
        Los campos llegan de un archivo y pueden contener cualquier cosa. La
        conversión no lanza: devuelve $null cuando no hay conversión exacta,
        para que quien llama lo trate como un rechazo.

        Se usa Parse con cultura invariante y no un cast de PowerShell,
        porque el cast redondea ([long]3.7 da 4).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Valor,
        [ValidateSet('int', 'long')] [string] $Tipo = 'long'
    )

    if ($null -eq $Valor) { return $null }
    # Un booleano convertiría a 1 o 0 sin ser un número.
    if ($Valor -is [bool]) { return $null }

    $largo = $null

    # [int16] y no [short]: el acelerador [short] no existe en Windows
    # PowerShell 5.1 y la línea lanzaría al ejecutarse (no al cargar el
    # archivo). tests/Invariantes.Tests.ps1 vigila estos aceleradores.
    if ($Valor -is [int] -or $Valor -is [long] -or $Valor -is [int16] -or
        $Valor -is [byte] -or $Valor -is [uint32] -or $Valor -is [uint64]) {
        $largo = [long]$Valor
    } elseif ($Valor -is [double] -or $Valor -is [single] -or $Valor -is [decimal]) {
        # Los tamaños se guardan como double, pero deben ser enteros.
        $doble = [double]$Valor
        if ([double]::IsNaN($doble) -or [double]::IsInfinity($doble)) { return $null }
        if ([Math]::Floor($doble) -ne $doble) { return $null }
        if ($doble -gt 9.2E+18 -or $doble -lt -9.2E+18) { return $null }
        $largo = [long]$doble
    } else {
        $texto = ([string]$Valor).Trim()
        if ($texto.Length -eq 0) { return $null }
        try {
            $largo = [long]::Parse($texto, [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return $null
        }
    }

    if ($Tipo -eq 'int') {
        if ($largo -gt [int]::MaxValue -or $largo -lt [int]::MinValue) { return $null }
        return [int]$largo
    }
    return $largo
}

function Test-IndiceUtilizable {
    <#
    .SYNOPSIS
        ¿Se puede creer el índice guardado? Y si no, por qué.

    .DESCRIPTION
        Cálculo puro: no toca el disco ni el reloj. Compara la cabecera
        guardada con los datos actuales del disco y devuelve:

            Utilizable - si se puede usar.
            Codigo     - motivo estable en ASCII, para registro y pruebas
                         (permite distinguir un rechazo de otro).
            Motivo     - el mismo motivo en castellano.

        Cada comprobación detecta una forma distinta de desfase:

          Versión del formato   escrito por otra versión del programa.
          Número de serie       otro disco con la misma letra (USB,
                                unidad remontada).
          Identificador diario  el diario se recreó (chkdsk, restauración,
                                desactivación); la historia anterior no existe.
          USN de corte          frente al primer USN disponible, indica si el
                                diario dio la vuelta y perdió el tramo necesario.
          Entradas y suma       cuerpo truncado o alterado (p. ej., apagón).
          Caducidad             ver Get-CaducidadIndice.

        Las comprobaciones van de lo más fundamental a lo más fino, para que
        el motivo devuelto sea el más explicativo de los que aplican.

    .PARAMETER Cabecera
        Cabecera leída del índice: objeto o tabla hash con los siete campos.
    .PARAMETER VersionEsperada
        Versión del formato que entiende el programa actual.
    .PARAMETER SerieVolumen
        Número de serie actual del volumen.
    .PARAMETER IdDiario
        Identificador actual del diario USN.
    .PARAMETER PrimerUsn
        Primer USN que el diario conserva todavía.
    .PARAMETER Ahora
        Fecha actual; se recibe como parámetro para que la función sea pura.
    .PARAMETER EntradasLeidas
        Entradas que trae realmente el cuerpo leído. Opcional: si no se pasa,
        esta comprobación queda a cargo del lector.
    .PARAMETER SumaCalculada
        Suma de comprobación calculada sobre el cuerpo leído. Opcional, igual
        que la anterior.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Cabecera,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $VersionEsperada,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $SerieVolumen,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $IdDiario,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $PrimerUsn,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Ahora,
        [AllowNull()] [AllowEmptyString()] $EntradasLeidas = $null,
        [AllowNull()] [AllowEmptyString()] $SumaCalculada  = $null
    )

    # --- 1. ¿Hay cabecera? -------------------------------------------
    if ($null -eq $Cabecera) {
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'CabeceraAusente'
            Motivo     = 'No hay cabecera que comprobar, así que el índice no se puede creer.'
        }
    }

    # --- 2. ¿Hay con qué contrastarla? -------------------------------
    # Sin los datos actuales del disco no se puede contrastar nada, y un
    # índice sin contrastar es tan peligroso como uno que no cuadra.
    $versionHoy = ConvertTo-NumeroIndice -Valor $VersionEsperada -Tipo 'int'
    $serieHoy   = if ($null -eq $SerieVolumen) { '' } else { ([string]$SerieVolumen).Trim() }
    $diarioHoy  = if ($null -eq $IdDiario)     { '' } else { ([string]$IdDiario).Trim() }
    $primerUsn  = ConvertTo-NumeroIndice -Valor $PrimerUsn -Tipo 'long'

    $ahoraFecha = $null
    if ($Ahora -is [datetime]) {
        $ahoraFecha = $Ahora
    } elseif ($null -ne $Ahora -and ([string]$Ahora).Trim().Length -gt 0) {
        try { $ahoraFecha = [datetime]$Ahora } catch { $ahoraFecha = $null }
    }

    if ($null -eq $versionHoy -or $serieHoy.Length -eq 0 -or $diarioHoy.Length -eq 0 -or
        $null -eq $primerUsn  -or $primerUsn -lt 0 -or $null -eq $ahoraFecha) {
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'DatosDelDiscoNoValidos'
            Motivo     = 'No se puede contrastar la cabecera con el disco de hoy: faltan datos del volumen.'
        }
    }

    # --- 3. ¿Está entera la cabecera? --------------------------------
    # Una propiedad inexistente se lee como $null (objeto o tabla hash), así
    # que "falta" y "es nulo" se tratan igual.
    foreach ($campo in @('Version', 'SerieVolumen', 'IdDiario', 'UsnCorte', 'Entradas', 'Suma', 'Escrito')) {
        $valor = $Cabecera.$campo
        $vacio = ($null -eq $valor)
        if (-not $vacio -and $valor -is [string]) { $vacio = ($valor.Trim().Length -eq 0) }
        if ($vacio) {
            $texto = 'A la cabecera del índice le falta el campo {0}.' -f $campo
            return [pscustomobject]@{
                Utilizable = $false
                Codigo     = 'CampoAusente'
                Motivo     = $texto
            }
        }
    }

    # --- 4. ¿Son creíbles los valores que trae? ----------------------
    $version  = ConvertTo-NumeroIndice -Valor $Cabecera.Version  -Tipo 'int'
    $usnCorte = ConvertTo-NumeroIndice -Valor $Cabecera.UsnCorte -Tipo 'long'
    $entradas = ConvertTo-NumeroIndice -Valor $Cabecera.Entradas -Tipo 'int'

    $escrito = $null
    if ($Cabecera.Escrito -is [datetime]) {
        $escrito = $Cabecera.Escrito
    } else {
        try { $escrito = [datetime]$Cabecera.Escrito } catch { $escrito = $null }
    }

    $imposible = ''
    if     ($null -eq $version)  { $imposible = 'Version' }
    elseif ($null -eq $usnCorte) { $imposible = 'UsnCorte' }
    elseif ($usnCorte -lt 0)     { $imposible = 'UsnCorte' }
    elseif ($null -eq $entradas) { $imposible = 'Entradas' }
    elseif ($entradas -lt 0)     { $imposible = 'Entradas' }
    elseif ($null -eq $escrito)  { $imposible = 'Escrito' }
    # Anterior a 2000: campo nunca escrito (DateTime.MinValue, fecha cero).
    elseif ($escrito -lt ([datetime]'2000-01-01')) { $imposible = 'Escrito' }
    # Futura: archivo alterado o reloj movido. El minuto de margen evita
    # rechazar un índice válido por un pequeño ajuste de reloj.
    elseif ($escrito -gt $ahoraFecha.AddMinutes(1)) { $imposible = 'Escrito' }

    if ($imposible.Length -gt 0) {
        $texto = 'El campo {0} de la cabecera no trae un valor creíble.' -f $imposible
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'ValorImposible'
            Motivo     = $texto
        }
    }

    # --- 5. ¿Lo escribió esta versión del programa? ------------------
    if ($version -ne $versionHoy) {
        # El texto se arma fuera del @{}: -f tiene más precedencia que + y la
        # coma entre argumentos se confundiría con un separador.
        $texto = 'El índice lo escribió otra versión del programa: trae el formato {0} y aquí se lee el {1}.' -f
                 $version, $versionHoy
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'VersionDistinta'
            Motivo     = $texto
        }
    }

    # --- 6. ¿Es el mismo disco? --------------------------------------
    # Sin distinguir mayúsculas: el número de serie es hexadecimal.
    if (-not [string]::Equals(([string]$Cabecera.SerieVolumen).Trim(), $serieHoy,
                              [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'VolumenDistinto'
            Motivo     = 'El número de serie del volumen no coincide: es otro disco que ha heredado la misma letra.'
        }
    }

    # --- 7. ¿Es el mismo diario? -------------------------------------
    if (-not [string]::Equals(([string]$Cabecera.IdDiario).Trim(), $diarioHoy,
                              [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'DiarioDistinto'
            Motivo     = 'El diario de cambios se creó de nuevo, así que la historia anterior ya no existe.'
        }
    }

    # --- 8. ¿Sigue estando el tramo que hace falta? ------------------
    # -lt y no -le: si el corte coincide con el primer USN disponible, no se
    # ha perdido nada.
    if ($usnCorte -lt $primerUsn) {
        $texto = ('El diario ha dado la vuelta y se ha comido el tramo que hacía falta: ' +
                  'el corte guardado es {0} y ahora el diario empieza en {1}.') -f $usnCorte, $primerUsn
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'DiarioDioLaVuelta'
            Motivo     = $texto
        }
    }

    # --- 9. ¿Cuadra el cuerpo con lo que promete la cabecera? --------
    if ($null -ne $EntradasLeidas) {
        $leidas = ConvertTo-NumeroIndice -Valor $EntradasLeidas -Tipo 'int'
        if ($null -eq $leidas -or $leidas -ne $entradas) {
            $texto = ('El cuerpo del índice está truncado o alterado: ' +
                      'la cabecera promete {0} entradas y se han leído {1}.') -f $entradas, $EntradasLeidas
            return [pscustomobject]@{
                Utilizable = $false
                Codigo     = 'CuerpoNoCuadra'
                Motivo     = $texto
            }
        }
    }

    if ($null -ne $SumaCalculada -and ([string]$SumaCalculada).Trim().Length -gt 0) {
        if (-not [string]::Equals(([string]$Cabecera.Suma).Trim(), ([string]$SumaCalculada).Trim(),
                                  [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Utilizable = $false
                Codigo     = 'CuerpoNoCuadra'
                Motivo     = 'El cuerpo del índice está truncado o alterado: la suma de comprobación no coincide.'
            }
        }
    }

    # --- 10. ¿Es lo bastante reciente? -------------------------------
    $dias = ($ahoraFecha - $escrito).TotalDays
    $tope = Get-CaducidadIndice
    if ($dias -gt $tope) {
        $texto = 'El índice se escribió hace {0:N0} días y solo se dan por buenos los de menos de {1}.' -f
                 $dias, $tope
        return [pscustomobject]@{
            Utilizable = $false
            Codigo     = 'Caducado'
            Motivo     = $texto
        }
    }

    return [pscustomobject]@{
        Utilizable = $true
        Codigo     = 'Utilizable'
        Motivo     = ''
    }
}

function Resolve-CarpetaIndice {
    <#
    .SYNOPSIS
        Devuelve la entrada de una carpeta del índice, creándola si hace
        falta y se puede colocar correctamente.

    .DESCRIPTION
        Un alta puede caer en una carpeta posterior al último recorrido. La
        entrada solo se crea si cuelga de un antepasado conocido, y entonces
        se crea la cadena entera con sus niveles correctos (el Nivel decide
        la propagación). Sin antepasado conocido devuelve $null y quien llama
        descarta el cambio.

    .PARAMETER Crear
        Sin este conmutador solo busca; una baja no necesita crear nada.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Carpetas,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Ruta,
        [switch] $Crear
    )

    if ($null -eq $Carpetas -or -not ($Carpetas -is [Collections.IDictionary])) { return $null }
    if ($null -eq $Ruta) { return $null }

    # ContainsKey y no Contains: existe en Hashtable y en Dictionary, donde
    # Contains es una implementación explícita de interfaz y PowerShell no
    # siempre la ve.
    $clave = [string]$Ruta
    if ($clave.Trim().Length -eq 0) { return $null }
    if ($Carpetas.ContainsKey($clave)) { return $Carpetas[$clave] }

    # La raíz de unidad se guarda con barra ("C:\") y el resto sin ella.
    $sinBarra = $clave.TrimEnd([char]'\', [char]'/')
    if ($sinBarra.Length -gt 0 -and $sinBarra -ne $clave -and $Carpetas.ContainsKey($sinBarra)) {
        return $Carpetas[$sinBarra]
    }
    if ($sinBarra.Length -eq 0) { return $null }

    if (-not $Crear) { return $null }

    # Se sube hasta un antepasado conocido anotando las carpetas que faltan.
    # El límite de vueltas evita un bucle infinito si Split-Path devuelve la
    # misma ruta que recibe.
    $faltan = [Collections.Generic.List[string]]::new()
    $actual = $sinBarra
    $conocida = $null
    $guarda = 0

    while ($guarda -lt 512) {
        $guarda++
        $padre = [string](Split-Path $actual -Parent)
        if ([string]::IsNullOrWhiteSpace($padre) -or $padre -eq $actual) { break }
        if ($Carpetas.ContainsKey($padre)) { $conocida = $Carpetas[$padre]; break }
        $sinBarraPadre = $padre.TrimEnd([char]'\', [char]'/')
        if ($sinBarraPadre.Length -gt 0 -and $Carpetas.ContainsKey($sinBarraPadre)) {
            $conocida = $Carpetas[$sinBarraPadre]
            break
        }
        $faltan.Add($padre)
        $actual = $padre
    }

    if ($null -eq $conocida) { return $null }

    # De la más alta a la más honda, para que cada una herede el Nivel de su
    # padre.
    $nivel = [int]$conocida.Nivel
    for ($i = $faltan.Count - 1; $i -ge 0; $i--) {
        $nivel++
        $Carpetas[$faltan[$i]] = New-EntradaCarpeta -Ruta $faltan[$i] -Nivel $nivel
    }
    $nivel++
    $Carpetas[$sinBarra] = New-EntradaCarpeta -Ruta $sinBarra -Nivel $nivel
    return $Carpetas[$sinBarra]
}

function Update-CadenaCarpetas {
    <#
    .SYNOPSIS
        Propaga una diferencia por la cadena de carpetas hasta la raíz.

    .DESCRIPTION
        El total (Bytes) de una carpeta incluye todo lo que cuelga de ella,
        así que cada cambio de tamaño debe aplicarse a todos los antepasados.
        Se hace un salto por nivel, sin volver a sumar el índice.

        Devuelve cuántos totales han tenido que recortarse a cero.

    .NOTES
        Un antepasado ausente del índice no corta la cadena: se sigue
        subiendo, porque los niveles superiores también contienen el archivo.

        Ultimo solo aumenta. Tras una baja no se puede saber la fecha mayor
        restante sin releer la carpeta, y no afecta al espacio mostrado.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo cambia numeros de un diccionario en memoria.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Carpetas,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Ruta,
        [double] $DeltaBytes    = 0.0,
        [int]    $DeltaArchivos = 0,
        [AllowNull()] $Ultimo   = $null
    )

    $recortes = 0
    if ($null -eq $Carpetas -or -not ($Carpetas -is [Collections.IDictionary])) { return $recortes }
    if ($null -eq $Ruta) { return $recortes }

    $actual = [string]$Ruta
    $guarda = 0

    while ($guarda -lt 512 -and -not [string]::IsNullOrWhiteSpace($actual)) {
        $guarda++

        $clave = $null
        if ($Carpetas.ContainsKey($actual)) {
            $clave = $actual
        } else {
            $sinBarra = $actual.TrimEnd([char]'\', [char]'/')
            if ($sinBarra.Length -gt 0 -and $Carpetas.ContainsKey($sinBarra)) { $clave = $sinBarra }
        }

        if ($null -ne $clave) {
            $entrada = $Carpetas[$clave]
            $entrada.Bytes    = [double]$entrada.Bytes + $DeltaBytes
            $entrada.Archivos = [int]$entrada.Archivos + $DeltaArchivos

            # Un total negativo indica un índice ya descuadrado: se recorta a
            # cero y se cuenta, para que quien llama pueda optar por recorrer
            # de nuevo.
            if ($entrada.Bytes -lt 0)    { $entrada.Bytes = 0.0; $recortes++ }
            if ($entrada.Archivos -lt 0) { $entrada.Archivos = 0; $recortes++ }

            if ($null -ne $Ultimo -and $Ultimo -is [datetime] -and $Ultimo -gt $entrada.Ultimo) {
                $entrada.Ultimo = $Ultimo
            }
        }

        $padre = [string](Split-Path $actual -Parent)
        if ($padre -eq $actual) { break }
        $actual = $padre
    }

    return $recortes
}

function Update-IndiceConCambios {
    <#
    .SYNOPSIS
        Aplica altas, bajas y cambios de tamaño al índice en memoria y
        propaga los totales por carpeta.

    .DESCRIPTION
        No toca el disco, no lee el reloj ni variables globales, y es
        determinista. Sí modifica en el sitio el índice recibido: copiar un
        diccionario de un millón de entradas costaría más que recorrer el
        disco.

        No lanza nunca (lista vacía, nulos, carpetas desaparecidas, bajas de
        archivos desconocidos): como mucho, el índice se declara no fiable.

        Cada cambio se aplica entero o no se aplica: primero se resuelve la
        carpeta y el tamaño anterior, y solo después se modifica nada.

        Forma de un cambio:

            Tipo    'Alta' | 'Baja' | 'Cambio'   (sin distinguir mayúsculas)
            Ruta    ruta completa del archivo
            Bytes   tamaño actual (alta y cambio; la baja lo ignora)
            Carpeta opcional; si falta, se deduce de la ruta
            Ultimo  opcional, fecha de la última escritura

        Devuelve:

            Indice      el mismo objeto recibido, actualizado
            Aplicados   cambios aplicados
            Altas / Bajas / Modificados
            Ignorados   cambios sin efecto (p. ej., baja de un archivo que el
                        índice no tenía; es un caso normal)
            Descartados cambios que debían aplicarse y no se pudo
            Recortes    totales que salían negativos y se llevaron a cero
            Confiable   $false si hubo descartes o recortes; quien llama
                        puede entonces recorrer el disco entero
            Motivo      explicación cuando Confiable es $false
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo cambia estructuras en memoria; no toca el disco.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Indice,
        [Parameter(Mandatory)] [AllowNull()] $Cambios
    )

    $aplicados = 0; $altas = 0; $bajas = 0; $modificados = 0
    $ignorados = 0; $descartados = 0; $recortes = 0
    $netoBytes = 0.0; $netoArchivos = 0

    # @($null) no es una lista vacía: sin esta comprobación, "sin cambios"
    # contaría como un cambio descartado.
    $lista = @()
    if ($null -ne $Cambios) { $lista = @($Cambios) }

    $carpetas = $null
    $archivos = $null
    if ($null -ne $Indice) {
        if ($Indice.Carpetas -is [Collections.IDictionary]) { $carpetas = $Indice.Carpetas }
        if ($Indice.Archivos -is [Collections.IDictionary]) { $archivos = $Indice.Archivos }
    }

    # Sin las dos tablas no se puede aplicar nada de forma coherente.
    if ($null -eq $carpetas -or $null -eq $archivos) {
        return [pscustomobject]@{
            Indice      = $Indice
            Aplicados   = 0
            Altas       = 0
            Bajas       = 0
            Modificados = 0
            Ignorados   = 0
            Descartados = @($lista | Where-Object { $null -ne $_ }).Count
            Recortes    = 0
            Confiable   = $false
            Motivo      = 'El índice no trae las dos tablas que hacen falta, la de archivos y la de carpetas.'
        }
    }

    foreach ($cambio in $lista) {
        if ($null -eq $cambio) { $descartados++; continue }

        $tipo = ''
        if ($null -ne $cambio.Tipo) { $tipo = ([string]$cambio.Tipo).Trim() }
        $ruta = ''
        if ($null -ne $cambio.Ruta) { $ruta = ([string]$cambio.Ruta).Trim() }

        if ($ruta.Length -eq 0) { $descartados++; continue }
        if ($tipo -notin @('Alta', 'Baja', 'Cambio')) { $descartados++; continue }

        $carpetaRuta = ''
        if ($null -ne $cambio.Carpeta) { $carpetaRuta = ([string]$cambio.Carpeta).Trim() }
        if ($carpetaRuta.Length -eq 0) { $carpetaRuta = [string](Split-Path $ruta -Parent) }
        if ([string]::IsNullOrWhiteSpace($carpetaRuta)) { $descartados++; continue }

        $ultimo = $null
        if ($cambio.Ultimo -is [datetime]) { $ultimo = $cambio.Ultimo }

        # La tabla de archivos guarda entradas (Read-IndiceDisco
        # -ComoDiccionario), que permiten volver a guardar el índice; se
        # admite también el número suelto para facilitar las pruebas.
        $tenia = $archivos.ContainsKey($ruta)
        $anterior = 0.0
        if ($tenia) {
            $valor = $archivos[$ruta]
            if ($null -ne $valor -and $valor -isnot [ValueType] -and $valor -isnot [string]) {
                $valor = $valor.Bytes
            }
            $bruto = ConvertTo-NumeroIndice -Valor $valor -Tipo 'long'
            if ($null -eq $bruto) { $descartados++; continue }
            $anterior = [double]$bruto
        }

        if ($tipo -eq 'Baja') {
            # Baja de algo desconocido: pudo crearse y borrarse entre dos
            # pasadas. No hay nada que restar.
            if (-not $tenia) { $ignorados++; continue }

            $entrada = Resolve-CarpetaIndice -Carpetas $carpetas -Ruta $carpetaRuta
            if ($null -eq $entrada) { $descartados++; continue }

            $null = $archivos.Remove($ruta)
            $entrada.Propios = [double]$entrada.Propios - $anterior
            if ($entrada.Propios -lt 0) { $entrada.Propios = 0.0; $recortes++ }
            $recortes += Update-CadenaCarpetas -Carpetas $carpetas -Ruta $entrada.Ruta `
                             -DeltaBytes (-$anterior) -DeltaArchivos (-1)
            $netoBytes -= $anterior
            $netoArchivos--
            $bajas++
            $aplicados++
            continue
        }

        # Alta y Cambio comparten código: lo que decide es si el índice ya
        # conocía el archivo, no la etiqueta. Fiarse de la etiqueta
        # descuadraría los totales.
        $nuevo = ConvertTo-NumeroIndice -Valor $cambio.Bytes -Tipo 'long'
        if ($null -eq $nuevo -or $nuevo -lt 0) { $descartados++; continue }

        $entrada = Resolve-CarpetaIndice -Carpetas $carpetas -Ruta $carpetaRuta -Crear
        if ($null -eq $entrada) { $descartados++; continue }

        $delta = [double]$nuevo - $anterior
        # Se conserva la forma existente de la tabla (entrada o número) para
        # no mezclar ambas.
        if ($tenia -and $null -ne $archivos[$ruta] -and
            $archivos[$ruta] -isnot [ValueType] -and $archivos[$ruta] -isnot [string]) {
            $archivos[$ruta].Bytes = [double]$nuevo
        } else {
            $archivos[$ruta] = [double]$nuevo
        }
        $entrada.Propios = [double]$entrada.Propios + $delta
        if ($entrada.Propios -lt 0) { $entrada.Propios = 0.0; $recortes++ }

        $cuenta = 0
        if (-not $tenia) { $cuenta = 1 }
        $recortes += Update-CadenaCarpetas -Carpetas $carpetas -Ruta $entrada.Ruta `
                         -DeltaBytes $delta -DeltaArchivos $cuenta -Ultimo $ultimo

        $netoBytes += $delta
        $netoArchivos += $cuenta
        if ($tenia) { $modificados++ } else { $altas++ }
        $aplicados++
    }

    # Totales globales del índice, si existen: se ajustan por la diferencia,
    # sin volver a sumar la tabla. Se comprueba que la propiedad existe
    # porque escribir una inexistente lanza (formatos anteriores).
    if ($null -ne $Indice -and $null -ne $Indice.PSObject) {
        if ($null -ne $Indice.PSObject.Properties['Bytes']) {
            $total = [double]$Indice.Bytes + $netoBytes
            if ($total -lt 0) { $total = 0.0; $recortes++ }
            $Indice.Bytes = $total
        }
        if ($null -ne $Indice.PSObject.Properties['TotalArchivos']) {
            $cuentaTotal = [int]$Indice.TotalArchivos + $netoArchivos
            if ($cuentaTotal -lt 0) { $cuentaTotal = 0; $recortes++ }
            $Indice.TotalArchivos = $cuentaTotal
        }
    }

    # El motivo permite a quien llama distinguir descartes, un índice ya
    # descuadrado o un fallo del programa.
    $confiable = ($descartados -eq 0 -and $recortes -eq 0)
    $porque = ''
    if (-not $confiable) {
        $partes = [Collections.Generic.List[string]]::new()
        if ($descartados -gt 0) {
            $partes.Add(('{0} {1} no se {2} podido aplicar' -f $descartados,
                         $(if ($descartados -eq 1) { 'cambio' } else { 'cambios' }),
                         $(if ($descartados -eq 1) { 'ha' } else { 'han' })))
        }
        if ($recortes -gt 0) {
            $partes.Add(('{0} {1} de carpeta {2} en negativo, así que el índice ya venía descuadrado' -f
                         $recortes,
                         $(if ($recortes -eq 1) { 'total' } else { 'totales' }),
                         $(if ($recortes -eq 1) { 'salía' } else { 'salían' })))
        }
        $porque = 'El índice actualizado no es de fiar: ' + ($partes -join ', ') +
                  '. Conviene recorrer el disco entero.'
    }

    return [pscustomobject]@{
        Indice      = $Indice
        Aplicados   = $aplicados
        Altas       = $altas
        Bajas       = $bajas
        Modificados = $modificados
        Ignorados   = $ignorados
        Descartados = $descartados
        Recortes    = $recortes
        Confiable   = $confiable
        Motivo      = $porque
    }
}
