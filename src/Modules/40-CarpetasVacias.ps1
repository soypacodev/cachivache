<#
.SYNOPSIS
    Carpetas sin un solo archivo dentro, en todo su subárbol.
.DESCRIPTION
    No liberan espacio: ordenan. Se excluyen las carpetas espejo del sistema
    (Mis imágenes, Favoritos, Vínculos...), que parecen vacías pero son
    enlaces heredados, y se saltan los junctions.

    Una cadena de carpetas vacías anidadas (a\b\c) se propone una sola vez,
    por su carpeta más alta.
#>

$BuscarCarpetasVacias = {
    param($Configuracion, $Sync)

    $zonas = @($Configuracion.ZonasUsuario)
    if ($zonas.Count -eq 0) { return }

    foreach ($zona in $zonas) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Revisando $(Get-RutaCorta $zona)..."

        # Recorrido con poda. Las carpetas excluidas (enlaces, node_modules,
        # .git, carpetas espejo) no son candidatas, no se recorren y cuentan
        # como contenido para su padre: una carpeta con solo un .git no está
        # vacía.
        $excluidas = @('node_modules', '.git', '.svn', '.hg')
        $candidatas = [Collections.Generic.List[IO.DirectoryInfo]]::new()
        $porVisitar = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $porVisitar.Push((Get-Item -LiteralPath $zona -Force -ErrorAction SilentlyContinue))

        while ($porVisitar.Count -gt 0) {
            if (Test-Cancelacion $Sync) { break }
            $actual = $porVisitar.Pop()
            if ($null -eq $actual) { continue }

            try   { $hijas = @($actual.EnumerateDirectories()) }
            catch { continue }

            foreach ($hija in $hijas) {
                if ($hija.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($excluidas -contains $hija.Name) { continue }
                if (Test-CarpetaEspejo $hija.Name)   { continue }
                $candidatas.Add($hija)
                $porVisitar.Push($hija)
            }
        }
        if ($candidatas.Count -eq 0) { continue }

        # --- Paso 1: de abajo arriba, quién tiene el subárbol limpio ------
        # De más profunda a menos: al evaluar una carpeta ya se conoce el
        # veredicto de sus hijas, y cada una se mira un solo nivel (coste
        # lineal).
        $limpia = @{}
        $porProfundidad = @($candidatas | Sort-Object -Property @{
            Expression = { ($_.FullName -split '[\\/]').Count }
        } -Descending)

        foreach ($dir in $porProfundidad) {
            if (Test-Cancelacion $Sync) { break }
            # EnumerateFileSystemInfos y no Get-ChildItem: permite parar en
            # el primer archivo sin construir antes todos los objetos.
            $estaLimpia = $true
            $hijos = @()
            try   { $hijos = $dir.EnumerateFileSystemInfos() }
            catch { $hijos = @() }

            foreach ($hijo in $hijos) {
                if ($hijo -isnot [IO.DirectoryInfo]) { $estaLimpia = $false; break }
                # Una subcarpeta desconocida (excluida, enlace o ilegible)
                # cuenta como contenido.
                if (-not $limpia.ContainsKey($hijo.FullName) -or -not $limpia[$hijo.FullName]) {
                    $estaLimpia = $false; break
                }
            }
            $limpia[$dir.FullName] = $estaLimpia
        }
        if (Test-Cancelacion $Sync) { break }

        # --- Paso 2: emitir solo la cima de cada cadena -------------------
        foreach ($dir in $candidatas) {
            if (Test-Cancelacion $Sync) { break }
            if (-not $limpia[$dir.FullName]) { continue }

            # Si el padre también está limpio, se propondrá él.
            $padre = Split-Path $dir.FullName -Parent
            if ($limpia.ContainsKey($padre) -and $limpia[$padre]) { continue }

            if (-not (Test-RutaSegura $dir.FullName $zonas)) { continue }

            $niveles = @($candidatas | Where-Object {
                $_.FullName.StartsWith($dir.FullName + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            }).Count
            $info = if ($niveles -gt 0) {
                "creada $($dir.CreationTime.ToString('yyyy-MM-dd')) - contiene $niveles subcarpetas, todas vacías"
            } else {
                "creada $($dir.CreationTime.ToString('yyyy-MM-dd'))"
            }

            # Solo se premarca dentro de AppData/ProgramData, o fuera si es
            # antigua: una carpeta vacía reciente en Documentos o el
            # Escritorio suele ser una que el usuario acaba de crear para
            # ordenar.
            $enAppData = $false
            foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData)) {
                if ([string]::IsNullOrWhiteSpace($base)) { continue }
                if ($dir.FullName.StartsWith($base.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar,
                                             [StringComparison]::OrdinalIgnoreCase)) {
                    $enAppData = $true
                    break
                }
            }

            $diasDesdeCreacion = [int]((Get-Date) - $dir.CreationTime).TotalDays
            $marcar = $enAppData -or ($diasDesdeCreacion -ge $Configuracion.DiasSinUso)

            $aviso = if (-not $marcar) {
                'Creada hace poco y fuera de AppData: puede ser una carpeta que hayas hecho tú para ordenar.'
            } else { '' }

            New-Candidato -ModuloId 'vacias' -Categoria 'Carpetas vacías' `
                          -Nombre (Get-RutaCorta $dir.FullName) -Ruta $dir.FullName -Bytes 0 `
                          -Info $info `
                          -Efecto 'Ni un solo archivo en toda la carpeta. No libera espacio: ordena.' `
                          -Aviso $aviso `
                          -Metodo 'CarpetaVacia' -Raices $zonas -Riesgo 'Bajo' -Preseleccionado $marcar
        }
    }
}

New-ModuloLimpieza -Id 'vacias' -Orden 40 `
    -Nombre 'Carpetas vacías' `
    -Descripcion 'Carpetas sin un solo archivo dentro. Ordenan, no liberan espacio.' `
    -Riesgo 'Bajo' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarCarpetasVacias
