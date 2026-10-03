<#
.SYNOPSIS
    Restos de programas que ya no están instalados.
.DESCRIPTION
    Recorre AppData -Local, Roaming y LocalLow- y ProgramData buscando
    carpetas que no correspondan a nada instalado, en ejecución, registrado
    como servicio ni presente en el menú Inicio. Es el módulo con más
    posibilidad de falso positivo, así que nada viene marcado por defecto y
    se inspecciona el interior en busca de partidas guardadas, perfiles y
    documentos.

    Se revisan dos niveles: muchos restos están en "<Editor>\<Producto>",
    donde el editor sigue instalado por otro producto. LocalLow se incluye
    porque es donde guardan sus datos los juegos hechos con Unity.
#>

$BuscarRestosProgramas = {
    param($Configuracion, $Sync)

    $vocabulario = Get-TokensProgramasInstalados -Sync $Sync

    # Carpetas del sistema que nunca corresponden a un programa instalado
    # pero tampoco son basura. De estas no se desciende al segundo nivel.
    $protegidas = @(
        'microsoft', 'windows', 'windowsapps', 'packages', 'packagecache', 'programs',
        'temp', 'tempstate', 'crashdumps', 'connecteddevicesplatform', 'comms',
        'publishers', 'virtualstore', 'iconcache', 'history', 'inetcache',
        'applicationdata', 'locallow', 'lowlevel', 'elevateddiagnostics',
        'nvidia', 'nvidiacorporation', 'intel', 'amd', 'realtek', 'oracle', 'java',
        'javasoft', 'dotnet', 'powershell', 'windowspowershell', 'ssh', 'nvm', 'npm',
        'nodejs', 'd3dscache', 'placeholdertiles', 'placeholdertilelogofolder',
        'usoshared', 'usoprivate', 'systemdata', 'wer', 'diagnosis', 'installer',
        'driverstore', 'drivers', 'searchcache', 'clipsvc', 'deviceassociationservice',
        'notifications', 'fonts', 'startmenu', 'menuinicio', 'desktop', 'escritorio',
        'plantillas', 'templates', 'recent', 'sendto', 'printhood', 'nethood',
        'cookies', 'libraries', 'bibliotecas', 'identities', 'identitycrl',
        'credentials', 'protect', 'crypto', 'vault', 'systemcertificates',
        'commonfiles', 'internetexplorer', 'modifiablewindowsapps'
    )

    # LocalLow no tiene variable de entorno propia: se deriva del perfil.
    $localLow = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\LocalLow' } else { $null }

    $zonas = @($env:LOCALAPPDATA, $env:APPDATA, $localLow, $env:ProgramData) |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    # Nombres de subcarpeta que casi siempre contienen algo que el usuario
    # querría conservar.
    $patronValioso = '^(saves?|savegames?|worlds?|profiles?|perfiles|projects?|proyectos|backups?|documents?|screenshots?|capturas|exports?|mods?|characters?|partidas)$'
    $extensionesValiosas = '^\.(docx?|xlsx?|pptx?|pdf|jpe?g|png|psd|ai|mp4|mov|sav|save|world|blend|kdbx)$'

    # Decide si una carpeta es un resto y, si lo es, la propone. Sirve para
    # los dos niveles.
    $evaluarCarpeta = {
        param($Carpeta, $Nivel, $NombreEditor)

        if (Test-EsEnlace $Carpeta)                                { return }
        if ($protegidas -contains (ConvertTo-Token $Carpeta.Name))  { return }
        if (Test-NombreSensible $Carpeta.Name)                      { return }
        if (Test-RutaIntocable $Carpeta.FullName)                   { return }

        # La guardia antes que la medición: es mucho más barata.
        if (-not (Test-RutaSegura $Carpeta.FullName $zonas))        { return }

        # En el segundo nivel se prueba también "<Editor> <Carpeta>": los
        # productos suelen figurar como instalados con el editor delante
        # ("Adobe Acrobat", no "Acrobat").
        if (Test-TokenConocido -Nombre $Carpeta.Name -Vocabulario $vocabulario) { return }
        if ($Nivel -eq 2 -and
            (Test-TokenConocido -Nombre "$NombreEditor $($Carpeta.Name)" -Vocabulario $vocabulario)) { return }

        Set-Progreso $Sync "Midiendo: $($Carpeta.Name)"

        # Una sola pasada de disco: tamaño, fecha, subcarpetas valiosas y
        # documentos personales salen del mismo recorrido.
        $resumen = Get-ResumenArbol -Carpeta $Carpeta `
                                    -PatronCarpetaValiosa $patronValioso `
                                    -PatronExtensionValiosa $extensionesValiosas

        if ($resumen.Bytes -lt ($Configuracion.MinimoMB * 1MB)) { return }

        $ultimo = if ($null -ne $resumen.Ultimo) { $resumen.Ultimo } else { $Carpeta.LastWriteTime }
        $dias = [int]((Get-Date) - $ultimo).TotalDays
        if ($dias -lt $Configuracion.DiasSinUso) { return }

        $avisos = @()
        foreach ($nombre in ($resumen.CarpetasValiosas | Select-Object -Unique)) {
            $avisos += "contiene una carpeta '$nombre'"
        }
        if ($resumen.ArchivosValiosos -gt 0) {
            $avisos += "$($resumen.ArchivosValiosos) archivos que parecen personales"
        }

        # Aquí más antiguo es más seguro: una carpeta sin tocar desde hace
        # más de un año es la que menos falta hace.
        $riesgo = if ($avisos.Count -gt 0) { 'Alto' }
                  elseif ($Nivel -eq 2)    { 'Medio' }
                  elseif ($dias -gt 365)   { 'Bajo' }
                  else                     { 'Medio' }

        $efecto = if ($Nivel -eq 2) {
            "Está dentro de '$NombreEditor', que sí sigue instalado, pero no coincide con ningún producto suyo que esté en el equipo."
        } else {
            'No coincide con ningún programa instalado, proceso, servicio ni acceso directo del menú Inicio.'
        }

        New-Candidato -ModuloId 'restos' -Categoria 'Restos de programas' `
                      -Nombre $Carpeta.Name -Ruta $Carpeta.FullName -Bytes $resumen.Bytes `
                      -Info "$($resumen.Archivos) archivos - sin tocar desde $($ultimo.ToString('yyyy-MM-dd')) ($(Format-Antiguedad $ultimo))" `
                      -Efecto $efecto `
                      -Aviso ($avisos -join '; ') -Metodo 'Ruta' -Raices $zonas `
                      -Riesgo $riesgo -Preseleccionado $false
    }

    foreach ($zona in $zonas) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Revisando $(Get-RutaCorta $zona)..."

        foreach ($carpeta in @(Get-ChildItem -LiteralPath $zona -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Cancelacion $Sync) { break }

            # Una carpeta reconocida no es un resto, pero puede contenerlos
            # (un editor con varios productos). Se baja un único nivel: bajar
            # más convertiría en candidatos los datos de aplicaciones vivas.
            $esProtegida = $protegidas -contains (ConvertTo-Token $carpeta.Name)
            $esConocida  = Test-TokenConocido -Nombre $carpeta.Name -Vocabulario $vocabulario

            if ($esConocida -and -not $esProtegida -and -not (Test-EsEnlace $carpeta)) {
                foreach ($hija in @(Get-ChildItem -LiteralPath $carpeta.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    if (Test-Cancelacion $Sync) { break }
                    & $evaluarCarpeta $hija 2 $carpeta.Name
                }
                continue
            }

            & $evaluarCarpeta $carpeta 1 ''
        }
    }
}

New-ModuloLimpieza -Id 'restos' -Orden 30 `
    -Nombre 'Restos de programas desinstalados' `
    -Descripcion 'Carpetas de AppData, LocalLow y ProgramData que no corresponden a ningún programa instalado. Detección automática: revisa la lista antes de borrar.' `
    -Riesgo 'Alto' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarRestosProgramas
