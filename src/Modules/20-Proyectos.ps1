<#
.SYNOPSIS
    Carpetas regenerables dentro de proyectos de programación.
.DESCRIPTION
    node_modules, dist, build, target, __pycache__ y compañía: todo lo que
    vuelve solo con un comando. Nunca se toca código fuente ni la carpeta
    .git, y las carpetas ambiguas (out, build, dist) solo se proponen si
    junto a ellas hay un manifiesto de proyecto que lo justifique.
#>

$BuscarProyectos = {
    param($Configuracion, $Sync)

    $raices = @($Configuracion.RaicesProyecto | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($raices.Count -eq 0) { return }

    # Carpetas cuyo nombre ya es prueba suficiente.
    $patronInequivoco = '^(node_modules|\.next|\.nuxt|\.svelte-kit|\.turbo|\.parcel-cache|__pycache__|\.pytest_cache|\.mypy_cache|\.tox|\.gradle|Pods)$'
    # Carpetas ambiguas: solo se proponen con un manifiesto de proyecto al
    # lado. "vendor" y "target" van aquí a propósito: en Go, vendor/ se
    # versiona y permite compilar sin red, y "target" es un nombre corriente
    # fuera de Rust y Maven.
    $patronAmbiguo    = '^(dist|build|out|obj|bin|\.venv|venv|target|vendor)$'

    $manifiestos = @('package.json', 'pom.xml', 'build.gradle', 'build.gradle.kts',
                     'CMakeLists.txt', 'Cargo.toml', 'go.mod', 'pyproject.toml',
                     'requirements.txt', 'composer.json', 'Gemfile')

    $efectos = @{
        'node_modules'  = 'Vuelve con: npm install'
        '.next'         = 'Vuelve con: npm run build'
        '.nuxt'         = 'Vuelve con: npm run build'
        'target'        = 'Vuelve con: mvn package o gradle build'
        '__pycache__'   = 'Vuelve solo al ejecutar Python'
        '.venv'         = 'Vuelve con: python -m venv .venv && pip install -r requirements.txt'
        'venv'          = 'Vuelve con: python -m venv venv && pip install -r requirements.txt'
        'vendor'        = 'Vuelve con: composer install'
        '.gradle'       = 'Vuelve con el siguiente build'
    }

    foreach ($raiz in $raices) {
        if (Test-Cancelacion $Sync) { break }
        Set-Progreso $Sync "Buscando proyectos en $(Get-RutaCorta $raiz)..."

        # Recorrido con poda: al encontrar una carpeta regenerable se emite y
        # no se desciende. Así no se enumeran los miles de subdirectorios de
        # cada node_modules, y los dist/build de sus paquetes (que traen su
        # propio package.json) no se proponen además del padre, lo que
        # contaría los mismos bytes dos veces.
        #
        # La misma regla decide qué se emite y dónde no se entra; si se
        # separaran, volvería el doble conteo.
        $esRegenerable = {
            param($Carpeta)
            if ($Carpeta.Name -match $patronInequivoco) { return $true }
            if ($Carpeta.Name -match $patronAmbiguo)    { return $true }
            # El único caso que depende del padre: .angular\cache.
            return ($Carpeta.Name -eq 'cache' -and
                    [IO.Path]::GetFileName($Carpeta.DirectoryName) -eq '.angular')
        }

        $noDescender = {
            param($Carpeta)
            # El control de versiones no se recorre; $esRegenerable lo
            # descarta después.
            if ($Carpeta.Name -eq '.git' -or $Carpeta.Name -eq '.svn') { return $true }
            return (& $esRegenerable $Carpeta)
        }

        $encontradas = [Collections.Generic.List[object]]::new()
        Get-ElementosDelArbol -Ruta $raiz -Que Carpetas `
                              -NoDescender $noDescender `
                              -Cancelado { Test-Cancelacion $Sync } |
            ForEach-Object {
                if (& $esRegenerable $_) { $encontradas.Add($_) }
            }

        foreach ($carpeta in $encontradas) {
            if (Test-Cancelacion $Sync) { break }

            # Las ambiguas exigen un manifiesto de proyecto al lado.
            if ($carpeta.Name -match $patronAmbiguo) {
                $padre = $carpeta.DirectoryName
                $tieneManifiesto = $false
                foreach ($manifiesto in $manifiestos) {
                    if (Test-Path -LiteralPath (Join-Path $padre $manifiesto)) { $tieneManifiesto = $true; break }
                }
                if (-not $tieneManifiesto) {
                    $tieneManifiesto = @(Get-ChildItem -LiteralPath $padre -File -Filter '*.*proj' -ErrorAction SilentlyContinue).Count -gt 0
                }
                if (-not $tieneManifiesto) { continue }
            }

            # La guardia antes que la medición: medir un node_modules cuesta
            # cientos de milisegundos y la guardia, uno.
            if (-not (Test-RutaSegura $carpeta.FullName $raices)) { continue }

            Set-Progreso $Sync "Midiendo: $(Get-RutaElidida $carpeta.FullName)"
            $bytes = Measure-Ruta $carpeta.FullName
            if ($bytes -lt ($Configuracion.MinimoMB * 1MB)) { continue }

            $efecto = 'Se regenera al recompilar el proyecto.'
            if ($efectos.ContainsKey($carpeta.Name)) { $efecto = $efectos[$carpeta.Name] }

            # Un proyecto tocado esta semana probablemente está en marcha.
            $dias = [int]((Get-Date) - $carpeta.LastWriteTime).TotalDays
            $riesgo = if ($dias -lt 7) { 'Medio' } else { 'Bajo' }
            $aviso  = if ($dias -lt 7) { 'Proyecto activo: lo has tocado esta semana.' } else { '' }

            New-Candidato -ModuloId 'proyectos' -Categoria 'Proyectos regenerables' `
                          -Nombre (Get-RutaCorta $carpeta.FullName) -Ruta $carpeta.FullName -Bytes $bytes `
                          -Info "$($carpeta.Name) - último cambio $($carpeta.LastWriteTime.ToString('yyyy-MM-dd')) ($(Format-Antiguedad $carpeta.LastWriteTime))" `
                          -Efecto $efecto -Aviso $aviso -Metodo 'Ruta' -Raices $raices -Riesgo $riesgo
        }
    }
}

New-ModuloLimpieza -Id 'proyectos' -Orden 20 `
    -Nombre 'Carpetas regenerables de proyectos' `
    -Descripcion 'node_modules, dist, build, target, __pycache__, .venv... Nunca se toca código fuente ni .git.' `
    -Riesgo 'Bajo' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarProyectos
