<#
    Mediciones sobre la propia red de seguridad, para que ninguna parte del
    programa quede sin ejecutarse nunca:

      1. Suelo de cobertura: las decisiones puras de tools/Cobertura.ps1
         sobre cuándo la cobertura medida es suficiente. tools/Probar.ps1
         mide, pero no decide.

      2. Inventario de funciones: toda función de src/ debe estar nombrada
         en alguna prueba o figurar en la lista de deuda. La lista solo
         puede encoger: si una función de la lista pasa a estar probada o
         deja de existir, la prueba falla para que se quite.

    Que una línea se ejecute no significa que haga lo correcto: esto mide
    abandono, no calidad.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    # La deuda vive en un .txt por dos motivos:
    #  - Escrita aquí se nombraría a sí misma: el inventario busca cada
    #    nombre en el código de tests/*.ps1.
    #  - Escrita en el cuerpo del Describe se asignaría durante el
    #    descubrimiento de Pester y los It la verían vacía. Lo que lee un It
    #    se construye en un BeforeAll.
    $script:RutaDeuda = Join-Path (Join-Path $script:Raiz 'tests') 'datos/deuda-de-pruebas.txt'
    $script:Deuda = @(Get-Content -LiteralPath $script:RutaDeuda |
                      ForEach-Object { $_.Trim() } |
                      Where-Object { $_ -and $_ -notmatch '^#' })

    . (Join-Path (Join-Path $script:Raiz 'tools') 'Cobertura.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Inventario: nombre de función -> ¿la nombra alguna prueba?
    #
    # Sin comentarios: si no, una función mencionada en un comentario (p.
    # ej. para explicar por qué no se puede probar) contaría como probada.
    #
    # Primero los bloques <# #> y después las líneas '#': al revés, el
    # primer paso se lleva la línea del "#>" y el bloque queda abierto.
    $script:TextoPruebas = (Get-ChildItem -LiteralPath (Join-Path $script:Raiz 'tests') `
                              -Filter '*.ps1' -Recurse |
                            ForEach-Object {
                                $t = [regex]::Replace([IO.File]::ReadAllText($_.FullName), '(?s)<#.*?#>', '')
                                (@($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
                            }) -join "`n"

    $script:Funciones = [Collections.Generic.List[object]]::new()
    foreach ($archivo in (Get-ChildItem -LiteralPath (Join-Path $script:Raiz 'src') -Filter '*.ps1' -Recurse)) {
        $tokens = $null; $errores = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($archivo.FullName, [ref]$tokens, [ref]$errores)
        foreach ($fn in $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $script:Funciones.Add([pscustomobject]@{
                Nombre   = $fn.Name
                Archivo  = $archivo.Name
                Nombrada = $script:TextoPruebas -match [regex]::Escape($fn.Name)
            })
        }
    }
}

Describe 'El suelo de cobertura' {

    It 'hay suelo para el total y para las cuatro carpetas de src' {
        # Sin suelos, lo siguiente comprobaría el vacío.
        $suelo = Get-SueloCobertura
        foreach ($clave in @('total', 'Core', 'Modules', 'Cli', 'UI')) {
            $suelo.ContainsKey($clave) | Should -BeTrue -Because "'$clave' tiene que tener suelo"
        }
    }

    It 'con la cobertura de hoy no hay ningun motivo de queja' {
        # Las dos mediciones de referencia, en Linux y en Windows (CI). El
        # suelo debe aguantar ambas; Windows cubre más en las cuatro filas,
        # así que el límite lo marca Linux.
        @(Test-CoberturaSuficiente -Medido @{
            'total' = 66.1; 'Core' = 88.6; 'Modules' = 65.4; 'Cli' = 89.4; 'UI' = 5.1
        }) | Should -BeNullOrEmpty -Because 'medido en Linux'
        @(Test-CoberturaSuficiente -Medido @{
            'total' = 66.8; 'Core' = 89.4; 'Modules' = 66.6; 'Cli' = 89.4; 'UI' = 5.1
        }) | Should -BeNullOrEmpty -Because 'medido en Windows por la integracion continua'
    }

    # Los casos siguientes se construyen desde el propio suelo y no con
    # números fijos: una prueba sobre el mecanismo no debe contener los
    # datos que el mecanismo vigila, o se rompe cada vez que suben los
    # suelos.
    BeforeAll {
        function script:New-MedicionQueAprueba {
            # Medición que supera todos los suelos con holgura.
            $m = @{}
            foreach ($par in (Get-SueloCobertura).GetEnumerator()) {
                $m[$par.Key] = [double]$par.Value + 5.0
            }
            return $m
        }
    }

    It 'una carpeta que baja de su suelo se nombra, y solo esa' {
        $medido = script:New-MedicionQueAprueba
        $medido['Core'] = (Get-SueloCobertura)['Core'] - 10.0
        $motivos = @(Test-CoberturaSuficiente -Medido $medido)
        $motivos.Count | Should -Be 1 -Because 'solo Core esta por debajo'
        $motivos[0] | Should -Match 'Core'
    }

    It 'y una que esta JUSTO en su suelo no se nombra' {
        # El borde exacto: detecta un ">=" cambiado por ">".
        $medido = script:New-MedicionQueAprueba
        $medido['Core'] = [double](Get-SueloCobertura)['Core']
        @(Test-CoberturaSuficiente -Medido $medido) | Should -BeNullOrEmpty
    }

    It 'una carpeta que FALTA es un fallo, no un aprobado' {
        # Si alguien renombra src/Core y deja de medirse, no puede pasar
        # por aprobada.
        $medido = script:New-MedicionQueAprueba
        $medido.Remove('Core')
        $motivos = @(Test-CoberturaSuficiente -Medido $medido)
        ($motivos -join ' ') | Should -Match "Falta la cobertura de 'Core'"
    }

    It 'una carpeta nueva sin suelo obliga a decidir' {
        $medido = script:New-MedicionQueAprueba
        $medido['Extensiones'] = 12.0
        ($motivos = @(Test-CoberturaSuficiente -Medido $medido)) | Should -Not -BeNullOrEmpty
        ($motivos -join ' ') | Should -Match 'Extensiones'
    }

    It 'no haber medido nada NO es estar en verde' {
        # "La medición falló" no puede confundirse con "todo bien".
        @(Test-CoberturaSuficiente -Medido @{})   | Should -Not -BeNullOrEmpty
        @(Test-CoberturaSuficiente -Medido $null) | Should -Not -BeNullOrEmpty
        { Test-CoberturaSuficiente -Medido $null } | Should -Not -Throw
    }
}

Describe 'Funciones que ninguna prueba nombra todavia' {


    It 'la lista de deuda se ha leido de verdad' {
        # Si el archivo se moviera o se vaciara, "no hay deuda" y "no se
        # pudo leer la deuda" se verían igual.
        Test-Path -LiteralPath $script:RutaDeuda | Should -BeTrue
        $script:Deuda.Count | Should -BeGreaterThan 0 -Because (
            'el dia que la lista se quede vacia de verdad, hay que borrar estas pruebas ' +
            'y celebrarlo, no dejarlas pasando por inercia')
    }

    It 'toda funcion de src esta nombrada en alguna prueba, o en la lista de deuda' {
        # Si el inventario sale vacío, la prueba no comprueba nada.
        $script:Funciones.Count | Should -BeGreaterThan 100 -Because 'el programa tiene casi doscientas funciones'

        $huerfanas = @($script:Funciones |
                       Where-Object { -not $_.Nombrada -and $script:Deuda -notcontains $_.Nombre } |
                       ForEach-Object { '{0} ({1})' -f $_.Nombre, $_.Archivo } | Sort-Object)

        ($huerfanas -join ', ') | Should -BeNullOrEmpty -Because (
            'una funcion que ninguna prueba nombra es codigo que nadie ha ejercitado nunca. ' +
            'Escribe la prueba, o añádela a la lista de deuda con su motivo')
    }

    It 'la lista de deuda no tiene nombres que ya sobran' {
        # Esto convierte la lista en un trinquete: si se prueba o se borra
        # una función de la lista, hay que quitarla.
        $nombresReales = @($script:Funciones | ForEach-Object { $_.Nombre })
        $sobran = @()
        foreach ($n in $script:Deuda) {
            if ($nombresReales -notcontains $n) {
                $sobran += ('{0}: ya no existe ninguna funcion asi' -f $n)
                continue
            }
            $probada = @($script:Funciones | Where-Object { $_.Nombre -eq $n -and $_.Nombrada })
            if ($probada.Count -gt 0) {
                $sobran += ('{0}: ya la nombra alguna prueba' -f $n)
            }
        }
        ($sobran -join '; ') | Should -BeNullOrEmpty -Because 'la lista de deuda solo puede encoger'
    }
}

Describe 'Funciones auxiliares de calculo puro' {
    <#
        Funciones de cálculo puro, sin dependencias del sistema.
    #>

    It 'Remove-SufijoVersion quita los digitos del final' {
        Remove-SufijoVersion -Token 'python39'   | Should -Be 'python'
        Remove-SufijoVersion -Token 'office2016' | Should -Be 'office'
    }

    It 'Remove-SufijoVersion NO parte un nombre que empieza por numero' {
        # Quitar todos los dígitos convertiría "7zip" en "zip" y
        # "1password" en "password".
        Remove-SufijoVersion -Token '7zip'      | Should -Be '7zip'
        Remove-SufijoVersion -Token '1password' | Should -Be '1password'
    }

    It 'Remove-SufijoVersion no deja un token demasiado corto' {
        # "vs2019" recortado sería "vs": dos letras casan con demasiadas
        # cosas.
        Remove-SufijoVersion -Token 'vs2019' | Should -Be 'vs2019'
        Remove-SufijoVersion -Token ''       | Should -Be ''
        Remove-SufijoVersion -Token $null    | Should -Be ''
    }

    It 'Format-VersionNormalizada escribe siempre igual lo que entiende' {
        Format-VersionNormalizada -Etiqueta 'v2.1'  | Should -Be '2.1.0'
        Format-VersionNormalizada -Etiqueta '2.1.3' | Should -Be '2.1.3'
    }

    It 'Format-VersionNormalizada devuelve vacio con lo que NO entiende' {
        # Viene de la red: solo se muestran los números entendidos, nunca
        # el texto tal como llegó.
        foreach ($basura in @('', $null, 'ultima', '<script>alert(1)</script>', 'v')) {
            Format-VersionNormalizada -Etiqueta $basura | Should -Be ''
        }
    }

    It 'Test-ModuloEnPerfil responde por la lista de perfiles del modulo' {
        $modulo = [pscustomobject]@{ Perfiles = @('rapido', 'equilibrado') }
        Test-ModuloEnPerfil -Modulo $modulo -Perfil 'equilibrado' | Should -BeTrue
        Test-ModuloEnPerfil -Modulo $modulo -Perfil 'exhaustivo'  | Should -BeFalse
    }

    It 'en el perfil personalizado entran todos' {
        # En el perfil personalizado el usuario elige con las casillas.
        $modulo = [pscustomobject]@{ Perfiles = @() }
        Test-ModuloEnPerfil -Modulo $modulo -Perfil 'personalizado' | Should -BeTrue
    }

    It 'Get-RaizQueContiene devuelve la raiz de la que cuelga la ruta' {
        Get-RaizQueContiene -Ruta 'C:\Windows\Temp\x.tmp' -Raices @('C:\Windows') |
            Should -Not -BeNullOrEmpty
    }

    It 'Get-RaizQueContiene NO da por buena la propia raiz' {
        # Exige la barra final: la raíz autorizada nunca es borrable, solo
        # su contenido.
        Get-RaizQueContiene -Ruta 'C:\Windows' -Raices @('C:\Windows') | Should -BeNullOrEmpty
    }

    It 'Get-RaizQueContiene con nada dentro no lanza y dice que no' {
        { Get-RaizQueContiene -Ruta $null -Raices @('C:\Windows') } | Should -Not -Throw
        Get-RaizQueContiene -Ruta $null   -Raices @('C:\Windows') | Should -BeNullOrEmpty
        Get-RaizQueContiene -Ruta 'C:\x'  -Raices @()             | Should -BeNullOrEmpty
        Get-RaizQueContiene -Ruta 'C:\x'  -Raices $null           | Should -BeNullOrEmpty
    }

    It 'Join-RutaNativa une sin preguntarle al proveedor por la unidad' {
        # Join-Path resuelve la unidad a través del proveedor y lanza si la
        # letra no existe en el proceso, como ocurre fuera de Windows.
        $s = [IO.Path]::DirectorySeparatorChar
        Join-RutaNativa -Base 'Z:' -Segmentos 'uno', 'dos' | Should -Be ('Z:{0}uno{0}dos' -f $s)
        { Join-RutaNativa -Base 'Z:' -Segmentos 'uno' }    | Should -Not -Throw
    }

    It 'Join-RutaNativa parte los segmentos por cualquier barra y se salta los huecos' {
        # La base se respeta (solo se quita la barra final) porque viene de
        # una carpeta existente; los segmentos se parten por ambas barras y
        # se unen con el separador nativo.
        $s = [IO.Path]::DirectorySeparatorChar
        Join-RutaNativa -Base 'C:\base\' -Segmentos 'uno/dos', '', 'tres' |
            Should -Be ('C:\base{0}uno{0}dos{0}tres' -f $s)
    }

    It 'Get-ProporcionPeor castiga los rectangulos alargados' {
        # Cuanto más cuadrada la fila, menor la proporción. Decide cuándo
        # cerrar una fila del mapa de árbol.
        $cuadrada  = Get-ProporcionPeor -Tamanos @(50.0, 50.0) -Suma 100.0 -Lado 10.0
        $alargada  = Get-ProporcionPeor -Tamanos @(99.0,  1.0) -Suma 100.0 -Lado 10.0
        $alargada | Should -BeGreaterThan $cuadrada
    }

    It 'Get-ProporcionPeor devuelve el peor caso con datos imposibles' {
        # Un número pequeño haría creer al algoritmo que la fila es buena y
        # no la cerraría nunca.
        Get-ProporcionPeor -Tamanos @()      -Suma 100.0 -Lado 10.0 | Should -Be ([double]::MaxValue)
        Get-ProporcionPeor -Tamanos @(1.0)   -Suma 0.0   -Lado 10.0 | Should -Be ([double]::MaxValue)
        Get-ProporcionPeor -Tamanos @(1.0)   -Suma 100.0 -Lado 0.0  | Should -Be ([double]::MaxValue)
        Get-ProporcionPeor -Tamanos @(0.0)   -Suma 100.0 -Lado 10.0 | Should -Be ([double]::MaxValue)
    }

    It 'New-Rectangulo compone los cuatro campos del mapa' {
        $r = New-Rectangulo -X 1.5 -Y 2.5 -Ancho 30.0 -Alto 40.0
        $r.X | Should -Be 1.5
        $r.Y | Should -Be 2.5
        $r.Ancho | Should -Be 30.0
        $r.Alto  | Should -Be 40.0
    }

    It 'Test-EsRutaDeVerdad distingue una ruta de una etiqueta' {
        # La raíz POSIX hace falta porque la suite corre en Linux.
        Test-EsRutaDeVerdad -Texto 'C:\Windows\Temp'      | Should -BeTrue
        Test-EsRutaDeVerdad -Texto '\\servidor\recurso'   | Should -BeTrue
        Test-EsRutaDeVerdad -Texto '/tmp/algo'            | Should -BeTrue
    }

    It 'Test-EsRutaDeVerdad dice que no a lo que solo es texto' {
        foreach ($etiqueta in @('Cache de Chrome', 'Papelera de reciclaje', '', $null, 'C-algo')) {
            Test-EsRutaDeVerdad -Texto $etiqueta | Should -BeFalse -Because "'$etiqueta' no es una ruta"
        }
    }
}
