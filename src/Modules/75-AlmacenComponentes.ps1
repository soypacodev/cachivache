<#
.SYNOPSIS
    Almacén de componentes de Windows (WinSxS).
.DESCRIPTION
    WinSxS nunca se toca a mano: borrar algo de ahí rompe Windows Update y
    puede impedir el arranque. Este módulo pregunta a DISM cuánto se podría
    recuperar y ofrece el comando oficial como acción explícita.
#>

$BuscarAlmacenComponentes = {
    param($Configuracion, $Sync)

    # System32 del propio equipo, nunca el PATH.
    $dism = Resolve-EjecutableDeSistema -Nombre 'Dism.exe'
    if ($null -eq $dism) { return }

    Set-Progreso $Sync 'Preguntando a DISM por el almacén de componentes (puede tardar un minuto)...'

    $salida = ''
    try {
        $salida = & $dism /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String
    } catch {
        return
    }
    if (Test-Cancelacion $Sync) { return }

    # La estimación es la suma de "Backups and Disabled Features" y "Cache
    # and Temporary Data" ("Number of Reclaimable Packages" es un conteo,
    # sin unidad). DISM escribe las etiquetas en el idioma de Windows, así
    # que se aceptan inglés y castellano. Se busca el trozo sin tildes
    # porque la salida llega con la página de códigos de la consola.
    $recuperable = 0.0
    $seHaInterpretado = $false
    $lineas = $salida -split "`r?`n"
    foreach ($linea in $lineas) {
        if ($linea -match '(?i)(backups and disabled features|copias de seguridad y caracter|cache and temporary data|datos temporales y en cach).*?:\s*([\d.,]+)\s*(KB|MB|GB)') {
            $numero = ConvertFrom-NumeroLocal $Matches[2]
            $recuperable += ConvertTo-BytesConUnidad -Numero $numero -Unidad $Matches[3]
            $seHaInterpretado = $true
        }
    }

    # En castellano DISM no escribe "Recomendada: sí" sino "Se recomienda la
    # limpieza del almacén de componentes": se reconocen las dos formas.
    $recomendada = ($salida -match '(?i)(recommended|recomendada).*?:\s*(yes|si|s.)') -or
                   ($salida -match '(?i)se recomienda')
    $winsxs = Join-Path $env:SystemRoot 'WinSxS'
    $ocupado = Measure-Ruta $winsxs

    if (-not $seHaInterpretado -and -not $recomendada) {
        New-Candidato -ModuloId 'componentes' -Categoria 'Almacén de componentes' `
                      -Nombre 'No se ha podido leer la estimación de DISM' -Ruta $winsxs -Bytes 0 `
                      -Info "WinSxS ocupa $(Format-Tamano $ocupado); no se ha podido interpretar la salida de DISM" `
                      -Efecto 'Puede que DISM haya cambiado el formato de su salida en esta versión de Windows.' `
                      -Metodo 'Informativo' -Raices @() -Riesgo 'Bajo' -Preseleccionado $false
        return
    }

    if ($recuperable -lt 100MB -and -not $recomendada) {
        New-Candidato -ModuloId 'componentes' -Categoria 'Almacén de componentes' `
                      -Nombre 'WinSxS está en buen estado' -Ruta $winsxs -Bytes 0 `
                      -Info "ocupa $(Format-Tamano $ocupado), DISM no recomienda limpiarlo ahora" `
                      -Efecto 'No hay nada que hacer. Windows limpia este almacén solo con una tarea programada.' `
                      -Metodo 'Informativo' -Raices @() -Riesgo 'Bajo' -Preseleccionado $false
        return
    }

    $infoRecuperable = if ($seHaInterpretado) {
        "WinSxS ocupa $(Format-Tamano $ocupado); DISM estima $(Format-Tamano $recuperable) recuperables"
    } else {
        "WinSxS ocupa $(Format-Tamano $ocupado); DISM recomienda limpiarlo pero no se ha podido interpretar cuanto recuperaria"
    }

    New-Candidato -ModuloId 'componentes' -Categoria 'Almacén de componentes' `
                  -Nombre 'Compactar el almacén de componentes con DISM' -Ruta $winsxs -Bytes $recuperable `
                  -Info $infoRecuperable `
                  -Efecto 'Ejecuta el comando oficial de Windows (DISM /StartComponentCleanup). Puede tardar entre 10 y 40 minutos y no se debe interrumpir.' `
                  -Aviso 'Después de esto no se podrán desinstalar las actualizaciones ya instaladas.' `
                  -Metodo 'Comando' `
                  -Ejecutable 'dism' -Argumentos @('/Online', '/Cleanup-Image', '/StartComponentCleanup') `
                  -Comando ('"{0}" /Online /Cleanup-Image /StartComponentCleanup' -f $dism) `
                  -Raices @() -Riesgo 'Medio' -Preseleccionado $false
}

New-ModuloLimpieza -Id 'componentes' -Orden 75 `
    -Nombre 'Almacén de componentes (WinSxS)' `
    -Descripcion 'Consulta a DISM cuánto se puede compactar y ejecuta el comando oficial. Nunca borra archivos de WinSxS a mano.' `
    -Riesgo 'Medio' -RequiereAdmin `
    -Perfiles @('agresivo') `
    -Buscar $BuscarAlmacenComponentes
