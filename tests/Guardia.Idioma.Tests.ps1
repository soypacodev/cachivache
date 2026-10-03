<#
    Las listas de palabras de la guardia no son texto de interfaz.

    Test-CarpetaEspejo, Test-ArchivoPersonal y la lista de nombres
    sensibles comparan contra palabras en castellano e inglés
    ("documentos"/"documents", "respaldo"/"backup"). Parecen cadenas
    traducibles, pero son la lógica que decide qué no se puede borrar. Si
    una extracción de textos las llevara a un archivo de idioma y se
    tradujeran, desaparecería una de las mitades y la guardia empezaría a
    aceptar rutas que antes vetaba, sin ningún error visible.

    La invariante tiene dos partes:

      1. Estructura: las listas son texto literal en src/Core/Guard.ps1,
         sin variables ni llamadas en su valor; Guard.ps1 no lee texto de
         archivos, recursos ni cultura, y ningún otro archivo de src las
         reasigna.
      2. Contenido: se pregunta a las funciones públicas (no a los arrays)
         y se exige el par completo en los dos idiomas, para detectar
         también que una función pase a consultar otra fuente.

    No garantiza que la guardia funcione en otros idiomas de Windows; eso
    se resuelve añadiendo idiomas a las listas, nunca sustituyéndolos.
#>

BeforeAll {
    $script:Raiz     = Split-Path $PSScriptRoot -Parent
    $script:CarpetaSrc  = Join-Path $script:Raiz 'src'
    $script:RutaGuardia = Join-Path (Join-Path $script:CarpetaSrc 'Core') 'Guard.ps1'

    . (Join-Path (Join-Path $script:CarpetaSrc 'Core') 'Bootstrap.ps1')

    # Carpetas personales vacías: el veredicto depende solo de las listas.
    Initialize-Guardia -Configuracion ([pscustomobject]@{
        Escritorio = ''; Documentos = ''; Descargas = ''
        Imagenes   = ''; Musica     = ''; Videos     = ''; CarpetaDatos = ''
    })

    # Listas protegidas, nombradas explícitamente: qué se protege es una
    # decisión, no un efecto de cómo está escrito el archivo.
    $script:ListasDeSeguridad = @(
        'FragmentosProhibidos'    # \system32\, \microsoft\crypto\, \.ssh\...
        'NombresSensibles'        # seguridad/security, respaldo/backup, banco/bank
        'ExtensionesPersonales'   # .docx, .kdbx, .pst...
        'NombresBasuraConocida'   # thumbs.db, .ds_store
        'CarpetasEspejo'          # documentos/documents, descargas/downloads
        'RegexCarpetaPersonal'    # el patron bilingue de carpeta personal
        'RegexCopiaSeguridad'     # backup/respaldo/copias
    )

    $script:AstGuardia = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:RutaGuardia, [ref]$null, [ref]$null)

    function Get-AsignacionDe {
        <#
            La asignación "$script:<Nombre> = ..." de Guard.ps1. Se busca en
            el AST para que un comentario que mencione la lista no cuente.
        #>
        param([string] $Nombre)
        return @($script:AstGuardia.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -eq ('script:' + $Nombre)
        }, $true))
    }

    function Get-NodosDe {
        param($Nodo, [type] $Tipo)
        return @($Nodo.FindAll({ param($n) $n -is $Tipo }, $true))
    }

    function Get-ArchivosSrc {
        return @(Get-ChildItem -LiteralPath $script:CarpetaSrc -Recurse -Filter '*.ps1' -File)
    }
}

