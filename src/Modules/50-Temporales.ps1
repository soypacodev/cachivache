<#
.SYNOPSIS
    Archivos temporales sueltos repartidos por las carpetas del usuario.
.DESCRIPTION
    .tmp, .bak, .old, autoguardados de Office, descargas a medias y bases de
    datos de miniaturas. Se excluye .log a propósito: hay programas que
    guardan información útil ahí.
#>

$BuscarTemporales = {
    param($Configuracion, $Sync)

    $zonas = @($Configuracion.ZonasUsuario)
    if ($zonas.Count -eq 0) { return }

    $nombresMetadatos = @('Thumbs.db', 'ehthumbs.db', '.DS_Store', 'desktop.ini.bak')

    # Un bloqueo de Office, una descarga a medias o un .tmp/.temp muy
    # reciente pueden seguir en uso.
    $limiteReciente = (Get-Date).AddMinutes(-30)
    $officeAbierto  = @(Test-ProcesoAbierto @('winword', 'excel', 'powerpnt')).Count -gt 0

    foreach ($zona in $zonas) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Revisando $(Get-RutaCorta $zona)..."

        # Get-ElementosDelArbol por las rutas largas. -MedirEnDisco solo
        # consulta el tamaño en disco de los archivos comprimidos por NTFS,
        # para no prometer el tamaño lógico.
        Get-ElementosDelArbol -Ruta $zona -MedirEnDisco |
        Where-Object {
            $_.FullName -notmatch '\\node_modules\\|\\\.git\\' -and
            (
                $_.Extension -match '^\.(tmp|bak|old|dmp|chk|gid|crdownload|partial|download|temp)$' -or
                $_.Name -like '~$*' -or
                # Solo la extensión, no ".~" en cualquier posición.
                $_.Extension -like '.~*' -or
                $nombresMetadatos -contains $_.Name
            )
        } |
        ForEach-Object {
            if (Test-Cancelacion $Sync) { return }

            $esBloqueoOffice   = $_.Name -like '~$*'
            $esDescargaAMedias = $_.Extension -match '^\.(crdownload|partial|download)$'
            $esTmpGenerico     = $_.Extension -match '^\.(tmp|temp)$'

            # No se sabe a qué documento pertenece cada ~$*: no se proponen
            # mientras haya algún Office abierto.
            if ($esBloqueoOffice -and $officeAbierto) { return }
            # Reciente: puede seguir escribiéndose.
            if (($esBloqueoOffice -or $esDescargaAMedias -or $esTmpGenerico) -and
                $_.LastWriteTime -gt $limiteReciente) { return }

            if (-not (Test-RutaSegura $_.FullName $zonas)) { return }

            $categoria = 'Temporales sueltos'
            $efecto    = 'Archivo temporal. Ningún programa lo necesita.'
            if ($nombresMetadatos -contains $_.Name) {
                $categoria = 'Miniaturas y metadatos'
                $efecto    = 'Caché de miniaturas del Explorador. Se regenera al abrir la carpeta.'
            } elseif ($_.Name -like '~$*') {
                $categoria = 'Autoguardados de Office'
                $efecto    = 'Archivo de bloqueo de Word o Excel. Sobra si el documento no está abierto.'
            } elseif ($_.Extension -match '^\.(crdownload|partial|download)$') {
                $categoria = 'Descargas a medias'
                $efecto    = 'Descarga interrumpida. No sirve para nada: hay que volver a bajarla.'
            } elseif ($_.Extension -match '^\.(bak|old)$') {
                $categoria = 'Copias .bak y .old'
                $efecto    = 'Copia antigua que dejó algún programa al guardar.'
            }

            # Un .bak reciente puede ser la única copia de algo.
            $reciente = ((Get-Date) - $_.LastWriteTime).TotalDays -lt 7
            $riesgo = if ($_.Extension -match '^\.(bak|old)$') { 'Medio' } else { 'Bajo' }
            $aviso  = if ($reciente -and $riesgo -eq 'Medio') { 'Creado hace menos de una semana.' } else { '' }

            New-Candidato -ModuloId 'temporales' -Categoria $categoria `
                          -Nombre $_.Name -Ruta $_.FullName -Bytes $_.Length `
                          -TamanoEnDisco $_.TamanoEnDisco `
                          -Info "$(Get-RutaElidida $_.DirectoryName 55) - $($_.LastWriteTime.ToString('yyyy-MM-dd'))" `
                          -Efecto $efecto -Aviso $aviso -Metodo 'Ruta' -Raices $zonas -Riesgo $riesgo
        }
    }
}

New-ModuloLimpieza -Id 'temporales' -Orden 50 `
    -Nombre 'Temporales sueltos y miniaturas' `
    -Descripcion 'Archivos .tmp, .bak, .old, autoguardados de Office, descargas a medias y Thumbs.db repartidos por tus carpetas.' `
    -Riesgo 'Bajo' `
    -Perfiles @('conservador', 'equilibrado', 'agresivo') `
    -Buscar $BuscarTemporales
