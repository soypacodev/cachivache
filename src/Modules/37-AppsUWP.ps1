<#
.SYNOPSIS
    Datos de aplicaciones de la Store: cachés regenerables y carpetas de
    aplicaciones que ya no están instaladas.
.DESCRIPTION
    Cada aplicación de la Store guarda sus datos en
    "%LOCALAPPDATA%\Packages\<NombreDeFamilia>". Al desinstalarla, Windows
    a menudo deja esa carpeta.

    Dentro de cada paquete:
      - LocalCache, TempState, AC\INetCache: regenerables, riesgo bajo.
      - LocalState, RoamingState, Settings: datos del usuario; nunca se
        proponen por separado.

    Una carpeta de paquete huérfana va con aviso y sin marcar, porque su
    LocalState puede guardar datos del usuario. La guardia solo veta
    "Packages" como ruta exacta, así que sus hijas son alcanzables.
#>

$BuscarAppsUwp = {
    param($Configuracion, $Sync)

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }
    $paquetes = Join-RutaNativa $env:LOCALAPPDATA 'Packages'
    if (-not (Test-Path -LiteralPath $paquetes)) { return }

    $raices = @($paquetes)

    # Paquetes instalados, por nombre de familia. Si Get-AppxPackage falla
    # o no existe, la lista queda vacía y no se declara huérfano nada (si
    # no, se propondrían los datos de todas las aplicaciones de la Store):
    # solo se limpian las cachés internas.
    $instalados = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($paquete in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if ($paquete.PackageFamilyName) { [void]$instalados.Add($paquete.PackageFamilyName) }
        }
    } catch {
        Write-Verbose "No se ha podido consultar la lista de aplicaciones de la Store: $($_.Exception.Message)"
    }
    $sePuedeDecidir = $instalados.Count -gt 0

    # Subcarpetas que la aplicación regenera sola.
    $regenerables = @(
        @{ Nombre = 'LocalCache';  Efecto = 'Caché local de la aplicación. Se regenera al abrirla.' }
        @{ Nombre = 'TempState';   Efecto = 'Archivos temporales de la aplicación. Sin efecto.' }
        @{ Nombre = 'INetCache';   Efecto = 'Caché de red de la aplicación. Se regenera.' }
        @{ Nombre = 'INetCookies'; Efecto = 'Cookies de la vista web de la aplicación. Puede que tengas que iniciar sesión otra vez.' }
    )

    Set-Progreso $Sync 'Revisando aplicaciones de la Store...'

    foreach ($paquete in @(Get-ChildItem -LiteralPath $paquetes -Directory -Force -ErrorAction SilentlyContinue)) {
        if (Test-Cancelacion $Sync) { break }
        if (Test-EsEnlace $paquete) { continue }

        $huerfano = $sePuedeDecidir -and -not $instalados.Contains($paquete.Name)

        if ($huerfano) {
            if (Test-NombreSensible $paquete.Name)                     { continue }
            if (-not (Test-RutaSegura $paquete.FullName $raices))       { continue }

            $resumen = Get-ResumenArbol -Carpeta $paquete
            if ($resumen.Bytes -lt ($Configuracion.MinimoMB * 1MB)) { continue }

            $dias = if ($null -ne $resumen.Ultimo) {
                [int]((Get-Date) - $resumen.Ultimo).TotalDays
            } else { 0 }
            if ($dias -lt $Configuracion.DiasSinUso) { continue }

            New-Candidato -ModuloId 'appsuwp' -Categoria 'Aplicaciones de la Store desinstaladas' `
                          -Nombre $paquete.Name -Ruta $paquete.FullName -Bytes $resumen.Bytes `
                          -Info "$($resumen.Archivos) archivos - sin tocar desde hace $dias días" `
                          -Efecto 'La aplicación ya no está instalada, pero Windows dejó su carpeta de datos.' `
                          -Aviso 'Dentro puede haber datos tuyos: la carpeta LocalState guarda lo que la aplicación hubiera guardado.' `
                          -Metodo 'Ruta' -Raices $raices -Riesgo 'Medio'
            continue
        }

        # Aplicación instalada: solo sus cachés internas.
        foreach ($sub in $regenerables) {
            if (Test-Cancelacion $Sync) { break }

            foreach ($candidata in @(
                (Join-RutaNativa $paquete.FullName $sub.Nombre),
                (Join-RutaNativa $paquete.FullName 'AC' $sub.Nombre))) {

                if (-not (Test-Path -LiteralPath $candidata)) { continue }
                if (-not (Test-RutaSegura $candidata $raices)) { continue }

                $bytes = Measure-Ruta $candidata
                if ($bytes -lt 5MB) { continue }

                New-Candidato -ModuloId 'appsuwp' -Categoria 'Cachés de aplicaciones de la Store' `
                              -Nombre "$($paquete.Name) - $($sub.Nombre)" `
                              -Ruta $candidata -Bytes $bytes `
                              -Info 'se vacía el contenido, la carpeta se queda' `
                              -Efecto $sub.Efecto `
                              -Metodo 'Contenido' -Raices $raices -Riesgo 'Bajo' -ForzarPermanente
            }
        }
    }
}

New-ModuloLimpieza -Id 'appsuwp' -Orden 37 `
    -Nombre 'Aplicaciones de la Store' `
    -Descripcion 'Cachés internas de las aplicaciones de la Store y carpetas de datos de aplicaciones que ya no están instaladas.' `
    -Riesgo 'Medio' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarAppsUwp
