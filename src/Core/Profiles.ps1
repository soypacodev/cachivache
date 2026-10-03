<#
.SYNOPSIS
    Perfiles de limpieza: conjuntos de umbrales y módulos preconfigurados.
#>

$script:PerfilesDisponibles = @(
    [pscustomobject]@{
        Id          = 'conservador'
        Nombre      = 'Conservador'
        Resumen     = 'Solo lo que el sistema vuelve a crear solo.'
        Descripcion = @'
Toca únicamente cachés y temporales que cualquier programa regenera sin
intervención. No propone nada que dependa de un juicio sobre si algo se usa
o no. Es la opción recomendada si es la primera vez que ejecutas el programa.
'@
        DiasSinUso        = 365
        MinimoMB          = 50
        MinimoGrandeMB    = 250
        MinimoDuplicadoMB = 5
        IncluirMenores    = $false
        Permanente        = $false
        Color             = '#3DD68C'
    }
    [pscustomobject]@{
        Id          = 'equilibrado'
        Nombre      = 'Equilibrado'
        Resumen     = 'Cachés, restos de programas y descargas antiguas.'
        Descripcion = @'
Añade los restos de programas desinstalados, los instaladores viejos de la
carpeta Descargas y las carpetas regenerables de proyectos. Todo lo que
implique una decisión aparece marcado en rojo y sin seleccionar.
'@
        DiasSinUso        = 180
        MinimoMB          = 10
        MinimoGrandeMB    = 250
        MinimoDuplicadoMB = 5
        IncluirMenores    = $false
        Permanente        = $false
        Color             = '#4C8DFF'
    }
    [pscustomobject]@{
        Id          = 'agresivo'
        Nombre      = 'Exhaustivo'
        Resumen     = 'Analiza todo, incluidos duplicados y archivos grandes.'
        Descripcion = @'
Activa todos los módulos, baja los umbrales y busca además duplicados por
hash y archivos grandes sin abrir. Tarda bastante más y encuentra muchísimo
más, pero exige revisar la lista con calma antes de eliminar nada.
'@
        DiasSinUso        = 90
        MinimoMB          = 1
        # Archivos grandes no levanta ningún veto de la guardia: bajar el
        # umbral solo amplía lo que se muestra.
        MinimoGrandeMB    = 100
        # Duplicados es el único módulo que levanta el veto por extensión
        # personal (garantiza que existe otra copia). Su umbral baja poco a
        # propósito: cuanto más bajo, más documentos y fotos entran.
        MinimoDuplicadoMB = 3
        IncluirMenores    = $true
        Permanente        = $false
        Color             = '#F5A524'
    }
    [pscustomobject]@{
        Id          = 'personalizado'
        Nombre      = 'Personalizado'
        Resumen     = 'Tus propios umbrales y tu propia selección de módulos.'
        Descripcion = @'
Mantiene exactamente lo que hayas configurado en la pestaña de ajustes y
la selección de módulos que dejaste la última vez.
'@
        DiasSinUso        = 180
        MinimoMB          = 10
        MinimoGrandeMB    = 250
        MinimoDuplicadoMB = 5
        IncluirMenores    = $false
        Permanente        = $false
        Color             = '#8A93A6'
    }
)

function Get-PerfilesLimpieza {
    <#
    .SYNOPSIS
        Devuelve la lista de perfiles disponibles.
    #>
    [CmdletBinding()]
    param()
    return $script:PerfilesDisponibles
}

function Get-PerfilLimpieza {
    <#
    .SYNOPSIS
        Busca un perfil por su identificador.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id)

    $perfil = $script:PerfilesDisponibles | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -eq $perfil) {
        $perfil = $script:PerfilesDisponibles | Where-Object { $_.Id -eq 'equilibrado' } | Select-Object -First 1
    }
    return $perfil
}

function Set-PerfilConfiguracion {
    <#
    .SYNOPSIS
        Aplica los umbrales de un perfil sobre un objeto de configuración.
    .DESCRIPTION
        El perfil "personalizado" respeta lo que ya hubiera configurado el
        usuario y por tanto no sobreescribe nada.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Modifica un objeto en memoria que recibe por parámetro.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Configuracion,
        [Parameter(Mandatory)] [string] $Perfil
    )

    $Configuracion.Perfil = $Perfil
    if ($Perfil -eq 'personalizado') { return $Configuracion }

    # Se copian todos los umbrales que declara el perfil.
    $datos = Get-PerfilLimpieza $Perfil
    $Configuracion.DiasSinUso        = $datos.DiasSinUso
    $Configuracion.MinimoMB          = $datos.MinimoMB
    $Configuracion.MinimoGrandeMB    = $datos.MinimoGrandeMB
    $Configuracion.MinimoDuplicadoMB = $datos.MinimoDuplicadoMB
    $Configuracion.IncluirMenores    = $datos.IncluirMenores
    $Configuracion.Permanente        = $datos.Permanente
    return $Configuracion
}

function Test-ModuloEnPerfil {
    <#
    .SYNOPSIS
        Indica si un módulo forma parte de un perfil.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Modulo,
        [Parameter(Mandatory)] [string] $Perfil
    )

    if ($Perfil -eq 'personalizado') { return $true }
    return $Modulo.Perfiles -contains $Perfil
}
