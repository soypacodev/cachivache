<#
    Los manifiestos de winget y de Scoop.

    Ambos declaran cuatro datos que cambian en cada versión: la versión sin
    la v, la URL de descarga, la carpeta dentro del zip y el SHA-256. Por eso
    se generan, y además del formato se prueban los tres puntos de unión
    que pueden desincronizarse en silencio:

      1. El nombre del zip lo decide publicar.yml y lo repiten las dos URL.
      2. La dirección del repositorio la decide src/Core/Version.ps1.
      3. El hash va en mayúsculas en winget y en minúsculas en Scoop, y debe
         ser el mismo en ambos.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:Raiz 'tools') 'Manifiestos.ps1')

    # SHA-256 en mayúsculas, como lo devuelve Get-FileHash.
    $script:Hash = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
    $script:Etiqueta = 'v2.1.0'

    $script:Identidad  = Get-IdentidadPaquete
    $script:WVersion   = Format-ManifiestoWingetVersion   -Etiqueta $script:Etiqueta
    $script:WInstalador = Format-ManifiestoWingetInstalador -Etiqueta $script:Etiqueta -Hash $script:Hash
    $script:WLocale    = Format-ManifiestoWingetLocale    -Etiqueta $script:Etiqueta
    $script:Scoop      = Format-ManifiestoScoop           -Etiqueta $script:Etiqueta -Hash $script:Hash

    # El flujo de publicación sin comentarios, para no encontrar en ellos lo que se busca.
    $script:Flujo = (Get-Content -LiteralPath (Join-Path $script:Raiz '.github/workflows/publicar.yml') |
        Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}

Describe 'Get-VersionDesdeEtiqueta: la version que ponen los manifiestos' {

    It 'quita la v inicial' {
        # winget y Scoop no ordenan 'v2.1.0' como número de versión.
        Get-VersionDesdeEtiqueta -Etiqueta 'v2.1.0' | Should -BeExactly '2.1.0'
        Get-VersionDesdeEtiqueta -Etiqueta 'v10.0.3.1' | Should -BeExactly '10.0.3.1'
    }

    It 'rechaza <Que>' -ForEach @(
        @{ Que = 'una version sin v';      Etiqueta = '2.1.0' }
        @{ Que = 'una rama';               Etiqueta = 'main' }
        @{ Que = 'el dev del disparo a mano'; Etiqueta = 'dev' }
        @{ Que = 'una v con letras';       Etiqueta = 'v2.1.0-beta' }
        @{ Que = 'solo la v';              Etiqueta = 'v' }
        @{ Que = 'un solo numero';         Etiqueta = 'v2' }
        @{ Que = 'una cadena vacia';       Etiqueta = '' }
    ) {
        # Adivinar produciría una URL de descarga que devuelve 404.
        { Get-VersionDesdeEtiqueta -Etiqueta $Etiqueta } | Should -Throw
    }

    It 'con nulo lanza, y lo dice' {
        { Get-VersionDesdeEtiqueta -Etiqueta $null } | Should -Throw -ExpectedMessage '*etiqueta*'
    }

    It 'una V mayuscula no cuela' {
        # -cnotmatch: las etiquetas son v* en minúscula y GitHub distingue mayúsculas.
        { Get-VersionDesdeEtiqueta -Etiqueta 'V2.1.0' } | Should -Throw
    }
}

Describe 'El nombre del zip y la carpeta de dentro' {

    It 'el zip lleva la etiqueta entera, con la v' {
        Get-NombrePaqueteZip -Etiqueta 'v2.1.0' | Should -BeExactly 'Cachivache-v2.1.0.zip'
    }

    It 'la carpeta de dentro del zip es el mismo nombre sin la extension' {
        # Compress-Archive -Path Cachivache-v2.1.0 comprime la carpeta, no su
        # contenido: al descomprimir aparece Cachivache-v2.1.0\Cachivache.exe.
        Get-CarpetaDentroDelZip -Etiqueta 'v2.1.0' | Should -BeExactly 'Cachivache-v2.1.0'
    }

    It 'una etiqueta invalida no llega a producir un nombre' {
        { Get-NombrePaqueteZip -Etiqueta 'dev' }     | Should -Throw
        { Get-CarpetaDentroDelZip -Etiqueta 'dev' }  | Should -Throw
    }

    It 'la URL de descarga es la de los adjuntos de la version' {
        Get-UrlDescarga -Etiqueta 'v2.1.0' -Archivo 'SHA256SUMS.txt' |
            Should -BeExactly ($script:Identidad.Repositorio + '/releases/download/v2.1.0/SHA256SUMS.txt')
    }

    It 'una URL sin archivo se rechaza' {
        { Get-UrlDescarga -Etiqueta 'v2.1.0' -Archivo '' }   | Should -Throw
        { Get-UrlDescarga -Etiqueta 'v2.1.0' -Archivo $null } | Should -Throw
    }
}

Describe 'ConvertTo-EscalarYaml: en YAML, 2.1 no es una cadena' {

    It 'deja en paz lo que no necesita comillas' {
        ConvertTo-EscalarYaml -Valor '2.1.0'    | Should -BeExactly '2.1.0'
        ConvertTo-EscalarYaml -Valor 'es-ES'    | Should -BeExactly 'es-ES'
        ConvertTo-EscalarYaml -Valor 'Cachivache-v2.1.0\Cachivache.exe' |
            Should -BeExactly 'Cachivache-v2.1.0\Cachivache.exe'
    }

    It 'entrecomilla <Que>, que YAML convertiria' -ForEach @(
        @{ Que = 'una version de dos partes'; Valor = '2.1' }
        @{ Que = 'un entero';                 Valor = '3' }
        @{ Que = 'algo con forma de si';      Valor = 'yes' }
        @{ Que = 'algo con forma de no';      Valor = 'no' }
        @{ Que = 'un nulo de YAML';           Valor = '~' }
        @{ Que = 'algo que empieza por guion'; Valor = '- raro' }
        @{ Que = 'algo con dos puntos y espacio'; Valor = 'clave: valor' }
    ) {
        (ConvertTo-EscalarYaml -Valor $Valor).StartsWith("'") | Should -BeTrue
        (ConvertTo-EscalarYaml -Valor $Valor).EndsWith("'")   | Should -BeTrue
    }

    It 'duplica las comillas simples de dentro' {
        # Una comilla inicial es un indicador de YAML y obliga a entrecomillar;
        # el caso empieza por ella para ejercitar también la duplicación.
        ConvertTo-EscalarYaml -Valor "'ojo'" | Should -BeExactly "'''ojo'''"
    }

    It 'una cadena vacia sale como cadena vacia, no como nada' {
        # "clave:" a secas es null en YAML; el esquema de winget pide cadena.
        ConvertTo-EscalarYaml -Valor '' | Should -BeExactly "''"
        ConvertTo-EscalarYaml -Valor $null | Should -BeExactly "''"
    }

    It 'la version de dos partes llega entrecomillada al manifiesto' {
        # Comprueba que se usa: "PackageVersion: 2.1" sería el número 2.1 en
        # YAML, y el validador de winget lo rechaza.
        Format-ManifiestoWingetVersion -Etiqueta 'v2.1' | Should -Match "PackageVersion: '2\.1'"
    }
}

Describe 'winget: los tres manifiestos' {

    It 'las pruebas leen tres manifiestos de verdad: si no, no comprueban nada' {
        foreach ($texto in @($script:WVersion, $script:WInstalador, $script:WLocale)) {
            $texto.Length | Should -BeGreaterThan 150
            $texto | Should -Match 'PackageIdentifier:'
        }
        # Deben ser distintos entre sí.
        (@($script:WVersion, $script:WInstalador, $script:WLocale) | Select-Object -Unique).Count |
            Should -Be 3
    }

    It 'cada uno declara su ManifestType, y son los tres que winget espera' {
        $script:WVersion    | Should -Match '(?m)^ManifestType: version$'
        $script:WInstalador | Should -Match '(?m)^ManifestType: installer$'
        $script:WLocale     | Should -Match '(?m)^ManifestType: defaultLocale$'
    }

    It 'los tres hablan del mismo paquete y de la misma version' {
        foreach ($texto in @($script:WVersion, $script:WInstalador, $script:WLocale)) {
            $texto | Should -Match ('(?m)^PackageIdentifier: ' + [regex]::Escape($script:Identidad.IdentificadorWinget) + '$')
            $texto | Should -Match '(?m)^PackageVersion: 2\.1\.0$'
        }
    }

    It 'el identificador tiene la forma Editor.Paquete que exige winget' {
        $script:Identidad.IdentificadorWinget | Should -Match '^[^.\s]{1,32}(\.[^.\s]{1,32}){1,7}$'
    }

    It 'el DefaultLocale del manifiesto de version es el PackageLocale del otro' {
        # Si no coinciden, winget no encuentra la descripción por defecto.
        $script:WVersion | Should -Match ('(?m)^DefaultLocale: ' + [regex]::Escape($script:Identidad.Idioma) + '$')
        $script:WLocale  | Should -Match ('(?m)^PackageLocale: ' + [regex]::Escape($script:Identidad.Idioma) + '$')
    }

    It 'el instalador es un zip portable con archivo anidado' {
        # Así winget acepta un paquete sin firmar: no ejecuta ningún instalador,
        # descomprime y crea un alias.
        $script:WInstalador | Should -Match '(?m)^InstallerType: zip$'
        $script:WInstalador | Should -Match '(?m)^NestedInstallerType: portable$'
        $script:WInstalador | Should -Match '(?m)^NestedInstallerFiles:$'
    }

    It 'la ruta del ejecutable dentro del zip lleva la carpeta de la version' {
        # Sin la carpeta, winget instala pero no encuentra el ejecutable.
        $script:WInstalador | Should -Match 'RelativeFilePath: Cachivache-v2\.1\.0\\Cachivache\.exe'
    }

    It 'la URL del instalador apunta al zip de esta version' {
        $esperada = Get-UrlDescarga -Etiqueta $script:Etiqueta -Archivo (Get-NombrePaqueteZip -Etiqueta $script:Etiqueta)
        $script:WInstalador | Should -Match ('(?m)^\s+InstallerUrl: ' + [regex]::Escape($esperada) + '$')
    }

    It 'el SHA-256 va en MAYUSCULAS' {
        # Igual que wingetcreate, para que regenerar solo cambie el hash si cambia el paquete.
        $script:WInstalador | Should -MatchExactly ('InstallerSha256: ' + $script:Hash.ToUpperInvariant())
        $script:WInstalador | Should -Not -MatchExactly ('InstallerSha256: ' + $script:Hash.ToLowerInvariant())
    }

    It 'un hash que no tiene forma de hash no llega a producir manifiesto' {
        # Una suma errónea hace que quien instala vea el paquete como adulterado.
        { Format-ManifiestoWingetInstalador -Etiqueta $script:Etiqueta -Hash 'e3b0c442' } | Should -Throw
        { Format-ManifiestoWingetInstalador -Etiqueta $script:Etiqueta -Hash '' }         | Should -Throw
        { Format-ManifiestoWingetInstalador -Etiqueta $script:Etiqueta -Hash $null }      | Should -Throw
    }

    It 'el manifiesto de idioma lleva lo que winget exige para publicar' {
        foreach ($clave in @('Publisher', 'PackageName', 'License', 'ShortDescription')) {
            $script:WLocale | Should -Match ('(?m)^' + $clave + ': \S')
        }
    }

    It 'la licencia que declara es la del repositorio' {
        # LICENSE es MIT.
        $licencia = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'LICENSE')
        $licencia | Should -Match 'MIT License'
        $script:Identidad.Licencia | Should -BeExactly 'MIT'
    }

    It 'los tres terminan en salto de linea y ninguno lleva retornos de carro' {
        foreach ($texto in @($script:WVersion, $script:WInstalador, $script:WLocale)) {
            $texto | Should -Not -Match "`r"
            $texto.EndsWith("`n") | Should -BeTrue
        }
    }
}

Describe 'Scoop: el .json' {

    BeforeAll {
        $script:ScoopObjeto = $script:Scoop | ConvertFrom-Json
    }

    It 'la prueba lee un JSON de verdad: si no, no comprueba nada' {
        { $script:Scoop | ConvertFrom-Json } | Should -Not -Throw
        $script:ScoopObjeto.version | Should -Not -BeNullOrEmpty
    }

    It 'la version va sin la v' {
        $script:ScoopObjeto.version | Should -BeExactly '2.1.0'
    }

    It 'el hash va en MINUSCULAS' {
        # El autoupdate toma el hash de SHA256SUMS.txt, que Sumas.ps1 escribe en
        # minúsculas; así cualquier comparación literal coincide.
        $script:ScoopObjeto.hash | Should -BeExactly $script:Hash.ToLowerInvariant()
    }

    It 'la url apunta al zip de esta version' {
        $script:ScoopObjeto.url | Should -BeExactly (
            Get-UrlDescarga -Etiqueta $script:Etiqueta -Archivo (Get-NombrePaqueteZip -Etiqueta $script:Etiqueta))
    }

    It 'extract_dir es la carpeta que hay dentro del zip' {
        # Sin esto, Scoop deja una carpeta intermedia y el acceso directo no funciona.
        $script:ScoopObjeto.extract_dir | Should -BeExactly (Get-CarpetaDentroDelZip -Etiqueta $script:Etiqueta)
    }

    It 'da un shim de consola y un acceso directo de ventana' {
        # Hacen falta las dos: un shim al .exe abriría una ventana sin salida
        # en la terminal, y solo el acceso directo no sirve desde la terminal.
        $script:ScoopObjeto.bin[0][0]       | Should -BeExactly 'Cachivache.ps1'
        $script:ScoopObjeto.bin[0][1]       | Should -BeExactly 'cachivache'
        $script:ScoopObjeto.shortcuts[0][0] | Should -BeExactly 'Cachivache.exe'
    }

    It 'lleva checkver y autoupdate' {
        # Permiten que Scoop se actualice aunque el .json no se regenere.
        $script:ScoopObjeto.checkver.github | Should -BeExactly $script:Identidad.Repositorio
        $script:ScoopObjeto.autoupdate.url  | Should -Not -BeNullOrEmpty
    }

    It 'el autoupdate deja los marcadores de Scoop sin expandir' {
        # $version y $baseurl los sustituye Scoop; con comillas dobles
        # PowerShell los expandiría a cadena vacía.
        $script:ScoopObjeto.autoupdate.url         | Should -BeLike '*/v$version/Cachivache-v$version.zip'
        # Con la v: la carpeta del zip lleva la etiqueta y $version va sin ella.
        $script:ScoopObjeto.autoupdate.extract_dir | Should -BeExactly 'Cachivache-v$version'
        $script:ScoopObjeto.autoupdate.hash.url    | Should -BeExactly '$baseurl/SHA256SUMS.txt'
    }

    It 'el autoupdate saca el hash del archivo que publica el flujo' {
        # $baseurl es la carpeta de adjuntos, donde action-gh-release deja SHA256SUMS.txt.
        $script:Flujo | Should -Match 'SHA256SUMS\.txt'
        $script:ScoopObjeto.autoupdate.hash.url | Should -BeLike '*SHA256SUMS.txt'
    }

    It 'un hash que no tiene forma de hash no llega a producir manifiesto' {
        { Format-ManifiestoScoop -Etiqueta $script:Etiqueta -Hash 'e3b0c442' } | Should -Throw
        { Format-ManifiestoScoop -Etiqueta $script:Etiqueta -Hash $null }      | Should -Throw
    }

    It 'saltos LF, salto final, y ningun retorno de carro' {
        # ConvertTo-Json devuelve CRLF en Windows.
        $script:Scoop | Should -Not -Match "`r"
        $script:Scoop.EndsWith("`n") | Should -BeTrue
    }
}

