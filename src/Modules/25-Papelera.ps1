<#
.SYNOPSIS
    Papelera de reciclaje.
.DESCRIPTION
    Se mide lo que ocupa en cada unidad fija. Vaciarla es irreversible, así
    que nunca viene marcado por defecto y se avisa de cuántos elementos hay.
#>

$BuscarPapelera = {
    param($Configuracion, $Sync)

    Set-Progreso $Sync 'Midiendo la papelera de reciclaje...'

    $totalBytes = 0.0
    $totalElementos = 0
    $detallePorUnidad = @()
    $letrasConContenido = @()

    # Solo las unidades seleccionadas y borrables. El filtro central de
    # ModuleRegistry.ps1 no basta: mira la Ruta del candidato (una sola
    # unidad), pero el vaciado actúa sobre todas las letras que se le pasan.
    # El filtro tiene que estar aquí, donde se decide qué letras se miden y
    # se vacían; si no, se vaciaría la papelera de un disco externo sin
    # pedirlo. Se usa Borrable (no Clase) porque Get-UnidadesAnalizables ya
    # traduce la clase en un único sitio.
    $unidades = @($Configuracion.Unidades | Where-Object {
        if ($_.PSObject.Properties['Borrable'] -and -not $_.Borrable) { return $false }
        Test-UnidadSeleccionada -Ruta ($_.Letra + '\') -Configuracion $Configuracion
    })

    foreach ($unidad in $unidades) {
        if (Test-Cancelacion $Sync) { break }
        $ruta = Join-Path ($unidad.Letra + '\') '$Recycle.Bin'
        if (-not (Test-Path -LiteralPath $ruta)) { continue }

        $bytes = 0.0
        $elementos = 0
        $raizPapelera = $ruta.TrimEnd('\')
        # Get-ElementosDelArbol y no Get-ChildItem -Recurse, por las rutas
        # largas: $Recycle.Bin conserva la profundidad original de lo borrado.
        Get-ElementosDelArbol -Ruta $ruta |
            ForEach-Object {
                # Los archivos $I son metadatos del propio contenedor: uno por
                # elemento borrado, en la carpeta de cada usuario ($Recycle.Bin\<SID>).
                if ($_.Name -like '$I*') {
                    $carpetaUsuario = Split-Path $_.DirectoryName -Parent
                    if ($carpetaUsuario -and $carpetaUsuario.TrimEnd('\') -ieq $raizPapelera) { $elementos++ }
                } else {
                    $bytes += [double]$_.Length
                }
            }
        if ($bytes -le 0) { continue }

        $totalBytes += $bytes
        $totalElementos += $elementos
        $detallePorUnidad += ('{0} {1}' -f $unidad.Letra, (Format-Tamano $bytes))
        $letrasConContenido += $unidad.Letra
    }

    # El recuento sale de los $I de las unidades medidas, no del shell: la
    # papelera del shell junta todas las unidades, también las no marcadas.

    if ($totalBytes -lt 1MB) { return }

    $info = if ($totalElementos -gt 0) { "$totalElementos elementos" } else { 'contenido de la papelera' }
    if ($detallePorUnidad.Count -gt 1) { $info += ' - ' + ($detallePorUnidad -join ', ') }

    # La ruta del candidato debe estar en una unidad marcada (el filtro
    # central la mira): se usa la primera marcada que tiene contenido, no
    # siempre la del sistema.
    $letraCandidato = if ($letrasConContenido.Count -gt 0) { $letrasConContenido[0] }
                      else { $Configuracion.Unidad }

    New-Candidato -ModuloId 'papelera' -Categoria 'Papelera de reciclaje' `
                  -Nombre 'Vaciar la papelera de reciclaje' `
                  -Ruta (Join-Path ($letraCandidato + '\') '$Recycle.Bin') `
                  -Bytes $totalBytes -Info $info `
                  -Efecto 'Libera el espacio de todo lo que ya habías borrado.' `
                  -Aviso 'Irreversible: después de esto no se puede restaurar nada de la papelera.' `
                  -Metodo 'Papelera' -Raices @() -Riesgo 'Medio' -Preseleccionado $false
}

New-ModuloLimpieza -Id 'papelera' -Orden 25 `
    -Nombre 'Papelera de reciclaje' `
    -Descripcion 'Lo que ya borraste sigue ocupando disco hasta que se vacía la papelera. Vaciarla es irreversible.' `
    -Riesgo 'Medio' `
    -Perfiles @('conservador', 'equilibrado', 'agresivo') `
    -Buscar $BuscarPapelera
