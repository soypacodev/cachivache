<#
.SYNOPSIS
    Archivos duplicados detectados por hash.
.DESCRIPTION
    Para no calcular hashes de todo el disco:
      1. Se agrupa por tamaño exacto.
      2. Dentro de cada grupo, una huella rápida de los extremos descarta
         casi todo; solo los que coinciden pasan al SHA-256 completo.

    Se conserva la copia mejor situada (bibliotecas antes que Descargas o
    temporales, menos profundidad y, a igualdad, la más antigua) y se
    proponen las demás. Nada viene marcado por defecto.
#>

$BuscarDuplicados = {
    param($Configuracion, $Sync)

    $zonas = @($Configuracion.ZonasUsuario)
    if ($zonas.Count -eq 0) { return }

    $minimo = [double]$Configuracion.MinimoDuplicadoMB * 1MB
    Set-Progreso $Sync 'Recopilando archivos para comparar...'

    $porTamano = @{}
    # Defensa frente a zonas solapadas (p. ej. OneDrive que contiene
    # Documentos): un archivo indexado dos veces sería "duplicado de sí
    # mismo" y se propondría borrar el único ejemplar.
    $rutasVistas = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Archivos omitidos por estar solo en la nube, para informar de ello.
    # Va en una tabla y no en una variable: mutar un objeto por referencia
    # sigue funcionando si este bloque acaba dentro de una función o de un
    # & { }, donde "$n++" afectaría a una copia en un ámbito hijo.
    $contador = @{ Nube = 0 }

    foreach ($zona in $zonas) {
        if (Test-Cancelacion $Sync) { break }
        # Get-ElementosDelArbol y no Get-ChildItem -Recurse, por las rutas largas.
        Get-ElementosDelArbol -Ruta $zona |
        Where-Object {
            # El filtro de nube va primero: leer un marcador de OneDrive para
            # calcular su hash lo descarga. Además, borrarlo no liberaría el
            # tamaño que declara.
            if (Test-ArchivoEnNube -Archivo $_) {
                $contador.Nube++
                return $false
            }
            $_.Length -ge $minimo -and
            $_.FullName -notmatch '\\node_modules\\|\\\.git\\|\\AppData\\|\\\$Recycle' -and
            -not (Test-EsEnlace $_)
        } |
        ForEach-Object {
            if (-not $rutasVistas.Add($_.FullName)) { return }

            $clave = [string]$_.Length
            if (-not $porTamano.ContainsKey($clave)) {
                $porTamano[$clave] = [Collections.Generic.List[object]]::new()
            }
            $porTamano[$clave].Add($_)
        }
    }

    # Se informa antes de salir por "no hay duplicados", para no dar a
    # entender que se ha revisado todo.
    if ($contador.Nube -gt 0) {
        Write-Registro -Sync $Sync -Nivel 'OMITIDO' -Mensaje (
            '{0} archivos no se han comparado porque están solo en la nube: leerlos los descargaría.' -f $contador.Nube)
        Set-Progreso $Sync ('{0} archivos de la nube no se comparan (descargarlos costaría datos).' -f $contador.Nube)
    }

    $gruposCandidatos = @($porTamano.Keys | Where-Object { $porTamano[$_].Count -gt 1 })
    if ($gruposCandidatos.Count -eq 0) { return }

    $procesados = 0
    foreach ($clave in $gruposCandidatos) {
        if (Test-Cancelacion $Sync) { break }
        $procesados++
        Set-Progreso $Sync "Comparando contenido: grupo $procesados de $($gruposCandidatos.Count)"

        # --- Prefiltro barato antes del hash completo ------------------
        # Comparar los 128 KB de los extremos descarta casi todo sin leer
        # el resto; solo lo que coincide paga el SHA-256 completo.
        $porHuella = @{}
        foreach ($archivo in $porTamano[$clave]) {
            if (Test-Cancelacion $Sync) { break }
            $huella = Get-HuellaRapida -Ruta $archivo.FullName
            if ([string]::IsNullOrEmpty($huella)) { continue }
            if (-not $porHuella.ContainsKey($huella)) {
                $porHuella[$huella] = [Collections.Generic.List[object]]::new()
            }
            $porHuella[$huella].Add($archivo)
        }

        $porHash = @{}
        foreach ($huella in $porHuella.Keys) {
            # Huella única: no puede ser duplicado.
            if ($porHuella[$huella].Count -lt 2) { continue }

            foreach ($archivo in $porHuella[$huella]) {
                if (Test-Cancelacion $Sync) { break }
                $hash = $null
                try {
                    $hash = (Get-FileHash -LiteralPath $archivo.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                } catch {
                    continue
                }
                if (-not $porHash.ContainsKey($hash)) {
                    $porHash[$hash] = [Collections.Generic.List[object]]::new()
                }
                $porHash[$hash].Add($archivo)
            }
        }

        foreach ($hash in $porHash.Keys) {
            if ($porHash[$hash].Count -lt 2) { continue }

            # Enlaces duros: dos rutas al mismo archivo. Borrar uno no libera
            # nada, así que se agrupan por identidad. La consulta solo se hace
            # aquí, sobre los pocos archivos que ya coinciden en hash.
            $porContenido = @{}
            $unicos = [Collections.Generic.List[object]]::new()
            foreach ($archivo in $porHash[$hash]) {
                $identidad = Get-IdentidadArchivo -Ruta $archivo.FullName
                if ($null -eq $identidad) {
                    # Un solo enlace: es un archivo independiente.
                    $unicos.Add($archivo)
                    continue
                }
                if ($porContenido.ContainsKey($identidad)) { continue }
                $porContenido[$identidad] = $true
                $unicos.Add($archivo)
            }
            # Se usa la lista local, sin reasignar $porHash[$hash]: modificar
            # el diccionario mientras se recorren sus claves lanza
            # "Collection was modified".
            if ($unicos.Count -lt 2) { continue }

            # Cuál se conserva: manda la ubicación, no CreationTime (que se
            # renueva al restaurar, descargar o copiar). Bibliotecas antes
            # que Descargas o temporales; luego la menos profunda; y a
            # igualdad, la más antigua.
            $puntuar = {
                param($Archivo)
                $ruta = $Archivo.FullName
                $puntos = 0
                foreach ($biblioteca in @($Configuracion.Documentos, $Configuracion.Imagenes,
                                          $Configuracion.Musica, $Configuracion.Videos)) {
                    if ([string]::IsNullOrWhiteSpace($biblioteca)) { continue }
                    if ($ruta.StartsWith($biblioteca.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar,
                                         [StringComparison]::OrdinalIgnoreCase)) {
                        $puntos += 100
                        break
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($Configuracion.Descargas) -and
                    $ruta.StartsWith($Configuracion.Descargas.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar,
                                     [StringComparison]::OrdinalIgnoreCase)) {
                    $puntos -= 100
                }
                if ($ruta -match '(?i)[\\/](temp|tmp|cache)[\\/]') { $puntos -= 50 }
                # Menos profundidad, mejor: lo ordenado suele estar arriba.
                $puntos -= ($ruta -split '[\\/]').Count
                return $puntos
            }

            $copias = @($unicos |
                        Sort-Object -Property @{ Expression = { & $puntuar $_ }; Descending = $true },
                                              @{ Expression = { $_.CreationTime }; Descending = $false })

            $original = $copias[0]
            foreach ($copia in $copias[1..($copias.Count - 1)]) {
                # Junto a ejecutables es una dependencia de un programa
                # (p. ej. dos portables con la misma DLL), no una copia
                # sobrante.
                $carpeta = Split-Path $copia.FullName -Parent
                $hermanosEjecutables = @(Get-ChildItem -LiteralPath $carpeta -File -Force -ErrorAction SilentlyContinue |
                                         Where-Object { $_.Extension -match '(?i)^\.(exe|dll|sys|so|dylib)$' } |
                                         Select-Object -First 1)
                if ($hermanosEjecutables.Count -gt 0) { continue }

                # Único sitio que levanta el veto por extensión personal: el
                # hash garantiza que queda otra copia idéntica.
                if (-not (Test-RutaSegura -Ruta $copia.FullName -Raices $zonas -PermitirPersonales)) { continue }

                # El tamaño en disco se consulta aquí, sobre unos pocos
                # archivos, y no con -MedirEnDisco en el recorrido general.
                $enDisco = $null
                if (Test-EstaComprimido -Atributos ([int]$copia.Attributes)) {
                    $enDisco = Get-TamanoEnDisco -Ruta $copia.FullName
                }

                New-Candidato -ModuloId 'duplicados' -Categoria 'Archivos duplicados' `
                              -Nombre $copia.Name -Ruta $copia.FullName -Bytes $copia.Length `
                              -TamanoEnDisco $enDisco `
                              -Info "copia identica de $(Get-RutaElidida $original.FullName 55)" `
                              -Efecto 'Se conserva la otra copia, la mejor situada: bibliotecas antes que Descargas o temporales, la menos profunda y, a igualdad, la más antigua.' `
                              -Aviso 'Comprueba que la copia que se conserva es la que quieres.' `
                              -Metodo 'Ruta' -Raices $zonas -Riesgo 'Medio' `
                              -PermitirPersonales -Preseleccionado $false
            }
        }
    }
}

New-ModuloLimpieza -Id 'duplicados' -Orden 55 `
    -Nombre 'Archivos duplicados' `
    -Descripcion 'Compara por tamaño y después por hash SHA-256. Conserva la copia mejor situada: bibliotecas antes que Descargas o temporales y, a igualdad, la más antigua.' `
    -Riesgo 'Medio' `
    -Perfiles @('agresivo') `
    -Buscar $BuscarDuplicados
