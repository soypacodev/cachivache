<#
.SYNOPSIS
    Discos virtuales de WSL y capas de imagen de Docker.
.DESCRIPTION
    Los discos de WSL crecen pero no se encogen solos: aunque borres los
    archivos de dentro, el .vhdx sigue ocupando lo mismo en Windows. Este
    módulo mide cuánto ocupan y ofrece los comandos oficiales para
    compactarlos. No borra ningún disco virtual.
#>

$BuscarDockerWsl = {
    param($Configuracion, $Sync)

    Set-Progreso $Sync 'Buscando discos virtuales de WSL y Docker...'
    $paquetes = Join-Path $env:LOCALAPPDATA 'Packages'
    $encontrados = @()

    # --- Distribuciones de WSL instaladas desde la Store ------------------
    if (Test-Path -LiteralPath $paquetes) {
        # Solo Packages\<paquete>\LocalState, donde WSL guarda el disco: un
        # recorrido recursivo de cada paquete sería muy costoso.
        foreach ($paquete in @(Get-ChildItem -LiteralPath $paquetes -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Cancelacion $Sync) { break }
            $estado = Join-RutaNativa $paquete.FullName 'LocalState'
            if (-not (Test-Path -LiteralPath $estado)) { continue }

            foreach ($disco in @(Get-ChildItem -LiteralPath $estado -Filter '*.vhdx' -File -Force -ErrorAction SilentlyContinue)) {
                $encontrados += $disco
            }
        }
    }

    # --- Docker Desktop --------------------------------------------------
    foreach ($carpeta in @(
        (Join-Path $env:LOCALAPPDATA 'Docker\wsl'),
        (Join-Path $env:APPDATA 'Docker\vms'))) {
        if (-not (Test-Path -LiteralPath $carpeta)) { continue }
        # Get-ElementosDelArbol por las rutas largas. -MedirEnDisco solo
        # consulta el tamaño en disco de los archivos comprimidos por NTFS.
        Get-ElementosDelArbol -Ruta $carpeta -Filtro '*.vhdx' -MedirEnDisco |
            ForEach-Object { $encontrados += $_ }
    }

    foreach ($disco in $encontrados) {
        if (Test-Cancelacion $Sync) { break }
        if ($disco.Length -lt 500MB) { continue }

        $esDocker = $disco.FullName -match '(?i)docker'
        $efecto = if ($esDocker) {
            'Ejecuta "docker system prune -a" para borrar imágenes y contenedores sin usar, y después "wsl --shutdown" seguido de Optimize-VHD para compactar el disco.'
        } else {
            'Borra lo que sobre dentro de la distribución, ejecuta "wsl --shutdown" y compacta el disco con diskpart o con Optimize-VHD.'
        }

        New-Candidato -ModuloId 'dockerwsl' -Categoria 'WSL y Docker' `
                      -Nombre "Disco virtual: $(Split-Path (Split-Path $disco.FullName -Parent) -Leaf)" `
                      -Ruta $disco.FullName -Bytes $disco.Length `
                      -TamanoEnDisco $disco.TamanoEnDisco `
                      -Info "$($disco.Name) - último cambio $($disco.LastWriteTime.ToString('yyyy-MM-dd'))" `
                      -Efecto $efecto `
                      -Aviso 'Este archivo contiene TODO el sistema de archivos de esa distribución. Borrarlo destruye los datos que haya dentro.' `
                      -Metodo 'Informativo' -Raices @() -Riesgo 'Alto' -Preseleccionado $false
    }

    # --- Caché de compilación de Docker (esta sí se puede vaciar) ----------
    # Mismo criterio que la ejecución (Resolve-EjecutablePermitido: solo
    # Archivos de programa, nunca el PATH). Un docker que solo está en el
    # PATH se propondría y luego el borrado lo rechazaría.
    if (Resolve-EjecutablePermitido -Ejecutable 'docker') {
        New-Candidato -ModuloId 'dockerwsl' -Categoria 'WSL y Docker' `
                      -Nombre 'Limpiar imágenes y contenedores de Docker sin usar' `
                      -Ruta 'docker system prune' -Bytes 0 `
                      -Info 'ejecuta el comando oficial de Docker' `
                      -Efecto 'Borra contenedores parados, redes sin usar, imágenes colgadas y la caché de compilación.' `
                      -Aviso 'Se perderán los contenedores parados que quisieras reutilizar.' `
                      -Metodo 'Comando' -Ejecutable 'docker' -Argumentos @('system', 'prune', '-a', '-f') `
                      -Comando 'docker system prune -a -f' `
                      -Raices @() -Riesgo 'Medio' -Preseleccionado $false
    }
}

New-ModuloLimpieza -Id 'dockerwsl' -Orden 85 `
    -Nombre 'WSL y Docker' `
    -Descripcion 'Discos virtuales .vhdx que crecen y no se encogen solos, y la caché de imágenes de Docker.' `
    -Riesgo 'Alto' `
    -Perfiles @('agresivo') `
    -Buscar $BuscarDockerWsl
