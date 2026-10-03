<#
.SYNOPSIS
    Cachés de navegadores basados en Chromium, perfil por perfil.
.DESCRIPTION
    Solo se vacían las subcarpetas de caché de cada perfil, nunca el perfil
    entero, que contiene contraseñas, cookies, marcadores, historial y
    extensiones.
#>

$BuscarNavegadores = {
    param($Configuracion, $Sync)

    $LA = $env:LOCALAPPDATA

    $navegadores = @(
        @{ N = 'Chrome';   R = "$LA\Google\Chrome\User Data";              P = 'chrome' }
        @{ N = 'Edge';     R = "$LA\Microsoft\Edge\User Data";             P = 'msedge' }
        @{ N = 'Brave';    R = "$LA\BraveSoftware\Brave-Browser\User Data";P = 'brave' }
        @{ N = 'Opera';    R = "$LA\Opera Software\Opera Stable";          P = 'opera' }
        @{ N = 'Opera GX'; R = "$LA\Opera Software\Opera GX Stable";       P = 'opera' }
        @{ N = 'Vivaldi';  R = "$LA\Vivaldi\User Data";                    P = 'vivaldi' }
        @{ N = 'Yandex';   R = "$LA\Yandex\YandexBrowser\User Data";       P = 'browser' }
        @{ N = 'Chromium'; R = "$LA\Chromium\User Data";                   P = 'chromium' }
    )

    # Subcarpetas de un perfil de Chromium que son solo caché.
    $subcarpetasCache = @(
        @{ S = 'Cache';                          D = 'páginas web guardadas' }
        @{ S = 'Code Cache';                     D = 'JavaScript compilado' }
        @{ S = 'GPUCache';                       D = 'shaders de la tarjeta gráfica' }
        @{ S = 'Service Worker\CacheStorage';    D = 'caché de aplicaciones web' }
        @{ S = 'Service Worker\ScriptCache';     D = 'scripts de aplicaciones web' }
        @{ S = 'DawnGraphiteCache';              D = 'cache gráfica' }
        @{ S = 'DawnWebGPUCache';                D = 'caché de WebGPU' }
    )

    $patronPerfil = '^(Default|Profile \d+|Guest Profile|System Profile)$'
    $raices = @($LA)

    foreach ($navegador in $navegadores) {
        if (Test-Cancelacion $Sync) { break }
        if (-not (Test-Path -LiteralPath $navegador.R)) { continue }

        Set-Progreso $Sync "Revisando $($navegador.N)..."
        $abierto = @(Test-ProcesoAbierto @($navegador.P)).Count -gt 0

        # Opera Stable no usa subcarpetas de perfil: la raíz ya es el perfil.
        $perfiles = @(Get-ChildItem -LiteralPath $navegador.R -Directory -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match $patronPerfil })
        if ($perfiles.Count -eq 0) {
            $perfiles = @(Get-Item -LiteralPath $navegador.R -Force -ErrorAction SilentlyContinue)
        }

        foreach ($perfil in $perfiles) {
            if (Test-Cancelacion $Sync) { break }

            foreach ($sub in $subcarpetasCache) {
                $ruta = Join-Path $perfil.FullName $sub.S
                if (-not (Test-Path -LiteralPath $ruta)) { continue }

                # La guardia antes que la medición: es mucho más barata.
                if (-not (Test-RutaSegura $ruta $raices)) { continue }

                $bytes = Measure-Ruta $ruta
                if ($bytes -lt 1MB) { continue }

                $etiquetaPerfil = if ($perfil.Name -eq (Split-Path $navegador.R -Leaf)) { 'perfil único' } else { $perfil.Name }
                # Va en Info, no en Aviso: un aviso deja el candidato sin
                # marcar, y tener el navegador abierto es el caso normal.
                $nota = if ($abierto) { " - $($navegador.N) está abierto: ciérralo para vaciarla del todo" } else { '' }

                New-Candidato -ModuloId 'navegadores' -Categoria "Navegador: $($navegador.N)" `
                              -Nombre "$($navegador.N) - $etiquetaPerfil - $(Split-Path $sub.S -Leaf)" `
                              -Ruta $ruta -Bytes $bytes `
                              -Info "$($sub.D) - se vacía el contenido$nota" `
                              -Efecto 'No borra contraseñas, marcadores, cookies, historial ni extensiones.' `
                              -Metodo 'Contenido' -Raices $raices `
                              -Riesgo 'Bajo' -Preseleccionado $true -ForzarPermanente
            }
        }
    }
}

New-ModuloLimpieza -Id 'navegadores' -Orden 15 `
    -Nombre 'Cachés de navegadores' `
    -Descripcion 'Caché por perfil de Chrome, Edge, Brave, Opera, Vivaldi y derivados. Nunca toca sesiones ni contraseñas.' `
    -Riesgo 'Bajo' `
    -Perfiles @('conservador', 'equilibrado', 'agresivo') `
    -Buscar $BuscarNavegadores
