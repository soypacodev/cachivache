<#
.SYNOPSIS
    Archivos gigantes que gestiona el propio Windows.
.DESCRIPTION
    hiberfil.sys, pagefile.sys, swapfile.sys y las instantáneas de
    restauración del sistema. Módulo informativo: estos archivos no se
    borran a mano, se ajustan desde Windows. Muestra cuánto ocupan y cómo
    reducirlos.
#>

$BuscarArchivosSistema = {
    param($Configuracion, $Sync)

    Set-Progreso $Sync 'Revisando archivos gestionados por Windows...'
    $unidad = $Configuracion.Unidad + '\'

    $archivos = @(
        @{
            N = 'Hibernación (hiberfil.sys)'
            F = 'hiberfil.sys'
            E = 'Guarda la RAM al hibernar. Si no usas hibernar, se desactiva desde una consola de administrador con: powercfg /hibernate off'
            A = 'Desactivarlo también apaga el Inicio rápido de Windows.'
        }
        @{
            N = 'Memoria virtual (pagefile.sys)'
            F = 'pagefile.sys'
            E = 'Extensión de la RAM en disco. Se ajusta en Sistema > Configuración avanzada > Rendimiento > Memoria virtual.'
            A = 'No lo desactives del todo: hay programas que dejan de funcionar sin archivo de paginación.'
        }
        @{
            N = 'Intercambio de aplicaciones (swapfile.sys)'
            F = 'swapfile.sys'
            E = 'Lo usan las aplicaciones de la Store. Ocupa poco y Windows lo gestiona solo.'
            A = ''
        }
    )

    foreach ($entrada in $archivos) {
        if (Test-Cancelacion $Sync) { break }
        $ruta = Join-Path $unidad $entrada.F
        $item = Get-Item -LiteralPath $ruta -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.Length -lt 1MB) { continue }

        New-Candidato -ModuloId 'sistema' -Categoria 'Archivos del sistema' -Nombre $entrada.N `
                      -Ruta $ruta -Bytes $item.Length `
                      -Info 'lo gestiona Windows: este programa no lo toca' `
                      -Efecto $entrada.E -Aviso $entrada.A -Metodo 'Informativo' `
                      -Raices @() -Riesgo 'Alto' -Preseleccionado $false
    }

    # --- Instantáneas de Restaurar sistema --------------------------------
    if ($Configuracion.Admin) {
        Set-Progreso $Sync 'Consultando el espacio de Restaurar sistema...'
        # Anclado a System32, nunca por PATH: esta rama se ejecuta como
        # administrador, y un vssadmin.exe en una carpeta del PATH escribible
        # por el usuario se ejecutaría elevado.
        $salida = ''
        $vssadmin = Resolve-EjecutableDeSistema -Nombre 'vssadmin.exe'
        if ($null -ne $vssadmin) {
            try { $salida = & $vssadmin list shadowstorage 2>&1 | Out-String } catch { $salida = '' }
        }

        # Se acumula: vssadmin imprime una línea "Used Shadow Copy Storage
        # space" por cada volumen protegido.
        $usado = 0.0
        foreach ($linea in ($salida -split "`r?`n")) {
            # "usado" es la etiqueta de vssadmin en castellano.
            if ($linea -match '(?i)(used|usado|utilizado).*?:\s*([\d.,]+)\s*(KB|MB|GB|TB)') {
                $numero = ConvertFrom-NumeroLocal $Matches[2]
                $usado += ConvertTo-BytesConUnidad -Numero $numero -Unidad $Matches[3]
            }
        }

        if ($usado -ge 100MB) {
            $puntos = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
            $info = if ($puntos.Count -gt 0) { "$($puntos.Count) puntos de restauración" } else { 'instantáneas del volumen' }

            New-Candidato -ModuloId 'sistema' -Categoria 'Archivos del sistema' `
                          -Nombre 'Puntos de restauración del sistema' -Ruta $unidad -Bytes $usado `
                          -Info $info `
                          -Efecto 'Se ajusta el límite en Sistema > Protección del sistema. Reducir el porcentaje libera espacio conservando el punto más reciente.' `
                          -Aviso 'Son tu red de seguridad si una actualización sale mal. No los elimines sin tener una copia de seguridad.' `
                          -Metodo 'Informativo' -Raices @() -Riesgo 'Alto' -Preseleccionado $false
        }
    }
}

New-ModuloLimpieza -Id 'sistema' -Orden 80 `
    -Nombre 'Archivos gigantes del sistema' `
    -Descripcion 'hiberfil.sys, pagefile.sys y puntos de restauración. Solo informa de cuánto ocupan y de cómo reducirlos desde Windows.' `
    -Riesgo 'Alto' -SoloInforma `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarArchivosSistema
