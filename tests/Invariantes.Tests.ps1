<#
    Invariantes estructurales del proyecto.

    No comprueban resultados de funciones sino reglas de construcción del
    proyecto que ninguna otra prueba vigila.

    Siempre que es posible se apoyan en el árbol de sintaxis (AST) y en
    reflexión, no en búsquedas de texto: un comentario que mencione
    "Remove-Item" no debe hacerlas fallar.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Bootstrap.ps1')

    function Get-AstDe {
        param([string] $Ruta)
        return [System.Management.Automation.Language.Parser]::ParseFile($Ruta, [ref]$null, [ref]$null)
    }

    # Todos los nombres de comando que aparecen invocados en un archivo.
    function Get-ComandosInvocados {
        param([string] $Ruta)
        $ast = Get-AstDe $Ruta
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                 ForEach-Object { $_.GetCommandName() } |
                 Where-Object { $_ })
    }
}

Describe 'Ningun modulo de limpieza borra ni escribe por su cuenta' {
    <#
        Garantía central: los módulos proponen y solo el motor de Remove.ps1
        ejecuta, revalidando la guardia justo antes. Un Remove-Item en un
        módulo se saltaría esa revalidación.
    #>

    # En BeforeAll y no en el cuerpo del Describe: este se evalúa en la fase
    # de descubrimiento y la lista llegaría como $null, con lo que la prueba
    # pasaría siempre.
    BeforeAll {
        $script:Destructivos = @(
            'Remove-Item', 'Remove-ItemProperty', 'Clear-RecycleBin', 'Clear-Content',
            'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Move-Item',
            'Rename-Item', 'Set-ItemProperty', 'New-ItemProperty',
            'Set-Item', 'Copy-Item', 'Start-Process', 'Invoke-Expression',
            'Stop-Process', 'Stop-Service', 'Set-Service', 'Remove-Service'
        )
    }

    It 'el modulo <Nombre> no invoca ningun comando destructivo' -ForEach @(
        (Get-ChildItem (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Modules') -Filter '*.ps1' |
            ForEach-Object { @{ Nombre = $_.Name; Ruta = $_.FullName } })
    ) {
        $script:Destructivos | Should -Not -BeNullOrEmpty -Because 'sin la lista, esta prueba no comprobaria nada'
        $invocados = Get-ComandosInvocados $Ruta
        $prohibidos = @($invocados | Where-Object { $_ -in $script:Destructivos })
        $prohibidos | Should -BeNullOrEmpty -Because (
            "$Nombre debe limitarse a proponer candidatos. Borrar o escribir desde un modulo " +
            "se salta la revalidacion de la guardia que hace Invoke-EliminacionCandidato")
    }

    It 'dentro del nucleo, solo Remove.ps1 borra archivos' {
        $borradores = @('Remove-Item', 'Clear-RecycleBin')
        $carpeta = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Core'
        $culpables = @()
        foreach ($archivo in (Get-ChildItem $carpeta -Filter '*.ps1')) {
            if ($archivo.Name -eq 'Remove.ps1') { continue }
            $invocados = Get-ComandosInvocados $archivo.FullName
            if (@($invocados | Where-Object { $_ -in $borradores })) { $culpables += $archivo.Name }
        }
        $culpables | Should -BeNullOrEmpty -Because 'todo borrado debe pasar por el motor que revalida la guardia'
    }

    It 'ningun modulo lanza procesos externos: eso es exclusivo del metodo Comando' {
        # El método 'Comando' está exento de la guardia de rutas; por eso se
        # centraliza en Remove.ps1 con una lista blanca de ejecutables.
        $carpeta = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Modules'
        $culpables = @()
        foreach ($archivo in (Get-ChildItem $carpeta -Filter '*.ps1')) {
            $invocados = Get-ComandosInvocados $archivo.FullName
            if (@($invocados | Where-Object { $_ -in @('Start-Process', 'Invoke-Expression', 'Invoke-Item') })) {
                $culpables += $archivo.Name
            }
        }
        $culpables | Should -BeNullOrEmpty
    }
}

Describe 'El candidato y la fila de la interfaz no pueden divergir' {
    <#
        Candidate.ps1 define el candidato y Types.ps1 define ItemVista, la
        fila que ve el usuario. Window.Analisis.ps1 copia los campos a mano;
        un campo nuevo (p. ej. Comando, que SECURITY.md exige mostrar) puede
        olvidarse sin que nada avise.
    #>

    BeforeAll {
        . (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Types.ps1')
        Initialize-TiposInterfaz

        # Campos del candidato: el hashtable que devuelve New-Candidato.
        $astCandidato = Get-AstDe (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Candidate.ps1')
        $funcion = $astCandidato.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-Candidato'
        }, $true)[0]
        $tabla = $funcion.FindAll({
            param($n) $n -is [System.Management.Automation.Language.HashtableAst]
        }, $true)[0]
        $script:CamposCandidato = @($tabla.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'`"") })

        # Propiedades reales de ItemVista, por reflexion.
        $script:PropsItemVista = @([Cachivache.ItemVista].GetProperties() | ForEach-Object { $_.Name })

        # Asignaciones "$item.X = ..." que hace Window.Analisis.ps1.
        $astVista = Get-AstDe (Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'UI') 'Window.Analisis.ps1')
        $script:Mapeadas = @($astVista.FindAll({
            param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                      $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                      $n.Left.Expression.Extent.Text -eq '$item'
        }, $true) | ForEach-Object { $_.Left.Member.Extent.Text })
    }

    It 'toda propiedad que existe en el candidato Y en ItemVista se copia de verdad' {
        # Propiedades que ItemVista calcula por su cuenta y no se copian.
        $propias = @('ColorRiesgo', 'Tamano', 'Borrable', 'Origen',
                     'Seleccionado', 'Hecho', 'Estado', 'VisibilidadAviso', 'VisibilidadComando')

        $deberian = @($script:PropsItemVista |
                      Where-Object { $_ -in $script:CamposCandidato -and $_ -notin $propias })
        $olvidadas = @($deberian | Where-Object { $_ -notin $script:Mapeadas })

        $olvidadas | Should -BeNullOrEmpty -Because (
            'si una propiedad existe en ambos lados pero no se copia en Window.Analisis.ps1, ' +
            'la interfaz la mostrara siempre vacia sin que nada falle')
    }

    It 'no se copia al item ninguna propiedad que ItemVista no declare' {
        $fantasma = @($script:Mapeadas | Where-Object { $_ -notin $script:PropsItemVista })
        $fantasma | Should -BeNullOrEmpty -Because 'asignar una propiedad inexistente falla en tiempo de ejecucion'
    }
}

Describe 'El nucleo se carga entero y en orden' {

    It 'Bootstrap.ps1 nombra todos los archivos que hay en src/Core' {
        $carpeta = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Core'
        $enDisco = @(Get-ChildItem $carpeta -Filter '*.ps1' |
                     Where-Object { $_.Name -ne 'Bootstrap.ps1' } |
                     ForEach-Object { $_.Name })
        $texto = Get-Content (Join-Path $carpeta 'Bootstrap.ps1') -Raw
        $ausentes = @($enDisco | Where-Object { $texto -notmatch [regex]::Escape($_) })
        $ausentes | Should -BeNullOrEmpty -Because 'un archivo del nucleo que no se cargue deja funciones sin definir'
    }
}

Describe 'Los controles de la ventana y el XAML no pueden divergir' {

    <#
        Window.ps1 resuelve los controles con FindName y los guarda en $c. Un
        nombre ausente de la lista o del XAML devuelve $null sin error: el
        control no responde o $null.Add_Click(...) falla en tiempo de ejecución.
    #>

    BeforeAll {
        $script:CarpetaUI = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        # El documento montado, no MainWindow.xaml: la ventana se reparte en
        # Panel.*.xaml y el armazón solo declara una parte de los nombres.
        . (Join-Path $script:CarpetaUI 'Xaml.ps1')
        $script:XamlMontado = Expand-PanelesXaml -Carpeta $script:CarpetaUI `
                                  -Texto ([IO.File]::ReadAllText((Join-Path $script:CarpetaUI 'MainWindow.xaml')))

        $script:NombresXaml = @{}
        foreach ($m in [regex]::Matches($script:XamlMontado, 'x:Name="([^"]+)"')) {
            $script:NombresXaml[$m.Groups[1].Value] = $true
        }

        # La lista literal que Window.ps1 pasa por FindName, acotada al bloque
        # que la construye para no arrastrar cadenas de otras partes del archivo.
        $textoVentana = Get-Content (Join-Path $script:CarpetaUI 'Window.ps1') -Raw
        $bloque = [regex]::Match($textoVentana, '(?s)\$c = @\{\}.*?\$c\[\$nombre\] = \$ventana\.FindName')
        $script:NombresResueltos = @{}
        foreach ($m in [regex]::Matches($bloque.Value, "'([^']+)'")) {
            $script:NombresResueltos[$m.Groups[1].Value] = $true
        }

        # Lo que consulta el código en cualquiera de los Window*.ps1.
        $script:NombresUsados = @{}
        foreach ($archivo in (Get-ChildItem $script:CarpetaUI -Filter 'Window*.ps1')) {
            $t = Get-Content $archivo.FullName -Raw
            foreach ($m in [regex]::Matches($t, "\`$c\.([A-Za-z_][A-Za-z0-9_]*)")) {
                $script:NombresUsados[$m.Groups[1].Value] = $archivo.Name
            }
            foreach ($m in [regex]::Matches($t, "\`$c\[\s*'([^']+)'\s*\]")) {
                $script:NombresUsados[$m.Groups[1].Value] = $archivo.Name
            }
        }
    }

    It 'la extraccion encuentra controles: si no, la prueba no esta probando nada' {
        $script:NombresXaml.Count      | Should -BeGreaterThan 30
        $script:NombresResueltos.Count | Should -BeGreaterThan 30
        $script:NombresUsados.Count    | Should -BeGreaterThan 30
    }

    It 'todo control que el codigo usa esta en la lista que Window.ps1 resuelve' {
        $huerfanos = @($script:NombresUsados.Keys |
                       Where-Object { -not $script:NombresResueltos.ContainsKey($_) } |
                       Sort-Object)
        $huerfanos | Should -BeNullOrEmpty -Because 'un nombre fuera de la lista deja $c.Nombre a $null y el control no responde'
    }

    It 'todo control que Window.ps1 resuelve existe en el XAML' {
        $inventados = @($script:NombresResueltos.Keys |
                        Where-Object { -not $script:NombresXaml.ContainsKey($_) } |
                        Sort-Object)
        $inventados | Should -BeNullOrEmpty -Because 'FindName de un nombre que no existe devuelve $null sin avisar'
    }
}

Describe 'Marcar en lote no puede alcanzar lo que el usuario no ve' {

    <#
        "Marcar todo" debe recorrer la vista filtrada, no $estado.Items: con
        un filtro puesto, marcaría filas ocultas que el siguiente "Eliminar
        lo marcado" borraría. La prueba lee el cuerpo del cierre.
    #>

    BeforeAll {
        $ruta = Join-Path (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI') 'Window.Eventos.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)

        # La asignación $marcarEnLote = { ... }, localizada por AST.
        $asignacion = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$marcarEnLote'
        }, $true))

        $script:CuerpoLote = if ($asignacion.Count -gt 0) { $asignacion[0].Right.Extent.Text } else { '' }

        # Sin comentarios: el cierre explica en ellos por qué no recorre Items.
        $script:CodigoLote = (($script:CuerpoLote -split "`r?`n") |
                              Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'la prueba encuentra el cierre: si no, no esta comprobando nada' {
        $script:CuerpoLote | Should -Not -BeNullOrEmpty
        $script:CodigoLote | Should -Match 'Seleccionado' -Because 'es el cierre que marca las casillas'
    }

    It 'recorre la vista filtrada, no la coleccion completa' {
        $script:CodigoLote | Should -Match '\$estado\.Vista' -Because 'marcar tiene que actuar sobre lo que se esta viendo'
    }

    It 'no toca $estado.Items' {
        $script:CodigoLote | Should -Not -Match '\$estado\.Items' -Because 'recorrer Items alcanza filas que el filtro esconde'
    }
}

Describe 'La codificación de los archivos no puede volver a romperse' {

    <#
        Windows PowerShell 5.1 lee un .ps1 sin BOM como ANSI, no como UTF-8,
        y los caracteres no ASCII salen corruptos. Todos los .ps1 y .xaml van
        en UTF-8 con BOM. El fallo es silencioso y cualquier editor puede
        guardar un archivo sin BOM.
    #>

    BeforeAll {
        $script:RaizProyecto = Split-Path $PSScriptRoot -Parent
        # En PowerShell 5.1, -Include se ignora con -LiteralPath y devuelve el
        # árbol entero. Se filtra por extensión a mano.
        $script:ConBom = @(
            Get-ChildItem -LiteralPath $script:RaizProyecto -Recurse -File |
            Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.xaml' } |
            Where-Object { $_.FullName -notmatch '\\\.git\\' }
        )
    }

    It 'la prueba encuentra archivos: si no, no comprueba nada' {
        $script:ConBom.Count | Should -BeGreaterThan 40
    }

    It 'todos los .ps1 y .xaml empiezan por el BOM de UTF-8' {
        $sinBom = @()
        foreach ($archivo in $script:ConBom) {
            $bytes = [IO.File]::ReadAllBytes($archivo.FullName)
            if ($bytes.Length -lt 3 -or
                $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
                $sinBom += $archivo.Name
            }
        }
        $sinBom | Should -BeNullOrEmpty -Because 'sin BOM, PowerShell 5.1 lee el archivo como ANSI y destroza los acentos'
    }

    It 'los .bat siguen siendo ASCII puro' {
        # La consola de Windows no usa UTF-8 por defecto.
        $sucios = @()
        # Filtrado a mano por lo mismo: -Include no filtra en 5.1.
        $bats = @(Get-ChildItem -LiteralPath $script:RaizProyecto -Recurse -File |
                  Where-Object { $_.Extension -eq '.bat' })
        $bats.Count | Should -BeGreaterThan 0 -Because 'sin ningun .bat esta prueba no comprueba nada'
        foreach ($archivo in $bats) {
            $bytes = [IO.File]::ReadAllBytes($archivo.FullName)
            if ($bytes | Where-Object { $_ -gt 127 }) { $sucios += $archivo.Name }
        }
        $sucios | Should -BeNullOrEmpty
    }

    It 'ni los .bat ni el sondeo invocan PowerShell por su nombre' {
        # cmd busca primero en el directorio actual: un powershell.exe ajeno
        # junto al .bat se ejecutaria en lugar del de Windows.
        $porNombre = @()
        $bats = @(Get-ChildItem -LiteralPath $script:RaizProyecto -Recurse -File |
                  Where-Object { $_.Extension -eq '.bat' })
        foreach ($archivo in $bats) {
            foreach ($linea in [IO.File]::ReadAllLines($archivo.FullName)) {
                if ($linea -match '^\s*(rem\b|::|echo\b)') { continue }
                if ($linea -match '(?i)(^|[\s(&|])(where\s+)?powershell(\.exe)?(\s|$)') { $porNombre += ('{0}: {1}' -f $archivo.Name, $linea.Trim()) }
            }
        }
        $sondeo = [IO.File]::ReadAllText((Join-Path (Join-Path $script:RaizProyecto 'tools') 'Sondeo-Robot.ps1'))
        if ($sondeo -match "(?i)-FilePath\s+'powershell(\.exe)?'") { $porNombre += 'Sondeo-Robot.ps1' }
        $porNombre | Should -BeNullOrEmpty
    }

    It 'un acento escrito en el codigo llega intacto al leerlo' {
        # Comprueba el texto leído, no solo la presencia del BOM.
        $ruta = Join-Path (Join-Path (Join-Path $script:RaizProyecto 'src') 'Modules') '10-Caches.ps1'
        $texto = Get-Content -Raw -LiteralPath $ruta
        $texto | Should -Match 'contrase'
        $texto | Should -Match ([regex]::Escape('contraseñas'))
    }

    It 'la interfaz no vuelve a escribir la enye como "ny"' {
        <#
            Se busca el patrón, no una lista de palabras: cualquier "ny"
            dentro de una palabra en una cadena de prosa (en español ese
            dígrafo no existe, y suele ser la sustitución ASCII de la eñe).
            Solo se mira la prosa entrecomillada, no los comentarios.
        #>
        $grafiasAscii = @()
        foreach ($archivo in $script:ConBom) {
            if ($archivo.FullName -match 'tests') { continue }
            if ($archivo.Extension -ne '.ps1')    { continue }

            $n = 0
            $enBloque = $false
            foreach ($linea in (Get-Content -LiteralPath $archivo.FullName)) {
                $n++
                if ($linea -match '<#') { $enBloque = $true }
                if ($enBloque) {
                    if ($linea -match '#>') { $enBloque = $false }
                    continue
                }
                if ($linea -match '^\s*#') { continue }

                foreach ($m in [regex]::Matches($linea, "'([^'`n]+)'|`"([^`"`n]+)`"")) {
                    $texto = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                    if ($texto.Length -lt 14) { continue }
                    if (@($texto -split ' ' | Where-Object { $_ }).Count -lt 3) { continue }

                    foreach ($palabra in [regex]::Matches($texto, '[A-Za-z]*ny[A-Za-z]*')) {
                        $grafiasAscii += ('{0}:{1}  {2}' -f $archivo.Name, $n, $palabra.Value)
                    }
                }
            }
        }
        $grafiasAscii | Should -BeNullOrEmpty -Because 'los archivos llevan BOM: la eñe se escribe tal cual'
    }
}

Describe 'El cuadro de filtro no dispara el filtro en cada tecla' {

    <#
        Enganchar Add_TextChanged directamente a $aplicarFiltro recorre la
        tabla en cada tecla (con 15.000 filas, segundos de bloqueo). Un
        DispatcherTimer reiniciado en cada pulsación filtra 250 ms después
        de la última. Es fácil de "simplificar" sin querer y ninguna prueba
        funcional lo detectaría.
    #>

    BeforeAll {
        $carpetaUi = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'
        $script:Eventos   = Get-Content -Raw -LiteralPath (Join-Path $carpetaUi 'Window.Eventos.ps1')
        $script:Ayudantes = Get-Content -Raw -LiteralPath (Join-Path $carpetaUi 'Window.Ayudantes.ps1')

        # Sin comentarios: algunos mencionan $aplicarFiltro.
        $script:CodigoEventos = (($script:Eventos -split "`r?`n") |
                                 Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }

    It 'la prueba encuentra el enganche: si no, no esta comprobando nada' {
        $script:CodigoEventos | Should -Match 'CampoFiltro\.Add_TextChanged'
    }

    It 'el cuadro de texto pide el filtro, no lo ejecuta' {
        $script:CodigoEventos | Should -Match 'CampoFiltro\.Add_TextChanged\(\{\s*&\s*\$solicitarFiltro'
    }

    It 'existe el temporizador que separa la tecla del filtrado' {
        $script:Ayudantes | Should -Match '\$solicitarFiltro\s*='
        $script:Ayudantes | Should -Match 'TemporizadorFiltro.*=.*DispatcherTimer'
    }

    It 'sin criterios se quita el filtro en vez de poner uno que diga que si a todo' {
        # Permite al resumen del pie saltarse el segundo recorrido sin filtro.
        $script:Ayudantes | Should -Match '\$estado\.Vista\.Filter = \$null'
    }
}

Describe 'Lo que el usuario elige a mano pasa el perfil a Personalizado' {

    <#
        Al arrancar, los módulos elegidos y los umbrales solo se aplican si
        el perfil es 'personalizado'. Por eso todo control cuyo valor se
        guarda llama a $pasarAPersonalizado; si no, la elección se perdería
        en silencio. Se comprueba por AST para los cuatro controles de
        Ajustes y las casillas de módulo.
    #>

    BeforeAll {
        $carpeta = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        $script:CodigoUi = @{}
        foreach ($nombre in @('Window.Eventos.ps1', 'Window.Ayudantes.ps1')) {
            $script:CodigoUi[$nombre] = Get-Content (Join-Path $carpeta $nombre) -Raw
        }

        # Cuerpo de una asignación de cierre, localizada por AST, sin comentarios.
        function Get-CuerpoCierre {
            param([string] $Texto, [string] $Nombre)
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Texto, [ref]$null, [ref]$null)
            $encontradas = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq $Nombre
            }, $true))
            if ($encontradas.Count -eq 0) { return '' }
            return ((($encontradas[0].Right.Extent.Text -split "`r?`n") |
                     Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        }
    }

    It 'existe el cierre que pasa a Personalizado' {
        $cuerpo = Get-CuerpoCierre $script:CodigoUi['Window.Eventos.ps1'] '$pasarAPersonalizado'
        $cuerpo | Should -Not -BeNullOrEmpty
        $cuerpo | Should -Match 'personalizado'
        $cuerpo | Should -Match 'SincronizandoPerfil' -Because 'sin la bandera, mover los controles al elegir perfil pasaria a Personalizado solo'
    }

    It 'las casillas de modulo pasan el perfil a Personalizado' {
        $cuerpo = Get-CuerpoCierre $script:CodigoUi['Window.Ayudantes.ps1'] '$manejadorModuloGlobal'
        $cuerpo | Should -Not -BeNullOrEmpty -Because 'sin manejador, tocar un modulo no se entera nadie'
        $cuerpo | Should -Match 'pasarAPersonalizado'
    }

    It 'el manejador de modulos se engancha a cada tarjeta' {
        $script:CodigoUi['Window.Ayudantes.ps1'] |
            Should -Match 'add_PropertyChanged\(\$manejadorModuloGlobal\)' -Because 'definirlo sin engancharlo no sirve de nada'
    }

    It 'los dos sliders de Ajustes pasan el perfil a Personalizado' {
        $texto = $script:CodigoUi['Window.Eventos.ps1']
        foreach ($control in @('SliderMinimoMB', 'SliderDias')) {
            $bloque = [regex]::Match($texto, "(?s)\`$c\.$control\.Add_\w+\(\{.*?\n    \}\)")
            $bloque.Success | Should -BeTrue -Because "hay que encontrar el manejador de $control"
            $bloque.Value | Should -Match 'pasarAPersonalizado' -Because "$control se guarda en preferencias y solo se relee en Personalizado"
        }
    }

    It 'las dos casillas de Ajustes pasan el perfil a Personalizado' {
        foreach ($cierre in @('$sincronizarMenores', '$sincronizarPermanente')) {
            $cuerpo = Get-CuerpoCierre $script:CodigoUi['Window.Eventos.ps1'] $cierre
            $cuerpo | Should -Not -BeNullOrEmpty -Because "hay que encontrar el cierre $cierre"
            $cuerpo | Should -Match 'pasarAPersonalizado'
        }
    }

    It 'las casillas usan Checked y Unchecked, nunca Click' {
        # Click solo se dispara al pulsar; asignar IsChecked desde código (al
        # elegir perfil o "Restablecer ajustes") no lo dispara y
        # $estado.Preferencias conservaría el valor anterior.
        $texto = $script:CodigoUi['Window.Eventos.ps1']
        foreach ($casilla in @('ChkMenores', 'ChkPermanente')) {
            $texto | Should -Not -Match "\`$c\.$casilla\.Add_Click" -Because 'Add_Click no se entera de los cambios por codigo'
            $texto | Should -Match "\`$c\.$casilla\.Add_Checked"
            $texto | Should -Match "\`$c\.$casilla\.Add_Unchecked"
        }
    }
}

