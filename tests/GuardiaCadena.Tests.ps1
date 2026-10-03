<#
    Las dos funciones por las que pasa toda la guardia.

    ConvertTo-RutaNormalizada: todas las comparaciones de texto de la
    guardia pasan por ella. Debe quitar el prefijo "\\?\": sin eso,
    "\\?\C:\Windows" no casa con "C:\Windows" en la lista negra y sí con el
    patrón de recurso de red (empieza por dos barras). Se exige que el
    prefijo desaparezca y que lo que queda no parezca una ruta de red.

    Test-CadenaSinEnlaces: convierte la lista blanca en una afirmación
    sobre dónde están los bytes, no sobre una cadena. Sin permisos de
    administrador se puede crear

        mklink /J "%USERPROFILE%\Downloads\copia" "D:\Contabilidad"

    y "...\Downloads\copia\facturas\2025.xlsx" empieza por la raíz
    autorizada. Las pruebas del enlace afirman a la vez que Test-BajoRaiz
    dice "dentro" y que Test-CadenaSinEnlaces dice que no.
#>

BeforeDiscovery {
    # -Skip se evalúa en el descubrimiento: una bandera calculada en
    # BeforeAll valdría $null y se saltarían todas las pruebas del enlace.
    # Por eso la sonda va en BeforeDiscovery.
    #
    # Crear enlaces no siempre es posible: en Windows PowerShell 5.1 un
    # enlace simbólico exige SeCreateSymbolicLink o el modo desarrollador.
    # El junction no lo exige (por eso el ataque es viable), así que en
    # Windows se intenta primero.
    $script:PuedeEnlazar = $false
    $sonda = Join-Path ([IO.Path]::GetTempPath()) ('sonda-enlace-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path (Join-Path $sonda 'destino') -Force)
        # $IsWindows no existe en 5.1 (vale $null): de ahí el
        # "-or ($null -eq $IsWindows)".
        $tipos = if ($IsWindows -or ($null -eq $IsWindows)) { @('Junction', 'SymbolicLink') } else { @('SymbolicLink') }
        foreach ($tipo in $tipos) {
            try {
                [void](New-Item -ItemType $tipo -Path (Join-Path $sonda 'enlace') `
                                -Target (Join-Path $sonda 'destino') -ErrorAction Stop)
                $script:PuedeEnlazar = $true
                break
            } catch { $script:PuedeEnlazar = $false }
        }
    } catch { $script:PuedeEnlazar = $false }
    finally {
        # Remove-Item sobre un enlace a carpeta lanza NullReferenceException
        # en 5.1 (del proveedor, -ErrorAction no lo evita).
        # [IO.Directory]::Delete no sigue el enlace.
        if (Test-Path -LiteralPath (Join-Path $sonda 'enlace')) {
            try   { [IO.Directory]::Delete((Join-Path $sonda 'enlace'), $false) }
            catch { Write-Verbose ('No se pudo retirar el enlace de sonda: ' + $_.Exception.Message) }
        }
        if (Test-Path -LiteralPath $sonda) {
            Remove-Item -LiteralPath $sonda -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    # Test-CadenaSinEnlaces mira el disco: hace falta un taller con
    # carpetas reales. La bandera se recalcula aquí porque BeforeAll corre
    # en la fase de ejecución.
    $script:Taller = Join-Path ([IO.Path]::GetTempPath()) ('guardia-cadena-' + [guid]::NewGuid().ToString('N'))

    #   taller/
    #     zona/                 <- raíz autorizada
    #       suelto.txt
    #       sub/nieta/dentro.txt
    #       atajo -> ../fuera   <- enlace del ataque
    #     fuera/
    #       oculto/secreto.txt
    $script:Zona    = Join-Path $script:Taller 'zona'
    $script:Nieta   = Join-Path (Join-Path $script:Zona 'sub') 'nieta'
    $script:Fuera   = Join-Path $script:Taller 'fuera'
    $script:Oculto  = Join-Path $script:Fuera 'oculto'
    [void](New-Item -ItemType Directory -Path $script:Nieta  -Force)
    [void](New-Item -ItemType Directory -Path $script:Oculto -Force)

    $script:ArchivoSuelto = Join-Path $script:Zona 'suelto.txt'
    $script:ArchivoHondo  = Join-Path $script:Nieta 'dentro.txt'
    $script:Secreto       = Join-Path $script:Oculto 'secreto.txt'

    # Los .tmp son para la última prueba: Test-RutaSegura veta los .txt por
    # extensión personal, y con .tmp el único motivo de rechazo posible es
    # el enlace.
    $script:BorrableLimpio = Join-Path $script:Nieta 'residuo.tmp'
    $script:BorrableFuera  = Join-Path $script:Oculto 'residuo.tmp'
    foreach ($f in @($script:ArchivoSuelto, $script:ArchivoHondo, $script:Secreto,
                     $script:BorrableLimpio, $script:BorrableFuera)) {
        Set-Content -LiteralPath $f -Value 'contenido' -Encoding ascii
    }

    # Para la última prueba (Test-RutaSegura), con carpetas conocidas en
    # blanco para no depender del perfil de quien ejecute.
    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio = ''; Documentos = ''; Descargas = ''
        Imagenes   = ''; Musica     = ''; Videos     = ''
        CarpetaDatos = ''
    })

    $script:Atajo = Join-Path $script:Zona 'atajo'
    $script:PuedeEnlazar = $false
    $tipos = if ($IsWindows -or ($null -eq $IsWindows)) { @('Junction', 'SymbolicLink') } else { @('SymbolicLink') }
    foreach ($tipo in $tipos) {
        try {
            [void](New-Item -ItemType $tipo -Path $script:Atajo -Target $script:Fuera -ErrorAction Stop)
            $script:PuedeEnlazar = $true
            break
        } catch { $script:PuedeEnlazar = $false }
    }

    # Rutas del ataque: el texto dice "cuelga de zona", los bytes están en
    # "fuera".
    $script:CarpetaPorAtajo  = Join-Path $script:Atajo 'oculto'
    $script:SecretoPorAtajo  = Join-Path $script:CarpetaPorAtajo 'secreto.txt'
    $script:BorrablePorAtajo = Join-Path $script:CarpetaPorAtajo 'residuo.tmp'
}

AfterAll {
    if ($script:Atajo -and (Test-Path -LiteralPath $script:Atajo)) {
        # En 5.1 no se borra con Remove-Item (ver la sonda). Borrarlo
        # antes evita que el -Recurse entre por el enlace y borre el
        # destino real.
        try   { [IO.Directory]::Delete($script:Atajo, $false) }
        catch { Write-Verbose ('No se pudo retirar el atajo del taller: ' + $_.Exception.Message) }
    }
    if ($script:Taller -and (Test-Path -LiteralPath $script:Taller)) {
        Remove-Item -LiteralPath $script:Taller -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertTo-RutaNormalizada' {

    It 'una cadena vacia se queda en cadena vacia' {
        ConvertTo-RutaNormalizada '' | Should -BeExactly ''
    }

    It 'una cadena de solo espacios tambien, y no en espacios' {
        # Una ruta "en blanco pero no vacía" pasaría los filtros que
        # preguntan por cadena vacía.
        ConvertTo-RutaNormalizada '   ' | Should -BeExactly ''
    }

    It 'la barra normal, que Windows acepta, se convierte en invertida' {
        ConvertTo-RutaNormalizada 'C:/Users/Paco' | Should -BeExactly 'c:\users\paco'
    }

    It 'la barra final se quita, y tambien si hay varias' {
        ConvertTo-RutaNormalizada 'C:\Temp\'    | Should -BeExactly 'c:\temp'
        ConvertTo-RutaNormalizada 'C:\Temp\\\'  | Should -BeExactly 'c:\temp'
    }

    It 'las mayusculas bajan a minusculas' {
        ConvertTo-RutaNormalizada 'C:\WINDOWS\System32' | Should -BeExactly 'c:\windows\system32'
    }

    It 'el prefijo de ruta larga se despoja: si no, no casaria con la lista negra' {
        # "\\?\C:\Windows" y "C:\Windows" son cadenas distintas: la lista
        # negra no reconocería la carpeta protegida.
        ConvertTo-RutaNormalizada '\\?\C:\Windows' | Should -BeExactly 'c:\windows'
    }

    It 'y despues de despojarlo ya no parece un recurso de red' {
        # El filtro de red solo mira si empieza por dos barras: con el
        # prefijo, una carpeta local se rechazaría como recurso de red.
        ConvertTo-RutaNormalizada '\\?\C:\Windows' | Should -Not -Match '^\\\\'
        ConvertTo-RutaNormalizada '\\?\D:\Juegos\Steam' | Should -Not -Match '^\\\\'
    }

    It 'un recurso de red de verdad sigue empezando por dos barras' {
        # Quitar barras sin criterio dejaría de detectar los recursos de
        # red reales.
        ConvertTo-RutaNormalizada '\\Servidor\Recurso\' | Should -BeExactly '\\servidor\recurso'
    }

    It 'y un recurso de red escrito en forma larga vuelve a parecerlo' {
        ConvertTo-RutaNormalizada '\\?\UNC\Servidor\Recurso' | Should -BeExactly '\\servidor\recurso'
    }

    It 'CONTRATO: cuatro formas de escribir la MISMA ruta acaban en la misma cadena' {
        # Es lo que la función promete: todo lo anterior son las piezas.
        $formas = @(
            'C:\Users\Paco',
            'C:/Users/Paco/',
            'c:/USERS/paco\',
            '\\?\C:\USERS\PACO'
        )
        # @(): en 5.1 .Count sobre un objeto suelto vale $null.
        $distintas = @($formas | ForEach-Object { ConvertTo-RutaNormalizada $_ } | Select-Object -Unique)
        $distintas.Count | Should -Be 1
        $distintas[0]    | Should -BeExactly 'c:\users\paco'
    }
}

Describe 'Test-CadenaSinEnlaces' {

    It 'una raiz en blanco no autoriza nada' {
        Test-CadenaSinEnlaces -Ruta $script:ArchivoHondo -Raiz '   ' | Should -BeFalse
    }

    It 'una raiz vacia del todo devuelve que no, y no lanza' {
        # Requiere AllowEmptyString: con Mandatory a secas el enlazador
        # rechaza "" y la guarda interna nunca se ejecuta. Una función de
        # seguridad que lanza obliga a envolverla en un try, donde un
        # rechazo puede convertirse por descuido en un permiso.
        Test-CadenaSinEnlaces -Ruta $script:ArchivoHondo -Raiz '' | Should -BeFalse
    }

    It 'una ruta vacia tampoco autoriza nada' {
        Test-CadenaSinEnlaces -Ruta '' -Raiz $script:Zona | Should -BeFalse
    }

    It 'una ruta que no existe se rechaza' {
        # Si un tramo no se puede leer, no se puede afirmar que sea seguro.
        Test-CadenaSinEnlaces -Ruta (Join-Path $script:Nieta 'no-existe.txt') -Raiz $script:Zona |
            Should -BeFalse
    }

    It 'un archivo dentro de la raiz pasa' {
        Test-CadenaSinEnlaces -Ruta $script:ArchivoSuelto -Raiz $script:Zona | Should -BeTrue
    }

    It 'un archivo a dos carpetas de hondura tambien: se sube por su .Directory' {
        # Un FileInfo no tiene .Parent: el bucle debe arrancar desde la
        # carpeta del archivo.
        Test-CadenaSinEnlaces -Ruta $script:ArchivoHondo -Raiz $script:Zona | Should -BeTrue
    }

    It 'la carpeta que ES la raiz pasa' {
        Test-CadenaSinEnlaces -Ruta $script:Zona -Raiz $script:Zona | Should -BeTrue
    }

    It 'una carpeta intermedia limpia pasa' {
        Test-CadenaSinEnlaces -Ruta $script:Nieta -Raiz $script:Zona | Should -BeTrue
    }

    It 'la raiz se compara normalizada: con barra final da lo mismo' {
        $conBarra = $script:Zona + [IO.Path]::DirectorySeparatorChar
        Test-CadenaSinEnlaces -Ruta $script:ArchivoHondo -Raiz $conBarra | Should -BeTrue
    }

    It 'una ruta que cuelga de otro sitio se rechaza' {
        # Se sube hasta la raíz del disco sin encontrar la raíz autorizada.
        Test-CadenaSinEnlaces -Ruta $script:Secreto -Raiz $script:Zona | Should -BeFalse
    }

    It 'GUARDA: el atajo del taller es de verdad un punto de reanalisis' -Skip:(-not $script:PuedeEnlazar) {
        # Si New-Item hubiera creado una carpeta normal, las pruebas
        # siguientes mirarían otra cosa.
        Test-EsEnlace (Get-Item -LiteralPath $script:Atajo -Force) | Should -BeTrue
    }

    It 'el enlace como ultimo tramo del camino se rechaza' -Skip:(-not $script:PuedeEnlazar) {
        Test-CadenaSinEnlaces -Ruta $script:Atajo -Raiz $script:Zona | Should -BeFalse
    }

    It 'EL ATAQUE: un enlace EN MEDIO del camino se rechaza aunque el texto diga que esta dentro' -Skip:(-not $script:PuedeEnlazar) {
        # La primera afirmación distingue este caso de una ruta que
        # simplemente cuelga de otro sitio.
        Test-BajoRaiz -Ruta $script:SecretoPorAtajo -Raices @($script:Zona) | Should -BeTrue
        Test-CadenaSinEnlaces -Ruta $script:SecretoPorAtajo -Raiz $script:Zona | Should -BeFalse
    }

    It 'y lo mismo cuando lo que cuelga del enlace es una carpeta' -Skip:(-not $script:PuedeEnlazar) {
        Test-BajoRaiz -Ruta $script:CarpetaPorAtajo -Raices @($script:Zona) | Should -BeTrue
        Test-CadenaSinEnlaces -Ruta $script:CarpetaPorAtajo -Raiz $script:Zona | Should -BeFalse
    }

    It 'COSTURA: el veredicto entero lo rechaza, y por ESTE motivo' -Skip:(-not $script:PuedeEnlazar) {
        # Comprueba que Test-RutaSegura llama de verdad a esta función.
        #
        # El testigo positivo va primero: sin Initialize-Guardia,
        # Test-RutaSegura devuelve $false para todo y la segunda línea
        # pasaría igual. Los dos son .tmp a la misma profundidad; solo el
        # segundo llega por el enlace.
        Test-RutaSegura -Ruta $script:BorrableLimpio   -Raices @($script:Zona) | Should -BeTrue
        Test-RutaSegura -Ruta $script:BorrablePorAtajo -Raices @($script:Zona) | Should -BeFalse

        # Y por el motivo correcto.
        Get-MotivoBloqueo -Ruta $script:BorrablePorAtajo -Raices @($script:Zona) |
            Should -BeExactly 'Alguna carpeta del camino es un enlace: la ruta no está donde parece.'
    }
}
