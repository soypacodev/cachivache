<#
.SYNOPSIS
    Perfiles de usuario abandonados en el equipo.
.DESCRIPTION
    Módulo informativo y solo para administradores. Un perfil de otro
    usuario puede ocupar decenas de GB, pero borrarlo destruye todos sus
    documentos. Se quita desde Configuración > Cuentas o Propiedades del
    sistema > Perfiles de usuario, que además limpia el registro.
#>

$BuscarPerfilesUsuario = {
    param($Configuracion, $Sync)

    Set-Progreso $Sync 'Revisando perfiles de usuario...'
    $miPerfil = $env:USERPROFILE.TrimEnd('\').ToLowerInvariant()

    Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Special } |
    ForEach-Object {
        if (Test-Cancelacion $Sync) { return }
        $ruta = $_.LocalPath
        if ([string]::IsNullOrWhiteSpace($ruta)) { return }
        if ($ruta.TrimEnd('\').ToLowerInvariant() -eq $miPerfil) { return }
        if (-not (Test-Path -LiteralPath $ruta)) { return }

        Set-Progreso $Sync "Midiendo el perfil $(Split-Path $ruta -Leaf)..."
        $bytes = Measure-Ruta $ruta
        if ($bytes -lt 100MB) { return }

        $ultimoUso = $null
        try { $ultimoUso = $_.LastUseTime } catch { $ultimoUso = $null }
        $descripcion = if ($ultimoUso) { "usado por última vez $($ultimoUso.ToString('yyyy-MM-dd')) ($(Format-Antiguedad $ultimoUso))" } else { 'fecha de último uso desconocida' }
        if ($_.Loaded) { $descripcion += ' - sesión iniciada ahora mismo' }

        New-Candidato -ModuloId 'perfiles' -Categoria 'Perfiles de usuario' `
                      -Nombre "Perfil: $(Split-Path $ruta -Leaf)" -Ruta $ruta -Bytes $bytes `
                      -Info $descripcion `
                      -Efecto 'Quítalo desde Propiedades del sistema > Configuración avanzada > Perfiles de usuario, que además limpia el registro.' `
                      -Aviso 'Contiene todos los documentos, fotos y ajustes de esa persona. Este programa nunca lo borra.' `
                      -Metodo 'Informativo' -Raices @() -Riesgo 'Alto' -Preseleccionado $false
    }
}

New-ModuloLimpieza -Id 'perfiles' -Orden 95 `
    -Nombre 'Perfiles de usuario abandonados' `
    -Descripcion 'Perfiles de otras cuentas que siguen ocupando disco. Solo informa: quitarlos se hace desde Windows.' `
    -Riesgo 'Alto' -RequiereAdmin -SoloInforma `
    -Perfiles @('agresivo') `
    -Buscar $BuscarPerfilesUsuario