Describe 'Los dos temas y el XAML no pueden divergir' {

    <#
        Cambiar de tema sustituye un diccionario por otro. Una clave presente
        solo en uno, o usada en el XAML sin definir, deja controles sin
        pincel o con el color del tema anterior. WPF no avisa.
    #>

    BeforeAll {
        $script:CarpetaTemas = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        function Get-ClavesDeTema {
            param([string] $Archivo)
            $texto = Get-Content (Join-Path $script:CarpetaTemas $Archivo) -Raw
            return @([regex]::Matches($texto, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        }

        $script:ClavesOscuro = Get-ClavesDeTema 'Theme.Dark.xaml'
        $script:ClavesClaro  = Get-ClavesDeTema 'Theme.Light.xaml'

        # Todo lo que los XAML piden por DynamicResource, incluidos los Panel.*.xaml.
        $script:Pedidas = @{}
        $aRevisar = @('MainWindow.xaml', 'Styles.xaml', 'ConfirmDialog.xaml') +
                    @(Get-ChildItem $script:CarpetaTemas -Filter 'Panel.*.xaml' | ForEach-Object { $_.Name })
        foreach ($archivo in $aRevisar) {
            $texto = Get-Content (Join-Path $script:CarpetaTemas $archivo) -Raw
            foreach ($m in [regex]::Matches($texto, '\{DynamicResource\s+([A-Za-z0-9_]+)\s*\}')) {
                $script:Pedidas[$m.Groups[1].Value] = $archivo
            }
        }
    }

    It 'la extraccion encuentra claves: si no, la prueba no prueba nada' {
        $script:ClavesOscuro.Count | Should -BeGreaterThan 15
        $script:ClavesClaro.Count  | Should -BeGreaterThan 15
        $script:Pedidas.Count      | Should -BeGreaterThan 15
    }

    It 'los dos temas declaran exactamente las mismas claves' {
        $soloOscuro = @($script:ClavesOscuro | Where-Object { $script:ClavesClaro -notcontains $_ } | Sort-Object)
        $soloClaro  = @($script:ClavesClaro  | Where-Object { $script:ClavesOscuro -notcontains $_ } | Sort-Object)
        $soloOscuro | Should -BeNullOrEmpty -Because 'estas claves faltan en el tema claro'
        $soloClaro  | Should -BeNullOrEmpty -Because 'estas claves faltan en el tema oscuro'
    }

    It 'ningun XAML pide un color que los temas no definan' {
        # Se descartan las claves que define Styles.xaml (estilos y fuentes),
        # que no son del tema: aquí solo interesan los pinceles.
        $delEstilo = @([regex]::Matches((Get-Content (Join-Path $script:CarpetaTemas 'Styles.xaml') -Raw),
                                        'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $huerfanas = @($script:Pedidas.Keys |
                       Where-Object { $script:ClavesOscuro -notcontains $_ -and $delEstilo -notcontains $_ } |
                       Sort-Object)
        $huerfanas | Should -BeNullOrEmpty -Because 'un DynamicResource sin destino no pinta nada y no avisa'
    }

    It 'ningun color del tema se declara y luego no lo usa nadie' {
        $sinUsar = @($script:ClavesOscuro | Where-Object { -not $script:Pedidas.ContainsKey($_) } | Sort-Object)
        $sinUsar | Should -BeNullOrEmpty -Because 'un color que no usa nadie es peso muerto en los dos temas'
    }
}

Describe 'La escala tipografica no admite tamaños sueltos' {

    <#
        Seis tamaños: 11 12 13 15 20 28. Una escala cerrada mantiene la
        coherencia visual entre paneles.
    #>

    BeforeAll {
        $script:Escala = @('11', '12', '13', '15', '20', '28')
        $script:CarpetaXaml = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'
    }

    It '<Archivo> solo usa tamaños de la escala' -ForEach @(
        @{ Archivo = 'MainWindow.xaml' }
        @{ Archivo = 'Styles.xaml' }
        @{ Archivo = 'ConfirmDialog.xaml' }
        @{ Archivo = 'Panel.Inicio.xaml' }
        @{ Archivo = 'Panel.Resultados.xaml' }
        @{ Archivo = 'Panel.Registro.xaml' }
        @{ Archivo = 'Panel.Informes.xaml' }
        @{ Archivo = 'Panel.Ajustes.xaml' }
        @{ Archivo = 'Panel.Acerca.xaml' }
    ) {
        $texto = Get-Content (Join-Path $script:CarpetaXaml $Archivo) -Raw
        $usados = @([regex]::Matches($texto, 'FontSize="([0-9.]+)"') |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $fuera = @($usados | Where-Object { $script:Escala -notcontains $_ })
        $fuera | Should -BeNullOrEmpty -Because "la escala es $($script:Escala -join ', ')"
    }
}

Describe 'La ventana partida en paneles monta el mismo documento de antes' {

    <#
        El documento que monta Expand-PanelesXaml debe ser idéntico, byte a
        byte, a la copia de referencia guardada en tests/. Un cambio
        deliberado de la ventana hace fallar esta prueba: se revisa y se
        actualiza la copia.
    #>

    BeforeAll {
        $script:CarpetaUi = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        # Xaml.ps1 no depende de WPF, así que se carga tal cual.
        . (Join-Path $script:CarpetaUi 'Xaml.ps1')
    }

    It 'el documento montado es identico al original, byte a byte' {
        # Oráculo: el documento de referencia. No es un resto de refactor; es
        # lo que garantiza que Expand-PanelesXaml reconstruye la ventana byte a byte.
        $original = [IO.File]::ReadAllText(
            (Join-Path (Join-Path $PSScriptRoot 'datos') 'MainWindow.montado.esperado.xaml'))
        $montado  = Expand-PanelesXaml -Texto ([IO.File]::ReadAllText((Join-Path $script:CarpetaUi 'MainWindow.xaml'))) `
                                       -Carpeta $script:CarpetaUi
        $montado | Should -BeExactly $original
    }

    It 'el documento montado sigue siendo XML valido' {
        $montado = Expand-PanelesXaml -Texto ([IO.File]::ReadAllText((Join-Path $script:CarpetaUi 'MainWindow.xaml'))) `
                                      -Carpeta $script:CarpetaUi
        { [xml]$montado } | Should -Not -Throw
    }

    It 'una marca que apunte a un panel inexistente falla al momento y lo dice' {
        # Si no, la pestaña quedaría en blanco sin ningún error.
        { Expand-PanelesXaml -Texto '<!--#panel Panel.QueNoExiste.xaml-->' -Carpeta $script:CarpetaUi } |
            Should -Throw -ExpectedMessage '*Panel.QueNoExiste.xaml*'
    }

    It 'cada Panel.*.xaml se usa y cada marca tiene su archivo' {
        $marcas = @([regex]::Matches(
            [IO.File]::ReadAllText((Join-Path $script:CarpetaUi 'MainWindow.xaml')),
            '<!--#panel\s+([^\s>]+?)\s*-->') | ForEach-Object { $_.Groups[1].Value })
        $archivos = @(Get-ChildItem $script:CarpetaUi -Filter 'Panel.*.xaml' | ForEach-Object { $_.Name })

        @($marcas   | Where-Object { $_ -notin $archivos }) | Should -BeNullOrEmpty -Because 'marca sin archivo'
        @($archivos | Where-Object { $_ -notin $marcas })   | Should -BeNullOrEmpty -Because 'archivo que no monta nadie'
    }

    It 'ningun panel declara xmlns por su cuenta' {
        # Un fragmento con xmlns propio sería XML inválido al montarse.
        foreach ($archivo in (Get-ChildItem $script:CarpetaUi -Filter 'Panel.*.xaml')) {
            # Sin comentarios: la cabecera de cada panel menciona xmlns.
            $sinComentarios = [regex]::Replace([IO.File]::ReadAllText($archivo.FullName), '(?s)<!--.*?-->', '')
            $sinComentarios | Should -Not -Match 'xmlns\s*=' -Because "$($archivo.Name) es un trozo, no un documento"
        }
    }
}

Describe 'Invariantes del hilo de analisis' {

    <#
        WPF no se puede arrancar desde las pruebas; se comprueban las
        propiedades estructurales del código.
    #>

    BeforeAll {
        $script:RutaAnalisis = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/UI') 'Window.Analisis.ps1'
        $script:TextoAnalisis = Get-Content -Raw -LiteralPath $script:RutaAnalisis
    }

    Context 'un solo runspace por operacion' {

        It 'el nucleo se carga en el arranque del runspace, no en cada trabajo' {
            $script:TextoAnalisis | Should -Match 'codigoArranqueRunspace'
            $script:TextoAnalisis | Should -Match '\$abrirRunspace'
        }

        It 'los guiones por modulo no cargan Bootstrap' {
            # Bootstrap carga miles de líneas; hacerlo por módulo multiplicaría el coste.
            # Se cuentan invocaciones, no menciones en comentarios.
            $cargas = @([regex]::Matches($script:TextoAnalisis, "(?m)^\s*\.\s+\(Join-Path[^\n]*Bootstrap\.ps1"))
            $cargas.Count | Should -Be 1 -Because 'solo el arranque del runspace lo carga'
        }

        It 'limpiarTrabajo NO cierra el runspace: lo comparten los modulos' {
            $ini = $script:TextoAnalisis.IndexOf('$limpiarTrabajo = {')
            $fin = $script:TextoAnalisis.IndexOf('$siguienteModulo = {')
            $cuerpo = $script:TextoAnalisis.Substring($ini, $fin - $ini)

            $cuerpo | Should -Not -Match 'Runspace\.Close\(\)' -Because (
                'cerrarlo por modulo es justo lo que obligaba a reabrirlo veintiuna veces')
        }

        It 'existe un cierre dedicado y lo llaman los tres finales' {
            $script:TextoAnalisis | Should -Match '\$cerrarRunspace = \{'

            # terminarAnalisis, terminarBorrado y el cierre de la ventana.
            $ui = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/UI'
            $llamantes = @(
                Get-ChildItem -LiteralPath $ui -Filter '*.ps1' |
                Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match '& \$cerrarRunspace' }
            )
            $llamantes.Count | Should -BeGreaterOrEqual 3 -Because (
                'si alguno se olvida, el runspace queda abierto hasta cerrar el programa')
        }
    }

    Context 'un fallo al lanzar no deja la ventana bloqueada' {

        It 'todo el montaje del trabajo va dentro de un try' {
            $ini = $script:TextoAnalisis.IndexOf('$lanzarTrabajo = {')
            $fin = $script:TextoAnalisis.IndexOf('$limpiarTrabajo = {')
            $cuerpo = $script:TextoAnalisis.Substring($ini, $fin - $ini)

            $cuerpo | Should -Match '(?s)try\s*\{.*BeginInvoke.*\}\s*catch' -Because (
                'sin esto, un fallo al abrir el runspace dejaba Ocupado en $true para siempre')
        }

        It 'el catch devuelve la ventana a un estado usable' {
            $ini = $script:TextoAnalisis.IndexOf('$lanzarTrabajo = {')
            $fin = $script:TextoAnalisis.IndexOf('$limpiarTrabajo = {')
            $cuerpo = $script:TextoAnalisis.Substring($ini, $fin - $ini)

            $cuerpo | Should -Match 'terminarAnalisis'
            $cuerpo | Should -Match 'terminarBorrado'
            $cuerpo | Should -Match 'cerrarRunspace' -Because 'el runspace abierto tambien hay que soltarlo'
        }
    }

    Context 'el boton de tema no toca la configuracion durante un trabajo' {

        It 'refrescarDiscos solo se llama si no hay nada en marcha' {
            $texto = Get-Content -Raw -LiteralPath (
                Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/UI') 'Window.Ayudantes.ps1')

            # $refrescarDiscos escribe Configuracion.Unidades, que se comparte
            # por referencia con el runspace que está analizando.
            $texto | Should -Match '(?s)if \(-not \$estado\.Ocupado\) \{\s*& \$refrescarDiscos'
        }
    }

    Context 'cerrar en mitad de un borrado no pierde el historial' {

        It 'el manejador de cierre declara los parametros del evento' {
            $texto = Get-Content -Raw -LiteralPath (
                Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/UI') 'Window.Eventos.ps1')
            $texto | Should -Match '(?s)Add_Closing\(\{.*param\(\$remitente, \$argumentos\)' -Because (
                'sin parametros de evento es imposible cancelar el cierre')
        }

        It 'anota la limpieza interrumpida antes de soltar nada' {
            $texto = Get-Content -Raw -LiteralPath (
                Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/UI') 'Window.Eventos.ps1')
            $texto | Should -Match 'limpieza-interrumpida' -Because (
                'el programa habia borrado archivos de verdad y no quedaba constancia')
        }
    }
}

Describe 'la ventana y la consola cuentan lo mismo' {

    It 'las dos anotan en el historial los bytes RECUPERABLES' {
        # El mismo análisis debe dar la misma cifra en historial.json desde
        # la ventana y desde la consola.
        $raiz = Split-Path $PSScriptRoot -Parent
        $ventana = Get-Content -Raw -LiteralPath (Join-Path $raiz 'src/UI/Window.Analisis.ps1')
        $consola = Get-Content -Raw -LiteralPath (Join-Path $raiz 'src/Cli/Cli.ps1')

        $ventana | Should -Match "Add-EntradaHistorial -Tipo 'analisis' -Elementos \`$estado\.Items\.Count -Bytes \`$bytesBorrables"
        $consola | Should -Match "Add-EntradaHistorial -Tipo 'analisis' -Elementos \`$todos\.Count -Bytes \`$bytesTotales"
    }

    It 'la consola pasa -Sync al motor de borrado, como la ventana' {
        # Se sigue el camino completo: el bucle vive en Remove.ps1 y lo
        # comparten las dos interfaces. Sin -Sync se pierden las líneas de
        # registro del borrado.
        $raiz = Split-Path $PSScriptRoot -Parent

        $consola = Get-Content -Raw -LiteralPath (Join-Path $raiz 'src/Cli/Cli.ps1')
        $consola | Should -Match '(?s)Invoke-LoteEliminacion.*-Sync \$sync'

        $ventana = Get-Content -Raw -LiteralPath (Join-Path $raiz 'src/UI/Window.Analisis.ps1')
        $ventana | Should -Match '(?s)Invoke-LoteEliminacion.*-Sync \$sync'

        $motor = Get-Content -Raw -LiteralPath (Join-Path $raiz 'src/Core/Remove.ps1')
        $motor | Should -Match '(?s)Invoke-EliminacionCandidato -Candidato \$candidato.*-Sync \$Sync'
    }

    It 'el bucle de borrado existe UNA sola vez' {
        # Dos copias (consola y ventana) acabarían divergiendo.
        $raiz = Split-Path $PSScriptRoot -Parent
        $copias = 0
        foreach ($archivo in @('src/Cli/Cli.ps1', 'src/UI/Window.Analisis.ps1')) {
            $texto = Get-Content -Raw -LiteralPath (Join-Path $raiz $archivo)
            $copias += @([regex]::Matches($texto, 'Invoke-EliminacionCandidato')).Count
        }
        $copias | Should -Be 0 -Because (
            'las dos interfaces tienen que llamar a Invoke-LoteEliminacion, no reimplementar el bucle')
    }
}

Describe 'un analisis incompleto no puede presentarse como completo' {

    <#
        Un análisis cancelado o con módulos fallidos, y una limpieza detenida
        a mitad, deben presentarse como incompletos en la ventana, la consola
        y el historial; si no, el usuario decide con información parcial.
    #>

    BeforeAll {
        $script:RaizCnf = Split-Path $PSScriptRoot -Parent
        $script:SinComentarios = {
            param([string] $Relativa)
            (Get-Content -LiteralPath (Join-Path $script:RaizCnf $Relativa) |
                Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        }
        $script:Analisis    = & $script:SinComentarios 'src/UI/Window.Analisis.ps1'
        $script:Eliminacion = & $script:SinComentarios 'src/UI/Window.Eliminacion.ps1'
        $script:Consola     = & $script:SinComentarios 'src/Cli/Cli.ps1'
    }

    It 'la ventana distingue terminado de detenido' {
        $script:Analisis | Should -Match 'Análisis detenido'
        $script:Analisis | Should -Match 'Análisis terminado'
    }

    It 'cancelar deja marca, no solo una linea en el registro' {
        $script:Analisis | Should -Match '\$estado\.AnalisisCancelado\s*=\s*\$true'
    }

    It 'se apunta QUE modulo ha fallado, no solo que hubo un error' {
        $script:Analisis | Should -Match '\$estado\.ModulosFallidos\.Add'
    }

    It 'la franja se enciende cuando falta algo y se apaga cuando no' {
        $script:Analisis | Should -Match "AvisoIncompleto\.Visibility\s*=\s*'Visible'"
        $script:Analisis | Should -Match "AvisoIncompleto\.Visibility\s*=\s*'Collapsed'"
    }

    It 'el historial recibe la verdad en los dos caminos' {
        # Las dos interfaces deben contar lo mismo.
        $script:Analisis    | Should -Match 'Add-EntradaHistorial[\s\S]{0,600}-Incompleto'
        $script:Eliminacion | Should -Match 'Add-EntradaHistorial[\s\S]{0,600}-Incompleto'
        $script:Consola     | Should -Match 'Add-EntradaHistorial[\s\S]{0,600}-Incompleto'
    }

    It 'no se anotan como revisados los modulos que no se llegaron a mirar' {
        # Solo se anotan los módulos que llegaron a ejecutarse.
        $script:Analisis | Should -Match 'Select-Object -First \$revisados'
        $script:Consola  | Should -Match 'notin \$idsFallidos'
    }

    It 'una limpieza detenida no se llama terminada' {
        $script:Eliminacion | Should -Match 'LIMPIEZA DETENIDA'
    }

    It 'la consola avisa igual que la ventana' {
        $script:Consola | Should -Match 'esta lista está incompleta'
    }

    It 'las banderas se reinician en cada analisis' {
        # Un aviso heredado del análisis anterior sería falso.
        $eventos = & $script:SinComentarios 'src/UI/Window.Eventos.ps1'
        $eventos | Should -Match '\$estado\.AnalisisCancelado\s*=\s*\$false'
        $eventos | Should -Match '\$estado\.ModulosFallidos\.Clear\(\)'
    }
}

Describe 'el texto que lee el usuario se escribe en espanol correcto' {

    <#
        Se comprueban solo las cadenas de prosa (catorce caracteres o más y
        al menos dos espacios), que es lo que llega a la pantalla y al
        informe. Los comentarios quedan fuera.

        La lista solo contiene palabras inequívocas: "solo", "esta", "mas",
        "de" o "si" dependen del contexto y producirían falsos positivos.
    #>

    BeforeAll {
        $script:RaizI18n = Split-Path $PSScriptRoot -Parent
        $script:SinTilde = @(
            'atencion', 'version', 'analisis', 'informacion', 'aplicacion',
            'configuracion', 'eliminacion', 'ubicacion', 'deteccion', 'ejecucion',
            'proteccion', 'extension', 'opcion', 'accion', 'sesion', 'revision',
            'conexion', 'instalacion', 'compilacion',
            'numero', 'codigo', 'menu', 'maquina', 'limite', 'minimo', 'maximo',
            'ningun', 'algun', 'ademas', 'despues', 'segun', 'tambien', 'aqui',
            'util', 'facil', 'dias', 'vacia', 'vacias', 'estan',
            'ultimo', 'ultima', 'ultimos', 'cache', 'caches', 'musica', 'anyos'
        )
    }

    It 'la prueba encuentra prosa: si no, no comprueba nada' {
        $s = 'Se ha borrado la carpeta entera'
        ($s.Length -ge 14 -and $s.Split(' ').Count -ge 3) | Should -BeTrue
    }

    It 'ninguna cadena de prosa usa una palabra sin su tilde' {
        $patron = '\b(' + ($script:SinTilde -join '|') + ')\b'
        $culpables = @()

        foreach ($archivo in @(Get-ChildItem (Join-Path $script:RaizI18n 'src') -Filter '*.ps1' -Recurse)) {
            $n = 0
            $enBloque = $false
            foreach ($linea in (Get-Content -LiteralPath $archivo.FullName)) {
                $n++
                # Los bloques de comentario también quedan fuera: citan código
                # (p. ej. "$null -contains $extension" en Guard.ps1).
                if ($linea -match '<#') { $enBloque = $true }
                if ($enBloque) {
                    if ($linea -match '#>') { $enBloque = $false }
                    continue
                }
                if ($linea -match '^\s*#') { continue }

                foreach ($m in [regex]::Matches($linea, "'([^'`n]+)'|`"([^`"`n]+)`"")) {
                    $texto = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }

                    # Se quitan antes las interpolaciones: en "hace $dias dias"
                    # la variable es código (sin tilde) y la palabra es prosa.
                    $texto = $texto -replace '\$\([^)]*\)', ' ' -replace '\$[A-Za-z_][A-Za-z0-9_:.]*', ' '

                    # Las rutas reales y las expresiones regulares que leen la
                    # salida de herramientas en inglés no son prosa: la carpeta
                    # se llama "cache" y DISM escribe "Cache and Temporary Data".
                    if ($texto -match '^\(\?') { continue }
                    $texto = $texto -replace '\\[^\\ ]*', ' '

                    if ($texto.Length -lt 14) { continue }
                    if (@($texto -split ' ' | Where-Object { $_ }).Count -lt 3) { continue }
                    if ($texto -cmatch $patron) {
                        $culpables += ('{0}:{1}  {2}' -f $archivo.Name, $n, $matches[0])
                    }
                }
            }
        }
        $culpables | Should -BeNullOrEmpty
    }

    It 'ninguna variable lleva tilde donde el resto del archivo no la lleva' {
        # Un reemplazo automático de tildes puede entrar en cadenas
        # interpoladas y renombrar una variable por otra inexistente, que
        # PowerShell resuelve a $null sin error.
        $culpables = @()
        foreach ($archivo in @(Get-ChildItem (Join-Path $script:RaizI18n 'src') -Filter '*.ps1' -Recurse)) {
            $texto  = Get-Content -Raw -LiteralPath $archivo.FullName
            $nombres = @([regex]::Matches($texto, '\$([A-Za-z_áéíóúñÁÉÍÓÚÑ][A-Za-z0-9_áéíóúñÁÉÍÓÚÑ]*)') |
                         ForEach-Object { $_.Groups[1].Value } |
                         Where-Object { $_ -cmatch '[áéíóúñÁÉÍÓÚÑ]' } | Select-Object -Unique)
            foreach ($nombre in $nombres) {
                $plano = $nombre -replace '[áÁ]', 'a' -replace '[éÉ]', 'e' -replace '[íÍ]', 'i' `
                                 -replace '[óÓ]', 'o' -replace '[úÚ]', 'u' -replace '[ñÑ]', 'n'
                if ($texto -cmatch ('\$' + [regex]::Escape($plano) + '\b')) {
                    $culpables += ('{0}: ${1} y ${2} conviven' -f $archivo.Name, $nombre, $plano)
                }
            }
        }
        $culpables | Should -BeNullOrEmpty -Because (
            'la misma variable escrita de dos formas significa que una de las dos no existe')
    }
}

Describe 'ninguna lista generica se crea con New-Object' {

    <#
        En Windows PowerShell 5.1, el objeto que devuelve
        "New-Object System.Collections.Generic.List[object]" no se puede
        enumerar con @( ): lanza ArgumentException ("Los tipos de argumentos
        no coinciden"), incluso vacío. foreach, la canalización, .Count y
        .ToArray() sí funcionan, y otros tipos genéricos no fallan.

        La regla se aplica a toda la familia Generic para no depender de una
        excepción arbitraria: se usa ::new().
    #>

    BeforeAll {
        $script:RaizProy = Split-Path $PSScriptRoot -Parent
        $script:Fuentes  = @(Get-ChildItem -Path (Join-Path $script:RaizProy 'src') -Filter '*.ps1' -Recurse) +
                           @(Get-ChildItem -Path $script:RaizProy -Filter 'Cachivache.ps1')
    }

    It 'la prueba encuentra archivos: si no, no comprueba nada' {
        @($script:Fuentes).Count | Should -BeGreaterThan 20
    }

    It 'ningun archivo usa New-Object con una coleccion generica' {
        $culpables = @()
        foreach ($archivo in $script:Fuentes) {
            $n = 0
            foreach ($linea in (Get-Content -LiteralPath $archivo.FullName)) {
                $n++
                if ($linea -match '^\s*#') { continue }
                if ($linea -match 'New-Object\s+[''"]?(System\.)?Collections\.Generic\.') {
                    $culpables += ('{0}:{1}' -f $archivo.Name, $n)
                }
            }
        }
        $culpables | Should -BeNullOrEmpty -Because (
            'hay que usar [Collections.Generic.X[...]]::new(); ver el comentario de Candidatos en Window.ps1')
    }

    It 'ningun Grid coloca cosas a la derecha sin declarar columnas' {
        # En un Grid sin columnas todos los hijos ocupan la misma celda;
        # alinear uno a la derecha simula dos columnas hasta que el contenido
        # crece y se superponen sin aviso. Con columnas declaradas, la de
        # Auto reserva su ancho antes de repartir. Sin WPF no se pueden medir
        # píxeles, así que se prohíbe la estructura.
        $malos = @()
        foreach ($archivo in @(Get-ChildItem -LiteralPath (Join-Path $script:Raiz 'src') `
                                             -Filter '*.xaml' -Recurse)) {
            $texto = [IO.File]::ReadAllText($archivo.FullName)
            # Grids hoja (sin otro Grid dentro), donde se colocan los controles.
            foreach ($m in [regex]::Matches($texto, '(?s)<Grid(?<attr>[^>]*)>(?<cuerpo>((?!<Grid[\s>]).)*?)</Grid>')) {
                $cuerpo = $m.Groups['cuerpo'].Value
                if ($cuerpo -notmatch 'HorizontalAlignment="Right"') { continue }
                if ($cuerpo -match '<Grid\.ColumnDefinitions>')      { continue }
                # Un solo hijo alineado a la derecha no se solapa con nada.
                $hijos = @([regex]::Matches($cuerpo,
                    '<(StackPanel|WrapPanel|DockPanel|Border|Button|TextBlock|CheckBox|ComboBox|Slider|ProgressBar|Image)[\s>]')).Count
                if ($hijos -lt 2) { continue }
                $linea = ($texto.Substring(0, $m.Index) -split "`n").Count
                $malos += ('{0}:{1}' -f $archivo.Name, $linea)
            }
        }
        $malos -join ', ' | Should -BeNullOrEmpty -Because (
            'sin columnas, todos los hijos comparten celda y se PINTAN ENCIMA cuando no caben')
    }

    It 'ningun Grid apila DOS grupos horizontales en la misma celda' {
        # Caso particular de la regla anterior: dos grupos horizontales en
        # un Grid sin columnas se superponen cuando su ancho total supera el
        # disponible. El Grid debe declarar columnas.
        $malos = @()
        foreach ($archivo in @(Get-ChildItem -LiteralPath (Join-Path $script:Raiz 'src') `
                                             -Filter '*.xaml' -Recurse)) {
            $texto = [IO.File]::ReadAllText($archivo.FullName)
            # Grids hoja: los que no contienen otro Grid.
            foreach ($m in [regex]::Matches($texto, '(?s)<Grid(?<attr>[^>]*)>(?<cuerpo>((?!<Grid[\s>]).)*?)</Grid>')) {
                $cuerpo = $m.Groups['cuerpo'].Value
                $grupos = @([regex]::Matches($cuerpo, '<(StackPanel|WrapPanel)[^>]*Orientation="Horizontal"'))
                if ($grupos.Count -lt 2) { continue }
                # Con columnas declaradas, o con cada grupo en su fila, el
                # solape no puede darse.
                if ($cuerpo -match '<Grid\.ColumnDefinitions>') { continue }
                if ($m.Groups['attr'].Value -match 'ColumnDefinitions') { continue }
                $malos += ('{0}: un Grid con {1} grupos horizontales y sin columnas' -f
                           $archivo.Name, $grupos.Count)
            }
        }
        $malos -join ' // ' | Should -BeNullOrEmpty -Because (
            'dos grupos horizontales en la misma celda se PINTAN ENCIMA cuando no caben')
    }

    It 'ningun archivo usa un acelerador de tipos que 5.1 no tiene' {
        # Aceleradores como [short] no existen hasta PowerShell 6: en 5.1,
        # "$Valor -is [short]" lanza "Unable to find type" al ejecutarse. No
        # falla al cargar ni lo ve el analizador; solo se nota al pasar por
        # esa línea en 5.1. Equivalentes válidos en 5.1: [int16], [uint16] y
        # [sbyte].
        $prohibidos = @{
            'short'  = '[int16]'
            'ushort' = '[uint16]'
            'bigint' = '[System.Numerics.BigInteger]'
        }
        $culpables = @()
        foreach ($archivo in $script:Fuentes) {
            $n = 0
            foreach ($linea in (Get-Content -LiteralPath $archivo.FullName)) {
                $n++
                if ($linea -match '^\s*#') { continue }
                foreach ($malo in $prohibidos.Keys) {
                    if ($linea -match ('\[\s*{0}\s*\]' -f $malo)) {
                        $culpables += ('{0}:{1} usa [{2}], hay que usar {3}' -f
                                       $archivo.Name, $n, $malo, $prohibidos[$malo])
                    }
                }
            }
        }
        $culpables -join ' // ' | Should -BeNullOrEmpty -Because (
            'esos aceleradores llegaron en PowerShell 6 y el programa corre en 5.1')
    }

    It 'ningun literal hexadecimal con el bit alto puesto se escribe sin la L' {
        # En PowerShell, [uint32]0xFFFFFFFF no vale 4.294.967.295: el literal
        # de ocho dígitos se lee como Int32 (-1) y la conversión lanza. Dentro
        # de un try, el fallo se confunde con un rechazo del sistema.
        #
        # Regla: un literal 0x de exactamente ocho dígitos que empieza por 8-F
        # es un Int32 negativo; compara mal con -band y lanza al convertir a
        # un tipo sin signo. El sufijo L lo convierte en Int64. Los de dieciséis
        # dígitos que empiezan por 8-F son Int64 negativos y la L no los
        # corrige: se escriben en decimal o con ::MaxValue.
        #
        # Se barren src/, tools/ y la raíz.
        function script:Get-SinComentariosHex {
            param([string] $Ruta)
            $t = [IO.File]::ReadAllText($Ruta)
            # Primero los bloques y después las líneas de comentario (al revés
            # se perdería el cierre). Los comentarios citan el literal sin L.
            $t = [regex]::Replace($t, '(?s)<#.*?#>', '')
            return (@($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        }

        # El detector va aparte para poder probarlo con texto fabricado, sin
        # depender de que el repositorio contenga ejemplos.
        function script:Get-LiteralesPeligrosos {
            param([string] $Texto)
            $malos = @()
            $n = 0
            foreach ($linea in ($Texto -split "`n")) {
                $n++
                # Ocho dígitos, el primero de 8 a F. (?![0-9A-Fa-f]) evita
                # capturar parte de un literal más largo.
                foreach ($m in [regex]::Matches($linea, '0x(?<d>[89A-Fa-f][0-9A-Fa-f]{7})(?![0-9A-Fa-f])(?<suf>[Ll]?)')) {
                    if ($m.Groups['suf'].Value) { continue }
                    # El valor se obtiene reinterpretando los bytes, como hace
                    # el analizador de PowerShell; [int][Convert]::ToUInt32(...)
                    # lanzaría con valores mayores que Int32.MaxValue.
                    $valor = [BitConverter]::ToInt32(
                                 [BitConverter]::GetBytes([Convert]::ToUInt32($m.Groups['d'].Value, 16)), 0)
                    $malos += ('linea {0}: 0x{1} sin la L (es un Int32 que vale {2})' -f
                               $n, $m.Groups['d'].Value, $valor)
                }
                foreach ($m in [regex]::Matches($linea, '0x(?<d>[89A-Fa-f][0-9A-Fa-f]{15})(?![0-9A-Fa-f])')) {
                    $malos += ('linea {0}: 0x{1}, que es un Int64 negativo y la L no lo arregla' -f
                               $n, $m.Groups['d'].Value)
                }
            }
            return $malos
        }

        # Control del detector con texto fabricado: debe marcar lo incorrecto
        # y no marcar lo correcto.
        @(script:Get-LiteralesPeligrosos '$mascara = [uint32]0xFFFFFFFF').Count |
            Should -Be 1 -Because 'si no ve el literal sin L, el barrido no detecta nada'
        @(script:Get-LiteralesPeligrosos '$fin = 0x8000000000000001').Count |
            Should -Be 1 -Because 'los de dieciseis digitos que empiezan por 8-F tambien'
        @(script:Get-LiteralesPeligrosos "`$ok = 0xFFFFFFFFL
`$tambien = 0x7FFFFFFF
`$y = 0x00000010
`$nueve = 0xFFFFFFFFF").Count |
            Should -Be 0 -Because 'un detector que marca lo correcto no sirve de nada'

        $aBarrer = @($script:Fuentes) +
                   @(Get-ChildItem -Path (Join-Path $script:RaizProy 'tools') -Filter '*.ps1' -Recurse)
        @($aBarrer).Count | Should -BeGreaterThan 20 -Because 'sin archivos que barrer, esto no comprueba nada'

        $culpables = @()
        foreach ($archivo in $aBarrer) {
            foreach ($malo in @(script:Get-LiteralesPeligrosos (script:Get-SinComentariosHex $archivo.FullName))) {
                $culpables += ('{0} {1}' -f $archivo.Name, $malo)
            }
        }

        $culpables -join ' // ' | Should -BeNullOrEmpty -Because (
            'un 0x de ocho digitos que empieza por 8-F es un Int32 NEGATIVO: ' +
            'lanza al convertirlo a un tipo sin signo y compara mal con -band')
    }

    It 'la lista de candidatos de la ventana se puede enumerar con @( )' {
        # Se construye como en Window.ps1 y se enumera como en Report.ps1.
        $lista = [Collections.Generic.List[object]]::new()
        $lista.Add([pscustomobject]@{ Bytes = 10 })
        $lista.Add([pscustomobject]@{ Bytes = 20 })

        { $null = @($lista) } | Should -Not -Throw
        @($lista).Count | Should -Be 2
    }
}

Describe 'simular no puede dejar rastro de una limpieza que no ocurrio' {

    <#
        Una simulación no anota historial ni guarda un informe de limpieza.
        Se comprueban la ventana y la consola.
    #>

    BeforeAll {
        $script:Raiz = Split-Path $PSScriptRoot -Parent
        $script:Consola = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/Cli/Cli.ps1')
        $script:Cierre  = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Window.Eliminacion.ps1')
    }

    It 'la consola no anota historial cuando simula' {
        $script:Consola | Should -Match '(?s)if \(-not \$Simular\).*Add-EntradaHistorial'
    }

    It 'la ventana corta ANTES de anotar historial y de exportar el informe' {
        # La condición debe ir antes de las dos llamadas: se compara su posición en el texto.
        $corte     = $script:Cierre.IndexOf('if ($simulado)')
        $historial = $script:Cierre.IndexOf('Add-EntradaHistorial')
        $informe   = $script:Cierre.IndexOf('Export-InformeHtml')

        $corte     | Should -BeGreaterThan -1 -Because 'tiene que haber una rama de simulacion'
        $historial | Should -BeGreaterThan $corte -Because 'el historial se anota despues del corte, nunca antes'
        $informe   | Should -BeGreaterThan $corte -Because 'el informe se exporta despues del corte, nunca antes'
    }

    It 'la ventana sale de la rama de simulacion sin seguir' {
        # Sin return, la rama seguiría por el camino normal (historial e informe).
        #
        # Se examina el tramo entre el corte y el camino normal; una expresión
        # con [^}]* se cortaría en los marcadores {0} y {1} de los mensajes.
        $corte  = $script:Cierre.IndexOf('if ($simulado)')
        $normal = $script:Cierre.IndexOf('$libreAhora = Get-EspacioLibre')

        $corte  | Should -BeGreaterThan -1
        $normal | Should -BeGreaterThan $corte

        $rama = $script:Cierre.Substring($corte, $normal - $corte)
        $rama | Should -Match '(?m)^\s*return\s*$' -Because (
            'sin return, la rama solo añade texto y luego borra igual')
    }

    It 'el modo del lote se congela al lanzarlo, no se relee de la casilla al final' {
        # El usuario puede desmarcar la casilla durante el lote.
        $script:Cierre | Should -Match '\$simulado\s*=\s*\[bool\]\$estado\.SimulandoLote'
        $script:Cierre | Should -Not -Match 'ChkSimular' -Because (
            'el cierre decide por el estado congelado, nunca por el control')
    }

    It 'simular no se guarda entre sesiones' {
        # Persistida, quedaría activada en silencio en sesiones posteriores.
        $prefs = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/Core/Preferencias.ps1')
        $prefs | Should -Not -Match '(?m)^\s*Simular\s*=' -Because (
            'no es una preferencia, es una comprobacion previa a un acto concreto')
    }

    It 'la casilla de la ventana llega al motor de borrado' {
        # Camino completo: casilla -> estado -> runspace -> motor. Un corte
        # mostraría "Solo simular" y borraría de verdad.
        $eventos  = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Window.Eventos.ps1')
        $analisis = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Window.Analisis.ps1')

        $eventos  | Should -Match '\$simular\s*=\s*\[bool\]\$c\.ChkSimular\.IsChecked'
        $eventos  | Should -Match '(?s)\$lanzarTrabajo \$codigoBorrado.*simular\s*=\s*\$simular'
        $analisis | Should -Match 'Invoke-LoteEliminacion.*-Simular:\$simular'
    }

    It 'el boton no puede decir "Eliminar" mientras simula' {
        $eventos = Get-Content -Raw -LiteralPath (Join-Path $script:Raiz 'src/UI/Window.Eventos.ps1')
        $eventos | Should -Match "BtnEliminar\.Content\s*=\s*'Simular limpieza'"
    }
}

Describe 'las cuatro listas de metodos no pueden divergir' {

    <#
        La lista de métodos válidos vive en cuatro sitios: la cabecera de
        Candidate.ps1, su ValidateSet, el array $sinRuta de ModuleRegistry.ps1
        y el switch de Remove.ps1. Un método sin rama cae en 'default', que
        borra por ruta: un método pensado para vaciar contenido o informar
        borraría la carpeta entera.
    #>

    BeforeAll {
        $script:CarpetaNucleo = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Core'

        # 1. La fuente de verdad: el ValidateSet del parámetro -Metodo.
        $astCandidato = Get-AstDe (Join-Path $script:CarpetaNucleo 'Candidate.ps1')
        $conjunto = $astCandidato.FindAll({
            param($n) $n -is [System.Management.Automation.Language.AttributeAst] -and
                      $n.TypeName.Name -eq 'ValidateSet'
        }, $true) | Select-Object -First 1
        $script:MetodosValidos = @($conjunto.PositionalArguments |
                                   ForEach-Object { $_.Value })

        # 2. Las ramas del switch del motor de borrado.
        $astRemove = Get-AstDe (Join-Path $script:CarpetaNucleo 'Remove.ps1')
        $switch = $astRemove.FindAll({
            param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] -and
                      $n.Condition.Extent.Text -match 'Metodo'
        }, $true) | Select-Object -First 1
        $script:RamasSwitch = @($switch.Clauses | ForEach-Object { $_.Item1.Extent.Text.Trim("'`"") })

        # 3. Los métodos exentos de la guardia por no tener ruta real.
        $textoRegistro = Get-Content -Raw -LiteralPath (
            Join-Path $script:CarpetaNucleo 'ModuleRegistry.ps1')
        $script:SinRuta = @()
        if ($textoRegistro -match "\`$sinRuta\s*=\s*@\(([^)]*)\)") {
            $script:SinRuta = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'`"") } |
                                Where-Object { $_ })
        }

        # 4. El comentario de cabecera que los documenta.
        $textoCandidato = Get-Content -Raw -LiteralPath (
            Join-Path $script:CarpetaNucleo 'Candidate.ps1')
        $script:Documentados = @([regex]::Matches($textoCandidato, '(?m)^#\s{3}(\w+)\s+->') |
                                 ForEach-Object { $_.Groups[1].Value })
    }

    It 'la prueba encuentra las cuatro listas: si no, no comprueba nada' {
        $script:MetodosValidos.Count | Should -BeGreaterThan 4
        $script:RamasSwitch.Count    | Should -BeGreaterThan 0
        $script:SinRuta.Count        | Should -BeGreaterThan 0
        $script:Documentados.Count   | Should -BeGreaterThan 4
    }

    It 'todo metodo del ValidateSet esta documentado en la cabecera' {
        $sinDocumentar = @($script:MetodosValidos | Where-Object { $_ -notin $script:Documentados })
        $sinDocumentar | Should -BeNullOrEmpty -Because (
            'la cabecera de Candidate.ps1 es donde se explica que hace cada metodo')
    }

    It 'todo metodo documentado existe de verdad en el ValidateSet' {
        # Caso inverso: no se documentan métodos inexistentes.
        $inventados = @($script:Documentados | Where-Object { $_ -notin $script:MetodosValidos })
        $inventados | Should -BeNullOrEmpty
    }

    It 'todo metodo o tiene rama propia en el motor, o esta exento de la guardia' {
        # 'Ruta' es el comportamiento del 'default' del switch y no necesita rama.
        $cubiertos = @($script:RamasSwitch) + @($script:SinRuta) + @('Ruta')
        $huerfanos = @($script:MetodosValidos | Where-Object { $_ -notin $cubiertos })

        $huerfanos | Should -BeNullOrEmpty -Because (
            'un metodo sin rama cae en el default del switch, que BORRA POR RUTA: ' +
            'un metodo pensado para informar acabaria borrando la carpeta')
    }

    It 'ninguna rama del switch invoca a un metodo que ya no existe' {
        $fantasmas = @($script:RamasSwitch | Where-Object { $_ -notin $script:MetodosValidos })
        $fantasmas | Should -BeNullOrEmpty -Because 'codigo inalcanzable que aparenta cubrir un caso'
    }

    It 'ningun metodo exento de la guardia se ha quedado sin existir' {
        $fantasmas = @($script:SinRuta | Where-Object { $_ -notin $script:MetodosValidos })
        $fantasmas | Should -BeNullOrEmpty
    }

    It 'todo metodo esta clasificado como recuperable o como irreversible' {
        <#
            Quinta lista de métodos, comprobada junto a las demás. Un método
            sin clasificar dado por recuperable por descarte haría que el
            programa ofreciera recuperar de la papelera algo que no está.
        #>
        $texto = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaNucleo 'Remove.ps1')

        $leerLista = {
            param([string] $Nombre)
            if ($texto -match ("\`$script:$Nombre\s*=\s*@\(([^)]*)\)")) {
                return @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'`"") } |
                         Where-Object { $_ })
            }
            return @()
        }

        $recuperables  = @(& $leerLista 'MetodosRecuperables')
        $irreversibles = @(& $leerLista 'MetodosIrreversibles')

        $recuperables.Count  | Should -BeGreaterThan 0 -Because 'si no se leen, la prueba no comprueba nada'
        $irreversibles.Count | Should -BeGreaterThan 0

        # 1. Juntas cubren todos los métodos válidos.
        $clasificados = @($recuperables) + @($irreversibles)
        $sinClasificar = @($script:MetodosValidos | Where-Object { $_ -notin $clasificados })
        $sinClasificar | Should -BeNullOrEmpty -Because (
            'un metodo sin clasificar se daria por recuperable por descarte, y el programa ' +
            'ofreceria rescatar de la papelera algo que nunca fue a la papelera')

        # 2. No se solapan: un método no puede ser las dos cosas.
        $ambiguos = @($recuperables | Where-Object { $_ -in $irreversibles })
        $ambiguos | Should -BeNullOrEmpty

        # 3. Ninguna inventa métodos que no existen.
        $fantasmas = @($clasificados | Where-Object { $_ -notin $script:MetodosValidos })
        $fantasmas | Should -BeNullOrEmpty
    }
}

Describe 'el criterio se dice en los DOS caminos' {

    <#
        El criterio de premarcado se muestra donde el usuario decide qué
        borrar, tanto en la ventana como en la consola.
    #>

    BeforeAll {
        $script:RaizCnf5 = Split-Path $PSScriptRoot -Parent
        $script:SinCom = {
            param([string] $Rel)
            [regex]::Replace(
                ((Get-Content -LiteralPath (Join-Path $script:RaizCnf5 $Rel) |
                  Where-Object { $_ -notmatch '^\s*#' }) -join "`n"), '(?s)<#.*?#>', '')
        }
    }

    It 'la ventana lo muestra en el resumen del análisis' {
        (& $script:SinCom 'src/UI/Window.Analisis.ps1') | Should -Match 'Get-ResumenPremarcado'
    }

    It 'la consola tambien' {
        (& $script:SinCom 'src/Cli/Cli.ps1') | Should -Match 'Get-ResumenPremarcado'
    }

    It 'y cada fila lleva su motivo' {
        (& $script:SinCom 'src/UI/Window.Analisis.ps1') | Should -Match 'MotivoMarcado = Get-MotivoPremarcado'
    }

    It 'la regla se decide en UN solo sitio' {
        # Si New-Candidato duplicara la condición, explicación y decisión podrían divergir.
        $candidato = & $script:SinCom 'src/Core/Candidate.ps1'
        $candidato | Should -Match '\$marcado = Test-DebeVenirMarcado'
        $candidato | Should -Not -Match "\`$marcado = \`$Riesgo -eq 'Bajo' -and"
    }
}

Describe 'La ventana no puede pedir un recurso que no existe' {

    <#
        Un {StaticResource} inexistente no falla al interpretar el XML sino
        al abrir la ventana, con una excepción que cierra el programa antes
        de poder informar. Es lo más parecido a "la ventana abrirá" que se
        puede comprobar sin WPF.
    #>

    BeforeAll {
        $script:CarpetaXaml = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'
        $script:Xamls = @(Get-ChildItem $script:CarpetaXaml -Filter '*.xaml')

        # Claves x:Key de cualquier archivo: los diccionarios de tema y estilos
        # se combinan al arrancar.
        $script:Claves = @{}
        foreach ($archivo in $script:Xamls) {
            $texto = Get-Content -Raw -LiteralPath $archivo.FullName
            foreach ($m in [regex]::Matches($texto, 'x:Key="([^"]+)"')) {
                $script:Claves[$m.Groups[1].Value] = $archivo.Name
            }
        }

        # Referencias sin comentarios XML, que pueden contener ejemplos.
        $script:Referencias = @{}
        foreach ($archivo in $script:Xamls) {
            $texto = [regex]::Replace(
                (Get-Content -Raw -LiteralPath $archivo.FullName), '(?s)<!--.*?-->', '')
            foreach ($m in [regex]::Matches($texto, '\{(?:Static|Dynamic)Resource\s+([A-Za-z_][\w.]*)\s*\}')) {
                $clave = $m.Groups[1].Value
                if (-not $script:Referencias.ContainsKey($clave)) { $script:Referencias[$clave] = @() }
                $script:Referencias[$clave] += $archivo.Name
            }
        }
    }

    It 'la prueba encuentra recursos: si no, no comprueba nada' {
        $script:Claves.Count      | Should -BeGreaterThan 20
        $script:Referencias.Count | Should -BeGreaterThan 20
    }

    It 'toda referencia a un recurso tiene su clave declarada' {
        $huerfanas = @()
        foreach ($clave in $script:Referencias.Keys) {
            if (-not $script:Claves.ContainsKey($clave)) {
                $huerfanas += ('{0} (usado en {1})' -f $clave,
                               (($script:Referencias[$clave] | Select-Object -Unique) -join ', '))
            }
        }
        $huerfanas | Should -BeNullOrEmpty -Because (
            'un recurso que no existe no falla al escribirlo: se lleva la ventana entera al abrirla')
    }

    It 'los dos temas declaran las mismas claves que se usan como DynamicResource' {
        # Un color solo del tema oscuro dejaría el claro a medio pintar.
        $oscuro = @{}
        $claro  = @{}
        foreach ($par in @(@('Theme.Dark.xaml', $oscuro), @('Theme.Light.xaml', $claro))) {
            $texto = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaXaml $par[0])
            foreach ($m in [regex]::Matches($texto, 'x:Key="([^"]+)"')) { $par[1][$m.Groups[1].Value] = $true }
        }
        @($oscuro.Keys | Where-Object { -not $claro.ContainsKey($_) })  | Should -BeNullOrEmpty
        @($claro.Keys  | Where-Object { -not $oscuro.ContainsKey($_) }) | Should -BeNullOrEmpty
    }
}

Describe 'El teclado tiene que poder salir del dialogo y no puede navegar sin querer' {
    <#
        Son atributos de XAML que pueden perderse en un cambio de formato sin
        que nada falle; de ellos depende la salida por teclado del diálogo
        que confirma un borrado.
    #>

    BeforeAll {
        $script:CarpetaUiTeclado = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        function Get-XamlSinComentarios {
            param([string]$Nombre)
            # Sin comentarios, que mencionan los mismos atributos.
            [regex]::Replace(
                (Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUiTeclado $Nombre)),
                '(?s)<!--.*?-->', '')
        }

        $script:Dialogo = Get-XamlSinComentarios 'ConfirmDialog.xaml'
        $script:Ventana = Get-XamlSinComentarios 'MainWindow.xaml'
    }

    It 'la prueba mira archivos con contenido: si no, no comprueba nada' {
        $script:Dialogo.Length | Should -BeGreaterThan 1000
        $script:Ventana.Length | Should -BeGreaterThan 1000
    }

    It 'el boton de cancelar es el de Escape' {
        # Sin IsCancel, Escape solo funciona con el foco en el cuadro de texto.
        $script:Dialogo | Should -Match 'x:Name="BtnNo"[^>]*IsCancel="True"' -Because (
            'un dialogo que bloquea la ventana tiene que poder cerrarse con el teclado desde cualquier foco')
    }

    It 'el boton de borrar NO es el de Enter' {
        # IsDefault lanzaría el borrado con Enter desde cualquier foco.
        $script:Dialogo | Should -Not -Match 'IsDefault="True"' -Because (
            'el dialogo existe para frenar un clic distraido; Enter global lo convertiria en un tramite')
    }

    It 'el dialogo no puede crecer hasta sacar los botones de la pantalla' {
        # Con SizeToContent="Height" y una lista variable, sin tope los botones
        # pueden quedar fuera de la pantalla.
        # Se mira solo la etiqueta <Window ...>: el ScrollViewer interior
        # tiene su propio MaxHeight.
        $etiqueta = [regex]::Match($script:Dialogo, '(?s)<Window\b.*?>').Value
        $etiqueta | Should -Match 'SizeToContent="Height"' -Because 'si no crece sola, esta prueba mira otra cosa'
        $etiqueta | Should -Match 'MaxHeight="\d+"'

        $tope = [int][regex]::Match($etiqueta, 'MaxHeight="(\d+)"').Groups[1].Value
        $tope | Should -BeLessOrEqual 768 -Because 'el caso peor comun es un portatil de 768 px de alto'
    }

    It 'las flechas no cambian de panel en la barra lateral' {
        $script:Ventana | Should -Match 'KeyboardNavigation\.DirectionalNavigation="None"' -Because (
            'son RadioButton en grupo: en WPF la flecha mueve el foco Y marca, y marcar aqui cambia de panel')
    }

    It 'las seis entradas de navegacion son puntos de tabulacion' {
        # Si las flechas no navegan, Tab es la única forma de recorrerlas.
        $radios = @([regex]::Matches($script:Ventana, '<RadioButton x:Name="Nav\w+"(?s).*?/>'))
        $radios.Count | Should -Be 6 -Because 'si no son seis, la prueba esta mirando otra cosa'

        foreach ($radio in $radios) {
            $radio.Value | Should -Match 'IsTabStop="True"' -Because (
                'sin flechas, una entrada que Tab no visita es una entrada inalcanzable con teclado')
        }
    }
}

Describe 'La etiqueta de riesgo no puede ser el texto más pequeño del programa' {
    <#
        El riesgo decide si algo se borra. La prueba no fija un tamaño
        concreto sino la relación con el resto de textos.
    #>

    BeforeAll {
        $script:Estilos = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI') 'Styles.xaml')),
            '(?s)<!--.*?-->', '')

        # Solo el bloque del estilo: Styles.xaml contiene muchos otros FontSize.
        function Get-BloqueEstilo {
            param([string]$Clave)
            $m = [regex]::Match($script:Estilos, ('(?s)<Style x:Key="{0}".*?</Style>' -f [regex]::Escape($Clave)))
            if (-not $m.Success) { throw ('no esta el estilo {0}' -f $Clave) }
            $m.Value
        }

        function Get-TamanyosDeLetra {
            # Dos formas de escribir un tamaño:
            #   <Setter Property="FontSize" Value="13"/>   (dentro de un Style)
            #   FontSize="13"                              (en un elemento)
            @([regex]::Matches($script:Estilos, 'Property="FontSize"\s+Value="(\d+)"') |
              ForEach-Object { [int]$_.Groups[1].Value }) +
            @([regex]::Matches($script:Estilos, '(?<!Property=")\bFontSize\s*=\s*"(\d+)"') |
              ForEach-Object { [int]$_.Groups[1].Value })
        }
    }

    It 'la prueba encuentra los dos estilos: si no, no comprueba nada' {
        (Get-BloqueEstilo 'TextoEtiqueta').Length | Should -BeGreaterThan 100
        (Get-BloqueEstilo 'Punto').Length         | Should -BeGreaterThan 50
    }

    It 'ningún texto de la interfaz es más pequeño que la etiqueta de riesgo' {
        $etiqueta = [int][regex]::Match((Get-BloqueEstilo 'TextoEtiqueta'), 'Property="FontSize"\s+Value="(\d+)"').Groups[1].Value

        $todos = @(Get-TamanyosDeLetra)
        $todos.Count | Should -BeGreaterThan 5 -Because 'si no hay tamaños que comparar, la prueba no compara nada'

        # Estrictamente mayor que el mínimo: el escalón de 11 es para rótulos
        # de estructura ("Seccion", cabeceras de columna), no para el riesgo,
        # que se lee en cada fila.
        $etiqueta | Should -BeGreaterThan ($todos | Measure-Object -Minimum).Minimum -Because (
            'el dato de seguridad de cada fila no puede ser el texto más pequeño del programa')
        $etiqueta | Should -BeGreaterOrEqual 12
    }

    It 'el punto de color se ve al lado de su etiqueta' {
        $punto = [int][regex]::Match((Get-BloqueEstilo 'Punto'), 'Property="Width"\s+Value="(\d+)"').Groups[1].Value
        $punto | Should -BeGreaterOrEqual 9 -Because 'el punto ES el color del riesgo; a 7 px es una mota'

        # Redondo: si alto y ancho se separan, deja de ser un punto.
        $alto = [int][regex]::Match((Get-BloqueEstilo 'Punto'), 'Property="Height"\s+Value="(\d+)"').Groups[1].Value
        $alto | Should -Be $punto
    }

    It 'no se ha inventado un séptimo tamaño de letra' {
        # Se usan escalones existentes de la escala; no se añaden nuevos.
        $escala = @(11, 12, 13, 15, 20, 28)
        $usados = @(Get-TamanyosDeLetra | Sort-Object -Unique)

        @($usados | Where-Object { $_ -notin $escala }) | Should -BeNullOrEmpty -Because (
            'la escala es 11/12/13/15/20/28 y el arreglo tenia que caber dentro')
    }
}

Describe 'Un disparador no puede apuntar a algo que no es un elemento' {
    <#
        Una RotateTransform con x:Name dentro de una plantilla es un
        Freezable, no un FrameworkElement: no entra en el ámbito de nombres y
        un Setter con TargetName no la encuentra. El contenido de una
        plantilla se analiza al aplicarse, así que el error ("La
        inicialización de System.Windows.Setter produjo una excepción")
        aparece en tiempo de ejecución, no al cargar el XAML.

        Lo correcto es apuntar al elemento y reemplazar su transformación.
    #>

    BeforeAll {
        $script:CarpetaXamlNombres = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        # Objetos de plantilla que no son elementos (pinceles, transformaciones,
        # geometrías) y quedan fuera del ámbito de nombres.
        $script:NoSonElementos = @(
            'RotateTransform', 'ScaleTransform', 'SkewTransform', 'TranslateTransform',
            'MatrixTransform', 'TransformGroup', 'RotateTransform3D',
            'SolidColorBrush', 'LinearGradientBrush', 'RadialGradientBrush', 'ImageBrush',
            'VisualBrush', 'DrawingBrush', 'GradientStop',
            'PathGeometry', 'StreamGeometry', 'RectangleGeometry', 'EllipseGeometry',
            'LineGeometry', 'GeometryGroup', 'CombinedGeometry',
            'DropShadowEffect', 'BlurEffect'
        )

        $script:NombradosPorArchivo = @{}
        foreach ($archivo in (Get-ChildItem $script:CarpetaXamlNombres -Filter '*.xaml')) {
            $texto = [regex]::Replace(
                (Get-Content -Raw -LiteralPath $archivo.FullName), '(?s)<!--.*?-->', '')
            $script:NombradosPorArchivo[$archivo.Name] = $texto
        }
    }

    It 'la prueba lee XAML de verdad: si no, no comprueba nada' {
        $script:NombradosPorArchivo.Count | Should -BeGreaterThan 5
        @($script:NombradosPorArchivo.Values | Where-Object { $_ -match 'x:Name=' }).Count |
            Should -BeGreaterThan 5
    }

    It 'nada que no sea un elemento lleva x:Name' {
        $malos = @()
        foreach ($nombre in $script:NombradosPorArchivo.Keys) {
            foreach ($m in [regex]::Matches($script:NombradosPorArchivo[$nombre], '<([A-Za-z][\w.]*)\s[^>]*x:Name="([^"]+)"')) {
                $etiqueta = $m.Groups[1].Value
                if ($etiqueta -in $script:NoSonElementos) {
                    $malos += ('{0} x:Name="{1}" en {2}' -f $etiqueta, $m.Groups[2].Value, $nombre)
                }
            }
        }
        $malos | Should -BeNullOrEmpty -Because (
            'no esta en el ambito de nombres de la plantilla: TargetName no lo encontrara y WPF lanzara al aplicar el disparador, no al cargar')
    }

    It 'todo TargetName apunta a un nombre que existe en el mismo archivo' {
        # Un TargetName sin resolver falla al aplicarse, no al cargar.
        $huerfanos = @()
        foreach ($nombre in $script:NombradosPorArchivo.Keys) {
            $texto = $script:NombradosPorArchivo[$nombre]
            $declarados = @{}
            foreach ($m in [regex]::Matches($texto, 'x:Name="([^"]+)"')) { $declarados[$m.Groups[1].Value] = $true }

            foreach ($m in [regex]::Matches($texto, 'TargetName="([^"]+)"')) {
                $destino = $m.Groups[1].Value
                if (-not $declarados.ContainsKey($destino)) {
                    $huerfanos += ('{0} -> {1}' -f $nombre, $destino)
                }
            }
        }
        $huerfanos | Should -BeNullOrEmpty
    }
}

Describe 'El manejador de fallos de la ventana no puede volver a inundar la pantalla' {
    <#
        El límite vive en Test-DebeAvisarDelFallo, pero lo llama el manejador
        de Window.ps1; quitar esa llamada no rompería ninguna otra prueba.
    #>

    BeforeAll {
        $script:TextoVentana = [regex]::Replace(
            (Get-Content -Raw -LiteralPath (Join-Path (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI') 'Window.ps1')),
            '(?m)^\s*#.*$', '')
    }

    It 'la prueba lee el manejador: si no, no comprueba nada' {
        $script:TextoVentana | Should -Match 'Add_DispatcherUnhandledException'
    }

    It 'el aviso por pantalla pasa por el filtro de repetidos' {
        $script:TextoVentana | Should -Match 'Test-DebeAvisarDelFallo' -Because (
            'sin el, un fallo que se repite abre un cuadro modal por repeticion y entierra la ventana')
    }

    It 'el registro se escribe SIEMPRE, tenga o no tenga aviso' {
        # El filtro es solo para la pantalla; el registro guarda cada aparición.
        $manejador = [regex]::Match($script:TextoVentana,
            '(?s)Add_DispatcherUnhandledException\(\{.*?\$argumentos\.Handled = \$true').Value
        $manejador.Length | Should -BeGreaterThan 200 -Because 'si no, la prueba mira otra cosa'

        $posicionRegistro = $manejador.IndexOf('Write-Registro')
        $posicionFiltro   = $manejador.IndexOf('Test-DebeAvisarDelFallo')
        $posicionRegistro | Should -BeGreaterThan 0
        $posicionFiltro   | Should -BeGreaterThan $posicionRegistro -Because (
            'primero se anota y despues se decide si ademas se avisa')
    }
}

Describe 'El cartel de la simulación no puede quedarse mintiendo' {
    <#
        La cifra del cartel ("se habrían liberado 9,83 GB") corresponde a la
        selección del momento de la simulación. Caduca en
        $actualizarResumenSeleccion, por donde pasa todo cambio de marcado.
    #>

    BeforeAll {
        $script:CarpetaUiSim = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        function Get-FuenteUi {
            param([string]$Nombre)
            [regex]::Replace(
                (Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUiSim $Nombre)),
                '(?m)^\s*#.*$', '')
        }

        $script:Ayudantes   = Get-FuenteUi 'Window.Ayudantes.ps1'
        $script:Eliminacion = Get-FuenteUi 'Window.Eliminacion.ps1'
    }

    It 'la prueba lee los dos archivos: si no, no comprueba nada' {
        $script:Ayudantes   | Should -Match 'actualizarResumenSeleccion'
        $script:Eliminacion | Should -Match 'terminarBorrado'
    }

    It 'la simulación deja el resultado en Resultados, no solo en el Registro' {
        $script:Eliminacion | Should -Match 'AvisoSimulacion' -Because (
            'el registro es otro panel: quien pulsa el boton no lo esta mirando')
        $script:Eliminacion | Should -Match 'Format-ResumenSimulacion'
    }

    It 'el cartel caduca al cambiar la selección' {
        $script:Ayudantes | Should -Match 'AvisoSimulacion' -Because (
            'sus cifras son las de lo que estaba marcado al simular')
    }

    It 'si el cartel no esta, se dice' {
        # Un FindName nulo no lanza; la ausencia del cartel debe registrarse.
        $script:Eliminacion | Should -Match 'AVISO INTERNO' -Because (
            'fallar en silencio al avisar es el mismo fallo, escondido un piso mas abajo')
    }

    It 'la cabecera de grupo no depende de un disparador para decir el numero' {
        # Con un DataTrigger para el singular, en Windows se aplicaba el
        # disparador pero no el valor por defecto ("12" sin palabra).
        $cabecera = [regex]::Match(
            (Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaUiSim 'Panel.Resultados.xaml')),
            '(?s)<ControlTemplate TargetType="GroupItem">.*?</ControlTemplate>').Value
        $cabecera.Length | Should -BeGreaterThan 500 -Because 'si no, la prueba mira otra cosa'

        $sinComentarios = [regex]::Replace($cabecera, '(?s)<!--.*?-->', '')
        $sinComentarios | Should -Not -Match '<Style TargetType="Run"' -Because (
            'no se deja en la cabecera un mecanismo que no se puede comprobar aqui')
    }

    It 'se pone DESPUES de actualizar el resumen, que es quien lo borra' {
        # Al revés, la actualización del resumen borraría el cartel recién puesto.
        $bloque = [regex]::Match($script:Eliminacion,
            '(?s)if \(\$simulado\).*?return').Value
        $bloque.Length | Should -BeGreaterThan 200 -Because 'si no, la prueba mira otra cosa'

        $posResumen = $bloque.IndexOf('actualizarResumenSeleccion')
        $posCartel  = $bloque.IndexOf('AvisoSimulacion')
        $posResumen | Should -BeGreaterThan 0
        $posCartel  | Should -BeGreaterThan $posResumen
    }
}

Describe 'ningun control sin texto puede quedarse sin nombre accesible' {
    <#
        El nombre accesible de un Button sale de su Content; si el Content es
        un dibujo (Path, Border), un lector de pantalla solo anuncia "botón".
        Lo mismo con las casillas de cada fila. El fallo no es visible ni lo
        detecta el analizador.

        1. Todo control interactivo sin texto propio declara un nombre.
        2. Todo nombre enlazado apunta a una propiedad que existe: un
           {Binding} mal escrito se resuelve a vacío sin aviso.
    #>

    BeforeAll {
        $script:CarpetaA11y = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'
        . (Join-Path $script:CarpetaA11y 'Xaml.ps1')

        # El documento montado: el armazón solo contiene la barra de título.
        $montado = Expand-PanelesXaml -Carpeta $script:CarpetaA11y `
                       -Texto ([IO.File]::ReadAllText((Join-Path $script:CarpetaA11y 'MainWindow.xaml')))

        $script:DocsA11y = @{
            'MainWindow (montado)' = [xml] $montado
            'ConfirmDialog.xaml'   = [xml] ([IO.File]::ReadAllText(
                                        (Join-Path $script:CarpetaA11y 'ConfirmDialog.xaml')))
        }

        # Controles interactivos: el lector los anuncia por su nombre. TextBlock
        # o Path son contenido y se leen como texto.
        $script:Interactivos = @(
            'Button', 'RadioButton', 'CheckBox', 'TextBox', 'ComboBox',
            'ToggleButton', 'Slider', 'PasswordBox', 'RepeatButton'
        )

        # Controles interactivos de los dos documentos.
        $script:ControlesA11y = @()
        foreach ($doc in $script:DocsA11y.Keys) {
            foreach ($n in $script:DocsA11y[$doc].SelectNodes('//*')) {
                if ($script:Interactivos -notcontains $n.LocalName) { continue }

                $contenido = $n.GetAttribute('Content')
                # Un Content enlazado no es texto propio: puede venir vacío.
                $tieneTextoPropio = $contenido -and ($contenido -notmatch '^\s*\{')

                $script:ControlesA11y += [pscustomobject]@{
                    Documento = $doc
                    Etiqueta  = $n.LocalName
                    Nombre    = $(if ($n.GetAttribute('x:Name')) { $n.GetAttribute('x:Name') } else { '(anonimo)' })
                    Texto     = $tieneTextoPropio
                    Auto      = $n.GetAttribute('AutomationProperties.Name')
                }
            }
        }

        # Propiedades expuestas por las clases de la ventana, extraídas del código.
        $texto = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaA11y 'Types.ps1')
        $script:PropiedadesVista = @{}
        foreach ($m in [regex]::Matches($texto, 'public\s+(?!class\b|abstract\b|event\b|override\b|virtual\b)[\w<>\[\],\s]*?([A-Za-z_]\w*)\s*(?:\r?\n\s*)?\{\s*get')) {
            $script:PropiedadesVista[$m.Groups[1].Value] = $true
        }
    }

    It 'la prueba lee controles de verdad: si no, no comprueba nada' {
        # Control: una lista vacía haría pasar las pruebas siguientes.
        $script:ControlesA11y.Count | Should -BeGreaterThan 30
        @($script:ControlesA11y | Where-Object { -not $_.Texto }).Count |
            Should -BeGreaterThan 10 -Because 'la ventana tiene botones de icono, casillas y campos sin rotulo propio'
        $script:PropiedadesVista.Count | Should -BeGreaterThan 20 -Because 'si no, se leyo mal Types.ps1'
    }

    It 'todo control sin texto propio declara AutomationProperties.Name' {
        $mudos = @($script:ControlesA11y |
            Where-Object { -not $_.Texto -and -not $_.Auto } |
            ForEach-Object { '{0}: {1} {2}' -f $_.Documento, $_.Etiqueta, $_.Nombre })

        $mudos | Should -BeNullOrEmpty -Because (
            'un lector de pantalla lo anunciaria solo por su tipo, y con varios iguales no hay forma de distinguirlos')
    }

    It 'ningun nombre accesible esta en blanco' {
        # AutomationProperties.Name="" pasaría la prueba anterior sin servir de nada.
        $vacios = @($script:ControlesA11y |
            Where-Object { $null -ne $_.Auto -and $_.Auto -ne '' -and $_.Auto.Trim() -eq '' } |
            ForEach-Object { '{0}: {1}' -f $_.Documento, $_.Nombre })

        $vacios | Should -BeNullOrEmpty
    }

    It 'todo nombre enlazado apunta a una propiedad que existe' {
        # Con un rótulo visible enlazado, el nombre accesible usa el mismo
        # enlace; la propiedad debe existir.
        $rotos = @()
        foreach ($c in $script:ControlesA11y) {
            if (-not $c.Auto) { continue }
            $m = [regex]::Match($c.Auto, '^\{Binding\s+(?:Path=)?([A-Za-z_]\w*)')
            if (-not $m.Success) { continue }

            $propiedad = $m.Groups[1].Value
            if (-not $script:PropiedadesVista.ContainsKey($propiedad)) {
                $rotos += ('{0}: {1} -> {2}' -f $c.Documento, $c.Nombre, $propiedad)
            }
        }

        $rotos | Should -BeNullOrEmpty -Because (
            'WPF resuelve un enlace roto a vacio sin lanzar: el control se queda mudo y el atributo aparenta que no')
    }
}

Describe 'cambiar de panel tiene que notarse sin mirar la pantalla' {
    <#
        Los lectores de pantalla anuncian lo que tiene el foco, no lo que se
        vuelve visible: al cambiar de panel, el foco pasa al panel.

        Los nombres de los paneles viven en cuatro sitios: el x:Name del
        XAML, la lista de Window.ps1, el bucle de mostrarPanel y los
        enganches de la barra lateral. Un panel ausente del bucle no se
        oculta nunca y queda encima del activo.
    #>

    BeforeAll {
        $script:CarpetaFoco = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'

        # 1. Los paneles según el XAML.
        $script:PanelesXaml = @{}
        $script:TextoPanel  = @{}
        foreach ($archivo in (Get-ChildItem $script:CarpetaFoco -Filter 'Panel.*.xaml')) {
            $texto = Get-Content -Raw -LiteralPath $archivo.FullName
            $m = [regex]::Match($texto, 'x:Name="(Panel[A-Za-z]+)"')
            if ($m.Success) {
                $script:PanelesXaml[$m.Groups[1].Value] = $archivo.Name
                $script:TextoPanel[$m.Groups[1].Value]  = $texto
            }
        }

        # 2. Los paneles que Window.ps1 resuelve por FindName.
        $ventana = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaFoco 'Window.ps1')
        $script:PanelesResueltos = @{}
        foreach ($m in [regex]::Matches($ventana, "'(Panel[A-Za-z]+)'")) {
            $script:PanelesResueltos[$m.Groups[1].Value] = $true
        }

        # 3. Los paneles del bucle de mostrarPanel, acotado a su bloque para
        #    no arrastrar cadenas de otras partes del archivo.
        $ayudantes = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaFoco 'Window.Ayudantes.ps1')
        $script:BloqueMostrar = [regex]::Match($ayudantes, '(?s)\$mostrarPanel = \{.*?\r?\n    \}').Value
        $script:PanelesBucle = @{}
        foreach ($m in [regex]::Matches($script:BloqueMostrar, "'(Panel[A-Za-z]+)'")) {
            $script:PanelesBucle[$m.Groups[1].Value] = $true
        }

        # 4. Los paneles que la barra lateral sabe pedir.
        $eventos = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaFoco 'Window.Eventos.ps1')
        $script:PanelesNavegacion = @{}
        foreach ($m in [regex]::Matches($eventos, "mostrarPanel '(Panel[A-Za-z]+)'")) {
            $script:PanelesNavegacion[$m.Groups[1].Value] = $true
        }
    }

    It 'la prueba encuentra las cuatro listas: si no, no comprueba nada' {
        $script:PanelesXaml.Count       | Should -BeGreaterThan 4
        $script:PanelesResueltos.Count  | Should -Be $script:PanelesXaml.Count
        $script:PanelesBucle.Count      | Should -BeGreaterThan 4
        $script:PanelesNavegacion.Count | Should -BeGreaterThan 4
        $script:BloqueMostrar.Length    | Should -BeGreaterThan 200 -Because 'si no, se acoto mal el bloque de mostrarPanel'
    }

    It 'las cuatro listas de paneles dicen exactamente lo mismo' {
        # Un panel en el XAML pero no en el bucle no se oculta nunca.
        $enXaml = ($script:PanelesXaml.Keys | Sort-Object) -join ', '

        (($script:PanelesResueltos.Keys  | Sort-Object) -join ', ') | Should -Be $enXaml -Because 'Window.ps1 no resolveria el control y $c[...] seria $null'
        (($script:PanelesBucle.Keys      | Sort-Object) -join ', ') | Should -Be $enXaml -Because 'un panel fuera del bucle no se oculta nunca'
        (($script:PanelesNavegacion.Keys | Sort-Object) -join ', ') | Should -Be $enXaml -Because 'un panel sin entrada en la barra lateral es inalcanzable'
    }

    It 'el panel <Panel> es destino de foco pero no parada de tabulacion' -ForEach @(
        @{ Panel = 'PanelInicio' }, @{ Panel = 'PanelResultados' }, @{ Panel = 'PanelRegistro' }
        @{ Panel = 'PanelInformes' }, @{ Panel = 'PanelAjustes' }, @{ Panel = 'PanelAcerca' }
    ) {
        # Focus() sobre un elemento con Focusable="False" devuelve $false sin efecto.
        $texto = $script:TextoPanel[$Panel]
        $texto | Should -Not -BeNullOrEmpty

        $declaracion = [regex]::Match($texto, ('(?s)<Grid x:Name="{0}".*?>' -f $Panel)).Value
        $declaracion | Should -Match 'Focusable="True"' -Because 'sin esto Focus() no hace nada y falla en silencio'
        $declaracion | Should -Match 'KeyboardNavigation.IsTabStop="False"' -Because 'si no, se añade una parada de tabulación por panel para quien ya ve la pantalla'
        $declaracion | Should -Match 'AutomationProperties.Name=' -Because 'sin nombre, el lector anuncia el foco como un contenedor sin mas'
    }

    It 'el nombre que anuncia el panel <Panel> es su titulo visible' -ForEach @(
        @{ Panel = 'PanelInicio' }, @{ Panel = 'PanelResultados' }, @{ Panel = 'PanelRegistro' }
        @{ Panel = 'PanelInformes' }, @{ Panel = 'PanelAjustes' }, @{ Panel = 'PanelAcerca' }
    ) {
        # Dos copias del mismo rótulo: el título visible y el anunciado deben coincidir.
        $texto = $script:TextoPanel[$Panel]

        $accesible = [regex]::Match(
            [regex]::Match($texto, ('(?s)<Grid x:Name="{0}".*?>' -f $Panel)).Value,
            'AutomationProperties.Name="([^"]+)"').Groups[1].Value
        $visible = [regex]::Match($texto, 'Text="([^"]+)" Style="\{StaticResource Titulo\}"').Groups[1].Value

        $visible   | Should -Not -BeNullOrEmpty -Because 'si no, la prueba compara contra la nada'
        $accesible | Should -Be $visible
    }

    It 'el foco se pide DESPUES de poner la visibilidad' {
        # Focus() sobre un elemento Collapsed devuelve $false sin lanzar.
        $posVisibilidad = $script:BloqueMostrar.IndexOf('.Visibility =')
        $posFoco        = $script:BloqueMostrar.IndexOf('.Focus()')

        $posVisibilidad | Should -BeGreaterThan 0
        $posFoco        | Should -BeGreaterThan $posVisibilidad
    }

    It 'el resultado de Focus() no se cuela en la salida de la funcion' {
        # Un Focus() sin consumir añadiría un booleano a la salida de mostrarPanel.
        $script:BloqueMostrar | Should -Match '\[void\]\s*\$c\[\$Cual\]\.Focus\(\)'
    }
}

Describe 'los atajos no pueden separarse de lo que hacen los botones' {
    <#
        Las combinaciones se prueban en Atajos.Tests.ps1. Aquí se protege:

        1. Que el despachador pulse los botones en vez de copiar lo que
           hacen (dos versiones de una acción acaban divergiendo).
        2. Que Ctrl+1..6 siga el orden visible de la barra lateral.
    #>

    BeforeAll {
        $script:CarpetaAtajos = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'UI'
        . (Join-Path $script:CarpetaAtajos 'Atajos.ps1')
        . (Join-Path $script:CarpetaAtajos 'Xaml.ps1')

        $script:MontadoAtajos = Expand-PanelesXaml -Carpeta $script:CarpetaAtajos `
                                    -Texto ([IO.File]::ReadAllText(
                                        (Join-Path $script:CarpetaAtajos 'MainWindow.xaml')))

        # Solo el bloque del despachador.
        $eventos = Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaAtajos 'Window.Eventos.ps1')
        $script:BloqueTeclado = [regex]::Match(
            $eventos, '(?s)\$ventana\.Add_PreviewKeyDown\(\{.*?\r?\n    \}\)').Value

        # Sin comentarios, para no encontrar en ellos lo que se busca.
        $script:TecladoLimpio = [regex]::Replace($script:BloqueTeclado, '(?m)^\s*#.*$', '')
    }

    It 'la prueba lee el despachador de verdad: si no, no comprueba nada' {
        $script:BloqueTeclado.Length | Should -BeGreaterThan 400 -Because 'si no, se acoto mal el bloque de PreviewKeyDown'
        $script:TecladoLimpio | Should -Match 'Get-AtajoDeTecla'
        (Get-NavegacionPorNumero).Count | Should -Be 6
    }

    It 'Ctrl+1..6 sigue el orden en que se ven las entradas en la barra lateral' {
        # Un número desalineado lleva a otro panel sin error.
        $enPantalla = @([regex]::Matches($script:MontadoAtajos, 'RadioButton x:Name="(Nav[A-Za-z]+)"') |
                        ForEach-Object { $_.Groups[1].Value })

        $enPantalla.Count | Should -Be 6 -Because 'si no, la prueba no esta leyendo la barra lateral'
        ($enPantalla -join ', ') | Should -Be ((Get-NavegacionPorNumero) -join ', ')
    }

    It 'toda accion que devuelve la funcion la sabe atender el despachador' {
        # Una acción sin rama cae en "default", que la trata como entrada de
        # la barra lateral: $c[$accion] sería $null y asignar una propiedad lanzaría.
        $devueltas = @()
        foreach ($m in [regex]::Matches(
            (Get-Content -Raw -LiteralPath (Join-Path $script:CarpetaAtajos 'Atajos.ps1')),
            "return '([A-Za-z]+)'")) {
            $devueltas += $m.Groups[1].Value
        }

        $devueltas.Count | Should -BeGreaterThan 2 -Because 'si no, la prueba mira otra cosa'

        $sinRama = @($devueltas | Where-Object {
            $_ -notmatch '^Nav' -and $script:TecladoLimpio -notmatch ("'{0}'" -f $_)
        })
        $sinRama | Should -BeNullOrEmpty -Because 'caeria en el default y se trataria como un panel inexistente'
    }

    It 'el despachador pulsa los botones, no repite lo que hacen' {
        # Un Remove, un Where-Object sobre los items o un Show-Confirmacion aquí
        # duplicaría una decisión que ya vive en el manejador del botón.
        $script:TecladoLimpio | Should -Match 'RaiseEvent'

        foreach ($prohibido in @(
            'Show-Confirmacion', 'Invoke-LoteEliminacion', 'Remove-Elemento',
            '\$estado\.Items', '\$estado\.Ocupado', 'Add-EntradaHistorial')) {
            $script:TecladoLimpio | Should -Not -Match $prohibido -Because (
                'esa decision ya vive en el manejador del boton: aqui seria una segunda copia')
        }
    }

    It 'la tecla se marca atendida DESPUES de saber que era un atajo' {
        # Al revés, se consumirían las teclas escritas en el filtro.
        $posSalida  = $script:TecladoLimpio.IndexOf('if (-not $accion) { return }')
        $posAtendida = $script:TecladoLimpio.IndexOf('$e.Handled = $true')

        $posSalida   | Should -BeGreaterThan 0
        $posAtendida | Should -BeGreaterThan $posSalida
    }
}

Describe 'Nada que no sea codigo puede colarse en lo que se publica' {
    <#
        En sistemas de archivos FUSE, sobrescribir un archivo abierto lo
        renombra a .fuse_hidden*, y ni Pester, ni el analizador ni la prueba
        del BOM miran archivos con esas extensiones. El paso "Armar el
        paquete" de publicar.yml copia src/ entero, así que acabarían en el
        .zip publicado.

        Regla: en las carpetas que se publican solo hay extensiones conocidas.
    #>

    BeforeAll {
        $script:RaizPublicable = Split-Path $PSScriptRoot -Parent

        # Extensiones legítimas en src/ y tools/. Ampliarla debe ser una decisión explícita.
        $script:ExtensionesPublicables = @('.ps1', '.psd1', '.psm1', '.xaml', '.bat', '.md')

        $script:CarpetasPublicables = @('src', 'tools', 'assets')

        $script:ArchivosPublicables = @()
        foreach ($carpeta in $script:CarpetasPublicables) {
            $ruta = Join-Path $script:RaizPublicable $carpeta
            if (-not (Test-Path -LiteralPath $ruta)) { continue }
            $script:ArchivosPublicables += @(Get-ChildItem -LiteralPath $ruta -Recurse -File -Force)
        }
    }

    It 'la prueba recorre las carpetas de verdad: si no, no comprueba nada' {
        # Control: una lista vacía haría pasar las pruebas siguientes.
        $script:ArchivosPublicables.Count | Should -BeGreaterThan 40
        @($script:ArchivosPublicables | Where-Object { $_.Extension -eq '.ps1' }).Count |
            Should -BeGreaterThan 20
    }

    It 'no hay ningun archivo oculto en lo que se publica' {
        # Un nombre que empieza por punto es la firma de los restos de FUSE
        # (.fuse_hidden*) y NFS (.nfs*). PowerShell les da BaseName vacío y
        # toda la cadena como Extension. Los legítimos (.gitignore,
        # .editorconfig) están en la raíz, que no se recorre.
        $ocultos = @($script:ArchivosPublicables |
            Where-Object { $_.Name.StartsWith('.') } |
            ForEach-Object { $_.FullName.Substring($script:RaizPublicable.Length + 1) })

        $ocultos | Should -BeNullOrEmpty -Because (
            'publicar.yml copia src/ entero al .zip, y esto se iria dentro sin que lo mire ninguna otra comprobacion')
    }

    It 'ninguna extension rara se cuela en lo que se publica' {
        $raros = @($script:ArchivosPublicables |
            Where-Object { $_.Extension -and $script:ExtensionesPublicables -notcontains $_.Extension.ToLowerInvariant() } |
            ForEach-Object { $_.FullName.Substring($script:RaizPublicable.Length + 1) })

        # Las imágenes de assets/ se permiten aparte para no ampliar la lista general.
        $raros = @($raros | Where-Object { $_ -notmatch '^assets[\\/]' })

        $raros | Should -BeNullOrEmpty
    }
}

Describe 'La publicacion se puede ensayar entera menos la publicacion' {
    <#
        El disparo manual de publicar.yml ensaya el empaquetado sin publicar.
        Solo el paso de adjuntar a la versión puede depender de la etiqueta;
        el resto, incluidos los manifiestos, debe ejecutarse en el ensayo.
    #>

    BeforeAll {
        $script:RaizFlujo = Split-Path $PSScriptRoot -Parent
        $script:Publicar = [IO.File]::ReadAllText(
            (Join-Path $script:RaizFlujo '.github/workflows/publicar.yml'))
    }

    It 'solo el paso que publica esta limitado a las etiquetas' {
        # Se cuentan las condiciones de etiqueta del archivo: solo puede haber una.
        $condiciones = @([regex]::Matches($script:Publicar, "if:\s*startsWith\(github\.ref,\s*'refs/tags/'\)"))
        @($condiciones).Count | Should -Be 1 -Because (
            'todo lo que no sea publicar tiene que poder ensayarse; si no, se estrena en la version de verdad')

        # Y debe ser la del paso de adjuntar.
        $script:Publicar | Should -Match (
            "(?s)- name: Adjuntar a la version\s*\r?\n\s*if:\s*startsWith\(github\.ref,\s*'refs/tags/'\)") -Because (
            'la unica condicion que debe quedar es la del paso que sube la version')
    }

    It 'UN SOLO SITIO DECIDE LA VERSION' {
        # Si cada paso dedujera la versión por su cuenta, el paquete y los
        # manifiestos podrían discrepar (p. ej. Cachivache-dev.zip frente a
        # Cachivache-v2.0.0.zip) y las URL darían 404.
        $deducciones = @([regex]::Matches($script:Publicar, 'GITHUB_REF\s+-replace'))
        @($deducciones).Count | Should -Be 1 -Because (
            'la version se decide una vez y se pasa por GITHUB_ENV; deducirla dos veces es como se llega a dos respuestas')

        $script:Publicar | Should -Match 'VERSION=\$version' -Because 'la decision tiene que quedar donde la lean los demas pasos'
        $script:Publicar | Should -Match 'Cachivache-\$env:VERSION' -Because 'el paquete se nombra con la version decidida'
        $script:Publicar | Should -Match '-Etiqueta \$env:VERSION'  -Because 'y los manifiestos declaran esa misma'
    }

    It 'la version se decide ANTES de compilar y empaquetar' {
        # Detecta una discrepancia antes de las pruebas, la compilación y el empaquetado.
        $posDecidir = $script:Publicar.IndexOf('- name: Decidir la version')
        $posPruebas = $script:Publicar.IndexOf('- name: Pruebas')
        $posDecidir | Should -BeGreaterThan 0
        $posPruebas | Should -BeGreaterThan $posDecidir
    }

    It 'la etiqueta y la version del programa no pueden divergir' {
        # Evita publicar v2.1.0 de un código que se presenta como 2.0.0.
        $script:Publicar | Should -Match 'Get-VersionCachivache' -Because (
            'la version tiene que salir del programa y no de lo que alguien escriba en la etiqueta')
        $script:Publicar | Should -Match 'no coincide con la version del programa'
    }
}

Describe 'Un flujo de trabajo invalido no llega ni a ejecutarse' {
    <#
        La clave "shell:" de un paso no admite el contexto "matrix": usarla
        invalida el archivo entero ("Invalid workflow file") y GitHub no
        ejecuta nada. Para variar el shell por matriz se usa
        jobs.<id>.defaults.run.shell.

        No sustituye a actionlint, que no está disponible en el entorno de
        pruebas.
    #>

    BeforeAll {
        $script:CarpetaFlujos = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) '.github') 'workflows'

        $script:Flujos = @{}
        foreach ($archivo in (Get-ChildItem $script:CarpetaFlujos -Filter '*.yml' -ErrorAction SilentlyContinue)) {
            $script:Flujos[$archivo.Name] = Get-Content -Raw -LiteralPath $archivo.FullName
        }
    }

    It 'la prueba lee los flujos de verdad: si no, no comprueba nada' {
        $script:Flujos.Count | Should -BeGreaterThan 1
        @($script:Flujos.Values | Where-Object { $_ -match '(?m)^\s*runs-on:' }).Count |
            Should -BeGreaterThan 1
    }

    It 'ninguna clave shell de un PASO lleva una expresion' {
        # Se quitan primero los bloques defaults.run.shell, donde la expresión sí es válida.
        $malos = @()
        foreach ($nombre in $script:Flujos.Keys) {
            $texto = [regex]::Replace($script:Flujos[$nombre],
                        '(?m)^\s*defaults:\s*\r?\n\s*run:\s*\r?\n\s*shell:.*$', '')

            foreach ($m in [regex]::Matches($texto, '(?m)^\s*shell:\s*(.+)$')) {
                if ($m.Groups[1].Value -match '\$\{\{') {
                    $malos += ('{0}: {1}' -f $nombre, $m.Groups[0].Value.Trim())
                }
            }
        }

        $malos | Should -BeNullOrEmpty -Because (
            'no da un shell equivocado: invalida el archivo entero y el flujo no llega a ejecutarse')
    }

    It 'el trabajo con matriz declara su shell donde SI se admite' {
        # Sin esto, las dos ramas de la matriz ejecutarían pwsh y nunca se
        # probaría PowerShell 5.1.
        $ci = $script:Flujos['ci.yml']
        $ci | Should -Not -BeNullOrEmpty

        $ci | Should -Match '(?s)strategy:.*?matrix:.*?defaults:\s*\r?\n\s*run:\s*\r?\n\s*shell:\s*\$\{\{\s*matrix\.shell'
    }

    It 'la validacion del XAML anota en la CI el archivo que falla' {
        # Se ejecuta el script del paso tal cual contra un XAML roto: la
        # anotacion ::error debe llevar la ruta del archivo.
        $ci = $script:Flujos['ci.yml']
        $m = [regex]::Match($ci, '(?s)- name: Comprobar cada archivo XAML.*?run: \|\r?\n(.*?)\r?\n\s*\r?\n\s*- name:')
        $m.Success | Should -BeTrue
        $guion = ($m.Groups[1].Value -split '\r?\n' | ForEach-Object { $_ -replace '^ {10}', '' }) -join "`n"

        $taller = Join-Path ([IO.Path]::GetTempPath()) ('cachivache-ci-' + [guid]::NewGuid())
        $ui = Join-Path (Join-Path $taller 'src') 'UI'
        New-Item -ItemType Directory -Path $ui -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ui 'Roto.xaml') -Value '<Window><Grid></Window>'
        $archivoGuion = Join-Path $taller 'paso.ps1'
        Set-Content -LiteralPath $archivoGuion -Value $guion
        try {
            Push-Location $taller
            $salida = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $archivoGuion 2>&1 | Out-String
            $codigo = $LASTEXITCODE
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $taller -Recurse -Force -ErrorAction SilentlyContinue
        }

        $codigo | Should -Be 1
        $salida | Should -Match '::error file=[^\r\n]*Roto\.xaml::'
    }
}

