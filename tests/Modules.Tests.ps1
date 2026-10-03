<#
    Pruebas del contrato de los módulos.

    No se ejecuta ninguna búsqueda de verdad: se comprueba que todos los
    módulos están bien declarados y que el registro los descubre.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
    $script:Modulos = @(Get-ModulosLimpieza -Raiz $script:Raiz)
}

Describe 'Descubrimiento de modulos' {

    It 'encuentra modulos en src/Modules' {
        $script:Modulos.Count | Should -BeGreaterThan 0
    }

    It 'no repite ningun identificador' {
        $repetidos = @($script:Modulos | Group-Object Id | Where-Object { $_.Count -gt 1 })
        $repetidos.Count | Should -Be 0
    }

    It 'no repite ningun numero de orden' {
        $repetidos = @($script:Modulos | Group-Object Orden | Where-Object { $_.Count -gt 1 })
        $repetidos.Count | Should -Be 0
    }

    It 'los devuelve ordenados' {
        $ordenes = @($script:Modulos | ForEach-Object { $_.Orden })
        $ordenes | Should -Be @($ordenes | Sort-Object)
    }

    It 'hay un archivo por modulo' {
        $archivos = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $script:Raiz 'src') 'Modules') -Filter '*.ps1')
        $script:Modulos.Count | Should -Be $archivos.Count
    }
}

