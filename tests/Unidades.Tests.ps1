<#
    Selección de unidades a analizar.

    El filtro vive en ModuleRegistry.ps1, por donde pasan los candidatos de
    todos los módulos, para que ninguno pueda saltárselo. Se comprueba que
    excluye lo que debe y que no oculta nada cuando no hay exclusión.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio = ''; Documentos = ''; Descargas = ''
        Imagenes   = ''; Musica     = ''; Videos     = ''; CarpetaDatos = ''
    })
}

Describe 'Get-LetraUnidad' {

    It 'saca la letra de "<Ruta>"' -ForEach @(
        @{ Ruta = 'C:\Users\x\algo'; Esperado = 'C:' }
        @{ Ruta = 'd:\otra\cosa';    Esperado = 'D:' }
        @{ Ruta = 'C:';              Esperado = 'C:' }
    ) { Get-LetraUnidad $Ruta | Should -Be $Esperado }

    It 'devuelve vacio cuando no hay unidad que sacar: "<Ruta>"' -ForEach @(
        @{ Ruta = '' }
        @{ Ruta = '\\servidor\recurso\algo' }   # red
        @{ Ruta = 'docker system prune' }       # etiqueta del método Comando
        @{ Ruta = 'carpeta\relativa' }
    ) { Get-LetraUnidad $Ruta | Should -BeNullOrEmpty }
}