Describe 'El historial no puede rechazar un tipo que el programa le manda' {
    <#
        El ValidateSet de Add-EntradaHistorial y los tipos que envía el
        programa (p. ej. 'limpieza-interrumpida') viven en archivos
        distintos. Un tipo no admitido lanza en el ValidateSet; el catch
        del cierre de la ventana solo hace Write-Verbose y la entrada se
        perdería sin aviso.
    #>

    BeforeAll {
        $script:RaizHist = Split-Path $PSScriptRoot -Parent
        $script:TextoHistorial = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path (Join-Path $script:RaizHist 'src') 'Core') 'Historial.ps1')

        # Lo que el ValidateSet admite.
        $m = [regex]::Match($script:TextoHistorial,
                "ValidateSet\(((?:\s*'[^']+'\s*,?)+)\)\]\s*\[string\]\s*\`$Tipo")
        $script:TiposAdmitidos = @()
        if ($m.Success) {
            foreach ($t in [regex]::Matches($m.Groups[1].Value, "'([^']+)'")) {
                $script:TiposAdmitidos += $t.Groups[1].Value
            }
        }

        # Lo que el programa envía en todo src, sin comentarios.
        $script:TiposUsados = @{}
        foreach ($archivo in (Get-ChildItem (Join-Path $script:RaizHist 'src') -Recurse -Filter '*.ps1')) {
            $texto = [regex]::Replace((Get-Content -Raw -LiteralPath $archivo.FullName), '(?m)^\s*#.*$', '')
            foreach ($u in [regex]::Matches($texto, "Add-EntradaHistorial\s+-Tipo\s+'([^']+)'")) {
                $script:TiposUsados[$u.Groups[1].Value] = $archivo.Name
            }
        }
    }

    It 'la prueba encuentra las dos listas: si no, no comprueba nada' {
        $script:TiposAdmitidos.Count | Should -BeGreaterThan 1 -Because 'si no, se leyo mal el ValidateSet'
        $script:TiposUsados.Count    | Should -BeGreaterThan 1 -Because 'si no, no se encontro ninguna llamada'
    }

    It 'todo tipo que el programa manda esta admitido' {
        $rechazados = @($script:TiposUsados.Keys |
            Where-Object { $script:TiposAdmitidos -notcontains $_ } |
            ForEach-Object { ('{0} (desde {1})' -f $_, $script:TiposUsados[$_]) })

        $rechazados | Should -BeNullOrEmpty -Because (
            'el ValidateSet lanza, el catch se lo traga y la entrada no se anota: el historial miente por omision')
    }
}

