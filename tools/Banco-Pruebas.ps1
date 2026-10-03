<#
.SYNOPSIS
    Monta y quita el banco de pruebas de Cachivache. Ejecutar solo en una
    máquina virtual con instantánea.

.DESCRIPTION
    Algunas garantías del programa (archivos que no caben en la papelera,
    rutas de más de 260 caracteres, archivos de OneDrive bajo demanda) solo
    se ejercitan al borrar de verdad. Este guion monta cebos deterministas
    en una carpeta propia dentro de Documentos para hacer una limpieza real
    y comprobar el resultado. docs/BANCO-PRUEBAS.md describe qué debe pasar
    con cada cebo.

    Va dentro de Documentos porque los módulos solo recorren las zonas del
    usuario (Escritorio, Documentos, Descargas, Imágenes, Música, Vídeos,
    OneDrive); por eso exige una máquina virtual.

    La lógica pura (ubicación, detección de VM, pertenencia de rutas y
    catálogo de cebos) está en Banco-Decisiones.ps1, que se puede cargar
    sin efectos; este archivo crea y borra archivos.

.PARAMETER Quitar
    Borra el banco entero en vez de montarlo.

.PARAMETER AunqueNoSeaVirtual
    Omite la comprobación de máquina virtual.

.PARAMETER ArchivosDeSobra
    Archivos temporales de relleno para las pruebas de desplazamiento y
    marcado en lote con miles de filas. Por defecto 3000.

.EXAMPLE
    .\Banco-Pruebas.ps1 -WhatIf
    Muestra lo que haría sin tocar nada.

.EXAMPLE
    .\Banco-Pruebas.ps1
    Monta el banco.

.EXAMPLE
    .\Banco-Pruebas.ps1 -Quitar
    Quita el banco. No recupera lo que haya borrado Cachivache: para eso,
    restaura la instantánea.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $Quitar,
    [switch] $AunqueNoSeaVirtual,
    [ValidateRange(0, 50000)]
    [int] $ArchivosDeSobra = 3000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Banco-Decisiones.ps1')

# ---------------------------------------------------------------------
#  Ubicación del banco
# ---------------------------------------------------------------------

function Get-RaizBanco {
    <#
    .SYNOPSIS
        La carpeta del banco, ya resuelta a ruta absoluta.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # MyDocuments y no "$env:USERPROFILE\Documents": OneDrive puede
    # redirigir Documentos, y Cachivache usa esta misma API.
    $documentos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documentos)) { return $null }

    $compuesta = Get-RutaRaizBanco -Documentos $documentos
    if ([string]::IsNullOrWhiteSpace($compuesta)) { return $null }
    return [IO.Path]::GetFullPath($compuesta)
}

function Get-DescripcionEquipo {
    <#
    .SYNOPSIS
        Fabricante y modelo, para saber si es una máquina virtual.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    try {
        # Get-CimInstance y no Get-WmiObject, que no existe en PowerShell 7.
        $s = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        return @{ Fabricante = [string]$s.Manufacturer; Modelo = [string]$s.Model }
    } catch {
        # Sin datos no se puede afirmar que sea virtual: el montaje se bloquea.
        Write-Verbose "No se ha podido leer Win32_ComputerSystem: $($_.Exception.Message)"
        return @{ Fabricante = ''; Modelo = '' }
    }
}

# ---------------------------------------------------------------------
#  Los cebos
# ---------------------------------------------------------------------

function New-ArchivoDeCebo {
    <#
    .SYNOPSIS
        Un archivo de tamaño dado y fecha antigua.

    .DESCRIPTION
        La fecha antigua es necesaria: el módulo de temporales no propone un
        .tmp escrito hace menos de treinta minutos.

        Hasta 1 MB se repite el texto de relleno (dos cebos con el mismo
        relleno salen idénticos, para el módulo de duplicados); por encima
        se escribe por bloques para no componer cientos de MB en memoria.

        Siempre se usa el prefijo de ruta larga: es inocuo en rutas cortas y
        permite crear el cebo de más de 260 caracteres, con el que New-Item
        y Set-Content de PowerShell 5.1 fallan.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [int] $KiloBytes = 4,
        [string] $Relleno = 'cebo'
    )

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Crear archivo de prueba')) { return }

    $largo = '\\?\' + $Ruta

    if ($KiloBytes -le 1024) {
        # Al menos un byte: ningún módulo propone un archivo vacío.
        $veces = [Math]::Max(1, [int](($KiloBytes * 1024) / [Math]::Max(1, $Relleno.Length)))
        [IO.File]::WriteAllText($largo, ($Relleno * $veces))
    } else {
        $bloque = [byte[]]::new(1MB)
        $flujo  = [IO.File]::Create($largo)
        try {
            foreach ($n in 1..[int]($KiloBytes / 1024)) { $flujo.Write($bloque, 0, $bloque.Length) }
        } finally {
            $flujo.Dispose()
        }
    }

    $antiguo = (Get-Date).AddDays(-400)
    [IO.File]::SetLastWriteTime($largo, $antiguo)
    [IO.File]::SetCreationTime($largo, $antiguo)
    [IO.File]::SetLastAccessTime($largo, $antiguo)
}

function New-BancoPruebas {
    <#
    .SYNOPSIS
        Monta todos los cebos del catálogo.

    .DESCRIPTION
        Rutas y nombres salen de Get-CebosBanco (cálculo puro y probado).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Raiz,
        [ValidateRange(0, 50000)]
        [int] $DeSobra = 3000
    )

    if (-not $PSCmdlet.ShouldProcess($Raiz, 'Montar el banco de pruebas')) { return }

    [void][IO.Directory]::CreateDirectory($Raiz)
    Write-Host "Banco en: $Raiz" -ForegroundColor Cyan

    foreach ($cebo in (Get-CebosBanco -ArchivosDeSobra $DeSobra)) {
        if ([int]$cebo.Cuantos -le 0) { continue }

        for ($n = 1; $n -le [int]$cebo.Cuantos; $n++) {
            $ruta = Get-RutaCebo -Cebo $cebo -Raiz $Raiz -Indice $n

            if ($cebo.EsCarpeta) {
                [void][IO.Directory]::CreateDirectory('\\?\' + $ruta)
                continue
            }

            # Con prefijo por el cebo de ruta larga: sin él, CreateDirectory
            # lanza por encima de 260 caracteres.
            $carpeta = $ruta.Substring(0, $ruta.LastIndexOf('\'))
            [void][IO.Directory]::CreateDirectory('\\?\' + $carpeta)

            if (-not [string]::IsNullOrWhiteSpace($cebo.EnlaceA)) {
                # Enlace duro: no requiere administrador (uno simbólico sí).
                $destino = Join-Path $carpeta $cebo.EnlaceA
                New-Item -ItemType HardLink -Path $ruta -Target $destino -ErrorAction Stop | Out-Null
                continue
            }

            New-ArchivoDeCebo -Ruta $ruta -KiloBytes ([int]$cebo.KiloBytes) `
                              -Relleno ([string]$cebo.Relleno)
        }

        Write-Host ('  {0,-16} {1,6} en {2}   {3}' -f `
                    $cebo.Id, $cebo.Cuantos, $cebo.Carpeta, $cebo.Para) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Montado. Sigue docs/BANCO-PRUEBAS.md desde el paso 5.' -ForegroundColor Green
}

function ConvertFrom-PrefijoLargo {
    <#
    .SYNOPSIS
        Quita el "\\?\" de una ruta. Equivale a ConvertFrom-RutaLarga del
        núcleo, que el banco no carga.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Ruta)

    if ($Ruta.StartsWith('\\?\')) { return $Ruta.Substring(4) }
    return $Ruta
}

function Get-ContenidoBanco {
    <#
    .SYNOPSIS
        Todo lo que hay dentro del banco, de lo más profundo a lo más
        superficial, incluida la ruta larga.

    .DESCRIPTION
        Pila propia y DirectoryInfo con el prefijo "\\?\", no
        Get-ChildItem -Recurse: en Windows PowerShell 5.1 este se detiene
        en 260 caracteres sin avisar y el banco no se desmontaría entero.

        Devuelve rutas sin el prefijo; el prefijo solo se usa en las
        llamadas a la API.

        Los puntos de reanálisis (uniones, enlaces simbólicos) se devuelven
        pero no se recorren: su contenido está fuera del banco y lo único
        que se puede quitar es el propio enlace.
    .PARAMETER Prefijo
        Prefijo de ruta larga. Solo las pruebas, fuera de Windows, lo cambian.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Raiz,
        [AllowEmptyString()] [string] $Prefijo = '\\?\'
    )

    $encontrados = [Collections.Generic.List[string]]::new()
    $pendientes  = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pendientes.Push([IO.DirectoryInfo]::new($Prefijo + $Raiz))

    while ($pendientes.Count -gt 0) {
        $actual = $pendientes.Pop()
        foreach ($archivo in $actual.EnumerateFiles()) {
            $encontrados.Add((ConvertFrom-PrefijoLargo -Ruta $archivo.FullName))
        }
        foreach ($sub in $actual.EnumerateDirectories()) {
            $encontrados.Add((ConvertFrom-PrefijoLargo -Ruta $sub.FullName))
            if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $pendientes.Push($sub)
        }
    }

    # De más larga a más corta: cada carpeta se borra después de su
    # contenido, sin borrado recursivo.
    return @($encontrados | Sort-Object -Property Length -Descending)
}

function Remove-BancoPruebas {
    <#
    .SYNOPSIS
        Quita el banco. Solo el banco.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)] [string] $Raiz)

    if (-not $PSCmdlet.ShouldProcess($Raiz, 'Borrar el banco de pruebas')) { return }

    # Una raíz que es un enlace llevaría el recorrido a otra carpeta.
    if ([IO.File]::GetAttributes('\\?\' + $Raiz) -band [IO.FileAttributes]::ReparsePoint) {
        throw ("La raiz del banco es un enlace y no se toca: $Raiz")
    }

    # De dentro hacia fuera y comprobando cada ruta contra la raíz (no
    # Remove-Item -Recurse), para que un error al calcular la raíz no borre
    # otra carpeta. Ver Test-DentroDeRaiz.
    foreach ($hijo in (Get-ContenidoBanco -Raiz $Raiz)) {
        if (-not (Test-DentroDeRaiz -Ruta $hijo -Raiz $Raiz)) {
            throw ("Algo esta fuera del banco y no se toca: $hijo")
        }
        $largo = '\\?\' + $hijo
        # GetAttributes no sigue el enlace: describe la propia entrada.
        $atributos = [IO.File]::GetAttributes($largo)
        if ($atributos -band [IO.FileAttributes]::Directory) {
            # Sin recursión: la carpeta ya está vacía, y un borrado recursivo
            # anularía la comprobación ruta a ruta. En una unión o enlace
            # simbólico quita solo el enlace, nunca su destino.
            [IO.Directory]::Delete($largo, $false)
        } elseif ($atributos -band [IO.FileAttributes]::ReparsePoint) {
            # Enlace a archivo: se borra el enlace sin cambiar atributos,
            # que podrían aplicarse al destino.
            [IO.File]::Delete($largo)
        } else {
            # Se quitan los atributos: un archivo de solo lectura no se borra.
            [IO.File]::SetAttributes($largo, [IO.FileAttributes]::Normal)
            [IO.File]::Delete($largo)
        }
    }

    [IO.Directory]::Delete('\\?\' + $Raiz, $false)
    Write-Host "Banco quitado: $Raiz" -ForegroundColor Green
    Write-Host 'Esto NO devuelve lo que borro Cachivache. Restaura la instantanea.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------
#  Ejecución
# ---------------------------------------------------------------------

$raiz = Get-RaizBanco
if (-not $raiz) {
    throw 'No se ha podido encontrar la carpeta Documentos de este usuario.'
}

$existe = [IO.Directory]::Exists($raiz)

if ($Quitar) {
    $motivo = Get-MotivoNoQuitarBanco -Raiz $raiz -Existe:$existe
    if ($motivo) {
        Write-Host $motivo -ForegroundColor Yellow
        return
    }
    Remove-BancoPruebas -Raiz $raiz
    return
}

$equipo = Get-DescripcionEquipo
$virtual = Test-PareceMaquinaVirtual -Fabricante $equipo.Fabricante -Modelo $equipo.Modelo

$ocupada = $existe -and
           @(Get-ChildItem -LiteralPath $raiz -Force -ErrorAction SilentlyContinue).Count -gt 0

$motivo = Get-MotivoNoMontarBanco -PareceVirtual:$virtual -Forzado:$AunqueNoSeaVirtual -RaizOcupada:$ocupada
if ($motivo) {
    Write-Host $motivo -ForegroundColor Yellow
    return
}

New-BancoPruebas -Raiz $raiz -DeSobra $ArchivosDeSobra
