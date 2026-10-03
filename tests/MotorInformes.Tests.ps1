<#
    Funciones auxiliares del motor de borrado, el informe HTML y las
    preferencias, sacadas de tests/datos/deuda-de-pruebas.txt.

    Clear-CacheFirefox y Clear-Miniaturas borran archivos de verdad, pero
    solo dentro de la -Ruta obligatoria que reciben: se ejercitan contra un
    taller bajo [IO.Path]::GetTempPath() que se borra en el AfterAll. Una
    guarda falla si el taller no cuelga de la carpeta temporal.

    Siempre con -Permanente: sin él, Remove-Elemento usa la papelera vía
    Microsoft.VisualBasic, que solo funciona en Windows.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Sin guardia inicializada, Test-RutaIntocable bloquea todo (estado de
    # fallo seguro) y no se borraría nada. Se inicializa con carpetas
    # personales vacías, como en tests/Remove.Tests.ps1.
    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio   = ''
        Documentos   = ''
        Descargas    = ''
        Imagenes     = ''
        Musica       = ''
        Videos       = ''
        CarpetaDatos = ''
    })

    # Aquí se borra de verdad: todo cuelga de la carpeta temporal.
    $script:Temporal = [IO.Path]::GetTempPath()

    function script:New-TallerTemporal {
        param([string] $Prefijo)
        $carpeta = Join-Path $script:Temporal ($Prefijo + '-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $carpeta -Force)
        return $carpeta
    }

    function script:Remove-TallerTemporal {
        param([string] $Carpeta)
        if ($Carpeta -and (Test-Path -LiteralPath $Carpeta)) {
            Remove-Item -LiteralPath $Carpeta -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Un texto corto, no vacío: un archivo de cero bytes sigue otra rama
    # en algunas mediciones.
    function script:New-ArchivoDePrueba {
        param([string] $Ruta)
        [IO.File]::WriteAllText($Ruta, 'contenido de prueba')
    }
}

Describe 'Initialize-MotorBorrado: deja el motor en condiciones de mandar a la papelera' {

    It 'deja el motor utilizable: dice que si Y el tipo que manda a la papelera resuelve' {
        # Que devuelva $true solo vale si el tipo se puede usar: un nombre
        # de ensamblado erróneo haría fallar la primera aserción; un
        # ensamblado que no trae la papelera, la segunda.
        Initialize-MotorBorrado | Should -BeTrue

        $tipo = 'Microsoft.VisualBasic.FileIO.FileSystem' -as [type]
        $tipo | Should -Not -BeNullOrEmpty -Because (
            'Remove-Elemento llama a este tipo para mandar a la papelera; ' +
            'si no resuelve, el motor no esta montado por mucho que lo diga')
    }

    It 'es idempotente: el programa la llama en cada arranque de analisis' {
        # Window.Analisis.ps1 la invoca por runspace: la segunda llamada
        # sobre un ensamblado ya cargado debe dar el mismo veredicto.
        $primera = Initialize-MotorBorrado
        $segunda = Initialize-MotorBorrado
        $tercera = Initialize-MotorBorrado

        $segunda | Should -Be $primera
        $tercera | Should -Be $primera
    }

    It 'nunca lanza: quien la llama decide que hacer con el no' {
        { Initialize-MotorBorrado } | Should -Not -Throw
    }

    It 'devuelve UN solo booleano, no una tuberia con restos dentro' {
        # Add-Type emite los tipos cargados si falta el [void]; con basura
        # delante, "if (Initialize-MotorBorrado)" seguiría siendo cierto.
        # @() obligatorio: en 5.1, .Count sobre un objeto suelto es $null.
        $salida = @(Initialize-MotorBorrado)
        $salida.Count | Should -Be 1
        $salida[0]    | Should -BeOfType [bool]
    }
}

Describe 'Clear-CacheFirefox: vacia cache2 y NADA mas' {

    BeforeAll {
        $script:Ff = script:New-TallerTemporal 'cachivache-ff'
    }

    AfterAll {
        script:Remove-TallerTemporal $script:Ff
    }

    BeforeEach {
        # Se rehace en cada It: las pruebas destruyen lo que miran y
        # compartir el montaje las haría depender del orden.
        Get-ChildItem -LiteralPath $script:Ff -Force | Remove-Item -Recurse -Force

        $script:Perfil   = Join-Path $script:Ff 'a1b2c3d4.default-release'
        $script:Cache2   = Join-Path $script:Perfil 'cache2'
        $script:Entradas = Join-Path $script:Cache2 'entries'
        [void](New-Item -ItemType Directory -Path $script:Entradas -Force)

        # Dentro de cache2: basura, en dos niveles.
        script:New-ArchivoDePrueba (Join-Path $script:Cache2 'index.bin')
        script:New-ArchivoDePrueba (Join-Path $script:Entradas 'ABCDEF0123.bin')

        # Fuera de cache2, en el mismo perfil: los tres archivos por los
        # que Firefox reconoce un perfil.
        script:New-ArchivoDePrueba (Join-Path $script:Perfil 'places.sqlite')
        script:New-ArchivoDePrueba (Join-Path $script:Perfil 'prefs.js')
        script:New-ArchivoDePrueba (Join-Path $script:Perfil 'logins.json')

        # Un perfil sin cache2.
        $script:PerfilLimpio = Join-Path $script:Ff 'zz99zz99.otro'
        [void](New-Item -ItemType Directory -Path $script:PerfilLimpio -Force)
        script:New-ArchivoDePrueba (Join-Path $script:PerfilLimpio 'prefs.js')
    }

    It 'el taller esta donde tiene que estar y montado' {
        # Un taller mal montado o fuera de la carpeta temporal dejaría las
        # pruebas siguientes comprobando el vacío, o borrando donde no
        # debe.
        $script:Ff | Should -Not -BeNullOrEmpty
        $script:Ff.StartsWith($script:Temporal) | Should -BeTrue -Because (
            'aqui se borra de verdad: el taller TIENE que colgar de la carpeta temporal')
        Test-Path -LiteralPath (Join-Path $script:Cache2 'index.bin')      | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Entradas 'ABCDEF0123.bin') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Perfil 'places.sqlite')  | Should -BeTrue
    }

    It 'vacia el cache2 de cada perfil, tambien lo que cuelga por debajo' {
        Clear-CacheFirefox -Ruta $script:Ff -Permanente -Confirm:$false

        Test-Path -LiteralPath (Join-Path $script:Cache2 'index.bin')        | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Entradas 'ABCDEF0123.bin') | Should -BeFalse
    }

    It 'y deja la carpeta cache2 en su sitio, que es la mitad del contrato' {
        # Firefox falla al arrancar si desaparece la carpeta de caché: el
        # método 'FirefoxCache' vacía, no borra el contenedor.
        Clear-CacheFirefox -Ruta $script:Ff -Permanente -Confirm:$false

        Test-Path -LiteralPath $script:Cache2 | Should -BeTrue -Because (
            'vaciar una cache no es borrar la carpeta: el programa que la creo la espera ahi')
    }

    It 'NO toca marcadores, contraseñas ni preferencias del perfil' {
        # Si el bucle se equivocara de nivel y vaciara el perfil en vez de
        # cache2, se vería aquí.
        Clear-CacheFirefox -Ruta $script:Ff -Permanente -Confirm:$false

        Test-Path -LiteralPath (Join-Path $script:Perfil 'places.sqlite')     | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Perfil 'prefs.js')          | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Perfil 'logins.json')       | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:PerfilLimpio 'prefs.js')    | Should -BeTrue
        Test-Path -LiteralPath $script:PerfilLimpio                           | Should -BeTrue
    }

    It 'un perfil sin cache2 no la crea ni provoca nada' {
        { Clear-CacheFirefox -Ruta $script:Ff -Permanente -Confirm:$false } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:PerfilLimpio 'cache2') | Should -BeFalse
    }

    It 'con -WhatIf no borra ni un archivo' {
        # Un SupportsShouldProcess sin ShouldProcess dentro compila, se
        # anuncia en la ayuda y borra igual.
        Clear-CacheFirefox -Ruta $script:Ff -Permanente -WhatIf

        Test-Path -LiteralPath (Join-Path $script:Cache2 'index.bin')        | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Entradas 'ABCDEF0123.bin') | Should -BeTrue
    }

    It 'una ruta que no existe no revienta ni deja rastro' {
        # Firefox puede no estar instalado; el módulo llama igual.
        $inventada = Join-Path $script:Ff 'no-hay-nada-aqui'
        { Clear-CacheFirefox -Ruta $inventada -Permanente -Confirm:$false } | Should -Not -Throw
        Test-Path -LiteralPath $inventada | Should -BeFalse
    }
}

