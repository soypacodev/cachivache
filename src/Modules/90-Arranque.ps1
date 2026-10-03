<#
.SYNOPSIS
    Entradas de arranque, servicios y tareas que apuntan a nada.
.DESCRIPTION
    Módulo informativo. No borra ni desactiva nada: solo señala entradas
    rotas para que se quiten a mano desde el Administrador de tareas o el
    Programador de tareas.

    Un ejecutable se declara "roto" solo si fallan las tres comprobaciones:
    la ruta tal cual, la ruta con .exe añadido y la resolución por PATH.
    Las tareas del árbol \Microsoft\ se excluyen enteras: son del sistema.
#>

$BuscarArranque = {
    param($Configuracion, $Sync)

    $estados = Get-EstadoArranque

    # --- 1. Entradas de arranque en el registro ---------------------------
    Set-Progreso $Sync 'Revisando el arranque del sistema...'
    $claves = @(
        @{ K = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              O = 'todos los usuarios' }
        @{ K = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';  O = 'todos los usuarios (32 bits)' }
        @{ K = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';          O = 'todos los usuarios, una vez' }
        @{ K = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              O = 'tu usuario' }
        @{ K = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';          O = 'tu usuario, una vez' }
    )

    foreach ($entrada in $claves) {
        if (Test-Cancelacion $Sync) { break }
        $valores = Get-ItemProperty -Path $entrada.K -ErrorAction SilentlyContinue
        if ($null -eq $valores) { continue }

        $valores.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
            # Los valores no textuales (p. ej. REG_BINARY del Explorador) se
            # convertirían en una lista de números y darían falsos rotos.
            if ($_.Value -isnot [string]) { return }

            $ejecutable = Get-EjecutableDeComando $_.Value
            if (Test-EjecutableExiste $ejecutable) { return }

            $activo = if ($estados.ContainsKey($_.Name)) {
                if ($estados[$_.Name]) { 'activada' } else { 'ya desactivada' }
            } else { 'estado desconocido' }

            New-Candidato -ModuloId 'arranque' -Categoria 'Arranque roto' `
                          -Nombre $_.Name -Ruta $entrada.K -Bytes 0 `
                          -Info "$($entrada.O) - $activo - apunta a: $(Get-RutaElidida $ejecutable 55)" `
                          -Efecto 'Quítala desde el Administrador de tareas, pestaña Inicio. Windows intenta lanzarla en cada arranque y falla en silencio.' `
                          -Metodo 'Informativo' -Raices @() -Riesgo 'Medio' -Preseleccionado $false
        }
    }

    # --- 2. Carpetas de Inicio -------------------------------------------
    $carpetasInicio = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell }
    catch { Write-Verbose 'No hay WScript.Shell: se omiten las carpetas de Inicio.' }

    foreach ($carpeta in $carpetasInicio) {
        if (Test-Cancelacion $Sync) { break }
        Get-ChildItem -LiteralPath $carpeta -Filter '*.lnk' -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $destino = Get-DestinoAccesoDirecto -Ruta $_.FullName -Shell $shell
            if ([string]::IsNullOrWhiteSpace($destino)) { return }
            if ($destino -match '^(shell:|ms-|http)') { return }
            if (Test-Path -LiteralPath $destino -ErrorAction SilentlyContinue) { return }

            New-Candidato -ModuloId 'arranque' -Categoria 'Arranque roto' `
                          -Nombre $_.BaseName -Ruta $_.FullName -Bytes $_.Length `
                          -Info "carpeta Inicio - apunta a: $(Get-RutaElidida $destino 55)" `
                          -Efecto 'Acceso directo de arranque cuyo destino ya no existe. Se puede borrar sin consecuencias.' `
                          -Metodo 'Informativo' -Raices @() -Riesgo 'Bajo' -Preseleccionado $false
        }
    }

    # --- 3. Servicios sin binario ----------------------------------------
    Set-Progreso $Sync 'Revisando servicios...'
    Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Cancelacion $Sync) { return }
        $ejecutable = Get-EjecutableDeComando $_.PathName
        if (Test-EjecutableExiste $ejecutable) { return }

        New-Candidato -ModuloId 'arranque' -Categoria 'Servicios rotos' `
                      -Nombre $_.Name -Ruta $ejecutable -Bytes 0 `
                      -Info "inicio: $($_.StartMode) - estado: $($_.State)" `
                      -Efecto 'El binario del servicio no existe. Suele ser el resto de un programa mal desinstalado.' `
                      -Aviso 'No lo borres si no sabes de qué programa venía: algunos servicios del sistema se registran de forma poco convencional.' `
                      -Metodo 'Informativo' -Raices @() -Riesgo 'Alto' -Preseleccionado $false
    }

    # --- 4. Tareas programadas de terceros -------------------------------
    Set-Progreso $Sync 'Revisando tareas programadas...'
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        ForEach-Object {
            if (Test-Cancelacion $Sync) { return }
            $accion = @($_.Actions) | Select-Object -First 1
            if ($null -eq $accion -or [string]::IsNullOrWhiteSpace($accion.Execute)) { return }

            $ejecutable = Get-EjecutableDeComando $accion.Execute
            if (Test-EjecutableExiste $ejecutable) { return }

            New-Candidato -ModuloId 'arranque' -Categoria 'Tareas programadas rotas' `
                          -Nombre $_.TaskName -Ruta ($_.TaskPath + $_.TaskName) -Bytes 0 `
                          -Info "estado: $($_.State) - apunta a: $(Get-RutaElidida $ejecutable 55)" `
                          -Efecto 'Quítala desde el Programador de tareas. Windows la intenta lanzar y falla.' `
                          -Metodo 'Informativo' -Raices @() -Riesgo 'Medio' -Preseleccionado $false
        }
}

New-ModuloLimpieza -Id 'arranque' -Orden 90 `
    -Nombre 'Arranque, servicios y tareas rotas' `
    -Descripcion 'Entradas que Windows intenta ejecutar en cada arranque y cuyo programa ya no existe. Solo informa: no modifica el registro.' `
    -Riesgo 'Medio' -SoloInforma `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarArranque
