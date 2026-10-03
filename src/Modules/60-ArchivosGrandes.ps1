<#
.SYNOPSIS
    Archivos muy grandes que llevan mucho tiempo sin abrirse.
.DESCRIPTION
    Módulo informativo: nunca borra nada, solo muestra dónde se va el
    espacio. Como Windows puede tener desactivado el seguimiento de último
    acceso, se usa la fecha más reciente entre acceso y modificación.
#>

$BuscarArchivosGrandes = {
    param($Configuracion, $Sync)

    $zonas = @($Configuracion.ZonasUsuario)
    if ($zonas.Count -eq 0) { return }

    $minimo = [double]$Configuracion.MinimoGrandeMB * 1MB
    $limite = (Get-Date).AddDays(-$Configuracion.DiasSinUso)

    foreach ($zona in $zonas) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Buscando archivos grandes en $(Get-RutaCorta $zona)..."

        # Get-ElementosDelArbol por las rutas largas. -MedirEnDisco solo
        # consulta el tamaño en disco de los archivos comprimidos por NTFS,
        # para no prometer el tamaño lógico.
        Get-ElementosDelArbol -Ruta $zona -MedirEnDisco |
        Where-Object {
            # Un archivo solo en la nube ocupa unos KB en local: borrarlo no
            # libera su tamaño lógico y lo quitaría de OneDrive.
            -not (Test-ArchivoEnNube -Archivo $_) -and
            $_.Length -ge $minimo -and
            $_.FullName -notmatch '\\node_modules\\|\\\.git\\|\\\$Recycle|hiberfil|pagefile|swapfile' -and
            -not (Test-EsEnlace $_)
        } |
        ForEach-Object {
            if (Test-Cancelacion $Sync) { return }

            $ultimoUso = $_.LastAccessTime
            if ($_.LastWriteTime -gt $ultimoUso) { $ultimoUso = $_.LastWriteTime }
            if ($ultimoUso -gt $limite) { return }

            New-Candidato -ModuloId 'grandes' -Categoria 'Archivos grandes sin usar' `
                          -Nombre $_.Name -Ruta $_.FullName -Bytes $_.Length `
                          -TamanoEnDisco $_.TamanoEnDisco `
                          -Info "$(Get-RutaElidida $_.DirectoryName 55) - sin abrir desde $($ultimoUso.ToString('yyyy-MM-dd')) ($(Format-Antiguedad $ultimoUso))" `
                          -Efecto 'Solo informativo: este módulo no borra nada. Decide tú si lo mueves a un disco externo o lo eliminas a mano.' `
                          -Metodo 'Informativo' -Raices $zonas -Riesgo 'Medio' -Preseleccionado $false
        }
    }
}

New-ModuloLimpieza -Id 'grandes' -Orden 60 `
    -Nombre 'Archivos grandes sin usar' `
    -Descripcion 'Informe de los archivos que más ocupan y llevan más tiempo sin abrirse. Este módulo nunca borra nada.' `
    -Riesgo 'Alto' -SoloInforma `
    -Perfiles @('agresivo') `
    -Buscar $BuscarArchivosGrandes
