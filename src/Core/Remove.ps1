<#
.SYNOPSIS
    Motor de eliminación. Todo borrado del programa pasa por aquí.

.DESCRIPTION
    Principios:
      * Nada se borra sin revalidar la guardia justo antes del borrado.
      * Por defecto se manda a la papelera; el borrado permanente es opt-in,
        salvo que el candidato declare ForzarPermanente (solo módulos de
        caché genuina: ver New-Candidato en Candidate.ps1).
      * Se mide antes y después para informar del espacio realmente
        liberado, no del estimado en el análisis.
      * Un fallo en un elemento nunca aborta el resto de la eliminación.
#>

$script:UltimoError = ''

# Métodos que vacían el contenido de una carpeta y la dejan en su sitio. Son
# los únicos que necesitan una breve espera antes de volver a medir.
$script:MetodosQueVacianContenido = @('Contenido', 'FirefoxCache', 'Miniaturas')

# Métodos que limpian solo una parte de su ruta a propósito (FirefoxCache:
# solo cache2 de cada perfil; Miniaturas: solo thumbcache_*.db). En ellos no
# se avisa de que "queda algo" al terminar.
$script:MetodosParciales = @('FirefoxCache', 'Miniaturas')

# ---------------------------------------------------------------------
# Qué se puede recuperar y qué no
#
#   Recuperable   lo que realmente va a la papelera de Windows, mientras
#                 no se vacíe.
#   Irreversible  vaciar la papelera (Papelera), comandos externos como
#                 DISM o "docker system prune" (Comando) y lo que no toca
#                 nada (Informativo).
#
# El borrado permanente pedido por el usuario o ForzarPermanente hacen
# irreversible cualquier método. Las dos listas se declaran completas para
# que un método nuevo tenga que clasificarse explícitamente (una prueba lo
# comprueba); nunca debe contarse como recuperable por descarte.
# ---------------------------------------------------------------------
$script:MetodosRecuperables  = @('Contenido', 'Ruta', 'CarpetaVacia', 'FirefoxCache', 'Miniaturas')
$script:MetodosIrreversibles = @('Papelera', 'Comando', 'Informativo')

function Test-CandidatoRecuperable {
    <#
    .SYNOPSIS
        ¿Se podría rescatar esto de la papelera después de borrarlo?

    .DESCRIPTION
        Cálculo puro sobre el candidato y el modo de borrado; no consulta el
        disco.

    .PARAMETER Permanente
        El borrado permanente que ha pedido el usuario para todo el lote.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # AllowNull: sin él, el enlazador de parámetros rechazaría el nulo
        # antes de llegar a la guarda de abajo.
        [Parameter(Mandatory)] [AllowNull()] $Candidato,
        [switch] $Permanente
    )

    if ($null -eq $Candidato) { return $false }
    if ($Permanente) { return $false }
    if ([bool]$Candidato.ForzarPermanente) { return $false }

    return ($script:MetodosRecuperables -contains [string]$Candidato.Metodo)
}

function Get-ResumenRecuperable {
    <#
    .SYNOPSIS
        Cuenta cuántos elementos de un lote ya borrado se pueden rescatar y
        cuántos no.

    .DESCRIPTION
        Solo cuenta los elementos realmente borrados (Hecho).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Candidatos,
        [switch] $Permanente
    )

    $recuperables = 0
    $definitivos  = 0
    foreach ($candidato in @($Candidatos)) {
        if (-not $candidato.Hecho) { continue }
        if (Test-CandidatoRecuperable -Candidato $candidato -Permanente:$Permanente) {
            $recuperables++
        } else {
            $definitivos++
        }
    }

    return [pscustomobject]@{
        Recuperables = $recuperables
        Definitivos  = $definitivos
    }
}