Describe 'Contrato de cada modulo' {

    It 'todos declaran las propiedades obligatorias' {
        foreach ($modulo in $script:Modulos) {
            foreach ($propiedad in @('Id', 'Nombre', 'Descripcion', 'Orden', 'Riesgo', 'Perfiles', 'Buscar')) {
                $modulo.PSObject.Properties[$propiedad] | Should -Not -BeNullOrEmpty `
                    -Because "el modulo $($modulo.Id) debe declarar $propiedad"
            }
        }
    }

    It 'todos tienen un identificador en minusculas y sin espacios' {
        foreach ($modulo in $script:Modulos) {
            $modulo.Id | Should -MatchExactly '^[a-z]+$' -Because "identificador del modulo $($modulo.Id)"
        }
    }

    It 'todos declaran un riesgo valido' {
        foreach ($modulo in $script:Modulos) {
            $modulo.Riesgo | Should -BeIn @('Bajo', 'Medio', 'Alto')
        }
    }

    It 'todos pertenecen al menos a un perfil valido' {
        $validos = @('conservador', 'equilibrado', 'agresivo')
        foreach ($modulo in $script:Modulos) {
            @($modulo.Perfiles).Count | Should -BeGreaterThan 0 -Because "modulo $($modulo.Id)"
            foreach ($perfil in $modulo.Perfiles) {
                $perfil | Should -BeIn $validos -Because "modulo $($modulo.Id)"
            }
        }
    }

    It 'Buscar es un bloque de codigo que acepta configuracion y sincronizacion' {
        foreach ($modulo in $script:Modulos) {
            $modulo.Buscar | Should -BeOfType [scriptblock] -Because "modulo $($modulo.Id)"
            @($modulo.Buscar.Ast.ParamBlock.Parameters).Count | Should -Be 2 -Because "modulo $($modulo.Id)"
        }
    }

    It 'todos tienen una descripcion util' {
        foreach ($modulo in $script:Modulos) {
            $modulo.Descripcion.Length | Should -BeGreaterThan 30 -Because "modulo $($modulo.Id)"
        }
    }
}

Describe 'Coherencia de los perfiles' {

    It 'el perfil conservador es el mas restrictivo' {
        $conservador = @($script:Modulos | Where-Object { $_.Perfiles -contains 'conservador' })
        $agresivo    = @($script:Modulos | Where-Object { $_.Perfiles -contains 'agresivo' })
        $conservador.Count | Should -BeLessThan $agresivo.Count
    }

    It 'el perfil conservador no incluye ningun modulo de riesgo alto' {
        $conservador = @($script:Modulos | Where-Object { $_.Perfiles -contains 'conservador' })
        foreach ($modulo in $conservador) {
            $modulo.Riesgo | Should -Not -Be 'Alto' -Because "modulo $($modulo.Id)"
        }
    }

    It 'el perfil agresivo incluye todos los modulos' {
        $agresivo = @($script:Modulos | Where-Object { $_.Perfiles -contains 'agresivo' })
        $agresivo.Count | Should -Be $script:Modulos.Count
    }
}

Describe 'Invoke-ModuloLimpieza' {

    It 'omite los modulos de administrador cuando no hay permisos' {
        $modulo = New-ModuloLimpieza -Id 'prueba' -Nombre 'Prueba' -Orden 1 `
                                     -Descripcion 'Modulo de prueba para las comprobaciones automaticas.' `
                                     -RequiereAdmin -Buscar { param($c, $s) }
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion ([pscustomobject]@{ Admin = $false })
        $resultado.Omitido | Should -Not -BeNullOrEmpty
    }

    It 'captura los errores de un modulo sin propagarlos' {
        $modulo = New-ModuloLimpieza -Id 'roto' -Nombre 'Roto' -Orden 1 `
                                     -Descripcion 'Modulo que falla a proposito para comprobar el aislamiento.' `
                                     -Buscar { param($c, $s) throw 'fallo controlado' }
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion ([pscustomobject]@{ Admin = $true })
        $resultado.Error | Should -BeLike '*fallo controlado*'
        $resultado.Candidatos.Count | Should -Be 0
    }

    It 'descarta los candidatos que no pasan la guardia' {
        $configuracion = [pscustomobject]@{
            Admin = $true; Escritorio = 'C:\Users\prueba\Desktop'; Documentos = 'C:\Users\prueba\Documents'
            Descargas = 'C:\Users\prueba\Downloads'; Imagenes = $null; Musica = $null; Videos = $null
            CarpetaDatos = 'C:\Users\prueba\AppData\Local\Cachivache'
        }
        Initialize-Guardia -Configuracion $configuracion

        $modulo = New-ModuloLimpieza -Id 'malicioso' -Nombre 'Malicioso' -Orden 1 `
                                     -Descripcion 'Intenta colar una ruta del sistema para comprobar la red de seguridad.' `
                                     -Buscar {
                                         param($c, $s)
                                         New-Candidato -ModuloId 'malicioso' -Categoria 'x' -Nombre 'Windows' `
                                                       -Ruta 'C:\Windows\System32' -Bytes 1GB `
                                                       -Raices @('C:\Windows') -Metodo 'Ruta'
                                     }
        $resultado = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $configuracion
        $resultado.Candidatos.Count | Should -Be 0
        $resultado.Descartados      | Should -Be 1
    }
}

Describe 'un modulo que falla a mitad no pierde lo que ya habia encontrado' {

    It 'conserva los candidatos emitidos antes de la excepcion' {
        # Con "$candidatos = @(& $Modulo.Buscar ...)" una excepción descarta
        # la asignación entera y se pierde lo ya encontrado.
        $modulo = [pscustomobject]@{
            Id = 'prueba'; RequiereAdmin = $false
            Buscar = {
                param($Configuracion, $Sync)
                New-Candidato -ModuloId 'prueba' -Categoria 'x' -Nombre 'antes' `
                              -Ruta 'C:\Users\prueba\AppData\Local\algo\uno' -Bytes 10 `
                              -Raices @('C:\Users\prueba\AppData\Local') -Metodo 'Informativo'
                throw 'la carpeta siguiente ha reventado'
            }
        }

        $resultado = Invoke-ModuloLimpieza -Modulo $modulo `
                                           -Configuracion ([pscustomobject]@{ Admin = $true })

        $resultado.Error | Should -Not -BeNullOrEmpty
        $resultado.Candidatos.Count | Should -Be 1 -Because 'lo encontrado antes del fallo sigue siendo valido'
        $resultado.Candidatos[0].Nombre | Should -Be 'antes'
    }

    It 'el error incluye donde ha ocurrido, no solo el mensaje' {
        $modulo = [pscustomobject]@{
            Id = 'prueba'; RequiereAdmin = $false
            Buscar = { param($Configuracion, $Sync) throw 'Acceso denegado' }
        }

        $resultado = Invoke-ModuloLimpieza -Modulo $modulo `
                                           -Configuracion ([pscustomobject]@{ Admin = $true })

        $resultado.Error | Should -Match 'Acceso denegado'
        $resultado.Error | Should -Match 'en ' -Because '"Acceso denegado" a secas no se puede investigar'
    }
}