Describe 'Test-UnidadSeleccionada' {

    It 'acepta una ruta de una unidad elegida' {
        $cfg = [pscustomobject]@{ UnidadesSeleccionadas = @('C:', 'D:') }
        Test-UnidadSeleccionada -Ruta 'C:\Users\x\cache' -Configuracion $cfg | Should -BeTrue
    }

    It 'rechaza una ruta de una unidad excluida' {
        $cfg = [pscustomobject]@{ UnidadesSeleccionadas = @('C:') }
        Test-UnidadSeleccionada -Ruta 'D:\datos\cache' -Configuracion $cfg | Should -BeFalse
    }

    It 'no distingue mayusculas de minusculas ni el formato de la letra' {
        $cfg = [pscustomobject]@{ UnidadesSeleccionadas = @('c:\') }
        Test-UnidadSeleccionada -Ruta 'C:\algo' -Configuracion $cfg | Should -BeTrue
    }

    Context 'Ante la duda, NO filtra: equivocarse hacia "no" borraria candidatos legitimos de la lista' {

        It 'lista vacia significa "todas las unidades"' {
            $cfg = [pscustomobject]@{ UnidadesSeleccionadas = @() }
            Test-UnidadSeleccionada -Ruta 'Z:\lo\que\sea' -Configuracion $cfg | Should -BeTrue
        }

        It 'una configuracion sin el campo (modo consola, config antigua) no filtra nada' {
            $cfg = [pscustomobject]@{ Perfil = 'equilibrado' }
            Test-UnidadSeleccionada -Ruta 'D:\algo' -Configuracion $cfg | Should -BeTrue
        }

        It 'sin configuracion tampoco filtra' {
            Test-UnidadSeleccionada -Ruta 'D:\algo' -Configuracion $null | Should -BeTrue
        }

        It 'una ruta sin letra de unidad no se filtra: no hay unidad que excluir' {
            $cfg = [pscustomobject]@{ UnidadesSeleccionadas = @('C:') }
            Test-UnidadSeleccionada -Ruta 'docker system prune'      -Configuracion $cfg | Should -BeTrue
            Test-UnidadSeleccionada -Ruta '\\servidor\recurso'       -Configuracion $cfg | Should -BeTrue
        }
    }
}

Describe 'El filtro se aplica en el nucleo, no modulo a modulo' {
    <#
        Se comprueba el punto central con un módulo falso: cualquier módulo
        nuevo queda cubierto sin pruebas adicionales.
    #>

    BeforeAll {
        # No se pueden fabricar carpetas en dos unidades reales, así que el
        # módulo emite candidatos Informativos, exentos de la guardia de
        # rutas: solo el filtro de unidad puede hacerlos desaparecer.
        $script:ModuloFalso = New-ModuloLimpieza -Id 'prueba' -Orden 99 `
            -Nombre 'Modulo de prueba' -Descripcion 'Solo para las pruebas.' `
            -Buscar {
                param($Configuracion, $Sync)
                New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'en C' `
                              -Ruta 'C:\carpeta\en-c' -Metodo 'Informativo' -Raices @()
                New-Candidato -ModuloId 'prueba' -Categoria 'c' -Nombre 'en D' `
                              -Ruta 'D:\carpeta\en-d' -Metodo 'Informativo' -Raices @()
            }
    }

    It 'con las dos unidades elegidas salen los dos candidatos' {
        $cfg = [pscustomobject]@{ Admin = $true; UnidadesSeleccionadas = @('C:', 'D:') }
        $r = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $cfg
        $r.Candidatos.Count | Should -Be 2
    }

    It 'al excluir D: desaparece su candidato y sobrevive el de C:' {
        $cfg = [pscustomobject]@{ Admin = $true; UnidadesSeleccionadas = @('C:') }
        $r = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $cfg

        $r.Candidatos.Count | Should -Be 1
        $r.Candidatos[0].Ruta | Should -Be 'C:\carpeta\en-c'
    }

    It 'excluir una unidad NO puede añadir candidatos, solo quitarlos' {
        $todas    = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso `
                        -Configuracion ([pscustomobject]@{ Admin = $true; UnidadesSeleccionadas = @('C:', 'D:') })
        $filtrado = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso `
                        -Configuracion ([pscustomobject]@{ Admin = $true; UnidadesSeleccionadas = @('C:') })

        $filtrado.Candidatos.Count | Should -BeLessOrEqual $todas.Candidatos.Count
        foreach ($c in $filtrado.Candidatos) {
            @($todas.Candidatos | ForEach-Object { $_.Ruta }) | Should -Contain $c.Ruta
        }
    }

    It 'una configuracion sin el campo se comporta como antes de existir esta funcion' {
        $cfg = [pscustomobject]@{ Admin = $true }
        $r = Invoke-ModuloLimpieza -Modulo $script:ModuloFalso -Configuracion $cfg
        $r.Candidatos.Count | Should -Be 2
    }
}

Describe 'La papelera vacia exactamente lo que midio' {
    <#
        Caso que el filtro central no cubre: el candidato de la papelera
        vive en la unidad del sistema y pasa el filtro aunque haya medido
        papeleras de discos excluidos. Vaciar de más borraría datos de una
        unidad que el usuario excluyó.
    #>

    BeforeAll {
        # Clear-RecycleBin solo existe en Windows y Mock exige que el
        # comando exista: se declara un sustituto para la CI de Linux.
        $script:HabiaClearRecycleBin = [bool](Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue)
        if (-not $script:HabiaClearRecycleBin) {
            function global:Clear-RecycleBin {
                param([string] $DriveLetter, [switch] $Force)
            }
        }
    }

    AfterAll {
        # Se retira para que otras pruebas no crean que el equipo sabe
        # vaciar la papelera.
        if (-not $script:HabiaClearRecycleBin) {
            Remove-Item -Path 'function:global:Clear-RecycleBin' -ErrorAction SilentlyContinue
        }
    }

    It 'Clear-Papelera vacia solo las unidades que se le pasan' {
        Mock Clear-RecycleBin {}
        Clear-Papelera -Unidades @('C:', 'E:') -Confirm:$false | Out-Null

        Should -Invoke Clear-RecycleBin -Times 2 -Exactly
        Should -Invoke Clear-RecycleBin -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'C' }
        Should -Invoke Clear-RecycleBin -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'E' }
    }

    It 'sin lista, las vacia todas: es el comportamiento de siempre' {
        Mock Clear-RecycleBin {}
        Clear-Papelera -Confirm:$false | Out-Null

        Should -Invoke Clear-RecycleBin -Times 1 -Exactly
        Should -Invoke Clear-RecycleBin -Times 0 -Exactly -ParameterFilter { $null -ne $DriveLetter }
    }

    It 'una unidad que falla no impide intentar las demas, pero SI se informa del fallo' {
        # Debe seguir con las demás unidades y, a la vez, no devolver éxito:
        # si no, el candidato se marcaría como hecho con la papelera llena.
        Mock Clear-RecycleBin { throw 'sin permisos' } -ParameterFilter { $DriveLetter -eq 'C' }
        Mock Clear-RecycleBin {}                        -ParameterFilter { $DriveLetter -eq 'D' }

        Clear-Papelera -Unidades @('C:', 'D:') -Confirm:$false |
            Should -BeFalse -Because 'una unidad que no se ha podido vaciar no es un exito'
        Should -Invoke Clear-RecycleBin -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'D' }
    }

    It 'cuando todas las unidades se vacian bien, devuelve exito' {
        Mock Clear-RecycleBin {}

        Clear-Papelera -Unidades @('C:', 'D:') -Confirm:$false | Should -BeTrue
        Should -Invoke Clear-RecycleBin -Times 2 -Exactly
    }

    It 'un fallo al vaciar deja el motivo en el candidato y no lo da por hecho' {
        Mock Clear-Papelera { $false }
        Mock Measure-Ruta { 0 }

        $candidato = New-Candidato -ModuloId 'papelera' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\$Recycle.Bin' -Metodo 'Papelera'
        Invoke-EliminacionCandidato -Candidato $candidato -Confirm:$false | Out-Null

        $candidato.Hecho | Should -BeFalse -Because 'no se vacio: decir que si es mentirle al usuario y al informe'
    }

    It 'Invoke-EliminacionCandidato le pasa las unidades elegidas' {
        Mock Clear-Papelera { $true }
        Mock Measure-Ruta { 0 }

        $candidato = New-Candidato -ModuloId 'papelera' -Categoria 'c' -Nombre 'n' `
                                   -Ruta 'C:\$Recycle.Bin' -Metodo 'Papelera'
        $cfg = [pscustomobject]@{ UnidadesSeleccionadas = @('C:') }

        Invoke-EliminacionCandidato -Candidato $candidato -Configuracion $cfg -Confirm:$false | Out-Null

        Should -Invoke Clear-Papelera -Times 1 -Exactly -ParameterFilter { $Unidades -contains 'C:' }
    }
}
