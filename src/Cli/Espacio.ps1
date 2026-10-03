<#
.SYNOPSIS
    Modo "¿dónde se fue el espacio?" en consola: el árbol de carpetas por
    tamaño y la lista de archivos mayores.

.DESCRIPTION
    Muestra en qué se ocupa el disco, al estilo de WizTree o WinDirStat. El
    índice y la geometría del mapa viven en el núcleo (Indice.ps1 y
    Mapa.ps1); este archivo solo presenta los datos en consola.

    Es un informe: no borra ni propone nada.
#>

function Write-BarraProporcion {
    <#
    .SYNOPSIS
        Barra de texto proporcional a una fracción.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([double] $Parte, [double] $Total, [int] $Ancho = 24)

    if ($Total -le 0) { return ''.PadRight($Ancho) }
    $llenos = [int][Math]::Round($Ancho * ($Parte / $Total))
    if ($llenos -lt 0)      { $llenos = 0 }
    if ($llenos -gt $Ancho) { $llenos = $Ancho }

    # Caracteres de bloque: se ven igual en la consola clásica y en Windows Terminal.
    return ([string][char]0x2588 * $llenos) + ([string][char]0x2591 * ($Ancho - $llenos))
}

function Show-InformeEspacio {
    <#
    .SYNOPSIS
        Vuelca el índice de espacio: carpetas por tamaño y archivos
        mayores.

    .PARAMETER Rutas
        Carpetas por las que empezar. Si no se dan, las zonas del usuario.
    .PARAMETER Profundidad
        Cuántos niveles de carpeta mostrar.
    .PARAMETER Archivos
        Cuántos archivos mayores listar.
    .PARAMETER Buscar
        Filtra los archivos por nombre. Solo * y ? son comodines; el resto,
        corchetes incluidos, es literal.
    .PARAMETER Orden
        Tamano (de mayor a menor) o Nombre (alfabético).
    .PARAMETER Recorrer
        Mide de nuevo el disco aunque haya un índice guardado utilizable.
    .PARAMETER Anonimo
        Sustituye perfil, usuario y equipo por marcadores.
    .PARAMETER Informe
        Ruta de un informe HTML con el mapa de árbol, además de la salida
        en consola.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Rutas        = @(),
        [int]      $Profundidad  = 2,
        [int]      $Archivos     = 15,
        [string]   $Buscar       = '',
        # Mismo ValidateSet que Get-VistaArchivos y Get-ResumenVistaArchivos.
        # Un atributo no admite llamadas a función, así que se copia y
        # tests/VistaArchivos.Tests.ps1 comprueba que coincidan.
        [ValidateSet('Tamano', 'Nombre')]
        [string]   $Orden        = 'Tamano',
        [switch]   $ContarEnlacesDuros,
        # El aviso de índice reutilizado nombra esta opción.
        [switch]   $Recorrer,
        [switch]   $Anonimo,
        [string]   $Informe = '',
        $Configuracion = $null
    )

    $zonas = @($Rutas | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($zonas.Count -eq 0 -and $null -ne $Configuracion) {
        $zonas = @($Configuracion.ZonasUsuario | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    }
    if ($zonas.Count -eq 0) {
        Write-Linea '  No hay ninguna carpeta que analizar.' 'aviso'
        return
    }

    $mostrar = {
        param([string] $Texto)
        if ($Anonimo) { return ConvertTo-RutaAnonima $Texto }
        return $Texto
    }

    Write-Cabecera 'Dónde se fue el espacio'
    foreach ($z in $zonas) { Write-Linea ('  Analizando: {0}' -f (& $mostrar $z)) }
    Write-Linea ''

    # ---------------- Índice: guardado o recorrido ----------------
    # Un índice reutilizado describe el disco cuando se guardó y no se
    # puede actualizar, así que se usa avisándolo (Get-AvisoIndiceReutilizado).
    $indice = $null
    $reutilizado = $false
    $rutaIndice = ''
    $huella = ''
    # Localizar el índice guardado es una optimización: si falla (p. ej.
    # sin LOCALAPPDATA ni TEMP), se recorre el disco en vez de abortar.
    try {
        $nombreIndice = Get-NombreIndiceEspacio -Zonas $zonas
        if ($nombreIndice) {
            $carpetaDatos = Get-CarpetaDatos
            if (-not [string]::IsNullOrWhiteSpace($carpetaDatos)) {
                $carpetaIndices = Join-Path $carpetaDatos 'indices'
                if (-not (Test-Path -LiteralPath $carpetaIndices)) {
                    New-Item -ItemType Directory -Path $carpetaIndices -Force -ErrorAction Stop | Out-Null
                }
                $rutaIndice = Join-Path $carpetaIndices $nombreIndice
                $huella = Get-HuellaVolumenDeZonas -Zonas $zonas
            }
        }
    } catch {
        Write-Verbose ('No se ha podido preparar el índice guardado: {0}' -f $_.Exception.Message)
        $rutaIndice = ''
    }

    $cronometro = [Diagnostics.Stopwatch]::StartNew()

    if (-not $Recorrer -and $rutaIndice) {
        $cabecera = Get-CabeceraIndice -Ruta $rutaIndice
        $veredicto = Test-IndiceUtilizable -Cabecera $cabecera `
                                           -VersionEsperada (Get-VersionFormatoIndice) `
                                           -SerieVolumen $huella `
                                           -IdDiario (Get-MarcaSinDiario) `
                                           -PrimerUsn 0 `
                                           -Ahora (Get-Date)
        if ($veredicto.Utilizable) {
            $indice = Read-IndiceDisco -Ruta $rutaIndice
            # El cuerpo se valida al leerlo: si falla, se recorre el disco.
            # Un índice parcial nunca se usa.
            if ($null -ne $indice) {
                $reutilizado = $true
                Write-Linea ('  ' + (Get-AvisoIndiceReutilizado -Escrito $cabecera.Escrito -Ahora (Get-Date))) 'aviso'
                Write-Linea ''
            }
        } elseif ($null -ne $cabecera) {
            # El rechazo solo se explica si existía un índice.
            Write-Linea ('  Había un índice guardado y no se ha usado: {0}' -f $veredicto.Motivo)
            Write-Linea ''
        }
    }

    if ($null -eq $indice) {
        $indice = New-IndiceDisco -Rutas $zonas -MinimoArchivoBytes 1MB `
                                  -ContarEnlacesDuros:$ContarEnlacesDuros
    }
    $cronometro.Stop()

    # Solo se guarda un índice recién recorrido: reescribir uno reutilizado
    # renovaría su fecha y anularía la caducidad de siete días.
    if (-not $reutilizado -and $rutaIndice -and $indice.Bytes -gt 0) {
        $guardado = Save-IndiceDisco -Indice $indice -Ruta $rutaIndice `
                                     -SerieVolumen $huella `
                                     -IdDiario (Get-MarcaSinDiario) -UsnCorte 0 `
                                     -Confirm:$false
        if (-not $guardado) {
            # No es grave: la próxima vez se volverá a recorrer.
            Write-Linea '  No se ha podido guardar el índice para la próxima vez.' 'aviso'
        }
    }

    if ($indice.Bytes -le 0) {
        Write-Linea '  No se ha podido medir nada. Comprueba los permisos.' 'aviso'
        return
    }

    # ---------------- Carpetas ----------------
    Write-Cabecera 'Carpetas por tamaño'

    $pilaVisita = [Collections.Generic.Stack[object]]::new()
    foreach ($z in ($zonas | Sort-Object { -$indice.Carpetas[$_].Bytes })) {
        if ($indice.Carpetas.ContainsKey($z)) {
            $pilaVisita.Push([pscustomobject]@{ Ruta = $z; Nivel = 0; Total = $indice.Carpetas[$z].Bytes })
        }
    }

    while ($pilaVisita.Count -gt 0) {
        $nodo = $pilaVisita.Pop()
        $entrada = $indice.Carpetas[$nodo.Ruta]
        if ($null -eq $entrada) { continue }

        $sangria = '  ' + ('   ' * $nodo.Nivel)
        $nombre  = if ($nodo.Nivel -eq 0) { & $mostrar $nodo.Ruta } else { $entrada.Nombre }

        Write-Linea ('{0}{1} {2,10}  {3}' -f $sangria,
                     (Write-BarraProporcion -Parte $entrada.Bytes -Total $indice.Bytes),
                     (Format-Tamano $entrada.Bytes),
                     (Get-RutaElidida $nombre 46))

        if ($nodo.Nivel -ge $Profundidad) { continue }

        # Se apilan al revés para que salgan de mayor a menor.
        $hijas = @(Get-HijasDirectas -Indice $indice -Ruta $nodo.Ruta |
                   Where-Object { $_.Bytes -ge ($indice.Bytes * 0.01) })
        for ($i = $hijas.Count - 1; $i -ge 0; $i--) {
            if (-not $indice.Carpetas.ContainsKey($hijas[$i].Ruta)) { continue }
            $pilaVisita.Push([pscustomobject]@{
                Ruta = $hijas[$i].Ruta; Nivel = $nodo.Nivel + 1; Total = $hijas[$i].Bytes
            })
        }
    }

    Write-Linea ''
    Write-Linea '  Solo se muestran las carpetas que pasan del 1% del total.'

    # ---------------- Archivos ----------------
    # Con -Orden Nombre la lista no son "los mayores": el título cambia.
    $titulo = 'Archivos mayores'
    if ($Orden -eq 'Nombre') { $titulo = 'Archivos por nombre' }
    Write-Cabecera $titulo

    # El filtrado y el orden los decide src/Core/VistaArchivos.ps1, común a
    # todas las vistas. No filtrar aquí con -like: trata [ y ] como clases
    # de caracteres y "foto[1].jpg" no se encontraría.
    if (-not [string]::IsNullOrWhiteSpace($Buscar)) {
        Write-Linea ('  Filtrando por: {0}' -f $Buscar)
        Write-Linea ''
    }

    # @(): en PowerShell 5.1 un único objeto devuelto no tiene .Count fiable.
    $vista = @(Get-VistaArchivos -Indice $indice -Buscar $Buscar `
                                 -Cuantos $Archivos -Orden $Orden)
    foreach ($a in $vista) {
        Write-Linea ('  {0,10}  {1}' -f (Format-Tamano $a.Bytes),
                     (Get-RutaElidida (& $mostrar $a.Ruta) 60))
    }

    # El resumen se escribe siempre: distingue "esto es todo" de "esto es
    # lo que cabe".
    if ($vista.Count -gt 0) { Write-Linea '' }
    $resumen = Get-ResumenVistaArchivos -Indice $indice -Buscar $Buscar `
                                        -Cuantos $Archivos -Orden $Orden
    # Estilo de aviso solo para una búsqueda sin resultados; una lista
    # vacía sin filtro no es un problema.
    $estilo = 'normal'
    if ($vista.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Buscar)) { $estilo = 'aviso' }
    Write-Linea ('  ' + $resumen) $estilo

    # ---------------- Resumen ----------------
    Write-Cabecera 'Resumen'
    Write-Linea ('  Espacio medido    : {0}' -f (Format-Tamano $indice.Bytes))
    Write-Linea ('  Archivos          : {0:N0}' -f $indice.TotalArchivos)
    Write-Linea ('  Carpetas          : {0:N0}' -f $indice.Carpetas.Count)
    Write-Linea ('  Tiempo            : {0}' -f (Format-Duracion $cronometro.Elapsed))

    if ($indice.Compartidos -gt 0) {
        Write-Linea ('  Enlaces duros     : {0:N0} archivos comparten contenido y se han contado una sola vez' -f
                     $indice.Compartidos)
    }
    if ($indice.Inaccesibles -gt 0) {
        Write-Linea ('  Sin permiso       : {0:N0} carpetas no se han podido leer' -f $indice.Inaccesibles) 'aviso'
    }

    # ---------------- Informe con mapa ----------------
    if (-not [string]::IsNullOrWhiteSpace($Informe)) {
        try {
            Export-InformeEspacio -Indice $indice -Ruta $Informe -Anonimo:$Anonimo -Confirm:$false
            Write-Linea ''
            Write-Linea ('  Mapa del disco guardado en: {0}' -f $Informe) 'ok'
        } catch {
            Write-Linea ('  No se ha podido guardar el informe: {0}' -f $_.Exception.Message) 'error'
        }
    }

    Write-Linea ''
    Write-Linea '  Esto es un informe: no se ha propuesto ni borrado nada.'
}
