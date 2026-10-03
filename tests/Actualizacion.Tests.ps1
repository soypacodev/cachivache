<#
    Aviso de versión nueva.

    La comparación de versiones es cálculo puro y concentra el riesgo: si
    falla, el programa no avisa nunca o avisa siempre, y ninguna otra
    prueba lo notaría.

    La consulta a la red se prueba sin red: una suite que falla sin
    conexión acaba ignorándose.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Version.ps1')
}

Describe 'ConvertTo-PartesVersion' {

    It 'lee las tres partes de una etiqueta normal' {
        (ConvertTo-PartesVersion -Etiqueta '2.1.3') -join ',' | Should -Be '2,1,3'
    }

    It 'quita la v de delante, en minuscula y en mayuscula' {
        # La publicación se etiqueta "v2.1.0" y la versión instalada es
        # "2.1.0": sin esto nunca coincidirían y el aviso saltaría siempre.
        (ConvertTo-PartesVersion -Etiqueta 'v2.1.0') -join ',' | Should -Be '2,1,0'
        (ConvertTo-PartesVersion -Etiqueta 'V2.1.0') -join ',' | Should -Be '2,1,0'
    }

    It 'completa con ceros las etiquetas de dos partes y de una' {
        (ConvertTo-PartesVersion -Etiqueta '2.1') -join ',' | Should -Be '2,1,0'
        (ConvertTo-PartesVersion -Etiqueta '3')   -join ',' | Should -Be '3,0,0'
    }

    It 'devuelve numeros, no texto' {
        # Con cadenas, la comparación sería alfabética sin notarse aquí.
        $partes = ConvertTo-PartesVersion -Etiqueta '2.10.0'
        $partes.Count | Should -Be 3
        $partes[1] | Should -BeOfType [int]
        $partes[1] | Should -Be 10
    }

    It 'aguanta los espacios de sobra' {
        (ConvertTo-PartesVersion -Etiqueta '  v2.1.0  ') -join ',' | Should -Be '2,1,0'
    }

    It 'no entiende <Etiqueta>, y eso es lo correcto' -ForEach @(
        @{ Etiqueta = ''            }
        @{ Etiqueta = '   '         }
        @{ Etiqueta = 'v'           }
        @{ Etiqueta = 'no-es-una-version' }
        @{ Etiqueta = '2.1.0-beta'  }
        @{ Etiqueta = '2.1.0.4'     }
        @{ Etiqueta = '2..1'        }
        @{ Etiqueta = '2.1.'        }
        @{ Etiqueta = '-1.0.0'      }
        @{ Etiqueta = '2,1,0'       }
        @{ Etiqueta = 'release-2.1.0' }
        @{ Etiqueta = '99999999999.0.0' }
    ) {
        ConvertTo-PartesVersion -Etiqueta $Etiqueta | Should -BeNullOrEmpty
    }

    It 'no revienta con nulo' {
        # [AllowNull()] en un parámetro Mandatory: la etiqueta viene de una
        # respuesta de red que puede no traer el campo.
        { ConvertTo-PartesVersion -Etiqueta $null } | Should -Not -Throw
        ConvertTo-PartesVersion -Etiqueta $null | Should -BeNullOrEmpty
    }
}

Describe 'Compare-VersionCachivache' {

    It 'la 2.10.0 es MAS NUEVA que la 2.9.0' {
        # Alfabéticamente "2.10.0" es menor que "2.9.0": una comparación de
        # cadenas dejaría de avisar al publicar la 2.10.0.
        Compare-VersionCachivache -Izquierda '2.10.0' -Derecha '2.9.0' | Should -Be 1
        Compare-VersionCachivache -Izquierda '2.9.0' -Derecha '2.10.0' | Should -Be -1
    }

    It 'la 3.0.0 es mas nueva que la 2.99.99' {
        Compare-VersionCachivache -Izquierda '3.0.0' -Derecha '2.99.99' | Should -Be 1
    }

    It 'solo se mira el numero siguiente cuando hay empate' {
        Compare-VersionCachivache -Izquierda '2.1.0' -Derecha '2.0.9' | Should -Be 1
        Compare-VersionCachivache -Izquierda '2.1.1' -Derecha '2.1.0' | Should -Be 1
    }

    It 'la v de la etiqueta y los ceros que faltan no cambian nada' {
        Compare-VersionCachivache -Izquierda 'v2.0.0' -Derecha '2.0.0' | Should -Be 0
        Compare-VersionCachivache -Izquierda '2.0'    -Derecha '2.0.0' | Should -Be 0
        Compare-VersionCachivache -Izquierda '2'      -Derecha '2.0.0' | Should -Be 0
    }

    It 'devuelve nulo -no cero- cuando alguna no se entiende' {
        # Cero significaría "misma versión", que aquí no se puede afirmar:
        # quien llama debe distinguir "iguales" de "no lo sé".
        Compare-VersionCachivache -Izquierda 'basura' -Derecha '2.0.0' | Should -BeNullOrEmpty
        Compare-VersionCachivache -Izquierda '2.0.0' -Derecha 'basura' | Should -BeNullOrEmpty
        Compare-VersionCachivache -Izquierda $null -Derecha $null | Should -BeNullOrEmpty
    }

    It 'no revienta con nulo' {
        { Compare-VersionCachivache -Izquierda $null -Derecha $null } | Should -Not -Throw
    }
}

