<#
.SYNOPSIS
    Accesos directos .lnk cuyo destino ya no existe.
.DESCRIPTION
    Se descartan los accesos de la Store (shell:, ms-...) y los que apuntan
    a direcciones web, que no tienen ruta en disco y darían falso positivo.
    El destino se vuelve a comprobar justo antes de borrar.
#>

$BuscarAccesosRotos = {
    param($Configuracion, $Sync)

    # El @() no es redundante: si ZonasUsuario llega como cadena suelta,
    # "$cadena + @(...)" concatenaría texto en vez de arrays.
    $zonas = @(
        @($Configuracion.ZonasUsuario) +
        @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu')
        )
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    if ($zonas.Count -eq 0) { return }

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { return }

    # Tipo de cada unidad, consultado una sola vez. DriveType 3 = disco fijo.
    $tiposUnidad = @{}
    try {
        foreach ($disco in Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop) {
            if ($disco.DeviceID) { $tiposUnidad[$disco.DeviceID.ToUpperInvariant()] = [int]$disco.DriveType }
        }
    } catch {
        Write-Verbose "No se han podido listar las unidades: $($_.Exception.Message)"
    }

    foreach ($zona in $zonas) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Comprobando destinos en $(Get-RutaCorta $zona)..."

        # Get-ElementosDelArbol por las rutas largas, con el filtro nativo.
        # Sin -MedirEnDisco a propósito: un .lnk ocupa uno o dos KB, la
        # diferencia sería invisible y costaría una llamada al sistema por
        # cada acceso directo.
        Get-ElementosDelArbol -Ruta $zona -Filtro '*.lnk' |
        ForEach-Object {
            if (Test-Cancelacion $Sync) { return }

            $destino = Get-DestinoAccesoDirecto -Ruta $_.FullName -Shell $shell
            if ([string]::IsNullOrWhiteSpace($destino)) { return }
            # Aplicaciones de la Store y enlaces web: no tienen ruta real.
            if ($destino -match '^(shell:|ms-|http|mailto:)') { return }
            # Rutas de red: Test-Path da $false igual si está roto que si el
            # servidor está apagado, así que no se juzgan.
            if ($destino -match '^\\\\') { return }
            if (Test-Path -LiteralPath $destino -ErrorAction SilentlyContinue) { return }
            if (-not (Test-RutaSegura $_.FullName $zonas)) { return }

            # Unidad extraíble quizá desconectada: se propone con aviso y sin
            # premarcar.
            $aviso = ''
            $preseleccionado = $true
            $raiz = [IO.Path]::GetPathRoot($destino)
            if ($raiz) {
                $letra = $raiz.TrimEnd('\')
                if ($tiposUnidad.ContainsKey($letra) -and $tiposUnidad[$letra] -ne 3) {
                    $aviso = 'El destino está en una unidad extraíble: puede que solo esté desconectada ahora mismo, no rota.'
                    $preseleccionado = $false
                }
            }

            # Test-Path también da $false sin permiso de lectura: es lo normal
            # en Program Files\WindowsApps (ACL restringida) y en el perfil de
            # otro usuario. Esos destinos se proponen con aviso y sin
            # premarcar.
            $destinoNormalizado = $destino.Replace('/', '\')
            $perfilPropio = if ($env:USERPROFILE) { $env:USERPROFILE.TrimEnd('\') } else { '' }
            $carpetaUsuarios = if ($env:SystemDrive) { $env:SystemDrive + '\Users\' } else { '' }

            $sinPermiso = $false
            if ($destinoNormalizado -match '(?i)\\WindowsApps\\') { $sinPermiso = $true }
            if ($carpetaUsuarios -and
                $destinoNormalizado.StartsWith($carpetaUsuarios, [StringComparison]::OrdinalIgnoreCase) -and
                -not ($perfilPropio -and $destinoNormalizado.StartsWith($perfilPropio + '\', [StringComparison]::OrdinalIgnoreCase))) {
                $sinPermiso = $true
            }

            if ($sinPermiso) {
                $aviso = 'No se puede comprobar el destino: está en una carpeta que este usuario no tiene permiso para leer, así que puede existir y estar bien.'
                $preseleccionado = $false
            }

            New-Candidato -ModuloId 'accesos' -Categoria 'Accesos directos rotos' `
                          -Nombre $_.Name -Ruta $_.FullName -Bytes $_.Length `
                          -Info "apunta a: $(Get-RutaElidida $destino 60)" `
                          -Efecto 'El destino ya no existe: este acceso directo no abre nada.' `
                          -Aviso $aviso -Metodo 'Ruta' -Raices $zonas -Riesgo 'Bajo' -Preseleccionado $preseleccionado
        }
    }

    if ($shell) {
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        catch { Write-Verbose "No se ha podido liberar el objeto COM: $($_.Exception.Message)" }
    }
}

New-ModuloLimpieza -Id 'accesos' -Orden 45 `
    -Nombre 'Accesos directos rotos' `
    -Descripcion 'Archivos .lnk cuyo destino ya no existe: no abren nada.' `
    -Riesgo 'Bajo' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarAccesosRotos
