<#
.SYNOPSIS
    Índice de disco: una sola pasada que responde "dónde se fue el espacio".

.DESCRIPTION
    Un único recorrido produce el total de cada carpeta (para el mapa de
    árbol) y los archivos más grandes (para la vista de archivos).

    Se guardan todas las carpetas, pero de los archivos solo los que
    superan un umbral configurable: guardar uno por archivo costaría
    decenas de MB y no lo necesita ninguna vista.

    Es un recorrido normal de carpetas, no una lectura de la MFT de NTFS.
    El resultado no expone cómo se obtuvo, para que otro proveedor (como la
    lectura de la MFT) pueda rellenar el mismo contrato.
#>

function New-EntradaCarpeta {
    <#
    .SYNOPSIS
        Fila del índice para una carpeta.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo compone un objeto en memoria.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Ruta, [int] $Nivel = 0)

    return [pscustomobject]@{
        Ruta     = $Ruta
        Nombre   = Split-Path $Ruta -Leaf
        Nivel    = $Nivel
        # Bytes de todo lo que cuelga de aquí, a cualquier profundidad.
        Bytes    = 0.0
        # Bytes de los archivos que están directamente aquí.
        Propios  = 0.0
        Archivos = 0
        Ultimo   = [datetime]'1900-01-01'
    }
}