Describe 'Test-HayVersionNueva' {

    It 'avisa cuando la publicada es mayor' {
        Test-HayVersionNueva -Instalada '2.0.0' -Publicada 'v2.1.0'  | Should -BeTrue
        Test-HayVersionNueva -Instalada '2.9.0' -Publicada 'v2.10.0' | Should -BeTrue
    }

    It 'no avisa cuando son la misma' {
        Test-HayVersionNueva -Instalada '2.0.0' -Publicada 'v2.0.0' | Should -BeFalse
        Test-HayVersionNueva -Instalada '2.0.0' -Publicada 'v2.0'   | Should -BeFalse
    }

    It 'no avisa cuando la instalada es mas nueva que la publicada' {
        # Ocurre al trabajar en la versión siguiente sin publicarla: avisar
        # llevaría a descargar una versión más vieja.
        Test-HayVersionNueva -Instalada '2.1.0' -Publicada 'v2.0.0' | Should -BeFalse
    }

    It 'no avisa de una preversion' {
        # De una beta no se avisa: la etiqueta con sufijo no se entiende y
        # ante la duda se calla.
        Test-HayVersionNueva -Instalada '2.0.0' -Publicada 'v2.1.0-beta' | Should -BeFalse
    }

    It 'ante cualquier duda se calla' {
        Test-HayVersionNueva -Instalada '2.0.0' -Publicada ''       | Should -BeFalse
        Test-HayVersionNueva -Instalada '2.0.0' -Publicada 'basura' | Should -BeFalse
        Test-HayVersionNueva -Instalada 'basura' -Publicada '9.9.9' | Should -BeFalse
    }

    It 'no revienta con nulo' {
        { Test-HayVersionNueva -Instalada $null -Publicada $null } | Should -Not -Throw
        Test-HayVersionNueva -Instalada $null -Publicada $null | Should -BeFalse
    }
}

Describe 'Get-AvisoActualizacion' {

    It 'dice que hay una nueva, con las dos versiones' {
        $aviso = Get-AvisoActualizacion -Instalada '2.0.0' -Publicada 'v2.10.0'
        $aviso.Hay     | Should -BeTrue
        $aviso.Version | Should -Be '2.10.0'
        $aviso.Texto   | Should -Match '2\.10\.0'
        $aviso.Texto   | Should -Match '2\.0\.0'
    }

    It 'dice que estas al dia sin ofrecer descarga' {
        $aviso = Get-AvisoActualizacion -Instalada '2.0.0' -Publicada 'v2.0.0'
        $aviso.Hay   | Should -BeFalse
        $aviso.Texto | Should -Match 'al día'
    }

    It 'dice que no ha podido comprobarlo, y no lo llama estar al dia' {
        # "Estás al día" es una afirmación que no se puede hacer si la
        # consulta ha fallado.
        $aviso = Get-AvisoActualizacion -Instalada '2.0.0' -Publicada ''
        $aviso.Hay   | Should -BeFalse
        $aviso.Texto | Should -Match 'No se ha podido comprobar'
        $aviso.Texto | Should -Not -Match 'al día'
    }

    It 'nunca enseña en pantalla el texto que llego de la red' {
        # La etiqueta viene de una respuesta HTTP: se muestran los números
        # entendidos, nunca la cadena tal cual.
        $veneno = '<b>PULSA AQUI</b> http://ejemplo.no/malo'
        $aviso = Get-AvisoActualizacion -Instalada '2.0.0' -Publicada $veneno
        $aviso.Hay   | Should -BeFalse
        $aviso.Texto | Should -Not -Match 'ejemplo'
        $aviso.Texto | Should -Not -Match 'PULSA'

        # La regla general: la versión que sale de aquí son números y
        # puntos, o nada, sea cual sea la rama.
        $aviso.Version | Should -Match '^$|^[0-9]+\.[0-9]+\.[0-9]+$'
        (Get-AvisoActualizacion -Instalada '2.0.0' -Publicada 'v2.10').Version |
            Should -Match '^[0-9]+\.[0-9]+\.[0-9]+$'
    }

    It 'una version instalada que no se entiende tampoco produce aviso' {
        $aviso = Get-AvisoActualizacion -Instalada 'lo-que-sea' -Publicada 'v9.9.9'
        $aviso.Hay | Should -BeFalse
    }

    It 'no revienta con nulo' {
        { Get-AvisoActualizacion -Instalada $null -Publicada $null } | Should -Not -Throw
        (Get-AvisoActualizacion -Instalada $null -Publicada $null).Hay | Should -BeFalse
    }
}