function Initialize-MotorBorrado {
    <#
    .SYNOPSIS
        Carga el ensamblado necesario para enviar a la papelera.
    #>
    [CmdletBinding()]
    param()
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Remove-Elemento {
    <#
    .SYNOPSIS
        Primitiva única de borrado: papelera o permanente, archivo o carpeta.
    .DESCRIPTION
        Todo borrado real pasa por aquí, tanto desde Remove-RutaSegura como
        desde Clear-ContenidoCarpeta, para que ambos caminos respeten
        -Permanente de la misma forma.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [Parameter(Mandatory)] [bool]   $EsCarpeta,
        [switch] $Permanente
    )

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Eliminar')) { return $false }

    # Rutas de más de 260 caracteres: System.IO admite el prefijo "\\?\" y
    # puede borrarlas de forma permanente, pero Microsoft.VisualBasic.FileIO
    # (la papelera) no. Si el usuario no pidió borrado permanente, se
    # rechaza y se explica en vez de borrar sin posibilidad de recuperación.
    $esLarga = Test-RutaDemasiadoLarga -Ruta $Ruta

    if ($esLarga -and -not $Permanente) {
        # Los paréntesis son necesarios: -f tiene más precedencia que +.
        $script:UltimoError = (
            ('La ruta tiene {0} caracteres y Windows no puede mandar a la papelera nada que pase de 260. ' +
             'Marca el borrado permanente si quieres eliminarlo.') -f $Ruta.Length)
        return $false
    }

    try {
        if ($Permanente) {
            # Rutas largas con System.IO: el proveedor de archivos de
            # PowerShell 5.1 no admite el prefijo. Las normales siguen con
            # Remove-Item.
            if ($esLarga) {
                $larga = ConvertTo-RutaLarga -Ruta $Ruta
                if ($EsCarpeta) { [IO.Directory]::Delete($larga, $true) }
                else            { [IO.File]::Delete($larga) }
                return $true
            }

            if ($EsCarpeta) {
                Remove-Item -LiteralPath $Ruta -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $Ruta -Force -ErrorAction Stop
            }
            return $true
        }

        if ($EsCarpeta) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $Ruta,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $Ruta,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing)
        }
        return $true
    } catch {
        $script:UltimoError = $_.Exception.Message
        return $false
    }
}

