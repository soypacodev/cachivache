<#
    Reutilización del índice guardado en "cachivache espacio".

    Sin diario de cambios, un índice reutilizado describe lo que había al
    guardarlo. Es útil, pero no puede presentarse como el estado actual.
#>

BeforeAll {
    # Variables de entorno de antes de este archivo: se restauran al final
    # para no contaminar los archivos siguientes.
    $script:EntornoAntesDelArchivo = @{}
    Get-ChildItem env: | ForEach-Object { $script:EntornoAntesDelArchivo[$_.Name] = $_.Value }
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Cli') 'Cli.ps1')
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Cli') 'Espacio.ps1')
}

Describe 'La huella del volumen' {

    It 'cambia cuando cambia cualquiera de las tres cosas que la componen' {
        $base = Get-HuellaVolumen -Formato 'NTFS' -Bytes 500107862016 -Creacion ([datetime]'2024-03-11T09:12:44Z')
        (Get-HuellaVolumen -Formato 'exFAT' -Bytes 500107862016 -Creacion ([datetime]'2024-03-11T09:12:44Z')) | Should -Not -Be $base
        (Get-HuellaVolumen -Formato 'NTFS'  -Bytes 250000000000 -Creacion ([datetime]'2024-03-11T09:12:44Z')) | Should -Not -Be $base
        (Get-HuellaVolumen -Formato 'NTFS'  -Bytes 500107862016 -Creacion ([datetime]'2025-01-02T00:00:00Z')) | Should -Not -Be $base
    }

    It 'NO SE COME LOS ARGUMENTOS' {
        # En PowerShell los nombres de variable no distinguen mayúsculas:
        # un "$bytes = 0.0" al principio pisaría el argumento $Bytes sin
        # error ni aviso del analizador.
        $h = Get-HuellaVolumen -Formato 'NTFS' -Bytes 500107862016 -Creacion ([datetime]'2024-03-11T09:12:44Z')
        $h | Should -Match '500107862016' -Because 'el tamaño tiene que llegar entero a la huella'
        $h | Should -Match '2024'         -Because 'la fecha tambien'
        $h | Should -Not -Match 'sin-fecha'
    }

    It 'la fecha no depende del idioma del sistema' {
        # Con la cultura del sistema, la misma fecha se escribiría distinta
        # según el idioma de Windows y la huella cambiaría.
        $antes = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('es-ES')
            $a = Get-HuellaVolumen -Formato 'NTFS' -Bytes 1000 -Creacion ([datetime]'2024-03-11T09:12:44Z')
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('en-US')
            $b = Get-HuellaVolumen -Formato 'NTFS' -Bytes 1000 -Creacion ([datetime]'2024-03-11T09:12:44Z')
            $a | Should -Be $b
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $antes
        }
    }

    It 'no lanza con nada dentro' {
        { Get-HuellaVolumen } | Should -Not -Throw
        { Get-HuellaVolumen -Formato $null -Bytes $null -Creacion $null } | Should -Not -Throw
        { Get-HuellaVolumen -Bytes 'no soy un numero' } | Should -Not -Throw
        { Get-HuellaVolumenDeZonas -Zonas $null } | Should -Not -Throw
        { Get-HuellaVolumenDeZonas -Zonas @('Z:\no\existe') } | Should -Not -Throw
    }
}

Describe 'El nombre del archivo de indice' {

    It 'UN INDICE VALE PARA LAS CARPETAS QUE MIDIO Y PARA NINGUNA OTRA' {
        # El formato del archivo no guarda qué carpetas se midieron: el
        # nombre evita reutilizar el índice de "Descargas" para "Descargas y
        # Documentos".
        $uno = Get-NombreIndiceEspacio -Zonas @('C:\Users\x\Downloads')
        $dos = Get-NombreIndiceEspacio -Zonas @('C:\Users\x\Downloads', 'C:\Users\x\Documents')
        $uno | Should -Not -Be $dos
    }

    It 'el orden y las mayusculas no cuentan: en Windows es la misma carpeta' {
        $a = Get-NombreIndiceEspacio -Zonas @('C:\Users\x\Downloads', 'C:\Users\x\Documents')
        $b = Get-NombreIndiceEspacio -Zonas @('c:\users\X\DOCUMENTS\', 'C:\Users\x\Downloads')
        $a | Should -Be $b -Because 'si no, el indice se perderia cada vez que las zonas vinieran en otro orden'
    }

    It 'sin zonas no hay nombre, y no se inventa uno' {
        Get-NombreIndiceEspacio -Zonas @()          | Should -BeNullOrEmpty
        Get-NombreIndiceEspacio -Zonas $null        | Should -BeNullOrEmpty
        Get-NombreIndiceEspacio -Zonas @('', '  ')  | Should -BeNullOrEmpty
    }

    It 'es un nombre de archivo valido en Windows' {
        $n = Get-NombreIndiceEspacio -Zonas @('C:\Users\x\Downloads')
        $n | Should -Match '^espacio-[0-9a-f]{16}\.idx$'
        @([IO.Path]::GetInvalidFileNameChars() | Where-Object { $n.Contains($_) }).Count | Should -Be 0
    }
}

Describe 'El aviso de que los datos son de antes' {

    It 'SIEMPRE dice que no se ha mirado el disco, y como forzarlo' {
        # La segunda mitad nombra una opción, que debe existir (lo
        # comprueba una prueba posterior).
        $a = Get-AvisoIndiceReutilizado -Escrito ([datetime]'2026-09-05T10:00:00') -Ahora ([datetime]'2026-09-05T10:06:30')
        $a | Should -Match 'no se ha vuelto a mirar el disco'
        $a | Should -Match '-Recorrer'
        $a | Should -Match '6 min'
    }

    It 'con fechas imposibles avisa igual, solo que sin la antiguedad' {
        # Un reloj raro no es motivo para dejar de avisar.
        foreach ($caso in @(
            @{ E = $null; A = ([datetime]'2026-09-05') }
            @{ E = ([datetime]'2026-09-05'); A = $null }
            @{ E = ([datetime]'2026-09-05T12:00:00'); A = ([datetime]'2026-09-05T10:00:00') }
        )) {
            $a = Get-AvisoIndiceReutilizado -Escrito $caso.E -Ahora $caso.A
            $a | Should -Match 'no se ha vuelto a mirar el disco'
            $a | Should -Match '-Recorrer'
        }
    }

    It 'la opcion que nombra el aviso existe de verdad en los dos sitios' {
        # Se comprueba en el comando y en el guion de entrada, que son dos
        # declaraciones distintas.
        (Get-Command Show-InformeEspacio).Parameters.Keys | Should -Contain 'Recorrer'
        $entrada = [IO.File]::ReadAllText((Join-Path $script:Raiz 'Cachivache.ps1'))
        $entrada | Should -Match '\[switch\]\s*\$Recorrer'
        $entrada | Should -Match '-Recorrer:\$Recorrer' -Because 'declararlo y no pasarlo lo dejaria sin efecto'
    }
}

Describe 'La marca de "sin diario"' {

    It 'quien guarda y quien comprueba dicen lo mismo' {
        # Si no coincidieran, el índice se rechazaría siempre sin error
        # visible, solo más lento. Por eso es una función y no un literal.
        Get-MarcaSinDiario | Should -Be (Get-MarcaSinDiario)
        Get-MarcaSinDiario | Should -Not -BeNullOrEmpty -Because 'Test-IndiceUtilizable rechaza un identificador vacio'
    }

    It 'un indice guardado sin diario lo rechazaria un programa CON diario' {
        # Es lo correcto: un programa con diario espera un identificador
        # real y debe rechazar los índices marcados 'sin-diario'.
        $cabecera = [pscustomobject]@{
            Version = (Get-VersionFormatoIndice); SerieVolumen = 'H'; IdDiario = (Get-MarcaSinDiario)
            UsnCorte = 0; Entradas = 3; Suma = 'x'; Escrito = (Get-Date)
        }
        $v = Test-IndiceUtilizable -Cabecera $cabecera -VersionEsperada (Get-VersionFormatoIndice) `
                                   -SerieVolumen 'H' -IdDiario '133164517833123661' -PrimerUsn 100 -Ahora (Get-Date)
        $v.Utilizable | Should -BeFalse
    }
}

Describe 'De punta a punta: `espacio` reutiliza el indice, y lo dice' {

    BeforeAll {
        # Se fija LOCALAPPDATA: otro archivo de la suite puede dejarla con
        # una ruta estilo Windows inexistente en Linux, y el comando se
        # saltaría el índice en silencio (correcto, es una optimización),
        # con lo que la prueba dependería del orden de ejecución.
        $script:AppDataAntes = $env:LOCALAPPDATA
        $script:AppData = Join-Path ([IO.Path]::GetTempPath()) ('appdata-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:AppData -Force)
        $env:LOCALAPPDATA = $script:AppData

        $script:Taller = Join-Path ([IO.Path]::GetTempPath()) ('esp-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:Taller -Force)
        foreach ($n in 1..3) {
            [IO.File]::WriteAllBytes((Join-Path $script:Taller "f$n.bin"), [byte[]]::new(2MB))
        }
        function script:Corre {
            param([switch] $Recorrer)
            return ((Show-InformeEspacio -Rutas @($script:Taller) -Profundidad 1 -Archivos 2 `
                                         -Recorrer:$Recorrer 6>&1 | Out-String))
        }
    }

    AfterAll {
        # Se restaura para no afectar al archivo siguiente.
        $env:LOCALAPPDATA = $script:AppDataAntes
        foreach ($carpeta in @($script:Taller, $script:AppData)) {
            if ($carpeta -and (Test-Path -LiteralPath $carpeta)) {
                Remove-Item -LiteralPath $carpeta -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'la primera vez recorre y no avisa de nada' {
        $s = script:Corre
        $s | Should -Match '6[.,]0 MB'
        $s | Should -Not -Match 'índice guardado' -Because 'la primera vez no hay indice, y decirlo seria ruido'
    }

    It 'la segunda reutiliza Y LO DICE' {
        $s = script:Corre
        $s | Should -Match '6[.,]0 MB'
        $s | Should -Match 'índice guardado'
        $s | Should -Match '-Recorrer'
    }

    It 'SI EL DISCO CAMBIA, ENSEÑA LO VIEJO — PERO DICIENDO QUE ES VIEJO' {
        # Sin diario no se detecta el archivo nuevo: no se puede evitar
        # mostrar 6 MB donde hay 11, pero sí indicar que no es una medición
        # reciente.
        [IO.File]::WriteAllBytes((Join-Path $script:Taller 'f4.bin'), [byte[]]::new(5MB))
        $s = script:Corre
        $s | Should -Match '6[.,]0 MB'
        $s | Should -Match 'no se ha vuelto a mirar el disco'
    }

    It '-Recorrer vuelve a mirar de verdad, y deja el indice al dia' {
        $s = script:Corre -Recorrer
        $s | Should -Match '11[.,]0 MB'
        $s | Should -Not -Match 'índice guardado'

        # Lo recorrido se guarda: la siguiente ya muestra lo nuevo.
        $t = script:Corre
        $t | Should -Match '11[.,]0 MB'
        $t | Should -Match 'índice guardado'
    }

    It 'REUTILIZAR NO REJUVENECE EL INDICE, o la caducidad no caducaria nunca' {
        # Si al reutilizar se volviera a guardar, el archivo llevaría fecha
        # de hoy con datos antiguos, y la caducidad de siete días (la única
        # red sin diario) nunca se alcanzaría con consultas diarias. Solo se
        # guarda lo que se ha recorrido.
        $ruta = Join-Path (Join-Path (Get-CarpetaDatos) 'indices') (Get-NombreIndiceEspacio -Zonas @($script:Taller))
        Test-Path -LiteralPath $ruta | Should -BeTrue -Because 'sin archivo esta prueba no comprueba nada'

        $antes = (Get-CabeceraIndice -Ruta $ruta).Escrito
        Start-Sleep -Milliseconds 1100
        $s = script:Corre
        $s | Should -Match 'índice guardado' -Because 'esta pasada tiene que ser de las que reutilizan'

        $despues = (Get-CabeceraIndice -Ruta $ruta).Escrito
        $despues | Should -Be $antes -Because 'reutilizar no es medir, y la fecha dice cuando se midio'
    }

    It 'no deja rastro en las carpetas que analiza' {
        # El índice vive en los datos de la aplicación: dentro de la
        # carpeta medida la ensuciaría y se contaría a sí mismo.
        @(Get-ChildItem -LiteralPath $script:Taller -Filter '*.idx' -Recurse).Count |
            Should -Be 0 -Because 'un informe no escribe en lo que informa'
    }
}

AfterAll {
    Get-ChildItem env: | Where-Object { -not $script:EntornoAntesDelArchivo.ContainsKey($_.Name) } |
        ForEach-Object { Remove-Item -LiteralPath ('env:' + $_.Name) }
    foreach ($par in $script:EntornoAntesDelArchivo.GetEnumerator()) {
        Set-Item -LiteralPath ('env:' + $par.Key) -Value $par.Value
    }
}
