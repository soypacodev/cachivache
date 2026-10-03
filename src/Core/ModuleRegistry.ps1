<#
.SYNOPSIS
    Descubrimiento y ejecución de los módulos de limpieza.

.DESCRIPTION
    Cada archivo de src/Modules termina devolviendo un objeto creado con
    New-ModuloLimpieza. Para añadir una categoría nueva basta con dejar
    caer un archivo en esa carpeta: no hay ninguna lista que mantener.
#>

function Get-RaizProyecto {
    <#
    .SYNOPSIS
        Carpeta raíz del repositorio, calculada desde este archivo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

function Get-ModulosLimpieza {
    <#
    .SYNOPSIS
        Carga y devuelve todos los módulos de limpieza, ordenados.
    #>
    [CmdletBinding()]
    param([string] $Raiz = (Get-RaizProyecto))

    $carpeta = Join-Path (Join-Path $Raiz 'src') 'Modules'
    if (-not (Test-Path -LiteralPath $carpeta)) { return @() }

    $modulos = [Collections.Generic.List[object]]::new()
    foreach ($archivo in (Get-ChildItem -LiteralPath $carpeta -Filter '*.ps1' -File | Sort-Object Name)) {
        try {
            # Se toma el último objeto con aspecto de módulo: si el archivo
            # deja escapar otra salida, el resultado es un array y el módulo
            # se descartaría.
            $modulo = @(. $archivo.FullName) |
                      Where-Object { $null -ne $_ -and $_.PSObject.Properties['Buscar'] } |
                      Select-Object -Last 1

            if ($null -ne $modulo -and $modulo.PSObject.Properties['Buscar']) {
                # Con la ruta del archivo, el hilo de análisis puede cargar
                # solo este módulo.
                $modulo | Add-Member -NotePropertyName 'Archivo' `
                                     -NotePropertyValue $archivo.FullName -Force
                $modulos.Add($modulo)
            } else {
                Write-Warning "El archivo $($archivo.Name) no devuelve un módulo válido."
            }
        } catch {
            Write-Warning "No se ha podido cargar $($archivo.Name): $($_.Exception.Message)"
        }
    }
    return @($modulos | Sort-Object Orden)
}

function Get-ModuloLimpieza {
    <#
    .SYNOPSIS
        Devuelve un único módulo por su identificador.
    .DESCRIPTION
        Pensada para las pruebas. Carga todos los módulos y después filtra,
        por eso el hilo de análisis no la usa y carga directamente el
        archivo de cada módulo (ver Window.Analisis.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $Raiz = (Get-RaizProyecto)
    )
    return (Get-ModulosLimpieza -Raiz $Raiz | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Get-ReglasFiltroCandidato {
    <#
    .SYNOPSIS
        Reglas que el embudo aplica a todos los candidatos de todos los
        módulos: nombre, coste y predicado.

    .DESCRIPTION
        Las reglas son datos: el embudo recorre la lista entera, de modo que
        añadir una regla es añadir un elemento. tests/Embudo.Tests.ps1 exige
        un caso de prueba que demuestre que cada regla se aplica.

        Contrato de una regla:
        - Nombre: único; para pruebas y legibilidad.
        - Coste: 0 = no mira el candidato, 1 = solo memoria, 2 = consulta
          el disco.
        - Predicado: recibe dos parámetros (el contexto de
          New-ContextoEmbudo y el candidato) y devuelve $true para
          conservarlo. Se aplica siempre así:

              @($candidatos) | Where-Object { & $regla.Predicado $contexto $_ }

        El candidato se pasa como parámetro y no en $_: que $_ atraviese el
        operador "&" depende de la afinidad de sesión del scriptblock y
        puede variar entre PowerShell 5.1 y 7. Si no llegara, el embudo
        descartaría todos los candidatos sin error. Una invariante prohíbe
        usar $_ en los predicados.

        Se usa un contexto y no cierres (.GetNewClosure()): un cierre se
        ejecuta en un módulo dinámico donde no se ven las funciones del
        núcleo, que no son globales (se cargan con dot-source de
        Bootstrap.ps1).

        Una regla solo puede descartar candidatos, nunca añadirlos.

        El orden no afecta al resultado (los predicados son puros y lo que
        sobrevive es la intersección), pero sí al coste: van de más barata a
        más cara, y la guardia, la única que consulta el disco, va la
        última. Hay pruebas de ambas cosas.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $reglas = [Collections.Generic.List[object]]::new()

    # Regla 0. Defensa en profundidad frente a un $null: leer $null.Ruta no
    # lanza, y produciría un candidato fantasma en lugar de un error.
    $reglas.Add([pscustomobject]@{
        Nombre    = 'Candidato existente'
        Coste     = 0
        Predicado = { param($Contexto, $Candidato) $null -ne $Candidato }
    })

    # Regla 1. Unidades que el usuario ha desmarcado.
    $reglas.Add([pscustomobject]@{
        Nombre    = 'Unidad seleccionada'
        Coste     = 1
        Predicado = {
            param($Contexto, $Candidato)
            Test-UnidadSeleccionada -Ruta $Candidato.Ruta -Configuracion $Contexto.Configuracion
        }
    })

    # Regla 2. Exclusiones del usuario. Se compara ClaveExclusion y no Ruta:
    # lo que no tiene ruta real se compara de forma exacta, no por prefijo.
    $reglas.Add([pscustomobject]@{
        Nombre    = 'Exclusiones del usuario'
        Coste     = 1
        Predicado = {
            param($Contexto, $Candidato)
            if ($Contexto.Excluidas.Count -eq 0) { return $true }
            return -not (Test-ClaveExcluida -Clave $Candidato.ClaveExclusion -Excluidas $Contexto.Excluidas)
        }
    })

    # Regla 2 bis. Las unidades extraíbles se analizan pero no se borran:
    # pueden desconectarse a mitad de una operación. Es una regla aparte de
    # Test-UnidadSeleccionada porque esa decide qué se analiza, y mezclarlas
    # sacaría la extraíble también del análisis.
    $reglas.Add([pscustomobject]@{
        Nombre    = 'Unidad donde se puede borrar'
        Coste     = 1
        Predicado = {
            param($Contexto, $Candidato)
            # Lo que no tiene ruta con letra (comandos, papelera,
            # informativos) se conserva, igual que en la regla 1.
            if ($Contexto.SinRuta -contains $Candidato.Metodo) { return $true }
            $letra = Get-LetraUnidad -Ruta $Candidato.Ruta
            if ([string]::IsNullOrWhiteSpace($letra)) { return $true }
            return -not $Contexto.NoBorrables.Contains($letra)
        }
    })

    # Regla 3. Guardia de rutas: se aplica a todo candidato que borre
    # archivos. Es la única que consulta el disco, por eso va la última.
    $reglas.Add([pscustomobject]@{
        Nombre    = 'Guardia de rutas'
        Coste     = 2
        Predicado = {
            param($Contexto, $Candidato)
            if ($Contexto.SinRuta -contains $Candidato.Metodo) { return $true }
            return (Test-RutaSegura -Ruta $Candidato.Ruta -Raices $Candidato.Raices `
                                    -PermitirPersonales:$Candidato.PermitirPersonales)
        }
    })

    return @($reglas)
}