function Get-MotivoNoSeBorra {
    <#
    .SYNOPSIS
        Devuelve el motivo para no borrar un candidato, o cadena vacía si se
        puede borrar.

    .DESCRIPTION
        La comparten el borrado real y la simulación, para que la simulación
        prevea exactamente lo que hará la ejecución.

    .PARAMETER Bytes
        Tamaño ya medido por quien llama, para no recorrer el árbol dos veces.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Candidato,
        [Parameter(Mandatory)] [double] $Bytes,
        [switch] $Permanente
    )

    # Segundo corte para unidades extraíbles (defensa en profundidad). El
    # embudo del análisis ya debería haberlas descartado, pero deja pasar
    # unidades que no conoce, como un disco conectado después de arrancar.
    if ($Candidato.Metodo -notin @('Informativo', 'Papelera', 'Comando')) {
        $clase = Get-ClaseDeUnidad -Tipo (Get-TipoDeUnidad -Ruta $Candidato.Ruta)
        if ($clase -ne 'desconocida' -and -not (Test-PuedeProducirCandidatoBorrable -Clase $clase)) {
            return (Get-MotivoNoBorrableEnUnidad -Clase $clase `
                        -Letra (Get-LetraUnidad -Ruta $Candidato.Ruta))
        }
    }

    # Sin borrado permanente, el usuario ha pedido poder recuperar lo
    # borrado. Si algo no cabe en la papelera, Windows lo borra de forma
    # definitiva sin avisar y devolviendo éxito; por eso se rechaza antes.
    if (-not $Permanente -and $Candidato.Metodo -in @('Ruta', 'CarpetaVacia')) {
        $veredicto = Test-IraAPapelera -Ruta $Candidato.Ruta -Bytes $Bytes
        if (-not $veredicto.Cabe) {
            # Paréntesis necesarios: ver Remove-Elemento.
            return (('No iria a la papelera sino a la nada: {0}. No se ha borrado. ' +
                     'Si aun asi quieres eliminarlo, marca el borrado permanente.') -f $veredicto.Motivo)
        }
    }

    return ''
}

function Remove-RutaSegura {
    <#
    .SYNOPSIS
        Borra un archivo o una carpeta entera, con revalidación previa.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [switch] $Permanente,
        [switch] $PermitirPersonales
    )

    if (Test-RutaIntocable $Ruta) { return $false }

    $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    if ($null -eq $item)     { return $false }
    if (Test-EsEnlace $item) { return $false }
    if (-not $PermitirPersonales -and
        -not $item.PSIsContainer -and
        (Test-ArchivoPersonal $item.FullName)) { return $false }

    # Una carpeta con enlaces o junctions dentro no se borra: en Windows
    # PowerShell 5.1 el borrado recursivo desciende por ellos y eliminaría el
    # destino. Es habitual en node_modules (pnpm, dependencias locales de npm),
    # que puede apuntar a código fuente.
    # Se usa Get-ElementosDelArbol con -IncluirEnlaces, y no Get-ChildItem
    # -Recurse, porque este último no ve más allá de 260 caracteres y el
    # borrado posterior sí llega ahí.
    if ($item.PSIsContainer) {
        $enlaceDentro = @(Get-ElementosDelArbol -Ruta $Ruta -Que Todo -IncluirEnlaces |
                          Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
                          Select-Object -First 1)
        if ($enlaceDentro.Count -gt 0) {
            $script:UltimoError = "No se ha tocado: contiene enlaces a otras carpetas (por ejemplo $($enlaceDentro[0].FullName)) y un borrado recursivo podria llevarse lo que hay al otro lado."
            return $false
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Eliminar')) { return $false }

    return Remove-Elemento -Ruta $Ruta -EsCarpeta $item.PSIsContainer -Permanente:$Permanente -Confirm:$false
}

function Invoke-LoteEliminacion {
    <#
    .SYNOPSIS
        Elimina una lista de candidatos y devuelve el resumen de lo que
        realmente se hizo.

    .DESCRIPTION
        Bucle de borrado único, compartido por la consola y por el runspace
        de la ventana.

    .PARAMETER Candidatos
        Candidatos a eliminar. Se modifican: cada uno termina con Hecho,
        BytesLiberados y Error establecidos.
    .PARAMETER Simular
        No borra nada: mide lo que se liberaría y lo registra, aplicando las
        mismas comprobaciones que el borrado real.
    .PARAMETER AlProgresar
        Bloque opcional que se invoca tras cada elemento con el candidato y
        el recuento (la consola escribe una línea; la ventana, una barra).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] $Candidatos,
        [switch] $Permanente,
        [switch] $Simular,
        $Configuracion = $null,
        $Sync = $null,
        [scriptblock] $AlProgresar = $null
    )

    $liberado = 0.0
    $hechos   = 0
    $conError = 0
    $simulados = 0
    # Candidatos que la simulación no borraría; separados de $simulados.
    $bloqueados = 0
    $total    = @($Candidatos).Count

    foreach ($candidato in @($Candidatos)) {
        if ($null -eq $candidato) { continue }
        if (Test-Cancelacion $Sync) { break }

        # --- Simulación: se mide y se anota, no se toca nada ----------
        if ($Simular) {
            # Se mide ahora: el tamaño del análisis puede estar desfasado.
            $tamano = Measure-Ruta $candidato.Ruta
            if ($tamano -le 0) { $tamano = [double]$candidato.Bytes }

            $permanenteSim = [bool]$Permanente -or [bool]$candidato.ForzarPermanente
            $motivo = Get-MotivoNoSeBorra -Candidato $candidato -Bytes $tamano -Permanente:$permanenteSim
            if (-not [string]::IsNullOrEmpty($motivo)) {
                $bloqueados++
                $candidato.Hecho = $false
                $candidato.BytesLiberados = 0
                Write-Registro -Sync $Sync -Nivel 'BLOQUEADO' -Mensaje (
                    'NO se borraria: {0} -> {1}' -f $candidato.Ruta, $motivo)

                if ($null -ne $AlProgresar) {
                    & $AlProgresar $candidato ([pscustomobject]@{
                        Hechos = $hechos; ConError = $conError
                        Liberado = $liberado; Total = $total; Simulados = $simulados
                    })
                }
                continue
            }

            $liberado += $tamano
            $simulados++
            $candidato.Hecho = $false
            $candidato.BytesLiberados = 0

            Write-Registro -Sync $Sync -Nivel 'SIMULACION' -Mensaje (
                'Se borraria: {0} -> {1}' -f $candidato.Ruta, (Format-Tamano $tamano))

            if ($null -ne $AlProgresar) {
                & $AlProgresar $candidato ([pscustomobject]@{
                    Hechos = $hechos; ConError = $conError
                    Liberado = $liberado; Total = $total; Simulados = $simulados
                })
            }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($candidato.Ruta, 'Eliminar')) { continue }

        $liberado += Invoke-EliminacionCandidato -Candidato $candidato `
                                                 -Permanente:$Permanente `
                                                 -Sync $Sync `
                                                 -Configuracion $Configuracion -Confirm:$false

        if ($candidato.Hecho) { $hechos++ } else { $conError++ }

        # Una línea por elemento para auditoría. El nivel refleja lo que
        # ocurrió realmente: las cachés con ForzarPermanente constan como
        # BORRADO aunque el usuario no pidiera borrado permanente.
        $nivel = if ($candidato.Error) { 'ERROR' }
                 elseif ($Permanente -or $candidato.ForzarPermanente) { 'BORRADO' }
                 else { 'PAPELERA' }
        $sufijo = if ($candidato.Error) { " (no se hizo: $($candidato.Error))" } else { '' }
        Write-Registro -Sync $Sync -Nivel $nivel -Mensaje (
            '{0} -> {1}{2}' -f $candidato.Ruta, (Format-Tamano $candidato.BytesLiberados), $sufijo)

        if ($null -ne $AlProgresar) {
            & $AlProgresar $candidato ([pscustomobject]@{
                Hechos = $hechos; ConError = $conError
                Liberado = $liberado; Total = $total; Simulados = $simulados
            })
        }
    }

    return [pscustomobject]@{
        Hechos    = $hechos
        ConError  = $conError
        Liberado  = $liberado
        Total     = $total
        # Si es mayor que cero, Liberado es lo que se habría liberado.
        Simulados = $simulados
        Bloqueados = $bloqueados
        Simulado  = [bool]$Simular
    }
}

function Clear-ContenidoCarpeta {
    <#
    .SYNOPSIS
        Vacía una carpeta dejándola en su sitio.
    .DESCRIPTION
        Muchos programas fallan si desaparece su carpeta de caché, así que se
        borra elemento a elemento y el contenedor se conserva. Los archivos en
        uso lanzan una excepción y se saltan.

    .PARAMETER EsCache
        Levanta el veto por extensión personal dentro de esta carpeta. Las
        cachés de aplicaciones suelen ser archivos .db (SQLite), que el veto
        protegería. Solo lo activan los candidatos de caché genuina (los que
        declaran ForzarPermanente); la guardia, el salto de enlaces y el resto
        de protecciones se mantienen.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [switch] $Permanente,
        [switch] $EsCache,
        [int]    $Profundidad = 0
    )

    if (Test-RutaIntocable $Ruta) { return }
    if ($Profundidad -gt 32) {
        # Límite contra bucles; se informa para que el mensaje final no
        # atribuya lo que queda a archivos en uso.
        $script:UltimoError = "Se ha alcanzado el límite de 32 niveles de anidamiento en ${Ruta}: el resto no se ha tocado."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Vaciar contenido')) { return }

    foreach ($hijo in @(Get-ChildItem -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue)) {
        if (Test-EsEnlace $hijo)             { continue }
        if (Test-RutaIntocable $hijo.FullName) { continue }
        if (-not $EsCache -and -not $hijo.PSIsContainer -and (Test-ArchivoPersonal $hijo.FullName)) { continue }

        try {
            if ($hijo.PSIsContainer) {
                Clear-ContenidoCarpeta -Ruta $hijo.FullName -Permanente:$Permanente -EsCache:$EsCache `
                                       -Profundidad ($Profundidad + 1) -Confirm:$false
                $restante = @(Get-ChildItem -LiteralPath $hijo.FullName -Force -ErrorAction SilentlyContinue)
                if ($restante.Count -eq 0) {
                    [void](Remove-Elemento -Ruta $hijo.FullName -EsCarpeta $true -Permanente:$Permanente -Confirm:$false)
                }
            } else {
                [void](Remove-Elemento -Ruta $hijo.FullName -EsCarpeta $false -Permanente:$Permanente -Confirm:$false)
            }
        } catch {
            $script:UltimoError = $_.Exception.Message
        }
    }
}

function Clear-CacheFirefox {
    <#
    .SYNOPSIS
        Vacía únicamente las carpetas cache2 de cada perfil de Firefox.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [switch] $Permanente
    )

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Vaciar caché de Firefox')) { return }
    foreach ($perfil in @(Get-ChildItem -LiteralPath $Ruta -Directory -Force -ErrorAction SilentlyContinue)) {
        $cache = Join-Path $perfil.FullName 'cache2'
        if (Test-Path -LiteralPath $cache) {
            Clear-ContenidoCarpeta -Ruta $cache -Permanente:$Permanente -Confirm:$false
        }
    }
}

function Clear-Miniaturas {
    <#
    .SYNOPSIS
        Borra las bases de datos de miniaturas e iconos del Explorador.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Ruta,
        [switch] $Permanente
    )

    if (-not $PSCmdlet.ShouldProcess($Ruta, 'Borrar miniaturas')) { return }
    Get-ChildItem -LiteralPath $Ruta -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(thumbcache|iconcache)_.*\.db$' -and -not (Test-EsEnlace $_) } |
        ForEach-Object {
            [void](Remove-Elemento -Ruta $_.FullName -EsCarpeta $false -Permanente:$Permanente -Confirm:$false)
        }
}

function Clear-Papelera {
    <#
    .SYNOPSIS
        Vacía la papelera de reciclaje mediante la API del shell.
    .DESCRIPTION
        Usa Clear-RecycleBin cuando existe (Windows 10+) y, si no,
        SHEmptyRecycleBin mediante P/Invoke.

        Vacía exactamente las unidades indicadas, o todas si no se indica
        ninguna: el módulo 'papelera' solo mide las unidades seleccionadas por
        el usuario, y se vacía lo que se midió.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string[]] $Unidades = @())

    if (-not $PSCmdlet.ShouldProcess('Papelera de reciclaje', 'Vaciar')) { return $false }

    $letras = @($Unidades | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('\').TrimEnd(':') })

    if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
        $fallos = 0
        try {
            if ($letras.Count -gt 0) {
                foreach ($letra in $letras) {
                    # Una unidad que falla no aborta el resto.
                    try { Clear-RecycleBin -DriveLetter $letra -Force -ErrorAction Stop }
                    catch { $fallos++; $script:UltimoError = $_.Exception.Message }
                }
            } else {
                Clear-RecycleBin -Force -ErrorAction Stop
            }
            return ($fallos -eq 0)
        } catch {
            $script:UltimoError = $_.Exception.Message
            return $false
        }
    }

    try {
        if (-not ('Cachivache.Shell32' -as [type])) {
            Add-Type -Namespace 'Cachivache' -Name 'Shell32' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SHEmptyRecycleBin(System.IntPtr hwnd, string pszRootPath, uint dwFlags);
'@ -ErrorAction Stop
        }

        # pszRootPath por unidad: con $null la API vacía todas las papeleras
        # del equipo, también las de unidades no seleccionadas.
        $rutas = if ($letras.Count -gt 0) { @($letras | ForEach-Object { "$_`:\" }) } else { @($null) }

        $fallos = 0
        foreach ($raiz in $rutas) {
            # 0x1 sin confirmación | 0x2 sin animación | 0x4 sin sonido
            $hr = [Cachivache.Shell32]::SHEmptyRecycleBin([IntPtr]::Zero, $raiz, 0x7)
            # 0 = S_OK. 0x8000FFFF (E_UNEXPECTED) indica que la papelera ya
            # estaba vacía: no es un fallo.
            if ($hr -ne 0 -and $hr -ne -2147418113) {
                $fallos++
                $script:UltimoError = 'SHEmptyRecycleBin ha devuelto 0x{0:X8} para {1}.' -f $hr, $(if ($raiz) { $raiz } else { 'todas las unidades' })
            }
        }
        return ($fallos -eq 0)
    } catch {
        $script:UltimoError = $_.Exception.Message
        return $false
    }
}

function Invoke-EliminacionCandidato {
    <#
    .SYNOPSIS
        Ejecuta la eliminación de un candidato y devuelve los bytes realmente
        liberados.

    .DESCRIPTION
        Único punto del programa que borra datos del usuario. Antes de tocar
        nada revalida la guardia contra las raíces declaradas por el módulo,
        de modo que un candidato manipulado o desfasado no puede colarse.
    .PARAMETER Sync
        Tabla sincronizada de New-EstadoSincronizado, si existe. Se reenvía a
        Write-Registro: sin ella se escribe al momento (consola); con ella se
        encola para el temporizador de la interfaz.
    .PARAMETER Configuracion
        Opcional. Aporta las exclusiones del usuario y, para el método
        'Papelera', las unidades seleccionadas (sin ella se vacían todas).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] $Candidato,
        [switch] $Permanente,
        $Sync = $null,
        $Configuracion = $null
    )

    # Se reinicia el resultado: un candidato reintentado no puede conservar
    # el Hecho de una pasada anterior si ahora sale por una rama temprana.
    $script:UltimoError = ''
    $Candidato.Error = ''
    $Candidato.Hecho = $false
    $Candidato.BytesLiberados = 0

    if ($Candidato.Metodo -eq 'Informativo') {
        $Candidato.Error = 'Este elemento solo informa: no se borra nada.'
        return 0.0
    }

    if ($Candidato.Metodo -eq 'Papelera') {
        $antes = Measure-Ruta $Candidato.Ruta
        $unidadesPapelera = @()
        if ($null -ne $Configuracion -and $Configuracion.PSObject.Properties['UnidadesSeleccionadas']) {
            $unidadesPapelera = @($Configuracion.UnidadesSeleccionadas)
        }
        if (-not (Clear-Papelera -Unidades $unidadesPapelera -Confirm:$false)) {
            $Candidato.Error = $script:UltimoError
            return 0.0
        }
        $Candidato.Hecho = $true
        $liberado = $antes - (Measure-Ruta $Candidato.Ruta)
        if ($liberado -lt 0) { $liberado = 0 }
        $Candidato.BytesLiberados = $liberado
        return $liberado
    }

    # Las exclusiones del usuario se revalidan aquí y no solo en el análisis,
    # porque el borrado ocurre más tarde y en otro runspace. Se aplican
    # también a 'Comando' (el único método que lanza un ejecutable externo),
    # comparando por ClaveExclusion porque un comando no tiene ruta real.
    if ($null -ne $Configuracion -and $Configuracion.PSObject.Properties['RutasExcluidas']) {
        $claveCandidato = if ($Candidato.PSObject.Properties['ClaveExclusion']) {
            $Candidato.ClaveExclusion
        } else {
            # Candidato construido sin clave: se calcula con la misma función.
            Get-ClaveExclusion -Ruta $Candidato.Ruta -ModuloId $Candidato.ModuloId -Nombre $Candidato.Nombre
        }

        if (Test-ClaveExcluida -Clave $claveCandidato -Excluidas @($Configuracion.RutasExcluidas)) {
            $Candidato.Error = 'Excluido por ti: esta en tu lista de "no tocar nunca".'
            return 0.0
        }
    }

    # 'Comando' no se valida contra la guardia de rutas: su Ruta puede ser
    # solo una etiqueta ("docker system prune") y su seguridad viene de la
    # lista blanca de ejecutables (Resolve-EjecutablePermitido).
    if ($Candidato.Metodo -ne 'Comando') {
        if (-not (Test-Path -LiteralPath $Candidato.Ruta)) {
            $Candidato.Error = 'La ruta ya no existe.'
            return 0.0
        }

        # --- Revalidación en vivo de la guardia -------------------------
        if (-not (Test-RutaSegura -Ruta $Candidato.Ruta -Raices $Candidato.Raices `
                                  -PermitirPersonales:$Candidato.PermitirPersonales)) {
            $Candidato.Error = 'Bloqueado por la guardia: ' + (Get-MotivoBloqueo $Candidato.Ruta $Candidato.Raices)
            return 0.0
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Candidato.Ruta, "Eliminar ($($Candidato.Metodo))")) { return 0.0 }

    # Se mide justo antes de borrar: el tamaño del análisis puede tener horas
    # y esta cifra alimenta el historial. El borrado recorre los mismos
    # archivos, así que el coste no cambia de orden de magnitud.
    $antes = Measure-Ruta $Candidato.Ruta
    # Si no se puede medir (enlace, 'Comando'...), se usa el valor del análisis.
    if ($antes -le 0) { $antes = [double]$Candidato.Bytes }

    # ForzarPermanente solo lo declaran las cachés genuinas (enviar cientos de
    # miles de archivos a la papelera es muy lento y la llena). En el resto
    # manda la preferencia del usuario.
    $permanenteEfectivo = [bool]$Permanente -or [bool]$Candidato.ForzarPermanente

    $motivoBloqueo = Get-MotivoNoSeBorra -Candidato $Candidato -Bytes $antes -Permanente:$permanenteEfectivo
    if (-not [string]::IsNullOrEmpty($motivoBloqueo)) {
        $Candidato.Error = $motivoBloqueo
        Write-Registro -Sync $Sync -Nivel 'BLOQUEADO' -Mensaje (
            'No se borra {0}: {1}' -f $Candidato.Ruta, $motivoBloqueo)
        return 0.0
    }

    switch ($Candidato.Metodo) {
        'CarpetaVacia' {
            # Este método borra un árbol entero, así que se comprueba de nuevo
            # que sigue sin archivos: algo ha podido escribir dentro desde el
            # análisis. Get-ElementosDelArbol ve también rutas de más de 260
            # caracteres.
            $conArchivos = @(Get-ElementosDelArbol -Ruta $Candidato.Ruta |
                             Select-Object -First 1)
            if ($conArchivos.Count -gt 0) {
                $Candidato.Error = 'Ya no está vacía: algo ha creado archivos dentro desde el análisis. No se ha tocado.'
            } else {
                [void](Remove-RutaSegura -Ruta $Candidato.Ruta -Permanente:$permanenteEfectivo -Confirm:$false)
            }
        }
        # No existe un método 'NpmClean': ejecutar npm.cmd pasaría por
        # cmd.exe. La caché de npm se limpia con 'Contenido'.
        'FirefoxCache' { Clear-CacheFirefox -Ruta $Candidato.Ruta -Permanente:$permanenteEfectivo -Confirm:$false }
        'Miniaturas'   { Clear-Miniaturas   -Ruta $Candidato.Ruta -Permanente:$permanenteEfectivo -Confirm:$false }
        'Contenido'    {
            # ForzarPermanente identifica las cachés genuinas, que son también
            # las que pueden levantar el veto por extensión personal.
            Clear-ContenidoCarpeta -Ruta $Candidato.Ruta -Permanente:$permanenteEfectivo `
                                   -EsCache:([bool]$Candidato.ForzarPermanente) -Confirm:$false
        }
        'Comando' {
            $rutaEjecutable = Resolve-EjecutablePermitido -Ejecutable $Candidato.Ejecutable
            if ($null -eq $rutaEjecutable) {
                $Candidato.Error = "Ejecutable no permitido o no encontrado: '$($Candidato.Ejecutable)'."
                Write-Registro -Sync $Sync -Nivel 'BLOQUEADO' -Mensaje (
                    "Comando rechazado por la lista blanca: ejecutable '{0}' ({1})." -f
                    $Candidato.Ejecutable, $Candidato.Comando)
            } else {
                try {
                    # -ArgumentList recibe un array: cada elemento llega como
                    # argumento nativo, sin intérprete de shell de por medio.
                    $proceso = Start-Process -FilePath $rutaEjecutable -ArgumentList @($Candidato.Argumentos) `
                                             -Wait -NoNewWindow -PassThru -ErrorAction Stop
                    Write-Registro -Sync $Sync -Nivel 'BORRADO' -Mensaje (
                        '{0} {1}  ->  código de salida {2}' -f $rutaEjecutable,
                        ($Candidato.Argumentos -join ' '), $proceso.ExitCode)
                    if ($proceso.ExitCode -ne 0) {
                        $Candidato.Error = "El comando termino con código de salida $($proceso.ExitCode)."
                    }
                } catch {
                    $script:UltimoError = $_.Exception.Message
                }
            }
        }
        default {
            [void](Remove-RutaSegura -Ruta $Candidato.Ruta -Permanente:$permanenteEfectivo `
                                     -PermitirPersonales:$Candidato.PermitirPersonales -Confirm:$false)
        }
    }

    # Un Error puesto por una rama del switch significa "no se ejecutó nada";
    # se guarda antes de que el bloque siguiente lo complete.
    $errorDeRama = $Candidato.Error

    # Breve espera antes de volver a medir, solo cuando el contenedor sigue
    # existiendo, para no contar descriptores aún abiertos.
    if ($script:MetodosQueVacianContenido -contains $Candidato.Metodo) {
        Start-Sleep -Milliseconds 50
    }

    $restante = Measure-Ruta $Candidato.Ruta
    $liberado = $antes - $restante
    if ($liberado -lt 0) { $liberado = 0 }

    $Candidato.BytesLiberados = $liberado
    if ($Candidato.Error) {
        # La rama ya ha explicado por qué no se hizo nada; no se pisa.
    } elseif ($script:UltimoError) {
        $Candidato.Error = $script:UltimoError
    } elseif ($restante -gt 1MB -and $antes -gt 0 -and
              $script:MetodosParciales -notcontains $Candidato.Metodo) {
        # Los métodos parciales dejan contenido a propósito: no se avisa.
        $Candidato.Error = "Quedan $(Format-Tamano $restante): archivos en uso por algún programa abierto."
    }

    # Hecho se decide al final, con el error ya consolidado:
    #   - una rama declinó actuar           -> no hecho
    #   - algo lanzó al ejecutar            -> no hecho
    #   - se ejecutó y quedan archivos en uso -> hecho (resultado parcial;
    #     el aviso de "quedan X" es informativo)
    # Hecho alimenta la interfaz, la columna "Eliminado" del CSV y el
    # historial.
    $Candidato.Hecho = [string]::IsNullOrEmpty($errorDeRama) -and
                       [string]::IsNullOrEmpty($script:UltimoError)

    return $liberado
}