Describe 'Clear-Miniaturas: solo los thumbcache_ e iconcache_ de esa carpeta' {

    BeforeAll {
        $script:Mn = script:New-TallerTemporal 'cachivache-mn'
    }

    AfterAll {
        script:Remove-TallerTemporal $script:Mn
    }

    BeforeEach {
        Get-ChildItem -LiteralPath $script:Mn -Force | Remove-Item -Recurse -Force

        # Lo que sí se borra.
        script:New-ArchivoDePrueba (Join-Path $script:Mn 'thumbcache_32.db')
        script:New-ArchivoDePrueba (Join-Path $script:Mn 'thumbcache_idx.db')
        script:New-ArchivoDePrueba (Join-Path $script:Mn 'iconcache_16.db')

        # Lo que no. 'Contrasenas.db' y 'notas.txt' son del usuario;
        # 'thumbcache_96.dbx' y 'copia_thumbcache_8.db' comprueban que el
        # patrón está anclado por los dos extremos.
        script:New-ArchivoDePrueba (Join-Path $script:Mn 'Contrasenas.db')
        script:New-ArchivoDePrueba (Join-Path $script:Mn 'notas.txt')
        script:New-ArchivoDePrueba (Join-Path $script:Mn 'thumbcache_96.dbx')
        script:New-ArchivoDePrueba (Join-Path $script:Mn 'copia_thumbcache_8.db')

        # Una subcarpeta: la función no baja niveles a propósito.
        $script:Sub = Join-Path $script:Mn 'sub'
        [void](New-Item -ItemType Directory -Path $script:Sub -Force)
        script:New-ArchivoDePrueba (Join-Path $script:Sub 'thumbcache_256.db')
    }

    It 'el taller esta donde tiene que estar y montado' {
        # Misma guarda que arriba, por el mismo motivo.
        $script:Mn.StartsWith($script:Temporal) | Should -BeTrue -Because (
            'aqui se borra de verdad: el taller TIENE que colgar de la carpeta temporal')
        @(Get-ChildItem -LiteralPath $script:Mn -File -Force).Count | Should -Be 7
    }

    It 'borra las bases de miniaturas y de iconos del Explorador' {
        Clear-Miniaturas -Ruta $script:Mn -Permanente -Confirm:$false

        Test-Path -LiteralPath (Join-Path $script:Mn 'thumbcache_32.db')  | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Mn 'thumbcache_idx.db') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Mn 'iconcache_16.db')   | Should -BeFalse
    }

    It 'y deja en pie cualquier otro .db, aunque este en la misma carpeta' {
        # Sin el ancla inicial entraría 'copia_thumbcache_8.db'; sin la
        # final, 'thumbcache_96.dbx'.
        Clear-Miniaturas -Ruta $script:Mn -Permanente -Confirm:$false

        Test-Path -LiteralPath (Join-Path $script:Mn 'Contrasenas.db')         | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Mn 'notas.txt')              | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Mn 'thumbcache_96.dbx')      | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Mn 'copia_thumbcache_8.db')  | Should -BeTrue
    }

    It 'no baja a las subcarpetas' {
        # Sin -Recurse a propósito: la carpeta del Explorador es plana.
        Clear-Miniaturas -Ruta $script:Mn -Permanente -Confirm:$false

        Test-Path -LiteralPath (Join-Path $script:Sub 'thumbcache_256.db') | Should -BeTrue
        Test-Path -LiteralPath $script:Sub | Should -BeTrue
    }

    It 'con -WhatIf no borra ni un archivo' {
        Clear-Miniaturas -Ruta $script:Mn -Permanente -WhatIf

        Test-Path -LiteralPath (Join-Path $script:Mn 'thumbcache_32.db') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Mn 'iconcache_16.db')  | Should -BeTrue
    }

    It 'una ruta que no existe no revienta' {
        $inventada = Join-Path $script:Mn 'no-hay-nada-aqui'
        { Clear-Miniaturas -Ruta $inventada -Permanente -Confirm:$false } | Should -Not -Throw
    }
}

Describe 'Get-InformeEstiloCss: el CSS tiene que poder incrustarse sin romper el HTML' {

    BeforeAll {
        $script:Css = Get-InformeEstiloCss
    }

    It 'devuelve un bloque de estilos con reglas de verdad dentro' {
        # Sin esta guarda, lo siguiente comprobaría una cadena vacía.
        $script:Css | Should -Not -BeNullOrEmpty
        # 20 es holgadamente menos que las reglas que hay y más que un
        # bloque vacío.
        ([regex]::Matches($script:Css, '\{')).Count | Should -BeGreaterThan 20 -Because (
            'un CSS sin reglas dentro dejaria el informe en texto plano y nadie lo notaria aqui')
    }

    # Pester sustituye lo que va entre ángulos por valores de -ForEach: un
    # "<style>" en el título saldría como "$null".
    It 'abre y cierra la etiqueta de estilos exactamente una vez' {
        ([regex]::Matches($script:Css, '<style>')).Count  | Should -Be 1
        ([regex]::Matches($script:Css, '</style>')).Count | Should -Be 1
        $script:Css.Trim().StartsWith('<style>') | Should -BeTrue
        $script:Css.Trim().EndsWith('</style>')  | Should -BeTrue
    }

    It 'y no lleva ningun "</" suelto dentro, que es lo que cerraria el bloque antes de tiempo' {
        # Un elemento <style> lo cierra "</" seguido del nombre: un "</"
        # perdido en un comentario del CSS partiría el informe y el resto
        # se pintaría como texto. Se mira el cuerpo, sin el cierre final.
        $cuerpo = $script:Css.Substring(
                     $script:Css.IndexOf('<style>') + '<style>'.Length)
        $cuerpo = $cuerpo.Substring(0, $cuerpo.LastIndexOf('</style>'))

        $cuerpo | Should -Not -BeNullOrEmpty -Because 'si el cuerpo saliera vacio esto no comprobaria nada'
        $cuerpo | Should -Not -Match '</'
    }

    It 'incrustado en un HTML, el bloque de estilos se recupera ENTERO' {
        # Se monta la cabecera de Export-InformeHtml y se extrae el bloque
        # con captura perezosa, como un analizador: un cierre adelantado
        # daría una captura corta.
        $html = '<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">' +
                $script:Css + '</head><body><div class="wrap"></div></body></html>'

        $m = [regex]::Match($html, '(?s)<style>(.*?)</style>')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value.Length | Should -Be (
            $script:Css.Trim().Length - '<style>'.Length - '</style>'.Length) -Because (
            'lo que un analizador recupera tiene que ser el CSS entero, no hasta el primer corte')
        ([regex]::Matches($html, '<style>')).Count | Should -Be 1
    }

    It 'define las clases que el informe pinta de verdad' {
        # Si el CSS dejara de declarar .chip, los niveles de riesgo
        # saldrían sin color. Un CSS que no casa con el HTML parece estilo
        # sin serlo.
        foreach ($selector in @('.wrap{', '.sub{', '.card{', '.chip{', '.path{',
                                '.num{', '.aviso{', '.count{', 'table{', 'footer{')) {
            $script:Css.Contains($selector) | Should -BeTrue -Because (
                "Export-InformeHtml emite ese selector y el CSS tiene que declararlo: $selector")
        }
    }

    It 'no lanza y no depende de nada del equipo' {
        { Get-InformeEstiloCss } | Should -Not -Throw
        # Es una constante: no depende del disco ni de la hora.
        Get-InformeEstiloCss | Should -Be $script:Css
    }
}

