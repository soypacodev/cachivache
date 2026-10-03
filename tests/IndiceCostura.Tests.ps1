<#
    Prueba de integración del índice persistente con la actualización
    incremental.

    IndicePersistente.ps1 guarda y lee; IndiceIncremental.ps1 decide si lo
    leído es fiable y le aplica cambios. Cada uno tiene sus pruebas, pero
    la integración depende de acuerdos que una prueba aislada no ve:

      1. Update-IndiceConCambios necesita Archivos como diccionario
         (Read-IndiceDisco -ComoDiccionario), no como array.
      2. Ambos lados deben coincidir en lo que guarda el diccionario
         ("ruta -> entrada"); si no, se descartan todas las bajas.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    $script:Taller = Join-Path ([IO.Path]::GetTempPath()) ('costura-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:Taller -Force)

    # Tres archivos de 2 MB, por encima del umbral y con un total redondo.
    foreach ($n in 1..3) {
        [IO.File]::WriteAllBytes((Join-Path $script:Taller "a$n.bin"), [byte[]]::new(2MB))
    }
    $script:Origen = New-IndiceDisco -Rutas @($script:Taller) -MinimoArchivoBytes 1MB
    $script:Fichero = Join-Path $script:Taller 'indice.bin'
}

AfterAll {
    if ($script:Taller -and (Test-Path -LiteralPath $script:Taller)) {
        Remove-Item -LiteralPath $script:Taller -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'el camino entero, de guardar a aplicar cambios' {

    It 'el indice de partida tiene lo que se espera' {
        # Si el recorrido no encontrara nada, lo siguiente comprobaría el
        # vacío.
        $script:Origen.Bytes | Should -Be (6MB)
        @($script:Origen.Archivos).Count | Should -Be 3
    }

    It 'se guarda y la cabecera se puede leer sin cargar el cuerpo' {
        Save-IndiceDisco -Indice $script:Origen -Ruta $script:Fichero `
                         -SerieVolumen 'AAAA-BBBB' -IdDiario '123' -UsnCorte 500 | Should -BeTrue

        $cab = Get-CabeceraIndice -Ruta $script:Fichero
        $cab               | Should -Not -BeNullOrEmpty
        $cab.Entradas      | Should -Be 3
        $cab.SerieVolumen  | Should -Be 'AAAA-BBBB'
    }

    It 'y esa cabecera la acepta quien decide si el indice se puede creer' {
        # Los campos de la cabecera deben coincidir en nombre entre las dos
        # mitades.
        $cab = Get-CabeceraIndice -Ruta $script:Fichero
        $v = Test-IndiceUtilizable -Cabecera $cab -VersionEsperada $cab.Version `
                                   -SerieVolumen 'AAAA-BBBB' -IdDiario '123' `
                                   -PrimerUsn 1 -Ahora (Get-Date)
        $v.Utilizable | Should -BeTrue -Because $v.Motivo
    }

    It 'un indice de OTRO disco se rechaza, aunque el archivo este perfecto' {
        # Caso típico: una llave USB que hereda la letra de otra. El archivo
        # está intacto; solo no cuadra el disco.
        $cab = Get-CabeceraIndice -Ruta $script:Fichero
        $v = Test-IndiceUtilizable -Cabecera $cab -VersionEsperada $cab.Version `
                                   -SerieVolumen 'CCCC-DDDD' -IdDiario '123' `
                                   -PrimerUsn 1 -Ahora (Get-Date)
        $v.Utilizable | Should -BeFalse
        $v.Codigo     | Should -Be 'VolumenDistinto'
    }

    It 'lo leido vale exactamente lo mismo que lo guardado' {
        $leido = Read-IndiceDisco -Ruta $script:Fichero
        $leido.Bytes         | Should -Be $script:Origen.Bytes
        $leido.TotalArchivos | Should -Be $script:Origen.TotalArchivos
        @($leido.Archivos).Count | Should -Be 3
    }

    It 'y una BAJA baja el total: la mentira que este punto viene a impedir' {
        # Si la propagación no restara, el mapa mostraría espacio que ya no
        # existe.
        #
        # -ComoDiccionario es necesario: con Archivos como array,
        # Update-IndiceConCambios no puede buscar rutas y descarta (con
        # aviso) todas las bajas.
        $leido = Read-IndiceDisco -Ruta $script:Fichero -ComoDiccionario
        $r = Update-IndiceConCambios -Indice $leido -Cambios @(
                 @{ Tipo = 'Baja'; Ruta = (Join-Path $script:Taller 'a1.bin') })

        $r.Confiable   | Should -BeTrue -Because $r.Motivo
        $r.Bajas       | Should -Be 1
        $r.Descartados | Should -Be 0
        $r.Indice.Bytes | Should -Be (4MB) -Because 'eran tres archivos de 2 MB y queda uno menos'
    }

    It 'un "no me fio" NUNCA viene sin motivo' {
        # Sin motivo, quien llama no puede distinguir entre cambios
        # descartados, índice descuadrado o un fallo del programa.
        $leido = Read-IndiceDisco -Ruta $script:Fichero -ComoDiccionario
        $r = Update-IndiceConCambios -Indice $leido -Cambios @(
                 @{ Tipo = 'inventado'; Ruta = 'C:\lo que sea' })

        $r.Confiable | Should -BeFalse
        $r.Motivo    | Should -Not -BeNullOrEmpty
        $r.Motivo    | Should -Match 'recorrer el disco entero'
    }

    It 'y con la forma de array avisa en vez de aplicar cambios a medias' {
        # Es un error de quien llama y debe notarse: aplicar la mitad de los
        # cambios dejaría el índice peor que antes.
        $leido = Read-IndiceDisco -Ruta $script:Fichero
        $r = Update-IndiceConCambios -Indice $leido -Cambios @(
                 @{ Tipo = 'Baja'; Ruta = (Join-Path $script:Taller 'a1.bin') })
        $r.Confiable | Should -BeFalse
        $r.Motivo    | Should -Not -BeNullOrEmpty
    }
}