function New-ContextoEmbudo {
    <#
    .SYNOPSIS
        Datos que necesitan las reglas del embudo, calculados una vez por
        módulo en lugar de una vez por candidato.

    .DESCRIPTION
        Cálculo puro: solo lee la configuración. Evita repetir trabajo en
        cada predicado (que puede ejecutarse cientos de miles de veces) y
        permite probar cada regla de forma aislada.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Solo construye un objeto en memoria: no cambia el estado de nada.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # AllowNull: el modo consola y varias pruebas llaman al embudo sin
        # configuración.
        [Parameter(Mandatory)] [AllowNull()] $Configuracion
    )

    # Métodos que no actúan directamente sobre el sistema de archivos
    # (informativos, papelera y comandos de Windows): se validan por otras
    # vías y no tienen una ruta que comprobar.
    $sinRuta = @('Informativo', 'Papelera', 'Comando')

    $excluidas = @()
    if ($null -ne $Configuracion -and $Configuracion.PSObject.Properties['RutasExcluidas']) {
        $excluidas = @($Configuracion.RutasExcluidas)
    }

    # Letras que no admiten candidatos borrables. Se guardan las prohibidas
    # y no las permitidas para que una unidad desconocida (p. ej. conectada
    # después de arrancar) mantenga el comportamiento normal.
    $noBorrables = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Configuracion -and $Configuracion.PSObject.Properties['Unidades']) {
        foreach ($unidad in @($Configuracion.Unidades)) {
            if ($null -eq $unidad) { continue }
            if (-not $unidad.PSObject.Properties['Borrable']) { continue }
            if (-not $unidad.Borrable) { [void]$noBorrables.Add([string]$unidad.Letra) }
        }
    }

    return [pscustomobject]@{
        Configuracion = $Configuracion
        Excluidas     = $excluidas
        SinRuta       = $sinRuta
        NoBorrables   = $noBorrables
    }
}

function Invoke-ModuloLimpieza {
    <#
    .SYNOPSIS
        Ejecuta la búsqueda de un módulo y devuelve sus candidatos.
    .DESCRIPTION
        Aísla los fallos: si un módulo lanza, se informa del error y el
        análisis continúa. Los resultados pasan por todas las reglas de
        Get-ReglasFiltroCandidato.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Modulo,
        [Parameter(Mandatory)] $Configuracion,
        $Sync = $null
    )

    # Las dos salidas de esta función devuelven exactamente los mismos campos.
    if ($Modulo.RequiereAdmin -and -not $Configuracion.Admin) {
        return [pscustomobject]@{
            ModuloId    = $Modulo.Id
            Candidatos  = @()
            Error       = ''
            Omitido     = 'Necesita permisos de administrador.'
            Descartados = 0
        }
    }

    # Se acumula candidato a candidato: con "$c = @(& $Modulo.Buscar ...)",
    # una excepción a mitad perdería también lo ya emitido. Se guarda la
    # primera línea de la traza para poder localizar el error.
    $recogidos = [Collections.Generic.List[object]]::new()
    $error1    = ''

    try {
        & $Modulo.Buscar $Configuracion $Sync | ForEach-Object {
            if ($null -ne $_) { $recogidos.Add($_) }
        }
    } catch {
        $error1 = $_.Exception.Message
        if ($_.ScriptStackTrace) {
            $error1 += " (en $($_.ScriptStackTrace -split "`n" | Select-Object -First 1))"
        }
    }

    $candidatos = @($recogidos)

    # El embudo: único punto por el que pasan todos los candidatos, para
    # que ningún módulo pueda saltarse los filtros. Se aplica la lista
    # entera de reglas.
    $contexto = New-ContextoEmbudo -Configuracion $Configuracion
    $validos  = @($candidatos)
    foreach ($regla in (Get-ReglasFiltroCandidato)) {
        $validos = @($validos | Where-Object { & $regla.Predicado $contexto $_ })
    }

    return [pscustomobject]@{
        ModuloId    = $Modulo.Id
        Candidatos  = @($validos | Sort-Object Bytes -Descending)
        Error       = $error1
        Omitido     = ''
        Descartados = $candidatos.Count - $validos.Count
    }
}

function New-EstadoSincronizado {
    <#
    .SYNOPSIS
        Crea la tabla compartida entre la interfaz y el hilo de análisis.
    .DESCRIPTION
        ColaRegistro es una ConcurrentQueue: la interfaz y el runspace de
        análisis/borrado encolan líneas ya formateadas y solo el
        temporizador de la interfaz las escribe a disco (con
        Invoke-VaciarColaRegistro). Así se evitan violaciones de uso
        compartido y líneas de auditoría perdidas durante el borrado.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Crea una tabla hash en memoria.')]
    [CmdletBinding()]
    param()
    return [hashtable]::Synchronized(@{
        Mensaje      = ''
        Terminado    = $true
        Cancelar     = $false
        Resultado    = $null
        Error        = ''
        ColaRegistro = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    })
}