Describe 'Get-CarpetaInformes: un unico sitio que sepa donde viven los informes' {

    BeforeAll {
        $script:Datos = script:New-TallerTemporal 'cachivache-inf'

        # Get-CarpetaDatos lee %LOCALAPPDATA% y crea carpetas: se redirige.
        # [Environment] y no "$env:X = $null" porque en 5.1 asignar nulo
        # deja la variable vacía en vez de quitarla.
        $script:LocalAppDataOriginal = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $script:Datos)
    }

    AfterAll {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $script:LocalAppDataOriginal)
        script:Remove-TallerTemporal $script:Datos
    }

    It 'compone una ruta absoluta y no lanza' {
        $ruta = Get-CarpetaInformes -CarpetaDatos $script:Datos
        { Get-CarpetaInformes -CarpetaDatos $script:Datos } | Should -Not -Throw

        $ruta | Should -Not -BeNullOrEmpty
        [IO.Path]::IsPathRooted($ruta) | Should -BeTrue -Because (
            'la ruta se usa tal cual para abrir el explorador: una relativa apuntaria a otro sitio segun quien llame')
    }

    It 'cuelga de la carpeta de datos que se le pasa, y añade un nivel' {
        $ruta = Get-CarpetaInformes -CarpetaDatos $script:Datos

        $ruta.StartsWith($script:Datos) | Should -BeTrue
        $ruta | Should -Not -Be $script:Datos -Because (
            'si devolviera la carpeta de datos a secas, listar informes listaria tambien el registro y las preferencias')
        (Split-Path $ruta -Leaf) | Should -Be 'informes'
    }

    It 'sin argumentos usa la carpeta de datos del programa' {
        $ruta = Get-CarpetaInformes

        [IO.Path]::IsPathRooted($ruta) | Should -BeTrue
        $ruta.StartsWith($script:Datos) | Should -BeTrue -Because (
            'por defecto tiene que salir de Get-CarpetaDatos, que es quien sabe donde escribe el programa')
    }

    It 'es EL MISMO sitio donde New-NombreInforme escribe: la costura que existe para no repetir el Join-Path' {
        # Si divergieran, el panel de Informes miraría una carpeta vacía
        # mientras los informes se escriben al lado.
        $carpeta = Get-CarpetaInformes -CarpetaDatos $script:Datos
        $nombre  = New-NombreInforme -Tipo 'analisis' -Extension 'html' -CarpetaDatos $script:Datos

        (Split-Path $nombre -Parent) | Should -Be $carpeta
    }
}

