<#
.SYNOPSIS
    Juzga una pasada del banco de pruebas. Lo ejecuta el trabajo "banco" de
    la integración continua; no borra nada por su cuenta.

.DESCRIPTION
    Comprueba de forma automática, en un runner de Windows (NTFS y borrado
    reales), lo que docs/BANCO-PRUEBAS.md describe para una máquina
    virtual. No monta el banco (eso es Banco-Pruebas.ps1) ni lo borra:
    recibe una fase, comprueba, imprime lo que ha visto y termina con
    código 1 si algo no cuadra.

    La lógica pura (catálogo de cebos, pertenencia de rutas al banco o a
    otro perfil, recuento de cebos encontrados) vive en
    Banco-Decisiones.ps1 para poder probarla en Linux.

    Un runner no tiene Steam, Docker ni navegadores con caché, así que un
    módulo vacío no es un fallo; un cebo que no aparece, sí. Cada
    comprobación falla si no encuentra lo que necesita, en vez de pasar
    sin haber mirado.

.PARAMETER Fase
    Qué se comprueba. Ver el bloque de cada fase más abajo.

.PARAMETER Informe
    El .json que generó el análisis. Fases 'analisis' y 'simulacion'.

.PARAMETER ArchivosDeSobra
    El mismo valor que se pasó a Banco-Pruebas.ps1; si no coincide, la
    fase 'analisis' buscaría cebos que no se montaron.

.PARAMETER Salida
    Dónde escribir el inventario. Fase 'inventario'.

.PARAMETER Antes
.PARAMETER Despues
    Los dos inventarios que se comparan. Fase 'limpieza'.

.EXAMPLE
    .\tools\Banco-Comprobar.ps1 -Fase montaje -ArchivosDeSobra 300
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('montaje', 'analisis', 'windows', 'dosanalisis',
                 'inventario', 'simulacion', 'limpieza')]
    [string] $Fase,

    [string] $Informe = '',
    [ValidateRange(0, 50000)]
    [int]    $ArchivosDeSobra = 300,
    [string] $Salida = '',
    [string] $Antes = '',
    [string] $Despues = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$RaizProyecto = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Banco-Decisiones.ps1')

# El núcleo se carga en el ámbito del guion, no dentro de una función: una
# función que hace dot-source se lleva las definiciones al terminar. Además,
# las variables $script: del núcleo (p. ej. $script:UltimoError, donde
# Remove.ps1 deja el motivo de un fallo) tienen que ser legibles desde aquí.
. (Join-Path (Join-Path (Join-Path $RaizProyecto 'src') 'Core') 'Bootstrap.ps1')

# ---------------------------------------------------------------------
#  Salida de resultados
# ---------------------------------------------------------------------

$script:Fallos = [Collections.Generic.List[string]]::new()

function Write-Veredicto {
    <#
    .SYNOPSIS
        Una línea por comprobación, con lo que se ha mirado.

    .DESCRIPTION
        El detalle se imprime siempre, también cuando la comprobación pasa,
        para que el registro sirva para diagnosticar fallos futuros.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Que,
        [Parameter(Mandatory)] [bool]   $Bien,
        [string] $Detalle = ''
    )

    if ($Bien) {
        Write-Host ('  OK     {0}' -f $Que) -ForegroundColor Green
    } else {
        Write-Host ('  FALLA  {0}' -f $Que) -ForegroundColor Red
        Write-Host ("::error::{0}: {1}" -f $Que, $Detalle)
        $script:Fallos.Add($Que)
    }
    if ($Detalle) { Write-Host ('         {0}' -f $Detalle) -ForegroundColor DarkGray }
}

function Write-Aviso {
    <#
    .SYNOPSIS
        Algo que hay que saber y que no es un fallo del programa.

    .DESCRIPTION
        Para lo que el runner no puede comprobar (un módulo omitido por
        permisos) o lo que el catálogo ya documenta como no cumplido. Sale
        como aviso de GitHub, visible pero sin marcar el trabajo en rojo.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Texto)

    Write-Host ('  AVISO  {0}' -f $Texto) -ForegroundColor Yellow
    Write-Host ("::warning::{0}" -f $Texto)
}

function Get-RaizDelBanco {
    <#
    .SYNOPSIS
        La carpeta del banco en este equipo.
    .DESCRIPTION
        Usa la misma función pura que Banco-Pruebas.ps1, para que el
        comprobador no pueda mirar otra carpeta.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $documentos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $raiz = Get-RutaRaizBanco -Documentos $documentos
    if ([string]::IsNullOrWhiteSpace($raiz)) {
        throw 'No se ha podido encontrar la carpeta Documentos de este usuario.'
    }
    return [IO.Path]::GetFullPath($raiz)
}

function Get-ArchivosDeVerdad {
    <#
    .SYNOPSIS
        Todos los archivos bajo una carpeta, incluidos los de rutas de más
        de 260 caracteres.

    .DESCRIPTION
        Pila propia y DirectoryInfo con el prefijo "\\?\": en Windows
        PowerShell 5.1, Get-ChildItem -Recurse se detiene en MAX_PATH sin
        avisar. Este inventario decide si la limpieza tocó algo indebido,
        así que no puede omitir archivos.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Carpeta)

    $encontrados = [Collections.Generic.List[string]]::new()
    if (-not [IO.Directory]::Exists('\\?\' + $Carpeta)) { return @() }

    $pendientes = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pendientes.Push([IO.DirectoryInfo]::new('\\?\' + $Carpeta))

    while ($pendientes.Count -gt 0) {
        $actual = $pendientes.Pop()
        try {
            foreach ($archivo in $actual.EnumerateFiles()) {
                $ruta = $archivo.FullName
                if ($ruta.StartsWith('\\?\')) { $ruta = $ruta.Substring(4) }
                $encontrados.Add($ruta)
            }
        } catch {
            Write-Host ('         (no se ha podido leer {0}: {1})' -f $actual.FullName, $_.Exception.Message)
        }
        try {
            foreach ($sub in $actual.EnumerateDirectories()) {
                # Los puntos de reanálisis no se siguen: llevan fuera del árbol.
                if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $pendientes.Push($sub)
            }
        } catch {
            Write-Host ('         (no se han podido listar las subcarpetas de {0})' -f $actual.FullName)
        }
    }
    return @($encontrados)
}

function Initialize-Comprobador {
    <#
    .SYNOPSIS
        Descubre el equipo y deja la guardia lista, como haría el programa.
    .DESCRIPTION
        Devuelve la configuración para las fases. El núcleo ya está cargado
        en el ámbito del guion.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()

    # Mismo orden que Cachivache.ps1. Initialize-Registro va primero: lo que
    # se registre antes se pierde, y el registro se sube como artefacto
    # cuando algo falla.
    [void](Initialize-Registro)
    $configuracion = New-Configuracion -Perfil 'agresivo'
    Initialize-Guardia -Configuracion $configuracion

    # Comprobación de cordura: una guardia sin inicializar aceptaría todo.
    if (-not (Test-RutaIntocable 'C:\Windows\System32')) {
        throw 'La guardia no se ha inicializado: no se puede comprobar nada.'
    }
    return $configuracion
}

# ---------------------------------------------------------------------
#  FASE montaje: el banco está donde dice el catálogo
# ---------------------------------------------------------------------
function Invoke-FaseMontaje {
    [CmdletBinding()]
    param()

    $raiz = Get-RaizDelBanco
    Write-Host ('Banco: {0}' -f $raiz) -ForegroundColor Cyan

    # Si Banco-Pruebas.ps1 se negó a montar (p. ej. no reconoció una
    # máquina virtual), no hay carpeta y las demás fases no mirarían nada.
    Write-Veredicto -Que 'el banco se ha montado' -Bien ([IO.Directory]::Exists($raiz)) `
        -Detalle ('Si no existe, Banco-Pruebas.ps1 no llegó a montarlo: mira su salida. ' +
                  'En el runner de la CI, la comprobación de máquina virtual debe saltarse sola.')
    if (-not [IO.Directory]::Exists($raiz)) { return }

    foreach ($cebo in (Get-CebosBanco -ArchivosDeSobra $ArchivosDeSobra)) {
        if ([int]$cebo.Cuantos -le 0) { continue }

        $faltan = 0
        $bytes  = 0.0
        for ($n = 1; $n -le [int]$cebo.Cuantos; $n++) {
            $ruta = '\\?\' + (Get-RutaCebo -Cebo $cebo -Raiz $raiz -Indice $n)
            if ($cebo.EsCarpeta) {
                if (-not [IO.Directory]::Exists($ruta)) { $faltan++ }
            } elseif ([IO.File]::Exists($ruta)) {
                $bytes += [double]([IO.FileInfo]::new($ruta).Length)
            } else {
                $faltan++
            }
        }

        Write-Veredicto -Que ('cebo {0}: los {1} montados' -f $cebo.Id, $cebo.Cuantos) `
            -Bien ($faltan -eq 0) `
            -Detalle ('faltan {0}; ocupan {1:N0} bytes en total ({2})' -f $faltan, $bytes, $cebo.Para)
    }

    # Con un perfil de ruta corta, el cebo podría no llegar a 260 caracteres
    # y las comprobaciones de rutas largas no probarían nada.
    $largo = Get-RutaCebo -Raiz $raiz -Cebo (
        Get-CebosBanco -ArchivosDeSobra $ArchivosDeSobra | Where-Object { $_.Id -eq 'ruta-larga' })
    Write-Veredicto -Que 'el cebo de ruta larga pasa de 260 caracteres' -Bien ($largo.Length -ge 260) `
        -Detalle ('mide {0}' -f $largo.Length)
}

# ---------------------------------------------------------------------
#  FASE analisis: qué propuso y, sobre todo, qué no debía proponer
# ---------------------------------------------------------------------
function Invoke-FaseAnalisis {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $Informe)) {
        throw "No esta el informe del analisis: $Informe"
    }

    $raiz      = Get-RaizDelBanco
    $documento = Get-Content -Raw -LiteralPath $Informe | ConvertFrom-Json
    $candidatos = @($documento.Candidatos)

    # Con un informe vacío, todas las comprobaciones de abajo pasarían.
    Write-Veredicto -Que 'el analisis ha propuesto algo' -Bien ($candidatos.Count -gt 0) `
        -Detalle ('{0} elementos en el informe' -f $candidatos.Count)
    if ($candidatos.Count -eq 0) { return }

    [void](Initialize-Comprobador)

    $rutas = @($candidatos | ForEach-Object { [string]$_.Ruta })

    # --- 1. Los cebos aparecen -----------------------------------------
    $resumen = Get-ResumenCebos -Cebos (Get-CebosBanco -ArchivosDeSobra $ArchivosDeSobra) `
                                -Raiz $raiz -Propuestas $rutas
    foreach ($fila in $resumen) {
        $detalle = ('{0} de {1}' -f $fila.Encontrados, $fila.Esperados)
        if ($fila.Ejemplos.Count -gt 0) {
            $detalle += ('; falta por ejemplo {0}' -f ($fila.Ejemplos -join ', '))
        }

        if ($fila.EnAnalisis) {
            Write-Veredicto -Que ('el analisis encuentra el cebo {0}' -f $fila.Id) `
                -Bien ($fila.Falta -eq 0) -Detalle $detalle
        } else {
            # No hace fallar, pero se muestra el recuento.
            Write-Host ('  NOTA   el cebo {0} no se espera en el analisis: {1}' -f $fila.Id, $detalle)
            Write-Host ('         {0}' -f $fila.MotivoFuera) -ForegroundColor DarkGray
            if ($fila.Falta -lt $fila.Esperados) {
                # Los paréntesis son imprescindibles: -f tiene más
                # precedencia que +.
                Write-Aviso (('El cebo {0} SI aparece en el analisis, y el catalogo dice que no. ' +
                              'Es una buena noticia: actualiza EnAnalisis en Get-CebosBanco.') -f $fila.Id)
            }
        }
    }

    # --- 2. Nada de perfiles de otros usuarios --------------------------
    # Esta y la siguiente son la comprobación 5.1 del banco, la que detiene
    # todo si falla. No se veta todo C:\Windows porque varios módulos
    # proponen ahí a propósito (Windows Update, registros, WinSxS).
    $carpetaUsuarios = [IO.Path]::GetDirectoryName($env:USERPROFILE)
    Write-Veredicto -Que 'se sabe donde estan los perfiles de usuario' `
        -Bien (-not [string]::IsNullOrWhiteSpace($carpetaUsuarios)) `
        -Detalle ('perfiles en {0}, el propio es {1}' -f $carpetaUsuarios, $env:USERPROFILE)

    $ajenas = @($rutas | Where-Object {
        Test-PerfilAjeno -Ruta $_ -CarpetaUsuarios $carpetaUsuarios -PerfilPropio $env:USERPROFILE
    } | Sort-Object -Unique)
    Write-Veredicto -Que 'no se propone nada del perfil de otro usuario' -Bien ($ajenas.Count -eq 0) `
        -Detalle $(if ($ajenas.Count -eq 0) { 'ninguna de las rutas propuestas cuelga de otro perfil' }
                   else { ($ajenas | Select-Object -First 10) -join ' | ' })

    # --- 3. Nada que la guardia prohíba ---------------------------------
    # Se consulta la guardia por cada candidato que borraría algo;
    # 'Informativo' no borra y 'Comando' no lleva ruta.
    $borrables = @($candidatos | Where-Object {
        $_.Metodo -ne 'Informativo' -and $_.Metodo -ne 'Comando' -and (Test-EsRutaDeVerdad -Texto ([string]$_.Ruta))
    })
    Write-Veredicto -Que 'hay candidatos con ruta real que comprobar' -Bien ($borrables.Count -gt 0) `
        -Detalle ('{0} de {1} candidatos borran algo de una ruta' -f $borrables.Count, $candidatos.Count)

    $prohibidas = [Collections.Generic.List[string]]::new()
    foreach ($candidato in $borrables) {
        $motivo = Get-MotivoIntocable ([string]$candidato.Ruta)
        if ($motivo) { $prohibidas.Add(('{0}  ->  {1}' -f $candidato.Ruta, $motivo)) }
    }
    Write-Veredicto -Que 'la guardia no prohibe ninguna de las rutas propuestas' `
        -Bien ($prohibidas.Count -eq 0) `
        -Detalle $(if ($prohibidas.Count -eq 0) { ('{0} rutas comprobadas una a una' -f $borrables.Count) }
                   else { ($prohibidas | Select-Object -First 10) -join ' | ' })

    # --- 4. DISM en un Windows que no está en castellano ----------------
    # 75-AlmacenComponentes reconoce las etiquetas de DISM en inglés y en
    # castellano; el runner (en inglés) prueba la variante inglesa. Si no
    # la reconoce, el módulo emite "No se ha podido leer la estimación".
    $componentes = @($candidatos | Where-Object { $_.ModuloId -eq 'componentes' })
    if ($componentes.Count -eq 0) {
        Write-Aviso ('el módulo del almacén de componentes no ha dado resultado (necesita administrador): ' +
                     'esta vez no se ha comprobado la lectura de la salida de DISM.')
    } else {
        $ilegible = @($componentes | Where-Object { [string]$_.Nombre -match 'No se ha podido leer la estimaci' })
        Write-Veredicto -Que 'se entiende la salida de DISM en este idioma' `
            -Bien ($ilegible.Count -eq 0) `
            -Detalle ('el módulo ha dicho: {0}' -f (@($componentes | ForEach-Object { $_.Nombre }) -join ' | '))
    }
}

# ---------------------------------------------------------------------
#  FASE windows: lo que solo se puede comprobar sobre NTFS de verdad
# ---------------------------------------------------------------------
function Invoke-FaseWindows {
    [CmdletBinding()]
    param()

    $raiz = Get-RaizDelBanco
    $configuracion = Initialize-Comprobador

    Write-Host ('Windows: {0}' -f $configuracion.Windows) -ForegroundColor Cyan
    Write-Host ('Idioma de la interfaz: {0} | cultura: {1}' -f `
                [Globalization.CultureInfo]::InstalledUICulture.Name,
                [Globalization.CultureInfo]::CurrentCulture.Name) -ForegroundColor Cyan

    # --- La guardia, en el idioma del sistema ---------------------------
    # Test-CarpetaEspejo y Test-ArchivoPersonal usan listas en castellano e
    # inglés; aquí se prueban con los nombres reales de este equipo.
    # El @() exterior evita que una sola carpeta se quede en cadena suelta.
    $carpetas = @(@('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos') |
                  ForEach-Object { Get-CarpetaConocida $_ } |
                  Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    Write-Veredicto -Que 'se han resuelto las carpetas del usuario' -Bien ($carpetas.Count -eq 6) `
        -Detalle (($carpetas | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')

    $sinProteger = @($carpetas | Where-Object { -not (Test-RutaIntocable $_) })
    Write-Veredicto -Que 'la guardia protege las carpetas personales de este idioma' `
        -Bien ($sinProteger.Count -eq 0) -Detalle ($sinProteger -join ' | ')

    # Test-CarpetaEspejo solo se exige para Desktop, Documents y Downloads.
    # Para Imágenes, Música y Vídeos la lista lleva solo los nombres
    # heredados (mypictures...), y no es un hueco: Test-RutaIntocable ya las
    # protege como carpetas personales (comprobación anterior).
    $conNombreIngles = @($carpetas | Where-Object {
        (Split-Path $_ -Leaf) -in @('Desktop', 'Documents', 'Downloads')
    })
    Write-Veredicto -Que 'hay carpetas con nombre ingles que preguntar: si no, esto no comprueba nada' `
        -Bien ($conNombreIngles.Count -eq 3) `
        -Detalle (($carpetas | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')

    $sinEspejo = @($conNombreIngles | Where-Object { -not (Test-CarpetaEspejo (Split-Path $_ -Leaf)) })
    Write-Veredicto -Que 'Test-CarpetaEspejo reconoce los nombres ingleses que dice cubrir' `
        -Bien ($sinEspejo.Count -eq 0) `
        -Detalle $(if ($sinEspejo.Count -eq 0) { 'Desktop, Documents y Downloads estan en la lista bilingue' }
                   else { ('no reconoce: {0}' -f (($sinEspejo | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) })

    # Resultado informativo para las seis carpetas.
    foreach ($carpeta in $carpetas) {
        $hoja = Split-Path $carpeta -Leaf
        Write-Host ('  NOTA   Test-CarpetaEspejo("{0}") = {1}' -f $hoja, (Test-CarpetaEspejo $hoja))
    }

    # SoftwareDistribution\Download termina en "Download": sin la excepción
    # para la carpeta de Windows, el filtro de carpeta personal vetaría la
    # caché de Windows Update.
    $cacheUpdate = Join-Path (Join-Path $env:SystemRoot 'SoftwareDistribution') 'Download'
    $motivo = Get-MotivoIntocable $cacheUpdate
    Write-Veredicto -Que 'la caché de Windows Update no queda vetada por llamarse Download' `
        -Bien ([string]::IsNullOrEmpty($motivo)) -Detalle ('{0} -> "{1}"' -f $cacheUpdate, $motivo)

    $documentos = Get-CarpetaConocida 'Documents'
    $personales = @(
        (Join-Path $documentos 'quarterly report.pdf')
        (Join-Path $documentos 'Document 3.tmp')
        (Join-Path $documentos 'invoice.xlsx')
    )
    $desprotegidos = @($personales | Where-Object { -not (Test-ArchivoPersonal $_) })
    Write-Veredicto -Que 'Test-ArchivoPersonal protege nombres en inglés' `
        -Bien ($desprotegidos.Count -eq 0) -Detalle ($desprotegidos -join ' | ')

    # --- Enlaces duros: dos nombres, un solo contenido ------------------
    $duros = Join-Path $raiz '04-enlaces-duros'
    Write-Veredicto -Que 'esta la carpeta de enlaces duros' -Bien (Test-Path -LiteralPath $duros) `
        -Detalle $duros
    if (Test-Path -LiteralPath $duros) {
        $carpeta = [IO.DirectoryInfo]::new($duros)
        $ingenuo = Get-ResumenArbol -Carpeta $carpeta
        $real    = Get-ResumenArbol -Carpeta $carpeta -ContarEnlacesDuros

        # Se comprueban las dos mediciones: si solo se mirara la buena, una
        # carpeta con 20 MB reales pasaría sin que el conteo hiciera nada.
        Write-Veredicto -Que 'sin contar enlaces duros salen 40 MB' `
            -Bien ([Math]::Abs($ingenuo.Bytes - 40MB) -lt 1MB) `
            -Detalle ('{0:N0} bytes en {1} archivos' -f $ingenuo.Bytes, $ingenuo.Archivos)

        Write-Veredicto -Que 'contándolos salen 20 MB, no 40' `
            -Bien ([Math]::Abs($real.Bytes - 20MB) -lt 1MB) `
            -Detalle ('{0:N0} bytes, {1} archivos, {2} compartidos con otro nombre' -f `
                      $real.Bytes, $real.Archivos, $real.Compartidos)

        Write-Veredicto -Que 'el archivo compartido se reconoce como tal' `
            -Bien ([int]$real.Compartidos -eq 1) -Detalle ('Compartidos = {0}' -f $real.Compartidos)
    }

    # --- Una ruta real de más de 260 caracteres ------------------------
    $cebo = Get-CebosBanco -ArchivosDeSobra $ArchivosDeSobra | Where-Object { $_.Id -eq 'ruta-larga' }
    $rutaLarga = Get-RutaCebo -Cebo $cebo -Raiz $raiz

    Write-Veredicto -Que 'el cebo largo existe y Windows lo considera largo' `
        -Bien ((Test-RutaDemasiadoLarga -Ruta $rutaLarga) -and [IO.File]::Exists('\\?\' + $rutaLarga)) `
        -Detalle ('{0} caracteres' -f $rutaLarga.Length)
    if (-not [IO.File]::Exists('\\?\' + $rutaLarga)) { return }

    # Se mide desde la carpeta corta: la que es larga es su descendiente.
    # Sin el prefijo "\\?\", EnumerateFiles lanzaría PathTooLongException y
    # la medición daría cero sin ningún error visible.
    $carpetaCorta = Join-Path $raiz '02-ruta-larga'
    $esperado = [double]([IO.FileInfo]::new('\\?\' + $rutaLarga).Length)
    $medido   = Measure-Ruta $carpetaCorta

    Write-Veredicto -Que 'se mide un árbol cuyo único archivo pasa de 260 caracteres' `
        -Bien ($medido -eq $esperado) `
        -Detalle ('{0} mide {1:N0} bytes; el cebo pesa {2:N0}' -f $carpetaCorta, $medido, $esperado)

    [void](Initialize-MotorBorrado)

    # Sin -Permanente: la papelera no admite rutas largas. Debe informarse,
    # no borrar de forma permanente sin que el usuario lo haya pedido.
    $script:UltimoError = ''
    $fue = Remove-Elemento -Ruta $rutaLarga -EsCarpeta $false -Confirm:$false
    Write-Veredicto -Que 'una ruta larga no se manda a la papelera' `
        -Bien ((-not $fue) -and [IO.File]::Exists('\\?\' + $rutaLarga)) `
        -Detalle ('devolvio {0}; el archivo {1}' -f $fue,
                  $(if ([IO.File]::Exists('\\?\' + $rutaLarga)) { 'sigue ahi' } else { 'HA DESAPARECIDO' }))

    # Se exige la longitud real en el mensaje: es lo que distingue un
    # mensaje bien formateado de uno con "{0}" literal.
    Write-Veredicto -Que 'y se explica por qué, con la longitud real' `
        -Bien ($script:UltimoError.Contains([string]$rutaLarga.Length) -and
               $script:UltimoError.Contains('260') -and
               $script:UltimoError.Contains('papelera') -and
               -not $script:UltimoError.Contains('{0}')) `
        -Detalle ('"{0}"  (la ruta mide {1})' -f $script:UltimoError, $rutaLarga.Length)

    # Con -Permanente sí se puede, vía System.IO. Va al final: después el
    # cebo ya no existe.
    $script:UltimoError = ''
    $fue = Remove-Elemento -Ruta $rutaLarga -EsCarpeta $false -Permanente -Confirm:$false
    Write-Veredicto -Que 'con borrado permanente sí se borra' `
        -Bien ($fue -and -not [IO.File]::Exists('\\?\' + $rutaLarga)) `
        -Detalle ('devolvio {0}; error "{1}"' -f $fue, $script:UltimoError)
}

# ---------------------------------------------------------------------
#  FASE dosanalisis: dos análisis seguidos en el mismo proceso
# ---------------------------------------------------------------------
function Invoke-FaseDosAnalisis {
    <#
        La ventana reutiliza un runspace entre análisis. Aquí se ejecutan
        los módulos dos veces en el mismo proceso, con el núcleo cargado una
        vez, para detectar estado que sobrevive entre pasadas (cachés sin
        invalidar, listas que se acumulan, módulos registrados dos veces).

        Se omiten los módulos que requieren administrador (DISM tarda
        minutos y no aporta nada aquí).
    #>
    [CmdletBinding()]
    param()

    $configuracion = Initialize-Comprobador
    $modulos = @(Get-ModulosLimpieza -Raiz $RaizProyecto | Where-Object { -not $_.RequiereAdmin })

    Write-Veredicto -Que 'hay modulos que ejecutar dos veces' -Bien ($modulos.Count -gt 0) `
        -Detalle ('{0} modulos sin permisos especiales' -f $modulos.Count)
    if ($modulos.Count -eq 0) { return }

    # Se cuenta por módulo, no solo el total, para que el registro diga qué
    # módulo cambió si las pasadas discrepan.
    $pasadas = @()
    foreach ($vuelta in 1, 2) {
        $sync = New-EstadoSincronizado
        $porModulo = [ordered]@{}
        $errores = [Collections.Generic.List[string]]::new()
        foreach ($modulo in $modulos) {
            $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $configuracion -Sync $sync
            if ($resultado.Error) { $errores.Add(('{0}: {1}' -f $modulo.Id, $resultado.Error)) }
            $porModulo[$modulo.Id] = @($resultado.Candidatos).Count
        }
        $cuenta = 0
        foreach ($valor in $porModulo.Values) { $cuenta += [int]$valor }

        $pasadas += [pscustomobject]@{
            Vuelta    = $vuelta
            Cuenta    = $cuenta
            PorModulo = $porModulo
            Errores   = @($errores)
            Memoria   = [GC]::GetTotalMemory($true)
        }
        Write-Host ('  pasada {0}: {1} candidatos, {2} modulos con error, {3:N0} bytes de memoria administrada' -f `
                    $vuelta, $cuenta, $errores.Count, [GC]::GetTotalMemory($true))
    }

    Write-Veredicto -Que 'la primera pasada encuentra algo' -Bien ($pasadas[0].Cuenta -gt 0) `
        -Detalle ('{0} candidatos repartidos en {1} modulos' -f $pasadas[0].Cuenta, $modulos.Count)

    $cambiados = [Collections.Generic.List[string]]::new()
    foreach ($id in $pasadas[0].PorModulo.Keys) {
        $antes   = [int]$pasadas[0].PorModulo[$id]
        $despues = [int]$pasadas[1].PorModulo[$id]
        if ($antes -ne $despues) { $cambiados.Add(('{0}: {1} -> {2}' -f $id, $antes, $despues)) }
    }
    Write-Veredicto -Que 'la segunda pasada encuentra lo mismo que la primera, modulo a modulo' `
        -Bien ($cambiados.Count -eq 0) `
        -Detalle $(if ($cambiados.Count -eq 0) { ('{0} candidatos las dos veces' -f $pasadas[0].Cuenta) }
                   else { $cambiados -join ' | ' })

    Write-Veredicto -Que 'ningun modulo falla en la segunda pasada habiendo ido bien en la primera' `
        -Bien ($pasadas[1].Errores.Count -le $pasadas[0].Errores.Count) `
        -Detalle (('primera: ' + (@($pasadas[0].Errores) -join ' | ')) + ' || ' +
                  ('segunda: ' + (@($pasadas[1].Errores) -join ' | ')))

    # La memoria solo se informa: el recolector no garantiza cuándo libera,
    # y un umbral daría fallos intermitentes.
    Write-Host ('  NOTA   memoria administrada: {0:N0} -> {1:N0} bytes' -f `
                $pasadas[0].Memoria, $pasadas[1].Memoria)
}

# ---------------------------------------------------------------------
#  FASE inventario / simulacion / limpieza
# ---------------------------------------------------------------------
function Invoke-FaseInventario {
    <#
        Lista todos los archivos de las carpetas del usuario. Se ejecuta
        antes y después de la limpieza real: la diferencia muestra lo que se
        borró de verdad, con independencia de lo que diga el informe.
    #>
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($Salida)) { throw 'Falta -Salida.' }

    $configuracion = Initialize-Comprobador
    $zonas = @($configuracion.ZonasUsuario)
    Write-Veredicto -Que 'hay zonas de usuario que inventariar' -Bien ($zonas.Count -gt 0) `
        -Detalle ($zonas -join ' | ')

    $todo = [Collections.Generic.List[string]]::new()
    foreach ($zona in $zonas) {
        foreach ($archivo in (Get-ArchivosDeVerdad -Carpeta $zona)) { $todo.Add($archivo) }
    }

    [IO.File]::WriteAllLines($Salida, @($todo | Sort-Object -Unique), [Text.UTF8Encoding]::new($false))
    Write-Host ('  {0} archivos inventariados en {1}' -f $todo.Count, $Salida)
}

function Invoke-FaseSimulacion {
    <#
        Red de seguridad antes de borrar. Lo marcado en el informe es
        exactamente lo que borrará "-Consola -Ejecutar"; si algo queda fuera
        del banco, el paso se detiene aquí con el disco intacto.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $Informe)) { throw "No esta el informe: $Informe" }

    $raiz = Get-RaizDelBanco
    $documento = Get-Content -Raw -LiteralPath $Informe | ConvertFrom-Json
    $marcados = @($documento.Candidatos |
                  Where-Object { $_.Seleccionado -and $_.Metodo -ne 'Informativo' })

    Write-Veredicto -Que 'hay algo marcado que borrar' -Bien ($marcados.Count -gt 0) `
        -Detalle ('{0} elementos vienen marcados' -f $marcados.Count)

    $fuera = Get-RutasFueraDelBanco -Rutas @($marcados | ForEach-Object { [string]$_.Ruta }) -Raiz $raiz
    Write-Veredicto -Que 'todo lo marcado esta dentro del banco' -Bien ($fuera.Count -eq 0) `
        -Detalle $(if ($fuera.Count -eq 0) { ('las {0} rutas cuelgan de {1}' -f $marcados.Count, $raiz) }
                   else { ('{0} fuera: {1}' -f $fuera.Count, (($fuera | Select-Object -First 20) -join ' | ')) })
}

function Invoke-FaseLimpieza {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $Antes))   { throw "No esta el inventario previo: $Antes" }
    if (-not (Test-Path -LiteralPath $Despues)) { throw "No esta el inventario posterior: $Despues" }

    $raiz = Get-RaizDelBanco
    $quedan = [Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-Content -LiteralPath $Despues), [StringComparer]::OrdinalIgnoreCase)
    $desaparecidas = @(@(Get-Content -LiteralPath $Antes) | Where-Object { -not $quedan.Contains($_) })

    Write-Veredicto -Que 'la limpieza real ha borrado algo' -Bien ($desaparecidas.Count -gt 0) `
        -Detalle ('han desaparecido {0} archivos' -f $desaparecidas.Count)

    $fuera = Get-RutasFueraDelBanco -Rutas $desaparecidas -Raiz $raiz
    Write-Veredicto -Que 'no ha desaparecido nada de fuera del banco' -Bien ($fuera.Count -eq 0) `
        -Detalle $(if ($fuera.Count -eq 0) { ('las {0} rutas borradas cuelgan de {1}' -f $desaparecidas.Count, $raiz) }
                   else { ('{0} fuera: {1}' -f $fuera.Count, (($fuera | Select-Object -First 20) -join ' | ')) })

    # Y a la inversa: lo que el catálogo marca como premarcado tiene que
    # haberse borrado; si no, una limpieza vacía pasaría lo anterior.
    $borradas = [Collections.Generic.HashSet[string]]::new(
        [string[]]$desaparecidas, [StringComparer]::OrdinalIgnoreCase)

    foreach ($cebo in (Get-CebosBanco -ArchivosDeSobra $ArchivosDeSobra)) {
        if (-not $cebo.Premarcado) { continue }

        # EnLimpieza es independiente de EnAnalisis: el cebo de ruta larga se
        # propone en el análisis, pero no desaparece aquí (la fase windows ya
        # lo borró y la papelera no admite rutas de más de 260 caracteres).
        if (-not $cebo.EnAnalisis -or -not $cebo.EnLimpieza) {
            Write-Host ('  NOTA   el cebo {0} no se espera en la limpieza real' -f $cebo.Id)
            Write-Host ('         {0}' -f $cebo.MotivoFuera) -ForegroundColor DarkGray
            continue
        }

        $siguen = [Collections.Generic.List[string]]::new()
        for ($n = 1; $n -le [int]$cebo.Cuantos; $n++) {
            $ruta = Get-RutaCebo -Cebo $cebo -Raiz $raiz -Indice $n
            if (-not $borradas.Contains($ruta)) { $siguen.Add($ruta) }
        }
        Write-Veredicto -Que ('el cebo premarcado {0} se ha borrado entero' -f $cebo.Id) `
            -Bien ($siguen.Count -eq 0) `
            -Detalle ('siguen {0} de {1}{2}' -f $siguen.Count, $cebo.Cuantos,
                      $(if ($siguen.Count -gt 0) { ': ' + (($siguen | Select-Object -First 5) -join ' | ') } else { '' }))
    }
}

# ---------------------------------------------------------------------
#  Ejecución
# ---------------------------------------------------------------------

Write-Host ''
Write-Host ('=== Banco de pruebas: fase {0} ===' -f $Fase) -ForegroundColor Cyan

switch ($Fase) {
    'montaje'     { Invoke-FaseMontaje }
    'analisis'    { Invoke-FaseAnalisis }
    'windows'     { Invoke-FaseWindows }
    'dosanalisis' { Invoke-FaseDosAnalisis }
    'inventario'  { Invoke-FaseInventario }
    'simulacion'  { Invoke-FaseSimulacion }
    'limpieza'    { Invoke-FaseLimpieza }
}

Write-Host ''
if ($script:Fallos.Count -gt 0) {
    Write-Host ('{0} comprobaciones han fallado:' -f $script:Fallos.Count) -ForegroundColor Red
    foreach ($fallo in $script:Fallos) { Write-Host ('  - {0}' -f $fallo) -ForegroundColor Red }
    exit 1
}
Write-Host 'Todo lo comprobado en esta fase cuadra.' -ForegroundColor Green
exit 0
