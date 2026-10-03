<#
.SYNOPSIS
    Restos de juegos y de sus plataformas: Steam, Epic, Battle.net, GOG,
    EA, Ubisoft y Riot.
.DESCRIPTION
    Las plataformas de juego dejan atrás instalaciones que ya no
    reconocen, cachés de sombreadores por juego, descargas interrumpidas y
    contenido del taller de juegos desinstalados.

    Dos clases de candidato:
      - Basura regenerable (cachés, registros, descargas a medias,
        volcados): la plataforma la recrea. Riesgo bajo, se marca.
      - Instalaciones huérfanas que la plataforma ya no reconoce: decenas
        de GB, pero nunca se marcan.

    Nunca se tocan:
      - "Ubisoft Game Launcher\savegames" (partidas guardadas).
      - "userdata\<id>\<appid>\remote" (partidas en la nube de Steam).
      - "Documents\My Games\<Juego>" y "Saved Games\<Juego>": solo se
        proponen sus subcarpetas de registros, volcados y caché; la
        carpeta del juego es informativa.
#>

$BuscarJuegos = {
    param($Configuracion, $Sync)

    $LA = $env:LOCALAPPDATA
    $RA = $env:APPDATA
    $PD = $env:ProgramData
    $UP = $env:USERPROFILE

    # ==================================================================
    # 1. Cachés y registros de las plataformas: basura pura
    # ==================================================================
    $plataformas = @(
        # --- Steam ------------------------------------------------------
        @{ N = 'Caché web de Steam';          R = "$LA\Steam\htmlcache";  M = 'Contenido'; Menor = $true;  E = 'Se regenera. Cierra Steam antes.' }

        # --- Epic Games -------------------------------------------------
        @{ N = 'Registros de Epic Games';     R = "$LA\EpicGamesLauncher\Saved\Logs";     M = 'Contenido'; Menor = $true;  E = 'Sin efecto. Cierra Epic antes.' }
        @{ N = 'Caché web de Epic Games';     R = "$LA\EpicGamesLauncher\Saved\webcache"; M = 'Contenido'; Menor = $true;  E = 'Se regenera. Cierra Epic antes.' }
        @{ N = 'Caché de datos derivados de Unreal'; R = "$LA\UnrealEngine\Common\DerivedDataCache"; M = 'Contenido'; Menor = $false; E = 'Se regenera al abrir el proyecto. La primera compilación tardará mucho más.' }

        # --- Battle.net / Blizzard --------------------------------------
        @{ N = 'Caché de Battle.net';         R = "$PD\Battle.net\Cache";  M = 'Contenido'; Menor = $false; E = 'Se regenera. Cierra Battle.net antes.' }
        @{ N = 'Caché local de Battle.net';   R = "$LA\Battle.net\Cache";  M = 'Contenido'; Menor = $true;  E = 'Se regenera.' }
        @{ N = 'Registros de Battle.net';     R = "$RA\Battle.net\Logs";   M = 'Contenido'; Menor = $true;  E = 'Sin efecto.' }
        @{ N = 'Caché de Blizzard';           R = "$PD\Blizzard Entertainment\Battle.net\Cache"; M = 'Contenido'; Menor = $false; E = 'Se regenera. Suele ser lo que más ocupa de Battle.net.' }

        # --- GOG Galaxy --------------------------------------------------
        @{ N = 'Caché web de GOG Galaxy';     R = "$PD\GOG.com\Galaxy\webcache"; M = 'Contenido'; Menor = $true; E = 'Se regenera.' }
        @{ N = 'Registros de GOG Galaxy';     R = "$PD\GOG.com\Galaxy\logs";     M = 'Contenido'; Menor = $true; E = 'Sin efecto.' }

        # --- EA / Origin --------------------------------------------------
        @{ N = 'Registros de EA Desktop';     R = "$LA\Electronic Arts\EA Desktop\Logs";  M = 'Contenido'; Menor = $true; E = 'Sin efecto.' }
        @{ N = 'Caché de EA Desktop';         R = "$LA\Electronic Arts\EA Desktop\cache"; M = 'Contenido'; Menor = $true; E = 'Se regenera.' }
        @{ N = 'Registros de Origin';         R = "$PD\Origin\Logs";                      M = 'Contenido'; Menor = $true; E = 'Sin efecto.' }

        # --- Ubisoft Connect ----------------------------------------------
        # La carpeta hermana "savegames" contiene partidas guardadas: queda
        # fuera de la lista a propósito.
        @{ N = 'Caché de Ubisoft Connect';    R = "$LA\Ubisoft Game Launcher\cache";  M = 'Contenido'; Menor = $true; E = 'Se regenera. No toca tus partidas guardadas.' }
        @{ N = 'Registros de Ubisoft Connect';R = "$LA\Ubisoft Game Launcher\logs";   M = 'Contenido'; Menor = $true; E = 'Sin efecto.' }

        # --- Riot Games -----------------------------------------------------
        @{ N = 'Registros de Riot Client';    R = "$LA\Riot Games\Riot Client\Logs";  M = 'Contenido'; Menor = $true; E = 'Sin efecto.' }
        @{ N = 'Datos de Riot Client';        R = "$LA\Riot Games\Riot Client\Data";  M = 'Contenido'; Menor = $true; E = 'Se regenera al abrir el cliente.' }
    )

    # Sin ninguna zona no se llama: -Raices es obligatorio y un array vacío
    # no supera el enlace de parámetros, así que el módulo lanzaría en vez
    # de devolver cero candidatos.
    $raicesPlataformas = @(@($LA, $RA, $PD) | Where-Object { $_ })

    if ($raicesPlataformas.Count -gt 0) {
        Invoke-BusquedaPorLista -ModuloId 'juegos' -Categoria 'Plataformas de juego' `
                                -Entradas $plataformas -Raices $raicesPlataformas -Sync $Sync `
                                -MinimoBytes 1MB -ForzarPermanente `
                                -IncluirMenores:$Configuracion.IncluirMenores
    }

    # ==================================================================
    # 2. Steam: biblioteca por biblioteca
    # ==================================================================
    foreach ($steamapps in (Get-BibliotecasSteam)) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Revisando la biblioteca de Steam en $(Get-RutaCorta $steamapps)..."

        $raices = @($steamapps)

        # --- 2a. Basura regenerable de la biblioteca --------------------
        $basura = @(
            @{ N = 'Descargas de Steam a medias'; R = (Join-RutaNativa $steamapps 'downloading');        M = 'Contenido'; Menor = $false; E = 'Descargas interrumpidas. Steam las vuelve a bajar si hacen falta.' }
            @{ N = 'Temporales de Steam';         R = (Join-RutaNativa $steamapps 'temp');               M = 'Contenido'; Menor = $true;  E = 'Sin efecto.' }
            @{ N = 'Descargas del taller';        R = (Join-RutaNativa $steamapps 'workshop' 'downloads'); M = 'Contenido'; Menor = $true;  E = 'Descargas de mods a medias. Se vuelven a bajar.' }
        )
        Invoke-BusquedaPorLista -ModuloId 'juegos' -Categoria 'Steam' `
                                -Entradas $basura -Raices $raices -Sync $Sync `
                                -MinimoBytes 1MB -ForzarPermanente `
                                -IncluirMenores:$Configuracion.IncluirMenores

        # --- 2b. Juegos que Steam conoce -------------------------------
        # Hay un appmanifest_<appid>.acf por juego instalado; su "installdir"
        # es la carpeta dentro de common. Una carpeta de common sin
        # manifiesto es una instalación que Steam ya no ve.
        $instalados = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        $appids = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)

        foreach ($acf in @(Get-ChildItem -LiteralPath $steamapps -Filter 'appmanifest_*.acf' `
                                         -File -Force -ErrorAction SilentlyContinue)) {
            foreach ($dir in (Get-ValorVdf -Ruta $acf.FullName -Clave 'installdir')) {
                [void]$instalados.Add($dir)
            }
            if ($acf.Name -match 'appmanifest_(\d+)\.acf') { [void]$appids.Add($Matches[1]) }
        }

        # Sin ningún manifiesto no se puede afirmar nada (Steam puede no
        # haber terminado de escribir, o no ser una biblioteca real); se
        # evita declarar huérfana la biblioteca entera.
        if ($instalados.Count -eq 0) { continue }

        $common = Join-RutaNativa $steamapps 'common'
        if (Test-Path -LiteralPath $common) {
            foreach ($juego in @(Get-ChildItem -LiteralPath $common -Directory -Force -ErrorAction SilentlyContinue)) {
                if (Test-Cancelacion $Sync) { break }
                if ($instalados.Contains($juego.Name))  { continue }
                if (Test-EsEnlace $juego)               { continue }
                if (-not (Test-RutaSegura $juego.FullName $raices)) { continue }

                Set-Progreso $Sync "Midiendo: $($juego.Name)"
                $resumen = Get-ResumenArbol -Carpeta $juego
                if ($resumen.Bytes -lt ($Configuracion.MinimoMB * 1MB)) { continue }

                New-Candidato -ModuloId 'juegos' -Categoria 'Juegos que Steam ya no reconoce' `
                              -Nombre $juego.Name -Ruta $juego.FullName -Bytes $resumen.Bytes `
                              -Info "$($resumen.Archivos) archivos en la biblioteca $(Get-RutaElidida $steamapps 45)" `
                              -Efecto 'Steam no tiene manifiesto de este juego: no aparece en tu biblioteca, no se actualiza y no se puede jugar sin volver a instalarlo.' `
                              -Aviso 'Comprueba que no es un juego que instalaste a mano o copiaste de otro equipo.' `
                              -Metodo 'Ruta' -Raices $raices -Riesgo 'Medio'
            }
        }

        # --- 2c. Sombreadores y taller de juegos desinstalados ----------
        foreach ($par in @(
            @{ Carpeta = (Join-RutaNativa $steamapps 'shadercache')
               Categoria = 'Steam'
               Riesgo = 'Bajo'
               Aviso = ''
               Efecto = 'Sombreadores precompilados de un juego que ya no está instalado. Se regeneran solos si lo reinstalas.' }
            @{ Carpeta = (Join-RutaNativa $steamapps 'workshop' 'content')
               Categoria = 'Steam'
               Riesgo = 'Medio'
               Aviso = 'Son mods descargados del taller de un juego que ya no está instalado.'
               Efecto = 'Contenido del taller de un juego desinstalado. Se vuelve a descargar si reinstalas el juego.' })) {

            if (-not (Test-Path -LiteralPath $par.Carpeta)) { continue }

            foreach ($carpeta in @(Get-ChildItem -LiteralPath $par.Carpeta -Directory -Force -ErrorAction SilentlyContinue)) {
                if (Test-Cancelacion $Sync) { break }
                # Solo carpetas cuyo nombre es un identificador de aplicación.
                if ($carpeta.Name -notmatch '^\d+$')     { continue }
                if ($appids.Contains($carpeta.Name))     { continue }
                if (Test-EsEnlace $carpeta)              { continue }
                if (-not (Test-RutaSegura $carpeta.FullName $raices)) { continue }

                $resumen = Get-ResumenArbol -Carpeta $carpeta
                if ($resumen.Bytes -lt ($Configuracion.MinimoMB * 1MB)) { continue }

                New-Candidato -ModuloId 'juegos' -Categoria $par.Categoria `
                              -Nombre "$(Split-Path $par.Carpeta -Leaf) del juego $($carpeta.Name)" `
                              -Ruta $carpeta.FullName -Bytes $resumen.Bytes `
                              -Info "$($resumen.Archivos) archivos - ningún juego instalado usa el identificador $($carpeta.Name)" `
                              -Efecto $par.Efecto -Aviso $par.Aviso `
                              -Metodo 'Ruta' -Raices $raices -Riesgo $par.Riesgo
            }
        }
    }

    # ==================================================================
    # 3. Partidas guardadas: solo informativo, y su basura interna
    # ==================================================================
    # La carpeta del juego es la partida: solo se informa de lo que ocupa.
    # Sí se proponen sus subcarpetas de registros y volcados, que el motor
    # recrea. Join-RutaNativa y no Join-Path, que resuelve la unidad a
    # través del proveedor de PowerShell (ver FileSystem.ps1).
    $zonasPartidas = @()
    $documentos = Get-CarpetaConocida -Nombre 'Documents'
    if ($documentos) { $zonasPartidas += (Join-RutaNativa $documentos 'My Games') }
    if ($UP)         { $zonasPartidas += (Join-RutaNativa $UP 'Saved Games') }

    $basuraDeJuego = @('Logs', 'Crashes', 'DerivedDataCache', 'ShaderCache', 'CrashReportClient')

    foreach ($zona in ($zonasPartidas | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Revisando $(Get-RutaCorta $zona)..."

        foreach ($juego in @(Get-ChildItem -LiteralPath $zona -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Cancelacion $Sync) { break }
            if (Test-EsEnlace $juego) { continue }

            $resumen = Get-ResumenArbol -Carpeta $juego
            if ($resumen.Bytes -ge ($Configuracion.MinimoMB * 1MB)) {
                New-Candidato -ModuloId 'juegos' -Categoria 'Partidas guardadas' `
                              -Nombre $juego.Name -Ruta $juego.FullName -Bytes $resumen.Bytes `
                              -Info "$($resumen.Archivos) archivos en $(Get-RutaElidida $zona 45)" `
                              -Efecto 'Aquí viven tus partidas guardadas y la configuración del juego. El programa no propone borrarlo: solo te dice lo que ocupa.' `
                              -Metodo 'Informativo' -Riesgo 'Bajo'
            }

            # Dentro sí: registros y cachés que el motor recrea.
            foreach ($nombre in $basuraDeJuego) {
                foreach ($encontrada in @(Get-ChildItem -LiteralPath $juego.FullName -Directory -Force `
                                                        -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                                          Where-Object { $_.Name -eq $nombre })) {
                    if (Test-EsEnlace $encontrada) { continue }
                    if (-not (Test-RutaSegura $encontrada.FullName @($zona))) { continue }

                    $bytes = Measure-Ruta $encontrada.FullName
                    if ($bytes -lt 1MB) { continue }

                    New-Candidato -ModuloId 'juegos' -Categoria 'Registros y caché de juegos' `
                                  -Nombre "$($juego.Name) - $($encontrada.Name)" `
                                  -Ruta $encontrada.FullName -Bytes $bytes `
                                  -Info 'se vacía el contenido, la carpeta se queda' `
                                  -Efecto 'Registros y datos temporales del motor del juego. Se regeneran solos y no afectan a tus partidas.' `
                                  -Metodo 'Contenido' -Raices @($zona) -Riesgo 'Bajo' -ForzarPermanente
                }
            }
        }
    }
}

New-ModuloLimpieza -Id 'juegos' -Orden 33 `
    -Nombre 'Juegos y plataformas de juego' `
    -Descripcion 'Cachés de Steam, Epic, Battle.net, GOG, EA, Ubisoft y Riot, juegos que Steam ya no reconoce y sombreadores de juegos desinstalados. Nunca toca partidas guardadas.' `
    -Riesgo 'Medio' `
    -Perfiles @('conservador', 'equilibrado', 'agresivo') `
    -Buscar $BuscarJuegos