Describe 'Get-RaizProyecto: encuentra la raiz del repositorio de verdad' {

    It 'devuelve una ruta absoluta, existente, y no lanza' {
        { Get-RaizProyecto } | Should -Not -Throw
        $raiz = Get-RaizProyecto

        $raiz | Should -Not -BeNullOrEmpty
        [IO.Path]::IsPathRooted($raiz) | Should -BeTrue
        Test-Path -LiteralPath $raiz | Should -BeTrue
    }

    It 'y es LA raiz: dentro estan src, tests y el propio arranque del nucleo' {
        # Que exista no basta: un Split-Path de más devolvería la carpeta
        # superior y Get-ModulosLimpieza no encontraría módulos, sin
        # errores.
        $raiz = Get-RaizProyecto

        Test-Path -LiteralPath (Join-Path $raiz 'src')   | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $raiz 'tests') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $raiz 'src') 'Core') 'Bootstrap.ps1') |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $raiz 'src') 'Modules') | Should -BeTrue
    }

    It 'coincide con la raiz que calculan las propias pruebas' {
        # Dos caminos independientes: la función sube dos niveles desde
        # src/Core y este archivo uno desde tests.
        (Get-RaizProyecto).TrimEnd('\', '/') | Should -Be $script:Raiz.TrimEnd('\', '/')
    }

    It 'los modulos de limpieza se encuentran desde esa raiz' {
        # Consecuencia observable de una raíz correcta. @() obligatorio por
        # 5.1.
        @(Get-ModulosLimpieza -Raiz (Get-RaizProyecto)).Count | Should -BeGreaterThan 0
    }
}