function New-IndiceDisco {
    <#
    .SYNOPSIS
        Recorre una o varias rutas y devuelve el índice de espacio.

    .PARAMETER Rutas
        Carpetas raíz por las que empezar.
    .PARAMETER MinimoArchivoBytes
        Tamaño a partir del cual un archivo se guarda en la lista. Los
        más pequeños suman en su carpeta pero no se guardan uno a uno.
    .PARAMETER MaximoArchivos
        Tope de archivos guardados. Al alcanzarlo se conservan los mayores
        y se sube el umbral, para acotar la memoria.
    .PARAMETER ContarEnlacesDuros
        Cuenta una sola vez el contenido compartido. Caro: ver
        Get-IdentidadArchivo.

    .PARAMETER Sync
        Tabla sincronizada para progreso y cancelación (opcional).

    .NOTES
        Usa una pila propia y no AllDirectories para poder saltar los puntos
        de reanálisis: seguirlos contaría dos veces el destino de una unión
        o entraría en un ciclo.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo lee el disco y compone un objeto en memoria.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Rutas,
        [double] $MinimoArchivoBytes = 1MB,
        [int]    $MaximoArchivos     = 20000,
        [switch] $ContarEnlacesDuros,
        $Sync = $null
    )

    $carpetas = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $archivos = [Collections.Generic.List[object]]::new()

    $vistos = $null
    if ($ContarEnlacesDuros) {
        $vistos = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }

    $totalBytes   = 0.0
    $totalArchivos = 0
    $compartidos  = 0
    $inaccesibles = 0
    $umbral       = [double]$MinimoArchivoBytes

    foreach ($raiz in @($Rutas)) {
        if ([string]::IsNullOrWhiteSpace($raiz)) { continue }
        if (Test-Cancelacion $Sync) { break }

        $item = Get-Item -LiteralPath $raiz -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or -not $item.PSIsContainer) { continue }
        if (Test-EsEnlace $item) { continue }

        Set-Progreso $Sync "Indexando $(Get-RutaCorta $raiz)..."

        $nivelRaiz = ($item.FullName.TrimEnd([char]'\', [char]'/') -split '[\\/]').Count
        $pendientes = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $pendientes.Push($item)

        while ($pendientes.Count -gt 0) {
            if (Test-Cancelacion $Sync) { break }
            $actual = $pendientes.Pop()

            $nivel = ($actual.FullName.TrimEnd([char]'\', [char]'/') -split '[\\/]').Count - $nivelRaiz
            if (-not $carpetas.ContainsKey($actual.FullName)) {
                $carpetas[$actual.FullName] = New-EntradaCarpeta -Ruta $actual.FullName -Nivel $nivel
            }
            $entrada = $carpetas[$actual.FullName]

            # --- Archivos de esta carpeta -----------------------------
            # La carpeta cuenta una sola vez como inaccesible aunque fallen
            # los dos recorridos.
            $inaccesible = $false
            try {
                foreach ($archivo in $actual.EnumerateFiles()) {
                    $totalArchivos++
                    $entrada.Archivos++

                    if ($archivo.LastWriteTime -gt $entrada.Ultimo) {
                        $entrada.Ultimo = $archivo.LastWriteTime
                    }

                    $sumar = $true
                    if ($null -ne $vistos) {
                        $identidad = Get-IdentidadArchivo -Ruta $archivo.FullName
                        if ($null -ne $identidad -and -not $vistos.Add($identidad)) {
                            $sumar = $false
                            $compartidos++
                        }
                    }
                    if (-not $sumar) { continue }

                    $tamaño = [double]$archivo.Length
                    $entrada.Propios += $tamaño
                    $totalBytes      += $tamaño

                    if ($tamaño -ge $umbral) {
                        $archivos.Add([pscustomobject]@{
                            Ruta      = $archivo.FullName
                            Nombre    = $archivo.Name
                            Carpeta   = $actual.FullName
                            Extension = $archivo.Extension.ToLowerInvariant()
                            Bytes     = $tamaño
                            Ultimo    = $archivo.LastWriteTime
                        })

                        # Al llegar al tope se conserva la mitad mayor y el
                        # umbral sube al más pequeño de los que quedan.
                        if ($archivos.Count -ge $MaximoArchivos) {
                            # Ordenar con expresión: ver la nota en el
                            # campo Archivos del objeto devuelto.
                            $ordenados = @($archivos | Sort-Object { [double]$_.Bytes } -Descending |
                                           Select-Object -First ([int]($MaximoArchivos / 2)))
                            $archivos.Clear()
                            foreach ($a in $ordenados) { $archivos.Add($a) }
                            if ($ordenados.Count -gt 0) {
                                $umbral = [double]$ordenados[-1].Bytes
                            }
                        }
                    }
                }
            } catch {
                $inaccesible = $true
            }

            # --- Subcarpetas ------------------------------------------
            try {
                foreach ($sub in $actual.EnumerateDirectories()) {
                    if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $pendientes.Push($sub)
                }
            } catch {
                $inaccesible = $true
            }
            if ($inaccesible) { $inaccesibles++ }
        }
    }

    # --- Propagar los totales hacia arriba ---------------------------
    # De más profunda a menos: al sumar una carpeta a su padre ya contiene
    # todo lo suyo. Una sola pasada, sin volver al disco.
    Set-Progreso $Sync 'Sumando carpetas...'
    foreach ($entrada in @($carpetas.Values)) { $entrada.Bytes = $entrada.Propios }

    foreach ($entrada in @($carpetas.Values | Sort-Object Nivel -Descending)) {
        if ($entrada.Nivel -le 0) { continue }
        $padre = Split-Path $entrada.Ruta -Parent
        if ([string]::IsNullOrWhiteSpace($padre)) { continue }
        if ($carpetas.ContainsKey($padre)) {
            $carpetas[$padre].Bytes    += $entrada.Bytes
            $carpetas[$padre].Archivos += $entrada.Archivos
            if ($entrada.Ultimo -gt $carpetas[$padre].Ultimo) {
                $carpetas[$padre].Ultimo = $entrada.Ultimo
            }
        }
    }

    return [pscustomobject]@{
        Carpetas     = $carpetas
        # Ordenar siempre con expresión, nunca "Sort-Object Bytes": el
        # índice leído de disco contiene diccionarios y, en PowerShell 5.1,
        # Sort-Object por nombre de propiedad no los ordena ni da error.
        # tests/IndicePersistente.Tests.ps1 lo exige.
        Archivos     = @($archivos | Sort-Object { [double]$_.Bytes } -Descending)
        Raices       = @($Rutas)
        Bytes        = $totalBytes
        TotalArchivos = $totalArchivos
        Compartidos  = $compartidos
        Inaccesibles = $inaccesibles
        # Umbral final de la lista de archivos; puede ser mayor que el
        # pedido si se alcanzó el tope.
        UmbralArchivo = $umbral
    }
}

function Get-HijasDirectas {
    <#
    .SYNOPSIS
        Subcarpetas inmediatas de una ruta dentro del índice, ordenadas de
        mayor a menor.
    .DESCRIPTION
        Lo que necesita el mapa de árbol para dibujar un nivel. Incluye un
        bloque con los archivos propios de la carpeta.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Indice,
        [Parameter(Mandatory)] [string] $Ruta
    )

    $prefijo = $Ruta.TrimEnd([char]'\', [char]'/')
    $separador = [IO.Path]::DirectorySeparatorChar
    $resultado = [Collections.Generic.List[object]]::new()

    foreach ($entrada in $Indice.Carpetas.Values) {
        $padre = Split-Path $entrada.Ruta -Parent
        if ([string]::IsNullOrWhiteSpace($padre)) { continue }
        if ($padre.TrimEnd([char]'\', [char]'/').Equals($prefijo, [StringComparison]::OrdinalIgnoreCase)) {
            $resultado.Add($entrada)
        }
    }

    # Los archivos propios de la carpeta forman un bloque más, para que el
    # mapa sume el 100 %. Una raíz de unidad ("C:\") se guarda con su barra.
    $clavePropia = $null
    foreach ($clave in @($prefijo, ($prefijo + $separador), $Ruta)) {
        if (-not [string]::IsNullOrEmpty($clave) -and $Indice.Carpetas.ContainsKey($clave)) { $clavePropia = $clave; break }
    }
    if ($null -ne $clavePropia) {
        $propia = $Indice.Carpetas[$clavePropia]
        if ($propia.Propios -gt 0) {
            $resultado.Add([pscustomobject]@{
                Ruta     = $prefijo + $separador
                Nombre   = '(archivos de esta carpeta)'
                Nivel    = $propia.Nivel + 1
                Bytes    = $propia.Propios
                Propios  = $propia.Propios
                Archivos = 0
                Ultimo   = $propia.Ultimo
            })
        }
    }

    # Ordenar con expresión: las entradas pueden venir de un índice leído
    # de disco (diccionarios). Ver la nota en New-IndiceDisco.
    return @($resultado | Sort-Object { [double]$_.Bytes } -Descending)
}