Describe 'las direcciones se derivan, no se escriben aparte' {

    It 'la pagina de la ultima publicacion cuelga del repositorio' {
        Get-UrlUltimaVersion -Repositorio 'https://github.com/quien/loquesea' |
            Should -Be 'https://github.com/quien/loquesea/releases/latest'
    }

    It 'la direccion de consulta sale de la del repositorio' {
        # Escritas por separado, olvidar cambiar una desactivaría el aviso
        # en silencio.
        Get-UrlApiUltimaVersion -Repositorio 'https://github.com/quien/loquesea' |
            Should -Be 'https://api.github.com/repos/quien/loquesea/releases/latest'
    }

    It 'la barra final y el .git no cambian el resultado' {
        Get-UrlApiUltimaVersion -Repositorio 'https://github.com/quien/loquesea/' |
            Should -Be 'https://api.github.com/repos/quien/loquesea/releases/latest'
        Get-UrlApiUltimaVersion -Repositorio 'https://github.com/quien/loquesea.git' |
            Should -Be 'https://api.github.com/repos/quien/loquesea/releases/latest'
    }

    It 'las del repositorio de verdad estan bien formadas' {
        Get-UrlUltimaVersion    | Should -Match '^https://github\.com/[^/]+/[^/]+/releases/latest$'
        Get-UrlApiUltimaVersion | Should -Match '^https://api\.github\.com/repos/[^/]+/[^/]+/releases/latest$'
    }

    It 'una direccion que no es de GitHub no produce ninguna consulta' {
        # Cadena vacía: Get-UltimaVersionPublicada no llega a abrir nada.
        Get-UrlApiUltimaVersion -Repositorio 'https://otro-sitio.example/quien/que' | Should -BeNullOrEmpty
        Get-UrlApiUltimaVersion -Repositorio 'https://github.com/solo-un-tramo'     | Should -BeNullOrEmpty
        Get-UrlApiUltimaVersion -Repositorio ''                                     | Should -BeNullOrEmpty
    }
}

Describe 'la consulta falla hacia dentro, nunca hacia el usuario' {

    <#
        Ninguna de estas pruebas toca la red: la primera falla antes de
        abrir un socket, así que funciona igual sin conexión.
    #>

    It 'una direccion imposible no lanza y devuelve cadena vacia' {
        { Get-UltimaVersionPublicada -Url 'esto no es una direccion' -TiempoEspera 1 } | Should -Not -Throw
        Get-UltimaVersionPublicada -Url 'esto no es una direccion' -TiempoEspera 1 | Should -BeNullOrEmpty
    }

    It 'sin direccion no consulta nada' {
        Get-UltimaVersionPublicada -Url '' -TiempoEspera 1 | Should -BeNullOrEmpty
    }

    It 'devuelve texto, para que quien llama no tenga que mirar el tipo' {
        (Get-UltimaVersionPublicada -Url '' -TiempoEspera 1) | Should -BeOfType [string]
    }
}