Describe 'las listas de la guardia se quedan donde estan' {

    It 'la prueba encuentra las <Cuantas> listas: si no, no esta comprobando nada' -ForEach @(
        @{ Cuantas = 7 }
    ) {
        # Si un cambio de nombre dejara la prueba sin objetivo, pasaría sin
        # mirar nada.
        $script:ListasDeSeguridad.Count | Should -Be $Cuantas

        foreach ($nombre in $script:ListasDeSeguridad) {
            @(Get-AsignacionDe -Nombre $nombre).Count | Should -Be 1 -Because (
                "no hay ninguna asignacion de `$script:$nombre en Guard.ps1: o se ha movido, o se ha renombrado")
        }
    }

    It 'la lista <Lista> es texto literal escrito en Guard.ps1' -ForEach @(
        @{ Lista = 'FragmentosProhibidos' }
        @{ Lista = 'NombresSensibles' }
        @{ Lista = 'ExtensionesPersonales' }
        @{ Lista = 'NombresBasuraConocida' }
        @{ Lista = 'CarpetasEspejo' }
        @{ Lista = 'RegexCarpetaPersonal' }
        @{ Lista = 'RegexCopiaSeguridad' }
    ) {
        $asignacion = @(Get-AsignacionDe -Nombre $Lista)
        $asignacion.Count | Should -Be 1

        $derecha = $asignacion[0].Right

        # Ninguna llamada a comando en el valor: excluye
        # Import-LocalizedData, Get-Content, ConvertFrom-Json, etc.
        $comandos = Get-NodosDe -Nodo $derecha -Tipo ([System.Management.Automation.Language.CommandAst])
        @($comandos | ForEach-Object { $_.GetCommandName() }) | Should -BeNullOrEmpty -Because (
            "el valor de $Lista tiene que estar escrito aqui, no venir de ningun sitio")

        # Ninguna variable: excluye una lista armada a partir de un
        # $textos.Carpetas rellenado en otro sitio.
        $variables = Get-NodosDe -Nodo $derecha -Tipo ([System.Management.Automation.Language.VariableExpressionAst])
        @($variables | ForEach-Object { $_.VariablePath.UserPath }) | Should -BeNullOrEmpty -Because (
            "$Lista no puede depender de ninguna variable: seria una lista construida a partir de un recurso")
    }

    It 'las listas de palabras tienen contenido de verdad, no dos ejemplos' {
        # Una lista vaciada seguiría siendo "texto literal".
        $minimos = @{
            FragmentosProhibidos  = 10
            NombresSensibles      = 30
            ExtensionesPersonales = 30
            NombresBasuraConocida = 4
            CarpetasEspejo        = 15
        }
        foreach ($nombre in $minimos.Keys) {
            $derecha  = (Get-AsignacionDe -Nombre $nombre)[0].Right
            $palabras = Get-NodosDe -Nodo $derecha -Tipo (
                [System.Management.Automation.Language.StringConstantExpressionAst])
            $palabras.Count | Should -BeGreaterOrEqual $minimos[$nombre] -Because (
                "$nombre se ha quedado en $($palabras.Count) palabras: la guardia protege menos que ayer")
        }
    }

    It 'Guard.ps1 no lee texto de ningun archivo de idioma, recurso ni cultura' {
        # Guard.ps1 no puede depender de nada elegido en tiempo de ejecución
        # según el idioma del equipo.
        $prohibidos = @(
            'Import-LocalizedData', 'Import-PowerShellDataFile', 'Get-Content',
            'ConvertFrom-Json', 'ConvertFrom-StringData', 'Import-Csv', 'Import-Clixml',
            'Import-Module', 'Invoke-WebRequest', 'Invoke-RestMethod',
            'Get-Culture', 'Get-UICulture'
        )
        $prohibidos.Count | Should -BeGreaterThan 5 -Because 'sin la lista, esto no comprueba nada'

        $invocados = @(Get-NodosDe -Nodo $script:AstGuardia `
                                   -Tipo ([System.Management.Automation.Language.CommandAst]) |
                       ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $invocados.Count | Should -BeGreaterThan 0 -Because 'si no se ve ni un comando, el AST no se ha leido'

        @($invocados | Where-Object { $_ -in $prohibidos }) | Should -BeNullOrEmpty -Because (
            'traer texto de fuera es el primer paso para que las listas dejen de estar aqui')

        # Lo mismo por .NET, que no es un comando y escaparía a la
        # comprobación anterior.
        $lecturas = @(Get-NodosDe -Nodo $script:AstGuardia `
                                  -Tipo ([System.Management.Automation.Language.InvokeMemberExpressionAst]) |
                      Where-Object { $_.Member.Value -match '^(ReadAllText|ReadAllLines|ReadAllBytes|ReadLines|OpenText|OpenRead)$' })
        $lecturas | Should -BeNullOrEmpty -Because 'Guard.ps1 no abre archivos: decide sobre rutas'

        # Ninguna decisión puede depender de la cultura del sistema.
        $culturas = @(Get-NodosDe -Nodo $script:AstGuardia `
                                  -Tipo ([System.Management.Automation.Language.VariableExpressionAst]) |
                      Where-Object { $_.VariablePath.UserPath -in @('PSUICulture', 'PSCulture') })
        $culturas | Should -BeNullOrEmpty -Because (
            'la guardia tiene que dar el mismo veredicto en un Windows en cualquier idioma')
    }

    It 'ningun otro archivo de src puede reasignar las listas de la guardia' {
        # Si otro archivo pudiera sobrescribirlas al arrancar, daría igual
        # dónde estén escritas.
        $archivos = Get-ArchivosSrc
        $archivos.Count | Should -BeGreaterThan 20 -Because 'si no se recorren archivos, esto no comprueba nada'

        $culpables = @()
        foreach ($archivo in $archivos) {
            if ($archivo.FullName -eq $script:RutaGuardia) { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $archivo.FullName, [ref]$null, [ref]$null)

            $tocan = @(Get-NodosDe -Nodo $ast -Tipo (
                          [System.Management.Automation.Language.VariableExpressionAst]) |
                       Where-Object { $_.VariablePath.UserPath -in
                                      @($script:ListasDeSeguridad | ForEach-Object { 'script:' + $_ }) })

            # Vía indirecta: Set-Variable -Name 'CarpetasEspejo' -Scope Script.
            $porNombre = @(Get-NodosDe -Nodo $ast -Tipo (
                              [System.Management.Automation.Language.CommandAst]) |
                           Where-Object { $_.GetCommandName() -in @('Set-Variable', 'New-Variable') } |
                           Where-Object {
                               $texto = $_.Extent.Text
                               @($script:ListasDeSeguridad | Where-Object { $texto -match $_ }).Count -gt 0
                           })

            if ($tocan.Count -gt 0 -or $porNombre.Count -gt 0) { $culpables += $archivo.Name }
        }

        $culpables | Should -BeNullOrEmpty -Because (
            'las listas de la guardia solo se escriben en Guard.ps1: quien las pueda cambiar desde fuera, manda')
    }

    It 'el aviso para quien traduzca sigue escrito donde lo va a ver' {
        # Quien extraiga textos leerá Guard.ps1: el aviso debe estar allí, y
        # solo desde aquí se puede exigir.
        $texto = Get-Content -Raw -LiteralPath $script:RutaGuardia
        $marcas = @([regex]::Matches($texto, '(?m)^\s*#.*NO TRADUCIR: lógica de seguridad'))
        $marcas.Count | Should -BeGreaterOrEqual 1 -Because (
            'sin el aviso "NO TRADUCIR" en un comentario de Guard.ps1, quien extraiga los textos no tiene forma de saberlo')
    }
}

Describe 'las dos mitades de cada lista bilingue siguen ahi' {
    <#
        Se pregunta a las funciones públicas y se exige el par completo:
        traducir es sustituir, y sustituir pierde una de las mitades.
    #>

    It 'Test-CarpetaEspejo reconoce "<Es>" y "<En>"' -ForEach @(
        @{ Es = 'Documentos';        En = 'Documents' }
        @{ Es = 'Descargas';         En = 'Downloads' }
        @{ Es = 'Escritorio';        En = 'Desktop' }
        @{ Es = 'Favoritos';         En = 'Favorites' }
        @{ Es = 'MisImagenes';       En = 'MyPictures' }
        @{ Es = 'MiMusica';          En = 'MyMusic' }
        @{ Es = 'MisVideos';         En = 'MyVideos' }
        @{ Es = 'MisDocumentos';     En = 'MyDocuments' }
        @{ Es = 'Vinculos';          En = 'Links' }
        @{ Es = 'Busquedas';         En = 'Searches' }
        @{ Es = 'PartidasGuardadas'; En = 'SavedGames' }
        @{ Es = 'Contactos';         En = 'Contacts' }
    ) {
        Test-CarpetaEspejo $Es | Should -BeTrue -Because (
            "'$Es' es la mitad castellana: si cae, alguien ha traducido la lista en vez de añadir a ella")
        Test-CarpetaEspejo $En | Should -BeTrue -Because (
            "'$En' es la mitad inglesa: si cae, alguien ha traducido la lista en vez de añadir a ella")
    }

    It 'Test-CarpetaEspejo sigue diciendo que no a lo que no es una carpeta espejo' {
        # Sin esto, una lista que aceptara todo pasaría los casos anteriores.
        Test-CarpetaEspejo 'node_modules'   | Should -BeFalse
        Test-CarpetaEspejo 'cache temporal' | Should -BeFalse
    }

    It 'Test-NombreSensible reconoce "<Es>" y "<En>"' -ForEach @(
        @{ Es = 'Seguridad del equipo'; En = 'Security Center' }
        @{ Es = 'Banco Santander';      En = 'Bank of America' }
        @{ Es = 'Respaldo 2024';        En = 'Backup 2024' }
        @{ Es = 'Contrasenas';          En = 'Passwords' }
        @{ Es = 'Sincronizacion';       En = 'Syncthing' }
        @{ Es = 'Certificados FNMT';    En = 'Certificates' }
    ) {
        Test-NombreSensible $Es | Should -BeTrue -Because "'$Es' es la mitad castellana de la lista"
        Test-NombreSensible $En | Should -BeTrue -Because "'$En' es la mitad inglesa de la lista"
    }

    It 'Test-NombreSensible sigue dejando pasar lo que no es sensible' {
        # Cada acierto es un 'continue' en 30-RestosProgramas: una lista que
        # aceptara todo dejaría de examinar el disco.
        Test-NombreSensible 'node_modules' | Should -BeFalse
        Test-NombreSensible 'Presets'      | Should -BeFalse
    }

    It 'Test-ArchivoPersonal protege "<Es>" y "<En>"' -ForEach @(
        @{ Es = 'Documento 3.tmp'; En = 'Document 3.tmp' }
        @{ Es = 'Foto1.tmp';       En = 'Photo1.tmp' }
        @{ Es = 'Imagen1.tmp';     En = 'Image1.tmp' }
        @{ Es = 'Respaldo1.tmp';   En = 'Backup1.tmp' }
    ) {
        # Extensión .tmp a propósito: no está en ExtensionesPersonales, así
        # que solo el patrón bilingüe de nombres puede protegerlo.
        Test-ArchivoPersonal ('C:\trabajo\cosas\' + $Es) | Should -BeTrue -Because (
            "'$Es' es la mitad castellana del patron de nombres personales")
        Test-ArchivoPersonal ('C:\trabajo\cosas\' + $En) | Should -BeTrue -Because (
            "'$En' es la mitad inglesa del patron de nombres personales")
    }

    It 'Test-ArchivoPersonal sigue dejando proponer basura de verdad' {
        Test-ArchivoPersonal 'C:\trabajo\cosas\salida.tmp'  | Should -BeFalse
        Test-ArchivoPersonal 'C:\trabajo\cosas\imagecache.dat' | Should -BeFalse
    }

    It 'la guardia veta la carpeta personal "<Es>" y "<En>", y por el mismo motivo' -ForEach @(
        @{ Es = 'Documentos'; En = 'Documents' }
        @{ Es = 'Escritorio'; En = 'Desktop' }
        @{ Es = 'Descargas';  En = 'Downloads' }
        @{ Es = 'Imagenes';   En = 'Pictures' }
        @{ Es = 'Musica';     En = 'Music' }
    ) {
        # Tres niveles a propósito: "D:\Documentos" también se bloquea, pero
        # por estar cerca de la raíz. Se exige el mismo motivo.
        (Get-MotivoIntocable ('D:\trabajo\' + $Es)) | Should -Match 'carpeta personal' -Because (
            "'$Es' es la mitad castellana del patron de carpetas personales")
        (Get-MotivoIntocable ('D:\trabajo\' + $En)) | Should -Match 'carpeta personal' -Because (
            "'$En' es la mitad inglesa del patron de carpetas personales")
    }

    It 'y lo mismo con las tildes del castellano, que no son decorativas' {
        # ConvertTo-RutaNormalizada conserva los diacríticos: sin
        # Remove-Tildes estas dos quedarían sin proteger en un Windows en
        # español.
        (Get-MotivoIntocable 'D:\trabajo\Imágenes') | Should -Match 'carpeta personal'
        (Get-MotivoIntocable 'D:\trabajo\Música')   | Should -Match 'carpeta personal'
    }

    It 'la guardia veta las copias de seguridad se llamen "<Nombre>"' -ForEach @(
        @{ Nombre = 'backup' }
        @{ Nombre = 'backups' }
        @{ Nombre = 'respaldo' }
        @{ Nombre = 'respaldos' }
        @{ Nombre = 'copias' }
    ) {
        (Get-MotivoIntocable ('D:\trabajo\' + $Nombre + '\lote')) |
            Should -Match 'copias de seguridad' -Because (
                "'$Nombre' esta en el patron bilingue de copias: una carpeta asi contiene lo que su duenyo no quiere perder")
    }

    It 'y no veta una carpeta cualquiera: si vetara todo, los casos de arriba no dirian nada' {
        (Get-MotivoIntocable 'D:\trabajo\cache\lote') | Should -BeNullOrEmpty
    }
}
