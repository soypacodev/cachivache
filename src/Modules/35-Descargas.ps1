<#
.SYNOPSIS
    Instaladores y archivos antiguos en la carpeta Descargas.
.DESCRIPTION
    Solo se propone lo que casi siempre se puede volver a descargar:
    instaladores, imágenes de disco y comprimidos. Nunca se propone un
    documento, una foto ni un vídeo, aunque sea antiguo y ocupe mucho.
#>

$BuscarDescargas = {
    param($Configuracion, $Sync)

    $zonas = @($Configuracion.Descargas) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if ($zonas.Count -eq 0) { return }

    $limite = (Get-Date).AddDays(-$Configuracion.DiasSinUso)

    $tipos = @{
        '.exe'  = 'Instalador de Windows'
        '.msi'  = 'Instalador de Windows'
        '.msix' = 'Paquete de aplicación'
        '.appx' = 'Paquete de aplicación'
        '.iso'  = 'Imagen de disco'
        '.img'  = 'Imagen de disco'
        '.dmg'  = 'Imagen de disco de macOS'
        '.pkg'  = 'Instalador de macOS'
        '.deb'  = 'Paquete de Linux'
        '.rpm'  = 'Paquete de Linux'
        '.cab'  = 'Archivo comprimido de Windows'
        '.zip'  = 'Archivo comprimido'
        '.rar'  = 'Archivo comprimido'
        '.7z'   = 'Archivo comprimido'
        '.tar'  = 'Archivo comprimido'
        '.gz'   = 'Archivo comprimido'
        '.msu'         = 'Actualización de Windows'
        '.msp'         = 'Parche de Windows'
        '.msixbundle'  = 'Paquete de aplicación'
        '.appxbundle'  = 'Paquete de aplicación'
        '.jar'         = 'Aplicación de Java'
        '.apk'         = 'Aplicación de Android'
        '.vhd'         = 'Disco virtual'
        '.vhdx'        = 'Disco virtual'
        '.esd'         = 'Imagen comprimida de Windows'
        '.bz2'         = 'Archivo comprimido'
        '.xz'          = 'Archivo comprimido'
        '.zst'         = 'Archivo comprimido'
    }

    foreach ($zona in $zonas) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Revisando $(Get-RutaCorta $zona)..."

        # Get-ElementosDelArbol por las rutas largas. -MedirEnDisco solo
        # consulta el tamaño en disco de los archivos comprimidos por NTFS,
        # para no prometer el tamaño lógico.
        Get-ElementosDelArbol -Ruta $zona -MedirEnDisco |
        # Solo LastWriteTime, no la fecha de último acceso: Windows no la
        # actualiza por defecto (NtfsDisableLastAccessUpdate) y, donde está
        # activa, la tocan el antivirus, el indexador y las copias de
        # seguridad. Fiarse de ella ocultaría candidatos legítimos; como este
        # módulo no premarca nada, se prefiere el error visible.
        Where-Object {
            $tipos.ContainsKey($_.Extension.ToLowerInvariant()) -and
            $_.LastWriteTime -lt $limite -and
            $_.Length -ge ($Configuracion.MinimoMB * 1MB)
        } |
        ForEach-Object {
            if (Test-Cancelacion $Sync) { return }
            if (-not (Test-RutaSegura $_.FullName $zonas)) { return }

            $tipo = $tipos[$_.Extension.ToLowerInvariant()]
            # Los comprimidos pueden contener cualquier cosa: más riesgo. Se
            # pasa -Preseleccionado $false aunque el riesgo sea "Bajo": este
            # módulo no premarca nada.
            $esComprimido = $_.Extension -match '(?i)^\.(zip|rar|7z|tar|gz|bz2|xz|zst)$'

            # Una imagen de disco grande suele ser una máquina virtual o un
            # respaldo, no un instalador: se propone con aviso.
            $esImagenGrande = ($_.Extension -match '(?i)^\.(iso|img|vhd|vhdx|esd)$') -and $_.Length -ge 1GB

            $riesgo = if ($esComprimido -or $esImagenGrande) { 'Medio' } else { 'Bajo' }
            $aviso  = if ($esComprimido) {
                'Es un comprimido: comprueba que no guarda nada tuyo dentro.'
            } elseif ($esImagenGrande) {
                'Es una imagen de disco de más de 1 GB: puede ser una máquina virtual o un respaldo, no un instalador.'
            } else { '' }

            New-Candidato -ModuloId 'descargas' -Categoria 'Descargas antiguas' `
                          -Nombre $_.Name -Ruta $_.FullName -Bytes $_.Length `
                          -TamanoEnDisco $_.TamanoEnDisco `
                          -Info "$tipo - descargado $($_.LastWriteTime.ToString('yyyy-MM-dd')) ($(Format-Antiguedad $_.LastWriteTime))" `
                          -Efecto 'Se puede volver a descargar de su página original.' `
                          -Aviso $aviso -Metodo 'Ruta' -Raices $zonas `
                          -Riesgo $riesgo -Preseleccionado $false
        }
    }
}

New-ModuloLimpieza -Id 'descargas' -Orden 35 `
    -Nombre 'Instaladores y descargas antiguas' `
    -Descripcion 'Instaladores, imágenes de disco y comprimidos viejos en la carpeta Descargas. Nunca propone documentos ni fotos.' `
    -Riesgo 'Medio' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarDescargas
