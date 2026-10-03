<#
    Prueba de integración del camino completo con archivos reales:
    CambiosLimpieza.ps1 genera las bajas e IndiceIncremental.ps1 las aplica.
    Cada parte tiene sus pruebas, pero dos mitades en verde pueden no
    encajar entre sí.

    La referencia es un análisis completo: el índice actualizado por el
    atajo debe decir exactamente lo mismo que New-IndiceDisco sobre la
    carpeta ya limpiada.

    Se borra de verdad, con Remove-Item, en una carpeta temporal propia,
    para comprobar que las rutas del índice y las del motor de borrado se
    escriben igual.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    $script:Taller = Join-Path ([IO.Path]::GetTempPath()) ('vel04-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:Taller -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $script:Taller 'cache') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $script:Taller 'cache\honda') -Force)
    # Trampa del prefijo en disco: "cache-vieja" empieza por "cache"; un
    # StartsWith sin barra la daría por contenida.
    [void](New-Item -ItemType Directory -Path (Join-Path $script:Taller 'cache-vieja') -Force)

    function script:Escribe([string] $Relativa, [int] $Mb) {
        [IO.File]::WriteAllBytes((Join-Path $script:Taller $Relativa), [byte[]]::new($Mb * 1MB))
    }
    script:Escribe 'cache\c1.bin'        2
    script:Escribe 'cache\c2.bin'        2
    script:Escribe 'cache\honda\c3.bin'  2
    script:Escribe 'cache-vieja\v1.bin'  2
    script:Escribe 'suelto.bin'          2
    script:Escribe 'otro.bin'            2

    # Se guarda y se vuelve a leer, como en el programa: New-IndiceDisco
    # devuelve la forma de array y Update-IndiceConCambios exige la de
    # diccionario, que es la que sale del archivo.
    $origen = New-IndiceDisco -Rutas @($script:Taller) -MinimoArchivoBytes 1MB
    # El índice se guarda fuera de la carpeta analizada: TotalArchivos
    # cuenta todos los archivos vistos, pero Archivos solo guarda los que
    # superan MinimoArchivoBytes, y el propio archivo del índice
    # descuadraría la comparación.
    $script:Fichero = Join-Path ([IO.Path]::GetTempPath()) ('vel04-indice-' + [guid]::NewGuid().ToString('N') + '.bin')
    [void](Save-IndiceDisco -Indice $origen -Ruta $script:Fichero -SerieVolumen 'TEST-0002' -IdDiario '0' -UsnCorte 0)
    $script:Indice = Read-IndiceDisco -Ruta $script:Fichero -ComoDiccionario
}

AfterAll {
    if ($script:Taller -and (Test-Path -LiteralPath $script:Taller)) {
        Remove-Item -LiteralPath $script:Taller -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:Fichero -and (Test-Path -LiteralPath $script:Fichero)) {
        Remove-Item -LiteralPath $script:Fichero -Force -ErrorAction SilentlyContinue
    }
}

Describe 'de la limpieza al indice actualizado' {

    It 'el indice de partida tiene lo que se espera: si no, nada de esto mide nada' {
        [int]$script:Indice.TotalArchivos | Should -Be 6
        [double]$script:Indice.Bytes      | Should -Be 12MB
    }

    It 'LA COSTURA: se limpia de verdad y el indice acaba diciendo lo mismo que un analisis completo' {
        $cache  = Join-Path $script:Taller 'cache'
        $suelto = Join-Path $script:Taller 'suelto.bin'

        # 1. Limpieza real: borra archivos del disco.
        Remove-Item -LiteralPath (Join-Path $cache 'c1.bin') -Force
        Remove-Item -LiteralPath (Join-Path $cache 'c2.bin') -Force
        Remove-Item -LiteralPath (Join-Path $cache 'honda\c3.bin') -Force
        Remove-Item -LiteralPath $suelto -Force

        # 2. Lo que Remove.ps1 dejaría en los candidatos, con uno incierto
        #    (vaciar la papelera) que no debe afectar a las bajas de los otros.
        $candidatos = @(
            [pscustomobject]@{ Ruta = $cache;  Metodo = 'Contenido'; Hecho = $true; Error = '' }
            [pscustomobject]@{ Ruta = $suelto; Metodo = 'Ruta';      Hecho = $true; Error = '' }
            [pscustomobject]@{ Ruta = 'Papelera de reciclaje'; Metodo = 'Papelera'; Hecho = $true; Error = '' }
        )

        # 3. Cálculo de las bajas.
        $resultado = Get-CambiosDeLimpieza -Candidatos $candidatos -RutasIndice @($script:Indice.Archivos.Keys)
        $resultado.Ciertos   | Should -Be 2
        $resultado.Inciertos | Should -Be 1
        @($resultado.Cambios).Count | Should -Be 4

        # 4. Se aplican.
        $aplicado = Update-IndiceConCambios -Indice $script:Indice -Cambios $resultado.Cambios
        $aplicado.Bajas     | Should -Be 4
        $aplicado.Confiable | Should -BeTrue

        # 5. Referencia: lo que daría recorrer el disco otra vez.
        $completo = New-IndiceDisco -Rutas @($script:Taller) -MinimoArchivoBytes 1MB

        [int]$aplicado.Indice.TotalArchivos | Should -Be ([int]$completo.TotalArchivos)
        [double]$aplicado.Indice.Bytes      | Should -Be ([double]$completo.Bytes)
        [int]$aplicado.Indice.TotalArchivos | Should -Be 2
        [double]$aplicado.Indice.Bytes      | Should -Be 4MB
    }

    It 'y las rutas concretas tambien coinciden, no solo los totales' {
        # Dos índices pueden sumar lo mismo con archivos distintos.
        # cache-vieja\v1.bin sigue en el disco y debe seguir en el índice.
        $completo = New-IndiceDisco -Rutas @($script:Taller) -MinimoArchivoBytes 1MB
        $delAtajo     = @($script:Indice.Archivos.Keys | Sort-Object)
        $delRecorrido = @($completo.Archivos | ForEach-Object { $_.Ruta } | Sort-Object)

        ($delAtajo -join ' | ') | Should -Be ($delRecorrido -join ' | ')
        $delAtajo | Should -Contain (Join-Path $script:Taller 'cache-vieja\v1.bin')
    }

    It 'lo que no se pudo borrar del todo se queda en el indice' {
        # Resultado parcial real de Remove.ps1: Hecho a $true y Error con
        # "quedan archivos en uso". El archivo sigue en el disco y el índice
        # debe seguir contándolo.
        $vieja = Join-Path $script:Taller 'cache-vieja'
        $antes = [double]$script:Indice.Bytes

        $r = Get-CambiosDeLimpieza -RutasIndice @($script:Indice.Archivos.Keys) -Candidatos @(
            [pscustomobject]@{
                Ruta = $vieja; Metodo = 'Contenido'; Hecho = $true
                Error = 'Quedan 2 MB: archivos en uso por algún programa abierto.'
            }
        )
        @($r.Cambios).Count | Should -Be 0

        $aplicado = Update-IndiceConCambios -Indice $script:Indice -Cambios $r.Cambios
        [double]$aplicado.Indice.Bytes | Should -Be $antes
        Test-Path -LiteralPath (Join-Path $vieja 'v1.bin') | Should -BeTrue -Because 'el archivo sigue en el disco: por eso sigue en el indice'
    }
}