Describe 'la ventana no decide por su cuenta lo que dice el panel' {

    <#
        La decisión vive en una función pura. Sin WPF, esta es la red de
        seguridad: una comparación de versiones en el manejador del botón
        (-ne, -lt sobre cadenas) no haría fallar nada más.
    #>

    BeforeAll {
        $script:CarpetaUI = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'
        $script:TextoEventos = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUI 'Window.Eventos.ps1')

        # Sin comentarios: los que hay junto a este código hablan de
        # comparar versiones.
        $script:CodigoEventos = ($script:TextoEventos -replace '(?s)<#.*?#>', '' -replace '(?m)^\s*#.*$', '')
    }

    It 'la prueba encuentra el codigo: si no, no comprueba nada' {
        $script:CodigoEventos.Length | Should -BeGreaterThan 10000
        $script:CodigoEventos | Should -Match 'BtnBuscarActualizacion'
    }

    It 'el panel se pinta con lo que devuelve Get-AvisoActualizacion' {
        $script:CodigoEventos | Should -Match 'Get-AvisoActualizacion'
        $script:CodigoEventos | Should -Match '\$c\.TxtActualizacion\.Text\s*=\s*\$aviso\.Texto'
        $script:CodigoEventos | Should -Match '\$c\.BtnIrAVersionNueva\.Visibility\s*=\s*if\s*\(\$aviso\.Hay\)'
    }

    It 'la ventana no compara versiones a mano en ningun sitio' {
        # Cualquier comparación con la versión del programa que no pase por
        # Version.ps1.
        $sospechosas = @([regex]::Matches($script:CodigoEventos,
            '\$script:VersionCachivache\s*-(eq|ne|lt|gt|le|ge)\b'))
        $sospechosas.Count | Should -Be 0 -Because (
            'comparar versiones es lo unico dificil de este punto y esta resuelto en una funcion pura')
    }

    It 'la consulta a la red no ocurre en el hilo de la interfaz' {
        # Get-UltimaVersionPublicada solo puede aparecer dentro del guion
        # del runspace: llamada desde el manejador congelaría la ventana
        # hasta seis segundos.
        $script:CodigoEventos | Should -Match "(?s)\`$codigoVersion = @'.*Get-UltimaVersionPublicada.*'@"
        $script:CodigoEventos | Should -Match 'BeginInvoke'
        $script:CodigoEventos | Should -Match 'DispatcherTimer'

        # Una sola aparición: cualquier otra sería una llamada síncrona en
        # el hilo de la interfaz.
        @([regex]::Matches($script:CodigoEventos, 'Get-UltimaVersionPublicada')).Count |
            Should -Be 1 -Because 'la unica llamada esta dentro del guion que corre en el runspace'
    }

    It 'la consulta no se lanza sola: hace falta pulsar el boton' {
        # La promesa de privacidad depende de esto: llamada desde el
        # arranque o desde $mostrarPanel, el programa se conectaría a un
        # tercero sin que nadie lo pida.
        $lanzamientos = @([regex]::Matches($script:CodigoEventos, 'TemporizadorVersion\.Start\(\)'))
        $lanzamientos.Count | Should -Be 1 -Because 'solo el boton de Acerca de puede empezar una consulta'

        $ayudantes = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUI 'Window.Ayudantes.ps1')
        $ayudantes | Should -Not -Match 'Get-UltimaVersionPublicada'
        $ventana = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUI 'Window.ps1')
        $ventana | Should -Not -Match 'Get-UltimaVersionPublicada'
    }

    It 'Version.ps1 es el unico archivo del programa que abre una conexion' {
        # El programa tiene una sola puerta a la red, aislada en una función
        # que no lanza. Otra debe decidirse explícitamente.
        $raiz = Split-Path $PSScriptRoot -Parent
        $culpables = @()
        foreach ($archivo in @(Get-ChildItem (Join-Path $raiz 'src') -Filter '*.ps1' -Recurse)) {
            if ($archivo.Name -eq 'Version.ps1') { continue }
            $texto = Get-Content -Raw -LiteralPath $archivo.FullName
            $texto = ($texto -replace '(?s)<#.*?#>', '' -replace '(?m)^\s*#.*$', '')
            if ($texto -match 'Invoke-RestMethod|Invoke-WebRequest|System\.Net\.WebClient|HttpClient') {
                $culpables += $archivo.Name
            }
        }
        $culpables | Should -BeNullOrEmpty -Because 'la unica conexion del programa vive en Get-UltimaVersionPublicada'
    }
}