Describe 'Los dos manifiestos dicen lo mismo' {
    <#
        Son dos representaciones del mismo paquete y no pueden divergir.
    #>

    It 'la misma version' {
        $scoop = $script:Scoop | ConvertFrom-Json
        $script:WInstalador | Should -Match ('(?m)^PackageVersion: ' + [regex]::Escape($scoop.version) + '$')
    }

    It 'el mismo hash, cada uno en su caso' {
        $scoop = $script:Scoop | ConvertFrom-Json
        # El mismo hash con distinta capitalización, no dos hashes.
        $script:WInstalador | Should -MatchExactly ('InstallerSha256: ' + $scoop.hash.ToUpperInvariant())
        $scoop.hash | Should -MatchExactly '^[0-9a-f]{64}$'
    }

    It 'la misma URL de descarga' {
        $scoop = $script:Scoop | ConvertFrom-Json
        $script:WInstalador | Should -Match ('InstallerUrl: ' + [regex]::Escape($scoop.url))
    }
}

Describe 'La costura con el flujo de publicacion' {
    <#
        El nombre del zip lo decide publicar.yml y lo repiten las dos URL;
        renombrarlo solo allí publicaría manifiestos que apuntan a un 404.
    #>

    It 'la prueba lee el flujo de verdad: si no, no comprueba nada' {
        $script:Flujo.Length | Should -BeGreaterThan 1000
        $script:Flujo | Should -Match 'Compress-Archive'
        $script:Flujo | Should -Match 'action-gh-release'
    }

    It 'el zip que arma el flujo se llama como dice Get-NombrePaqueteZip' {
        $carpeta = [regex]::Match($script:Flujo, '\$carpeta\s*=\s*"([^"]+)"')
        $carpeta.Success | Should -BeTrue -Because 'sin encontrar el nombre, esta prueba no compara nada'

        # El flujo escribe "Cachivache-$env:VERSION"; se sustituye la variable
        # por una etiqueta y se compara con los manifiestos. La versión la
        # decide un solo paso y los demás la leen del entorno.
        $delFlujo = $carpeta.Groups[1].Value.Replace('$env:VERSION', 'v2.1.0')
        ($delFlujo + '.zip') | Should -BeExactly (Get-NombrePaqueteZip -Etiqueta 'v2.1.0')
        $delFlujo            | Should -BeExactly (Get-CarpetaDentroDelZip -Etiqueta 'v2.1.0')
    }

    It 'y el zip se arma a partir de esa misma carpeta' {
        # "$carpeta.zip" debe ser el nombre del archivo, no otro -DestinationPath.
        $script:Flujo | Should -Match 'Compress-Archive -Path \$carpeta -DestinationPath "\$carpeta\.zip"'
    }

    It 'los manifiestos se generan DESPUES de armar el paquete' {
        # Antes no existiría el zip, o sería el de la ejecución anterior.
        $posPaquete = $script:Flujo.IndexOf('Compress-Archive')
        $posManifiestos = $script:Flujo.IndexOf('Publicar-Manifiestos.ps1')

        $posPaquete     | Should -BeGreaterThan 0
        $posManifiestos | Should -BeGreaterThan $posPaquete
    }

    It 'y ANTES de adjuntar nada' {
        $posManifiestos = $script:Flujo.IndexOf('Publicar-Manifiestos.ps1')
        $posAdjuntar    = $script:Flujo.IndexOf('action-gh-release')

        $posAdjuntar | Should -BeGreaterThan $posManifiestos
    }

    It 'el flujo comprueba lo que ha escrito antes de subirlo' {
        # La comprobación sigue un camino independiente: recalcula el hash del
        # zip y lo compara con lo escrito en los archivos.
        $script:Flujo | Should -Match 'ConvertFrom-Json'
        $script:Flujo | Should -Match 'Get-FileHash'
        $script:Flujo | Should -Match '-cne'
    }

    It 'el flujo adjunta los cuatro manifiestos a la version' {
        # Sin subirlos se perderían con el runner.
        #
        # Se mira solo el bloque files: del paso que publica: el paso que los
        # comprueba también nombra los archivos.
        $bloque = [regex]::Match($script:Flujo, '(?s)files: \|(.*?)\n\s*body: \|')
        $bloque.Success | Should -BeTrue -Because 'sin el bloque files:, esta prueba no comprueba nada'
        $adjuntos = $bloque.Groups[1].Value

        $identidad = Get-IdentidadPaquete
        foreach ($archivo in @(
            'packaging/{0}.json'                  -f $identidad.IdentificadorScoop
            'packaging/winget/{0}.yaml'           -f $identidad.IdentificadorWinget
            'packaging/winget/{0}.installer.yaml' -f $identidad.IdentificadorWinget
            ('packaging/winget/{0}.locale.{1}.yaml' -f $identidad.IdentificadorWinget, $identidad.Idioma)
        )) {
            $adjuntos | Should -Match ('(?m)^\s*' + [regex]::Escape($archivo) + '\s*$')
        }
    }

    It 'los manifiestos SI se generan en el ensayo a mano' {
        # El disparo manual no trae etiqueta: la versión sale de Version.ps1 y
        # el ensayo recorre todo el flujo salvo la publicación, incluida la
        # generación de manifiestos.
        $pos = $script:Flujo.IndexOf('Generar los manifiestos')
        $pos | Should -BeGreaterThan 0
        $paso = $script:Flujo.Substring($pos, 900)
        $paso | Should -Not -Match "startsWith\(github\.ref, 'refs/tags/'\)" -Because (
            'saltarse este paso en el ensayo lo deja sin probar hasta la version de verdad')
        $paso | Should -Match '-Etiqueta \$env:VERSION' -Because (
            'la version la decide un solo paso al principio; aqui solo se lee')
    }

    It 'y aun asi el ensayo no puede publicar nada' {
        # El único paso que sube archivos sigue exigiendo etiqueta.
        $script:Flujo | Should -Match (
            "(?s)- name: Adjuntar a la version\s*\r?\n\s*if:\s*startsWith\(github\.ref,\s*'refs/tags/'\)")
    }
}

Describe 'La costura con la version del programa' {

    It 'el repositorio que declaran los manifiestos es el de src/Core/Version.ps1' {
        # Version.ps1 es la única fuente de la dirección del repositorio.
        $texto = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/Core/Version.ps1')
        $url = [regex]::Match($texto, "RepositorioUrl\s*=\s*'([^']+)'")
        $url.Success | Should -BeTrue -Because 'sin encontrar la URL, esta prueba no compara nada'

        (Get-IdentidadPaquete).Repositorio | Should -BeExactly $url.Groups[1].Value
    }

    It 'todas las URL de los manifiestos cuelgan de ese repositorio' {
        $repo = (Get-IdentidadPaquete).Repositorio
        $urls = [regex]::Matches(
            ($script:WVersion + $script:WInstalador + $script:WLocale + $script:Scoop),
            'https://github\.com/[^\s",]+')

        $urls.Count | Should -BeGreaterThan 5 -Because 'si no hay URL, esta prueba no comprueba nada'
        foreach ($u in $urls) {
            # UrlEditor es el usuario, del que cuelga el repositorio.
            $u.Value | Should -BeLike ((Get-IdentidadPaquete).UrlEditor + '*')
        }
        $repo | Should -BeLike ((Get-IdentidadPaquete).UrlEditor + '/*')
    }
}

Describe 'Publicar-Manifiestos.ps1: de punta a punta' {
    <#
        Prueba la escritura de los archivos, no solo su formato. Con BOM, los
        validadores de winget-pkgs rechazan el YAML y ConvertFrom-Json de
        PowerShell 5.1 lee mal el JSON.
    #>

    BeforeAll {
        $script:Temporal = Join-Path ([IO.Path]::GetTempPath()) ("paquetes-" + [Guid]::NewGuid().ToString('N'))
        $script:Interior = Join-Path $script:Temporal 'Cachivache-v9.9.9'
        New-Item -ItemType Directory -Path $script:Interior -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Interior 'Cachivache.ps1') -Value 'exit 0'

        $script:Zip = Join-Path $script:Temporal 'Cachivache-v9.9.9.zip'
        Compress-Archive -Path $script:Interior -DestinationPath $script:Zip

        $script:Salida = Join-Path $script:Temporal 'packaging'
        & (Join-Path (Join-Path $script:Raiz 'tools') 'Publicar-Manifiestos.ps1') `
            -Etiqueta 'v9.9.9' -Paquete $script:Zip -Destino $script:Salida | Out-Null

        $script:Escritos = @(Get-ChildItem -LiteralPath $script:Salida -Recurse -File)

        # Sin comentarios: el guion menciona "Out-File" en uno de ellos.
        $script:Guion = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (
                Join-Path (Join-Path $script:Raiz 'tools') 'Publicar-Manifiestos.ps1')),
            '(?s)<#.*?#>', '')
        $script:Guion = (($script:Guion -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Temporal -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'escribe los cuatro archivos' {
        $script:Escritos.Count | Should -Be 4
        @($script:Escritos.Name) | Should -Contain 'cachivache.json'
    }

    It 'ninguno lleva BOM' {
        # Al contrario que los .ps1 y .xaml del proyecto, que exigen BOM.
        foreach ($archivo in $script:Escritos) {
            $bytes = [IO.File]::ReadAllBytes($archivo.FullName)
            $bytes.Length | Should -BeGreaterThan 3
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
                Should -BeFalse -Because "$($archivo.Name) no puede empezar por el BOM de UTF-8"
        }
    }

    It 'ninguno lleva retornos de carro' {
        foreach ($archivo in $script:Escritos) {
            [IO.File]::ReadAllText($archivo.FullName) | Should -Not -Match "`r"
        }
    }

    It 'el hash escrito es el del zip de verdad, no uno de antes' {
        # Se recalcula por un camino independiente.
        $real = (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash

        $scoop = Get-Content -Raw -LiteralPath (Join-Path $script:Salida 'cachivache.json') | ConvertFrom-Json
        $scoop.hash | Should -BeExactly $real.ToLowerInvariant()

        $instalador = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path $script:Salida 'winget') 'FranciscoLopez.Cachivache.installer.yaml')
        $instalador | Should -MatchExactly ('InstallerSha256: ' + $real.ToUpperInvariant())
    }

    It 'los nombres de archivo son los que adjunta el flujo' {
        # Si no coinciden, la versión sale sin manifiesto y el paso queda verde.
        foreach ($archivo in $script:Escritos) {
            $script:Flujo | Should -Match ([regex]::Escape($archivo.Name))
        }
    }

    It 'un zip que no se llama como toca para la publicacion' {
        # El nombre del zip y el de los manifiestos deben coincidir.
        $otro = Join-Path $script:Temporal 'Cachivache.zip'
        Copy-Item -LiteralPath $script:Zip -Destination $otro
        {
            & (Join-Path (Join-Path $script:Raiz 'tools') 'Publicar-Manifiestos.ps1') `
                -Etiqueta 'v9.9.9' -Paquete $otro -Destino $script:Salida
        } | Should -Throw -ExpectedMessage '*404*'
    }

    It 'un paquete que no existe para la publicacion' {
        {
            & (Join-Path (Join-Path $script:Raiz 'tools') 'Publicar-Manifiestos.ps1') `
                -Etiqueta 'v9.9.9' -Paquete (Join-Path $script:Temporal 'no-existe.zip') -Destino $script:Salida
        } | Should -Throw
    }

    It 'el guion no acepta un hash por parametro' {
        # El hash se calcula siempre del zip; no se acepta uno copiado a mano.
        $script:Guion.Length | Should -BeGreaterThan 500 -Because 'sin guion, esta prueba no comprueba nada'
        $script:Guion | Should -Not -Match '(?m)^\s*\[string\]\s*\$Hash'
        $script:Guion | Should -Match 'Get-FileHash'
    }

    It 'escribe con WriteAllText y sin BOM, no con Out-File' {
        # Sin BOM (ver el Describe), y Out-File en Windows convertiría los saltos a CRLF.
        $script:Guion | Should -Match '\[Text\.UTF8Encoding\]::new\(\$false\)'
        $script:Guion | Should -Not -Match 'Out-File'
    }
}

Describe 'El README cuenta las dos formas nuevas de instalar' {

    BeforeAll {
        $script:Lectura = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'README.md')
    }

    It 'la prueba lee el README de verdad: si no, no comprueba nada' {
        $script:Lectura.Length | Should -BeGreaterThan 5000
        $script:Lectura | Should -Match '## Empezar'
    }

    It 'nombra winget y Scoop' {
        $script:Lectura | Should -Match 'winget'
        $script:Lectura | Should -Match 'Scoop'
    }

    It 'y no promete que ya este en el repositorio de winget' {
        # El paquete no está en microsoft/winget-pkgs: "winget install Cachivache" fallaría.
        $script:Lectura | Should -Match 'packaging/README\.md|packaging\\README\.md'
    }
}

Describe 'Lo que se le entrega al usuario: cada cosa, con su motivo' {

    # El paquete no debe incluir herramientas de desarrollo: algunas, como
    # Banco-Pruebas.ps1 (crea y borra árboles) o Mutar.ps1 (reescribe
    # fuentes), son peligrosas para el usuario final.
    #
    # En lugar de prohibir nombres concretos, se exige que cada elemento
    # del paquete esté declarado aquí con su motivo.

    BeforeAll {
        $script:RaizPaq = Split-Path $PSScriptRoot -Parent
        $script:Publicar = [IO.File]::ReadAllText(
            (Join-Path (Join-Path (Join-Path $script:RaizPaq '.github') 'workflows') 'publicar.yml'))

        # Lo que se entrega y por qué. Todo lo que se añada al flujo debe
        # declararse aquí con su motivo.
        $script:MotivoDeCadaCosa = @{
            'src'             = 'el programa entero: sin esto no hay nada que ejecutar'
            'assets'          = 'los iconos que carga la ventana al abrirse'
            'Cachivache.ps1'  = 'el punto de entrada, en modo ventana y en modo consola'
            'Cachivache.bat'  = 'el arranque para quien no quiera usar el .exe'
            'Cachivache.exe'  = 'el lanzador sin consola negra detras; lo compila el paso anterior'
            'README.md'       = 'que es esto y como se usa'
            'LICENSE'         = 'la licencia; distribuir sin ella no es legal'
            'SECURITY.md'     = 'que hace el programa con tus archivos, que es lo que el proyecto promete que se puede leer'
        }
    }

    It 'la prueba encuentra la lista de verdad: si no, no comprueba nada' {
        $script:Publicar | Should -Match "foreach \(\`$elemento in @\("
    }

    It 'todo lo que se empaqueta esta declarado con su motivo' {
        $m = [regex]::Match($script:Publicar, "(?s)foreach \(\`$elemento in @\((?<lista>.*?)\)\) \{")
        $m.Success | Should -BeTrue
        $entregado = @([regex]::Matches($m.Groups['lista'].Value, "'(?<e>[^']+)'") |
                       ForEach-Object { $_.Groups['e'].Value })
        @($entregado).Count | Should -BeGreaterThan 4 -Because 'si la lista sale vacia, esto no mira nada'

        $sinMotivo = @($entregado | Where-Object { -not $script:MotivoDeCadaCosa.ContainsKey($_) })
        ($sinMotivo -join ', ') | Should -BeNullOrEmpty -Because (
            'lo que se le entrega a un usuario se justifica una por una, o acaba viajando algo que nadie decidio mandar')

        # Y al revés: no hay motivos para cosas que ya no se entregan.
        $sinEntregar = @($script:MotivoDeCadaCosa.Keys | Where-Object { $entregado -notcontains $_ })
        ($sinEntregar -join ', ') | Should -BeNullOrEmpty
    }

    It 'no viaja NADA que cree, borre o reescriba archivos por su cuenta' {
        # Se mira el contenido de cada carpeta entregada, no su nombre.
        $m = [regex]::Match($script:Publicar, "(?s)foreach \(\`$elemento in @\((?<lista>.*?)\)\) \{")
        $entregado = @([regex]::Matches($m.Groups['lista'].Value, "'(?<e>[^']+)'") |
                       ForEach-Object { $_.Groups['e'].Value })

        $peligrosos = @()
        foreach ($e in $entregado) {
            $ruta = Join-Path $script:RaizPaq $e
            if (-not (Test-Path -LiteralPath $ruta)) { continue }
            if (-not (Get-Item -LiteralPath $ruta).PSIsContainer) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $ruta -Recurse -File)) {
                if ($f.Name -match '\.Tests\.ps1$' -or $f.Name -match '^(Banco-|Mutar|Probar|Cobertura)') {
                    $peligrosos += ('{0} trae {1}' -f $e, $f.Name)
                }
            }
        }
        ($peligrosos -join ' // ') | Should -BeNullOrEmpty -Because (
            'quien se baja un limpiador no debe recibir bancos de pruebas ni el mutador')
    }

    It 'y tampoco viajan las pruebas ni la configuracion del repositorio' {
        $m = [regex]::Match($script:Publicar, "(?s)foreach \(\`$elemento in @\((?<lista>.*?)\)\) \{")
        $entregado = @([regex]::Matches($m.Groups['lista'].Value, "'(?<e>[^']+)'") |
                       ForEach-Object { $_.Groups['e'].Value })
        foreach ($prohibido in @('tests', '.github', 'pruebas', 'docs')) {
            $entregado | Should -Not -Contain $prohibido
        }
    }
}