Describe 'El texto que lee el usuario concuerda en singular' {
    <#
        Format-Antiguedad: evita "hace 1 meses" o "hace más de 1 años".
        No es una invariante general sobre plurales, sino casos concretos.
    #>

    BeforeAll {
        $script:RaizPlural = Split-Path $PSScriptRoot -Parent
        . (Join-Path (Join-Path (Join-Path $script:RaizPlural 'src') 'Core') 'Bootstrap.ps1')
    }

    It 'un solo mes se dice en singular' {
        $texto = Format-Antiguedad -Fecha ((Get-Date).AddDays(-40))
        $texto | Should -Not -Match '\b1 meses\b'
        $texto | Should -Be 'hace un mes'
    }

    It 'y varios, en plural' {
        Format-Antiguedad -Fecha ((Get-Date).AddDays(-100)) | Should -Be 'hace 3 meses'
    }

    It 'un solo año se dice en singular' {
        $texto = Format-Antiguedad -Fecha ((Get-Date).AddDays(-400))
        $texto | Should -Not -Match '\b1 años\b'
        $texto | Should -Be 'hace más de 1 año'
    }

    It 'los casos cortos siguen como estaban' {
        Format-Antiguedad -Fecha (Get-Date)                    | Should -Be 'hoy'
        Format-Antiguedad -Fecha ((Get-Date).AddDays(-1))      | Should -Be 'ayer'
        Format-Antiguedad -Fecha ((Get-Date).AddDays(-5))      | Should -Be 'hace 5 días'
    }

    It 'ningun tramo devuelve un numero pegado a un plural equivocado' {
        # Recorre todos los tramos: ninguna respuesta empieza por "1 " seguido de plural.
        foreach ($dias in @(0, 1, 2, 15, 29, 30, 45, 59, 60, 200, 364, 365, 400, 800)) {
            $texto = Format-Antiguedad -Fecha ((Get-Date).AddDays(-$dias))
            $texto | Should -Not -Match '\b1 (días|meses|años)\b' -Because "con $dias dias dice '$texto'"
        }
    }
}

Describe 'el programa no puede volver a recorrer con Get-ChildItem -Recurse' {

    <#
        En Windows PowerShell 5.1,

            Get-ChildItem -LiteralPath $zona -Recurse -File -Force -ErrorAction SilentlyContinue

        se detiene en MAX_PATH sin avisar: faltan candidatos o, en usos como
        el vocabulario de Registry.ps1 o la búsqueda de enlaces de Remove.ps1,
        se propone de más. La regla no admite excepciones.

        Alcance: src/ y Cachivache.ps1. Las pruebas quedan fuera, y
        tools/Banco-Pruebas.ps1 tiene su propia comprobación en Banco.Tests.ps1.
    #>

    BeforeAll {
        $script:RaizRec = Split-Path $PSScriptRoot -Parent
        $script:FuentesRec = @(Get-ChildItem -Path (Join-Path $script:RaizRec 'src') -Filter '*.ps1' -Recurse) +
                             @(Get-ChildItem -Path $script:RaizRec -Filter 'Cachivache.ps1')
    }

    It 'la prueba encuentra los archivos: si no, no comprueba nada' {
        @($script:FuentesRec).Count | Should -BeGreaterThan 20
    }

    It 'ningun archivo del programa recorre con Get-ChildItem -Recurse' {
        $culpables = @()
        foreach ($archivo in $script:FuentesRec) {
            # Sin comentarios, que explican por qué no se usa Get-ChildItem -Recurse.
            # Los bloques <# ... #> se sustituyen por sus saltos de línea para
            # conservar el número de línea real del culpable.
            $texto = Get-Content -Raw -LiteralPath $archivo.FullName
            $sinBloques = [regex]::Replace($texto, '(?s)<#.*?#>', {
                param($coincidencia)
                return ("`n" * @([regex]::Matches($coincidencia.Value, "`n")).Count)
            })

            $n = 0
            foreach ($linea in ($sinBloques -split "`n")) {
                $n++
                if ($linea -match '^\s*#') { continue }
                if ($linea -match 'Get-ChildItem[^\r\n]*-Recurse') {
                    $culpables += ('{0}:{1}' -f $archivo.Name, $n)
                }
            }
        }
        $culpables | Should -BeNullOrEmpty -Because (
            'hay que usar Get-ElementosDelArbol: Get-ChildItem -Recurse se para a los 260 caracteres y no lo dice')
    }

    It 'los ocho modulos llaman al recorrido compartido' -ForEach @(
        @{ Modulo = '20-Proyectos.ps1' }
        @{ Modulo = '25-Papelera.ps1' }
        @{ Modulo = '35-Descargas.ps1' }
        @{ Modulo = '45-AccesosRotos.ps1' }
        @{ Modulo = '50-Temporales.ps1' }
        @{ Modulo = '55-Duplicados.ps1' }
        @{ Modulo = '60-ArchivosGrandes.ps1' }
        @{ Modulo = '85-DockerWsl.ps1' }
    ) {
        # Sin esto, eliminar el recorrido de un módulo también pasaría la
        # prueba anterior.
        $ruta = Join-Path (Join-Path (Join-Path $script:RaizRec 'src') 'Modules') $Modulo
        $codigo = @(Get-Content -LiteralPath $ruta | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $codigo | Should -Match 'Get-ElementosDelArbol'
    }

    It 'el recorrido compartido pone el prefijo de ruta larga' {
        # El límite de 260 es de Windows; fuera de él quitar el prefijo no haría
        # fallar ninguna prueba de comportamiento. Se fija por texto y se
        # comprueba en Windows con el banco de pruebas.
        $texto = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path (Join-Path $script:RaizRec 'src') 'Core') 'FileSystem.ps1')
        $desde = $texto.IndexOf('function Get-ElementosDelArbol')
        $hasta = $texto.IndexOf('function Measure-Ruta')
        $desde | Should -BeGreaterThan 0
        $hasta | Should -BeGreaterThan $desde

        $cuerpo = @((($texto.Substring($desde, $hasta - $desde)) -split "`n") |
                    Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $cuerpo | Should -Match '\$rutaApi\s*=\s*ConvertTo-RutaLarga -Ruta \$raizLimpia'
        $cuerpo | Should -Match '\[IO\.DirectoryInfo\]::new\(\$rutaApi\)'
    }

    It 'y la ruta que devuelve se compone con la limpia, no se lee de FullName' {
        # Seguridad: un FileInfo de una enumeración con prefijo lo incluye en
        # FullName. Esa ruta llega a la guardia, y "\\?\C:\Windows" no
        # coincidiría con "C:\Windows" en su lista negra.
        $texto = Get-Content -Raw -LiteralPath (
            Join-Path (Join-Path (Join-Path $script:RaizRec 'src') 'Core') 'FileSystem.ps1')
        $desde = $texto.IndexOf('function Get-ElementosDelArbol')
        $hasta = $texto.IndexOf('function Measure-Ruta')
        $cuerpo = @((($texto.Substring($desde, $hasta - $desde)) -split "`n") |
                    Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        $cuerpo | Should -Match 'FullName\s*=\s*\$base \+ \$separador \+ \$nombre'
        $cuerpo | Should -Match '\$rutaSub\s*=\s*\$base \+ \$separador \+ \$sub\.Name'
        $cuerpo | Should -Not -Match 'FullName\s*=\s*\$archivo\.FullName'
        $cuerpo | Should -Not -Match 'FullName\s*=\s*\$sub\.FullName'
    }
}

Describe 'Las pruebas no dejan el entorno cambiado para el archivo siguiente' {

    It 'cada archivo que cambia variables de entorno las restaura al terminar' {
        # Todos los archivos se ejecutan en el mismo proceso: una variable
        # como USERPROFILE o SystemRoot cambiada y sin restaurar hace fallar
        # pruebas de otros archivos según el orden en que se ejecuten.
        $carpeta = Split-Path $PSCommandPath -Parent
        $sinRestaurar = @(Get-ChildItem -LiteralPath $carpeta -Filter '*.Tests.ps1' | Where-Object {
            $texto = [IO.File]::ReadAllText($_.FullName)
            ($texto -match '\$\{?env:[A-Za-z_()0-9]+\}?\s*=[^=]') -and
            ($texto -notmatch 'EntornoAntesDelArchivo')
        } | ForEach-Object { $_.Name })
        $sinRestaurar | Should -BeNullOrEmpty
    }
}