Describe 'Export-Preferencias: lo que se guarda se tiene que poder recuperar' {

    BeforeAll {
        $script:DatosPref = script:New-TallerTemporal 'cachivache-pref'
        $script:LocalAppDataPrevio = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $script:DatosPref)

        # Todo distinto de los valores por defecto: si Export no escribiera
        # nada, la lectura daría los valores por defecto y la prueba no lo
        # distinguiría.
        $script:Preferidas = @{
            Tema              = 'claro'          # por defecto: el de Windows
            Perfil            = 'agresivo'       # por defecto: equilibrado
            DiasSinUso        = 90               # por defecto: 180
            MinimoMB          = 25               # por defecto: 10
            IncluirMenores    = $true            # por defecto: false
            Permanente        = $true            # por defecto: false
            ModulosActivos    = @('caches', 'temporales')
            UnidadesExcluidas = @('D:')
            RutasExcluidas    = @('C:\proyectos\vivo')
        }
    }

    AfterAll {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $script:LocalAppDataPrevio)
        script:Remove-TallerTemporal $script:DatosPref
    }

    BeforeEach {
        $script:RutaPref = Get-RutaPreferencias
        if (Test-Path -LiteralPath $script:RutaPref) {
            Remove-Item -LiteralPath $script:RutaPref -Recurse -Force
        }
    }

    It 'escribe donde dice Get-RutaPreferencias, y no en otro sitio' {
        # Si la redirección de %LOCALAPPDATA% fallara, se escribiría en el
        # perfil de quien ejecuta la suite.
        $script:RutaPref.StartsWith($script:DatosPref) | Should -BeTrue -Because (
            'la suite no puede escribir preferencias en el perfil real de nadie')

        $resultado = Export-Preferencias -Preferencias $script:Preferidas -Confirm:$false
        Test-Path -LiteralPath $script:RutaPref | Should -BeTrue
        # Testigo positivo de la prueba del $false: sin él, una función que
        # devolviera siempre $false pasaría aquella.
        $resultado | Should -BeTrue -Because 'se ha guardado de verdad, y tiene que decirlo'
    }

    It 'ida y vuelta: lo guardado se recupera entero, valor a valor' {
        Export-Preferencias -Preferencias $script:Preferidas -Confirm:$false
        $leidas = Import-Preferencias

        $leidas.Tema           | Should -Be 'claro'
        $leidas.Perfil         | Should -Be 'agresivo'
        $leidas.DiasSinUso     | Should -Be 90
        $leidas.MinimoMB       | Should -Be 25
        $leidas.IncluirMenores | Should -BeTrue
        $leidas.Permanente     | Should -BeTrue
        # @() en las tres, por 5.1.
        @($leidas.ModulosActivos)    | Should -Be @('caches', 'temporales')
        @($leidas.UnidadesExcluidas) | Should -Be @('D:')
        @($leidas.RutasExcluidas)    | Should -Be @('C:\proyectos\vivo')
    }

    It 'lo escrito es JSON legible, no un volcado de PowerShell' {
        # El usuario puede abrir y editar el archivo; ConvertFrom-Json debe
        # leerlo sin ayuda.
        Export-Preferencias -Preferencias $script:Preferidas -Confirm:$false

        $texto = Get-Content -LiteralPath $script:RutaPref -Raw -Encoding UTF8
        $texto | Should -Not -BeNullOrEmpty
        { $texto | ConvertFrom-Json } | Should -Not -Throw

        # La conversión va fuera del scriptblock de Should: dentro, la
        # variable quedaría en el ámbito del bloque.
        $objeto = $texto | ConvertFrom-Json
        $objeto.Perfil     | Should -Be 'agresivo'
        $objeto.DiasSinUso | Should -Be 90
    }

    It 'una ruta con barras invertidas sobrevive al viaje sin duplicarse' {
        # JSON escapa la barra invertida; un serializador que no la
        # desescape haría que las exclusiones dejaran de casar.
        Export-Preferencias -Preferencias $script:Preferidas -Confirm:$false
        $leidas = Import-Preferencias

        @($leidas.RutasExcluidas)[0] | Should -Be 'C:\proyectos\vivo'
        @($leidas.RutasExcluidas)[0] | Should -Not -Match '\\\\'
    }

    It 'reemplaza el archivo existente a traves de un temporal que no queda' {
        Set-Content -LiteralPath $script:RutaPref -Value '{ "Perfil": "conservador" }'
        Export-Preferencias -Preferencias $script:Preferidas -Confirm:$false | Should -BeTrue

        (Import-Preferencias).Perfil | Should -Be 'agresivo'
        $carpeta = Split-Path $script:RutaPref -Parent
        @(Get-ChildItem -LiteralPath $carpeta -Filter 'preferencias.json.*.tmp').Count | Should -Be 0
    }

    It 'no escribe directamente sobre el destino' {
        # Si se escribiera directamente, un corte a mitad dejaria un JSON
        # truncado. Se comprueba que el destino aparece de golpe.
        Mock Move-ArchivoReemplazando { }
        Export-Preferencias -Preferencias $script:Preferidas -Confirm:$false | Should -BeTrue
        Test-Path -LiteralPath $script:RutaPref | Should -BeFalse
        Should -Invoke Move-ArchivoReemplazando -Times 1 -ParameterFilter {
            $Destino -eq $script:RutaPref -and $Origen -like "$($script:RutaPref).*.tmp"
        }
    }

    It 'con -WhatIf no escribe nada' {
        Export-Preferencias -Preferencias $script:Preferidas -WhatIf
        Test-Path -LiteralPath $script:RutaPref | Should -BeFalse -Because (
            'declara SupportsShouldProcess: si el ShouldProcess no estuviera dentro, escribiria igual')
    }

    It 'si el destino no se puede escribir, la funcion DEVUELVE $false' {
        # Requiere -ErrorAction Stop: sin él, Set-Content falla de forma no
        # terminante, el catch no salta y los ajustes se pierden en silencio.
        #
        # Se comprueba el valor devuelto y no solo la ausencia del archivo,
        # que por sí sola no distingue nada.
        #
        # El destino imposible es una carpeta donde va el archivo: vale en
        # Windows y en Linux y no depende de permisos.
        [void](New-Item -ItemType Directory -Path $script:RutaPref -Force)

        $resultado = Export-Preferencias -Preferencias $script:Preferidas -Confirm:$false -ErrorAction SilentlyContinue
        $resultado | Should -BeFalse -Because (
            'sin -ErrorAction Stop esto vuelve vacio y quien llama cree que se guardo')

        # Sigue siendo la carpeta: no se ha colado un archivo.
        (Get-Item -LiteralPath $script:RutaPref).PSIsContainer | Should -BeTrue

        # 2>$null: Get-Content tropieza con la carpeta y emite un error no
        # terminante que su try/catch no atrapa; no cambia el resultado.
        $leidas = Import-Preferencias 2>$null
        $leidas.Perfil     | Should -Be 'equilibrado' -Because 'no se guardo nada, asi que toca el valor por defecto'
        $leidas.Perfil     | Should -Not -Be 'agresivo'
        $leidas.DiasSinUso | Should -Be 180
        @($leidas.RutasExcluidas).Count | Should -Be 0
    }
}

<#
    Lo que este archivo no prueba:

    El camino a la papelera de Clear-CacheFirefox y Clear-Miniaturas. Sin
    -Permanente, Remove-Elemento usa Microsoft.VisualBasic.FileIO.FileSystem,
    que fuera de Windows resuelve como tipo pero falla al ejecutarse. Ese
    camino lo cubre Remove.Tests.ps1 desde Remove-Elemento.
#>

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
}