Describe 'El lanzador pasa cada argumento intacto' {
    <#
        Cachivache.exe arma la linea de ordenes de powershell.exe a partir de
        sus propios argumentos. Se compila solo la clase de escapado del
        codigo del lanzador (el resto usa Windows Forms) y se comprueba con
        el analizador de .NET, que parte la linea con las mismas reglas que
        Windows tambien fuera de el.
    #>

    BeforeAll {
        $guion = Join-Path (Join-Path $script:Raiz 'tools') 'Compilar-Lanzador.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($guion, [ref]$null, [ref]$null)
        $asignacion = $ast.Find({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$fuente' }, $true)
        $fuente = $asignacion.Right.Expression.Value
        $clase = [regex]::Match($fuente, '(?s)static class LineaDeOrdenes\s*\{.*?\r?\n\}').Value
        $script:ClaseLanzador = $clase
        if (-not ('LineaDeOrdenes' -as [type])) {
            Add-Type -TypeDefinition ("using System;`nusing System.Text;`n" + $clase.Replace('static class', 'public static class'))
        }

        $script:Casos = @(
            'simple'
            'con espacios'
            'comilla"dentro'
            'C:\carpeta con espacios\'
            'barras\\antes"de comilla'
            'a\b\\c'
            'termina en dos barras\\'
            ''
        )
    }

    It 'la clase de escapado esta en el codigo del lanzador' {
        $script:ClaseLanzador | Should -Match 'public static string Citar'
    }

    It 'cita sin escapar lo que no lo necesita' {
        [LineaDeOrdenes]::Citar('con espacios') | Should -BeExactly '"con espacios"'
        [LineaDeOrdenes]::Citar('')             | Should -BeExactly '""'
    }

    It 'dobla las barras finales y escapa las comillas internas' {
        [LineaDeOrdenes]::Citar('C:\carpeta\')   | Should -BeExactly '"C:\carpeta\\"'
        [LineaDeOrdenes]::Citar('di "hola"')     | Should -BeExactly '"di \"hola\""'
        [LineaDeOrdenes]::Citar('a\"b')          | Should -BeExactly '"a\\\"b"'
        [LineaDeOrdenes]::Citar('a\b')           | Should -BeExactly '"a\b"'
    }

    It 'la linea compuesta se parte en los mismos argumentos (Windows)' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        # En Windows se usa el mismo analizador que el sistema aplica a la
        # linea de ordenes del proceso: CommandLineToArgvW.
        if (-not ('PartirLineaDeOrdenes' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PartirLineaDeOrdenes {
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CommandLineToArgvW(string linea, out int cuantos);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memoria);
    public static string[] Partir(string linea) {
        int cuantos;
        IntPtr lista = CommandLineToArgvW(linea, out cuantos);
        try {
            string[] argumentos = new string[cuantos];
            for (int i = 0; i < cuantos; i++) {
                argumentos[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(lista, i * IntPtr.Size));
            }
            return argumentos;
        } finally { LocalFree(lista); }
    }
}
'@
        }
        $linea = 'programa.exe ' + (($script:Casos | ForEach-Object { [LineaDeOrdenes]::Citar($_) }) -join ' ')
        $recibidos = @([PartirLineaDeOrdenes]::Partir($linea) | Select-Object -Skip 1)
        $recibidos.Count | Should -Be $script:Casos.Count
        for ($i = 0; $i -lt $script:Casos.Count; $i++) {
            $recibidos[$i] | Should -BeExactly $script:Casos[$i]
        }
    }

    It 'la linea compuesta se parte en los mismos argumentos (.NET)' -Skip:([Environment]::OSVersion.Platform -eq 'Win32NT') {
        # Fuera de Windows se lanza este mismo PowerShell con la linea
        # compuesta y devuelve lo que ha recibido; .NET la parte con las
        # mismas reglas.
        $taller = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-args-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $taller -Force | Out-Null
        $eco = Join-Path $taller 'eco.ps1'
        Set-Content -LiteralPath $eco -Value 'ConvertTo-Json -InputObject @($args) -Compress'
        try {
            $inicio = [Diagnostics.ProcessStartInfo]::new()
            $inicio.FileName = (Get-Process -Id $PID).Path
            $inicio.Arguments = '-NoProfile -NonInteractive -File ' + [LineaDeOrdenes]::Citar($eco) + ' ' +
                                (($script:Casos | ForEach-Object { [LineaDeOrdenes]::Citar($_) }) -join ' ')
            $inicio.UseShellExecute = $false
            $inicio.RedirectStandardOutput = $true
            $proceso = [Diagnostics.Process]::Start($inicio)
            $salida = $proceso.StandardOutput.ReadToEnd()
            $proceso.WaitForExit()
        } finally {
            Remove-Item -LiteralPath $taller -Recurse -Force -ErrorAction SilentlyContinue
        }

        $recibidos = @($salida | ConvertFrom-Json)
        $recibidos.Count | Should -Be $script:Casos.Count
        for ($i = 0; $i -lt $script:Casos.Count; $i++) {
            $recibidos[$i] | Should -BeExactly $script:Casos[$i]
        }
    }
}
