<#
.SYNOPSIS
    Restos que deja la desinstalación fuera de AppData: entradas fantasma
    del registro, carpetas huérfanas de Archivos de programa, versiones
    viejas de aplicaciones Electron e instaladores de controladores.
.DESCRIPTION
    Complementa a 30-RestosProgramas (AppData y ProgramData) con el resto de
    sitios donde una desinstalación deja cosas atrás.

    Este módulo no escribe en el registro: las entradas fantasma solo se
    señalan como informativas. Lo que se propone borrar son carpetas.

    Fuentes, de más segura a menos:
      - Versiones viejas de Electron/Squirrel ("app-<versión>"): sobra la
        vieja cuando hay otra más nueva al lado. 150-400 MB por versión.
      - Instaladores de controladores (NVIDIA, AMD, Intel) descomprimidos
        en disco. Unos 800 MB por versión.
      - Huérfanos de Archivos de programa: sin entrada de desinstalación,
        servicio ni acceso del menú Inicio. Riesgo alto, nunca marcados.
#>

$BuscarRestosRegistro = {
    param($Configuracion, $Sync)

    $LA = $env:LOCALAPPDATA
    $RA = $env:APPDATA

    # ==================================================================
    # 1. Versiones antiguas de aplicaciones Electron / Squirrel
    # ==================================================================
    # Al actualizarse, la aplicación crea "app-1.0.9043" junto a
    # "app-1.0.9042" sin borrar la anterior. Se conserva siempre la versión
    # más alta y se proponen las demás.
    Set-Progreso $Sync 'Buscando versiones antiguas de aplicaciones...'

    $contenedores = @()
    foreach ($base in @($LA, $RA)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $contenedores += @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)
    }

    foreach ($contenedor in $contenedores) {
        if (Test-Cancelacion $Sync) { break }
        if (Test-EsEnlace $contenedor) { continue }

        $versiones = @(Get-ChildItem -LiteralPath $contenedor.FullName -Directory -Force -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match '^app-(\d+(\.\d+)*)$' })

        # Con una sola versión no sobra ninguna: es la que está en uso.
        if ($versiones.Count -lt 2) { continue }

        # Orden por [version], no por texto: como cadenas, "app-1.0.10"
        # quedaría antes que "app-1.0.9" y se propondría borrar la que está
        # en uso.
        $ordenadas = @($versiones | Sort-Object -Property @{ Expression = {
            $numero = $_.Name.Substring(4)
            try { [version]$numero } catch { [version]'0.0' }
        } })

        $masNueva = $ordenadas[-1]
        foreach ($vieja in $ordenadas[0..($ordenadas.Count - 2)]) {
            if (Test-Cancelacion $Sync) { break }
            if (Test-EsEnlace $vieja) { continue }
            if (-not (Test-RutaSegura $vieja.FullName @($contenedor.FullName))) { continue }

            $bytes = Measure-Ruta $vieja.FullName
            if ($bytes -lt ($Configuracion.MinimoMB * 1MB)) { continue }

            New-Candidato -ModuloId 'restosregistro' -Categoria 'Versiones antiguas de aplicaciones' `
                          -Nombre "$($contenedor.Name) - $($vieja.Name)" `
                          -Ruta $vieja.FullName -Bytes $bytes `
                          -Info "la versión en uso es $($masNueva.Name)" `
                          -Efecto "Versión anterior de $($contenedor.Name). La aplicación usa $($masNueva.Name) y no vuelve a esta." `
                          -Metodo 'Ruta' -Raices @($contenedor.FullName) -Riesgo 'Bajo'
        }
    }

    # ==================================================================
    # 2. Instaladores de controladores ya aplicados
    # ==================================================================
    # Carpetas donde el instalador se descomprime; el controlador ya está
    # instalado. El DriverStore de Windows (el controlador en sí) sigue
    # vetado por la guardia.
    $unidad = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }

    $instaladores = @(
        @{ N = 'Instaladores de NVIDIA';      R = (Join-RutaNativa $unidad 'NVIDIA'); E = 'Carpeta donde el instalador de NVIDIA se descomprime. El controlador ya está instalado: esto es el paquete.' }
        @{ N = 'Instaladores de AMD';         R = (Join-RutaNativa $unidad 'AMD');    E = 'Carpeta donde el instalador de AMD se descomprime. El controlador ya está instalado.' }
        @{ N = 'Instaladores de Intel';       R = (Join-RutaNativa $unidad 'Intel');  E = 'Carpeta donde el instalador de Intel se descomprime. El controlador ya está instalado.' }
        @{ N = 'Instaladores del fabricante'; R = (Join-RutaNativa $unidad 'SWSetup'); E = 'Instaladores que deja el fabricante del equipo. Se pueden volver a descargar de su web.' }
        @{ N = 'Descargas de NVIDIA';         R = (Join-RutaNativa $env:ProgramData 'NVIDIA Corporation' 'Downloader'); E = 'Paquetes descargados por GeForce Experience. Se vuelven a bajar.' }
    )

    foreach ($entrada in $instaladores) {
        if (Test-Cancelacion $Sync) { break }
        if ([string]::IsNullOrWhiteSpace($entrada.R)) { continue }
        if (-not (Test-Path -LiteralPath $entrada.R)) { continue }

        # La raíz autorizada es la propia carpeta: se vacía por dentro y el
        # contenedor se conserva.
        if (-not (Test-RutaSegura $entrada.R @($entrada.R))) { continue }

        Set-Progreso $Sync "Midiendo: $($entrada.N)"
        $bytes = Measure-Ruta $entrada.R
        if ($bytes -lt 50MB) { continue }

        New-Candidato -ModuloId 'restosregistro' -Categoria 'Instaladores de controladores' `
                      -Nombre $entrada.N -Ruta $entrada.R -Bytes $bytes `
                      -Info 'se vacía el contenido, la carpeta se queda' `
                      -Efecto $entrada.E `
                      -Metodo 'Contenido' -Raices @($entrada.R) -Riesgo 'Bajo'
    }

    # ==================================================================
    # 3. Entradas de desinstalación que apuntan a la nada
    # ==================================================================
    # Solo informativo. Estas entradas también alimentan el vocabulario de
    # programas instalados, así que hacen que restos de programas ya
    # desinstalados se den por reconocidos y no se propongan.
    Set-Progreso $Sync 'Revisando entradas de desinstalación...'

    $claves = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $fantasmas = [Collections.Generic.List[string]]::new()
    foreach ($clave in $claves) {
        if (Test-Cancelacion $Sync) { break }
        foreach ($entrada in @(Get-ItemProperty -Path $clave -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($entrada.DisplayName)) { continue }
            # Sin InstallLocation no se puede afirmar nada: muchos
            # programas legítimos no la declaran.
            if ([string]::IsNullOrWhiteSpace($entrada.InstallLocation)) { continue }

            $ruta = [Environment]::ExpandEnvironmentVariables($entrada.InstallLocation).Trim('"', ' ')
            if ([string]::IsNullOrWhiteSpace($ruta)) { continue }
            if (Test-Path -LiteralPath $ruta) { continue }

            # Una unidad no montada puede ser un disco externo: no prueba
            # que el programa no exista.
            $letra = Get-LetraUnidad $ruta
            if ($letra -and -not (Test-Path -LiteralPath ($letra + '\'))) { continue }

            $fantasmas.Add("$($entrada.DisplayName) -> $ruta")
        }
    }

    if ($fantasmas.Count -gt 0) {
        New-Candidato -ModuloId 'restosregistro' -Categoria 'Entradas de desinstalación fantasma' `
                      -Nombre "$($fantasmas.Count) entradas apuntan a carpetas que ya no existen" `
                      -Ruta 'Registro de Windows' -Bytes 0 `
                      -Info (($fantasmas | Select-Object -First 8) -join '; ') `
                      -Efecto ('Aparecen en "Aplicaciones instaladas" pero su carpeta ya no está. ' +
                               'Este programa NUNCA escribe en el registro: solo te avisa. ' +
                               'Además hacen que Cachivache de por instalados programas que ya no lo están.') `
                      -Metodo 'Informativo' -Riesgo 'Bajo'
    }

    # ==================================================================
    # 4. Carpetas de Archivos de programa sin nada que las respalde
    # ==================================================================
    # Lo más incierto del módulo: los programas portables no dejan entrada
    # de desinstalación. Por eso va con riesgo Alto, aviso y sin marcar.
    $vocabulario = Get-TokensProgramasInstalados -Sync $Sync

    $protegidas = @(
        'windowsapps', 'commonfiles', 'archivoscomunes', 'modifiablewindowsapps',
        'windowsdefender', 'windowsnt', 'windowsmediaplayer', 'windowsphotoviewer',
        'windowsportabledevices', 'windowssidebar', 'internetexplorer', 'microsoft',
        'microsoftoffice', 'microsoftsdks', 'microsoftvisualstudio', 'dotnet',
        'msbuild', 'referenceassemblies', 'uninstallinformation', 'desktop',
        'nvidiacorporation', 'amd', 'intel', 'realtek', 'applicationverifier'
    )

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        if (-not (Test-Path -LiteralPath $base)) { continue }
        if (Test-Cancelacion $Sync) { break }

        Set-Progreso $Sync "Revisando $(Get-RutaCorta $base)..."

        foreach ($carpeta in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Cancelacion $Sync) { break }

            if (Test-EsEnlace $carpeta)                                { continue }
            if ($protegidas -contains (ConvertTo-Token $carpeta.Name))  { continue }
            if (Test-NombreSensible $carpeta.Name)                      { continue }
            if (Test-RutaIntocable $carpeta.FullName)                   { continue }
            if (-not (Test-RutaSegura $carpeta.FullName @($base)))      { continue }
            if (Test-TokenConocido -Nombre $carpeta.Name -Vocabulario $vocabulario) { continue }

            Set-Progreso $Sync "Midiendo: $($carpeta.Name)"
            $resumen = Get-ResumenArbol -Carpeta $carpeta
            if ($resumen.Bytes -lt ($Configuracion.MinimoMB * 1MB)) { continue }
            if ($resumen.Archivos -eq 0) { continue }

            New-Candidato -ModuloId 'restosregistro' -Categoria 'Huérfanos de Archivos de programa' `
                          -Nombre $carpeta.Name -Ruta $carpeta.FullName -Bytes $resumen.Bytes `
                          -Info "$($resumen.Archivos) archivos en $(Get-RutaElidida $base 40)" `
                          -Efecto 'No hay entrada de desinstalación, ni servicio, ni acceso del menú Inicio que corresponda a esta carpeta.' `
                          -Aviso 'Un programa portable copiado a mano tampoco deja entrada de desinstalación: comprueba que no lo usas.' `
                          -Metodo 'Ruta' -Raices @($base) -Riesgo 'Alto' -Preseleccionado $false
        }
    }
}

New-ModuloLimpieza -Id 'restosregistro' -Orden 32 `
    -Nombre 'Restos fuera de AppData' `
    -Descripcion 'Versiones antiguas de aplicaciones, instaladores de controladores ya aplicados, entradas de desinstalación que apuntan a la nada y carpetas huérfanas de Archivos de programa.' `
    -Riesgo 'Medio' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarRestosRegistro
