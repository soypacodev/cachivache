<#
    El contrato del candidato y la fila que ve el usuario.

    Candidate.ps1 declara los campos del candidato; ItemVista (la clase C#
    que WPF enlaza a cada fila) expone los suyos, y la correspondencia se
    copia a mano en Window.Analisis.ps1.

    Invariantes.Tests.ps1 vigila la intersección. Este archivo cubre el
    paso anterior: un campo nuevo del contrato sin contraparte en ItemVista
    no aparece en esa intersección y nacería invisible. Cada campo del
    contrato debe estar en ItemVista o en una lista de exclusiones con su
    motivo.

    Cómo se lee cada lista:

      * El contrato, por AST: la tabla que devuelve New-Candidato.
      * El mapeo, por AST: asignaciones "$item.X = ..." en todos los
        src/UI/Window*.ps1, para que mover el bucle no desactive la prueba.
      * ItemVista, por reflexión sobre el tipo compilado: es C# dentro de
        una cadena de Types.ps1 y el AST de PowerShell no ve sus
        propiedades. Una prueba aparte compara esas propiedades con las
        extraídas del texto de Types.ps1.
#>

BeforeAll {
    $script:Raiz = Split-Path $PSScriptRoot -Parent
    $script:CarpetaUI = Join-Path (Join-Path $script:Raiz 'src') 'UI'

    . (Join-Path $script:CarpetaUI 'Types.ps1')
    Initialize-TiposInterfaz

    # --- El contrato, por AST -----------------------------------------
    $rutaCandidato = Join-Path (Join-Path (Join-Path $script:Raiz 'src') 'Core') 'Candidate.ps1'
    $astCandidato = [System.Management.Automation.Language.Parser]::ParseFile($rutaCandidato, [ref]$null, [ref]$null)
    $nueva = $astCandidato.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-Candidato'
    }, $true)[0]
    # La primera tabla de la función es la que se devuelve.
    $tabla = $nueva.FindAll({
        param($n) $n -is [System.Management.Automation.Language.HashtableAst]
    }, $true)[0]
    $script:CamposCandidato = @($tabla.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'`"") })

    # --- ItemVista, por reflexion --------------------------------------
    $script:PropsVista = @([Cachivache.ItemVista].GetProperties() | ForEach-Object { $_.Name })
    # Las que tienen "set" son las únicas que se rellenan desde fuera; las
    # demás las calcula la clase.
    $script:PropsRellenables = @([Cachivache.ItemVista].GetProperties() |
                                 Where-Object { $_.CanWrite } | ForEach-Object { $_.Name })

    # --- ItemVista, tambien desde el TEXTO de Types.ps1 ----------------
    # Se acota al cuerpo de la clase (hasta la siguiente "public class")
    # para no contar propiedades de ModuloVista, DiscoVista, etc.
    $textoTipos = [IO.File]::ReadAllText((Join-Path $script:CarpetaUI 'Types.ps1'))
    $inicio = $textoTipos.IndexOf('public class ItemVista', [StringComparison]::Ordinal)
    $siguiente = if ($inicio -ge 0) {
        $textoTipos.IndexOf('public class ', $inicio + 20, [StringComparison]::Ordinal)
    } else { -1 }
    $script:CuerpoItemVista = if ($inicio -lt 0) { '' }
                              elseif ($siguiente -lt 0) { $textoTipos.Substring($inicio) }
                              else { $textoTipos.Substring($inicio, $siguiente - $inicio) }

    # Una propiedad C# es "public <tipo> <Nombre> {"; los métodos llevan
    # paréntesis y los campos privados no son public.
    $script:PropsEnTexto = @([regex]::Matches(
        $script:CuerpoItemVista,
        'public\s+(?:abstract\s+|virtual\s+|override\s+|static\s+)?[A-Za-z_][\w<>\[\]\.]*\s+([A-Za-z_]\w*)\s*\{'
    ) | ForEach-Object { $_.Groups[1].Value })

    # --- El mapeo, por AST ---------------------------------------------
    # "$item.X = ..." en cualquier Window*.ps1; se guarda el archivo para
    # el mensaje de error.
    $script:Mapeadas = @{}
    foreach ($archivo in (Get-ChildItem $script:CarpetaUI -Filter 'Window*.ps1')) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($archivo.FullName, [ref]$null, [ref]$null)
        foreach ($n in $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                      $n.Left -is [System.Management.Automation.Language.MemberExpressionAst]
        }, $true)) {
            if ($n.Left.Expression.Extent.Text -eq '$item') {
                $script:Mapeadas[$n.Left.Member.Extent.Text] = $archivo.Name
            }
        }
    }

    # --- Lo que la fila lee del candidato SIN copiarlo ------------------
    # Window.Eliminacion.ps1 lee el error del candidato desde
    # $item.Origen en lugar de copiarlo; la prueba de exclusiones lo
    # comprueba.
    $script:LeidasDeOrigen = @{}
    foreach ($archivo in (Get-ChildItem $script:CarpetaUI -Filter '*.ps1')) {
        # Sin comentarios: suelen nombrar campos y harían pasar la prueba.
        $codigo = ((Get-Content $archivo.FullName) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        foreach ($m in [regex]::Matches($codigo, '\.Origen\.([A-Za-z_]\w*)')) {
            $script:LeidasDeOrigen[$m.Groups[1].Value] = $archivo.Name
        }
    }
}

Describe 'Ningun campo del contrato puede nacer invisible en la interfaz' {

    BeforeAll {
        <#
            Campos que no van a la fila, con su motivo. Una prueba exige que
            todos sigan existiendo en el contrato, para que la lista no tape
            campos futuros por coincidencia de nombre.
        #>
        $script:NoVanALaFila = [ordered]@{


            # La tabla agrupa por Categoria y el registro ya nombra cada
            # módulo una vez; repetirlo por fila no aporta.
            ModuloId = 'lo dice el registro una vez por modulo; la tabla agrupa por categoria'

            # Pareja técnica del método Comando: el binario sin ruta que
            # Remove.ps1 resuelve contra la lista blanca y el array que se
            # pasa a Start-Process. SECURITY.md exige mostrar el comando
            # legible, que es el campo Comando (con VisibilidadComando).
            Ejecutable = 'detalle interno del metodo Comando; el usuario ve el campo Comando'
            Argumentos = 'detalle interno del metodo Comando; el usuario ve el campo Comando'

            # Dato de la guardia (dónde se permite estar a la ruta), no del
            # elemento.
            Raices = 'parametro de la guardia de rutas, no informacion del elemento'

            # Excepción que solo usa el módulo de duplicados para que
            # Test-RutaSegura no vete extensiones personales (existe otra
            # copia idéntica). Es interna del motor.
            PermitirPersonales = 'excepcion interna de la guardia, solo la usa el modulo de duplicados'

            # Las cachés se borran sin papelera aunque el usuario la prefiera
            # (cientos de miles de archivos, sin liberar espacio). La fila no
            # habla de papelera en ninguna columna. Ver
            # Invoke-EliminacionCandidato en Remove.ps1.
            ForzarPermanente = 'decision del motor de borrado; la fila no habla de papelera en ninguna columna'

            # Tamaño real en disco con compresión NTFS, o $null. La columna
            # de tamaño ya muestra Bytes, que es la promesa calculada por
            # Get-EspacioRecuperable; el dato en crudo se conserva para
            # mostrar ambas cifras con Format-DetalleCompresion.
            TamanoEnDisco = 'dato en crudo de la compresión; la fila muestra Bytes, que ya es la promesa que decide Get-EspacioRecuperable'

            # Vale 0 hasta que se borra; el resultado se refleja en Estado y
            # el total liberado va al pie y al informe.
            BytesLiberados = 'se rellena al borrar; la fila cuenta el resultado en Estado y el total va al pie'

            # Llega a la fila sin copiarse: Window.Eliminacion lo lee de
            # $item.Origen.Error y lo vuelca en Estado (que decide el color
            # vía EstadoEsFallo). Lo comprueba 'los campos excluidos por
            # llegar en Origen se leen de verdad desde Origen'.
            Error = 'llega por $item.Origen y se vuelca en Estado; copiarlo seria una segunda copia del mismo dato'
        }

        # Exclusiones cuyo motivo es "llega por Origen"; se comprueban.
        $script:PorOrigen = @('Error')
    }

    It 'la prueba encuentra las tres listas: si no, no esta comprobando nada' {
        # Una lista vacía por un cambio de formato haría pasar todo lo
        # demás.
        $script:CamposCandidato.Count   | Should -BeGreaterThan 15 -Because 'el contrato tiene una veintena de campos'
        $script:PropsVista.Count        | Should -BeGreaterThan 15 -Because 'ItemVista expone una veintena de propiedades'
        $script:PropsRellenables.Count  | Should -BeGreaterThan 10 -Because 'la mayoria de ItemVista se rellena desde fuera'
        $script:Mapeadas.Count          | Should -BeGreaterThan 10 -Because 'el bucle que construye las filas copia campo a campo'
        $script:CamposCandidato         | Should -Contain 'Ruta'
        $script:PropsVista              | Should -Contain 'Ruta'
    }

    It 'todo campo del contrato o esta en ItemVista o esta excluido con su motivo' {
        # La comparación de la intersección no ve un campo que falte en
        # ItemVista.
        $sinSalida = @($script:CamposCandidato |
                       Where-Object { $_ -notin $script:PropsVista -and -not $script:NoVanALaFila.Contains($_) })

        $sinSalida | Should -BeNullOrEmpty -Because (
            'un campo del contrato que no exista en ItemVista no se puede mostrar de ninguna forma: ' +
            'nace invisible y nada falla. O se añade la propiedad a ItemVista y se copia en el bucle ' +
            'que construye las filas, o se añade a $script:NoVanALaFila con el motivo por el que no se ve')
    }

    It 'la lista de exclusiones no nombra campos que ya no existen' {
        # Una exclusión huérfana daría por decidido un campo futuro con el
        # mismo nombre.
        $fantasmas = @($script:NoVanALaFila.Keys | Where-Object { $_ -notin $script:CamposCandidato })
        $fantasmas | Should -BeNullOrEmpty -Because 'una exclusion sin campo detras tapa por casualidad al siguiente que se llame igual'
    }

    It 'ninguna exclusion se queda sin motivo escrito' {
        $mudas = @($script:NoVanALaFila.Keys |
                   Where-Object { [string]::IsNullOrWhiteSpace($script:NoVanALaFila[$_]) })
        $mudas | Should -BeNullOrEmpty -Because 'una lista de excepciones sin motivo es una forma de desactivar la prueba'
    }

    It 'los campos excluidos por llegar en Origen se leen de verdad desde Origen' {
        # Es el único motivo comprobable sobre el código.
        $nadie = @($script:PorOrigen | Where-Object { -not $script:LeidasDeOrigen.ContainsKey($_) })
        $nadie | Should -BeNullOrEmpty -Because (
            'si nadie lee $item.Origen.<campo>, ese campo no llega a la interfaz por ninguna via ' +
            'y su exclusion es falsa')
    }

    It 'toda propiedad rellenable de ItemVista la rellena alguien' {
        # Una propiedad declarada que nadie escribe sale siempre vacía.
        # Invariantes.Tests.ps1 no la ve: allí las propiedades que no son
        # campos del candidato (Tamano, ColorRiesgo, Borrable, Origen,
        # MotivoMarcado) están en su lista de excepciones.
        $vacias = @($script:PropsRellenables | Where-Object { -not $script:Mapeadas.ContainsKey($_) })
        $vacias | Should -BeNullOrEmpty -Because (
            'una propiedad de ItemVista que nadie asigna se muestra vacía en todas las filas sin que nada falle')
    }

    It 'no se asigna al item ninguna propiedad que ItemVista no declare' {
        # Asignar una propiedad inexistente a un objeto .NET lanza dentro
        # del bucle que llena la tabla y tumba el análisis.
        $inventadas = @($script:Mapeadas.Keys | Where-Object { $_ -notin $script:PropsVista })
        $inventadas | Should -BeNullOrEmpty -Because 'asignar una propiedad que no existe revienta al construir la fila'
    }
}

Describe 'ItemVista: lo compilado es lo que pone en Types.ps1' {

    <#
        Las pruebas anteriores preguntan a un tipo ya compilado, que sigue
        en memoria aunque cambie el archivo (Initialize-TiposInterfaz no
        recompila si el tipo existe). Aquí se relee Types.ps1 del disco.
    #>

    It 'la prueba encuentra la clase en el texto: si no, no comprueba nada' {
        $script:CuerpoItemVista | Should -Not -BeNullOrEmpty
        $script:PropsEnTexto.Count | Should -BeGreaterThan 15 -Because 'la clase declara una veintena de propiedades'
    }

    It 'las propiedades del texto y las del tipo compilado son las mismas' {
        $soloEnTexto  = @($script:PropsEnTexto | Where-Object { $_ -notin $script:PropsVista })
        $soloEnTipo   = @($script:PropsVista   | Where-Object { $_ -notin $script:PropsEnTexto })

        $soloEnTexto | Should -BeNullOrEmpty -Because 'lo que declara Types.ps1 tiene que existir en el tipo compilado'
        $soloEnTipo  | Should -BeNullOrEmpty -Because 'la reflexion estaria contestando por una version distinta del archivo'
    }
}

Describe 'Ninguna propiedad de ItemVista se queda sin quien la use' {

    <#
        Último tramo de candidato -> ItemVista -> fila: rellenar una
        propiedad no significa que se use. Sin WPF no se comprueba que se
        vea, solo que alguien la lea. Consumidores válidos (todos lecturas):

          1. Un {Binding ...} o SortMemberPath del XAML montado (no basta
             con que el nombre aparezca como texto).
          2. Una lectura desde el código de src/UI.
          3. Otra propiedad de la clase, como TextoCompleto, que es lo
             único que lee MotivoMarcado.

        Limitación conocida: la lectura en código no distingue
        $item.Metodo de $candidato.Metodo, así que un nombre compartido con
        el contrato puede darse por consumido. Sí detecta una propiedad
        nueva con nombre propio que no se enlaza en ninguna parte.
    #>

    BeforeAll {
        . (Join-Path $script:CarpetaUI 'Xaml.ps1')
        # El documento montado: el armazón sin los Panel.*.xaml no contiene
        # la tabla de resultados.
        $script:XamlMontado = Expand-PanelesXaml -Carpeta $script:CarpetaUI `
            -Texto ([IO.File]::ReadAllText((Join-Path $script:CarpetaUI 'MainWindow.xaml')))
        # Sin comentarios XML: OrdenRiesgo solo se enlaza en un
        # SortMemberPath y el comentario que lo explica bastaría para pasar.
        $sinComentarios = [regex]::Replace($script:XamlMontado, '(?s)<!--.*?-->', '')

        $script:Enlazadas = @{}
        foreach ($m in [regex]::Matches($sinComentarios, '\{Binding([^}]*)\}')) {
            # La expresión partida en palabras: cubre "{Binding Ruta}",
            # "{Binding Path=Ruta}" y las que llevan Converter, Mode, etc.
            foreach ($palabra in ($m.Groups[1].Value -split '[^A-Za-z0-9_]')) {
                if ($palabra) { $script:Enlazadas[$palabra] = $true }
            }
        }
        foreach ($m in [regex]::Matches($sinComentarios, 'SortMemberPath="([^"]+)"')) {
            $script:Enlazadas[$m.Groups[1].Value] = $true
        }

        $script:CodigoUI = ''
        foreach ($archivo in (Get-ChildItem $script:CarpetaUI -Filter '*.ps1')) {
            $script:CodigoUI += ((((Get-Content $archivo.FullName) |
                                   Where-Object { $_ -notmatch '^\s*#' }) -join "`n") + "`n")
        }
    }

    It 'la prueba encuentra enlaces y codigo: si no, no comprueba nada' {
        $script:Enlazadas.Count | Should -BeGreaterThan 20 -Because 'la ventana montada esta llena de enlaces de datos'
        $script:Enlazadas.ContainsKey('Seleccionado') | Should -BeTrue -Because 'la casilla de cada fila se enlaza a ella'
        $script:CodigoUI.Length | Should -BeGreaterThan 10000 -Because 'src/UI son varios miles de lineas'
    }

    It 'cada propiedad de ItemVista tiene quien la consuma' {
        $huerfanas = @($script:PropsVista | Where-Object {
            $nombre = [regex]::Escape($_)
            # (?!\s*=[^=]) descarta la asignación y deja pasar la lectura,
            # incluido "-eq".
            $leidaEnCodigo = $script:CodigoUI -match ('\.' + $nombre + '\b(?!\s*=[^=])')
            # Más de una aparición en la clase: alguien además de la propia
            # declaración la nombra.
            $usadaEnLaClase = ([regex]::Matches($script:CuerpoItemVista, '\b' + $nombre + '\b')).Count -gt 1
            -not ($script:Enlazadas.ContainsKey($_) -or $leidaEnCodigo -or $usadaEnLaClase)
        })
        $huerfanas | Should -BeNullOrEmpty -Because (
            'una propiedad que nadie enlaza ni lee llega a la fila y no la ve nadie: ' +
            'el dato viaja entero y muere en la tabla')
    }
}

Describe 'la clave de exclusion no puede ser la ruta a secas' {
    <#
        Para lo que no tiene ruta (un comando como "docker system prune",
        la papelera), comparar contra Ruta trataría una etiqueta como una
        carpeta: minúsculas, sin barra final y con una regla de prefijo que
        supone una jerarquía inexistente.
    #>

    BeforeAll {
        $script:RaizArq = Split-Path $PSScriptRoot -Parent
        . (Join-Path (Join-Path (Join-Path $script:RaizArq 'src') 'Core') 'Bootstrap.ps1')
    }

    Context 'Get-ClaveExclusion' {

        It 'con ruta de verdad, la clave ES la ruta' {
            # Para lo que ya funciona no debe cambiar nada: afecta al
            # camino del borrado.
            Get-ClaveExclusion -Ruta 'C:\Users\x\Downloads\a.tmp' -ModuloId 'temporales' -Nombre 'a.tmp' |
                Should -Be 'C:\Users\x\Downloads\a.tmp'
        }

        It 'reconoce las tres formas de ruta anclada' -ForEach @(
            @{ Que = 'unidad con barra invertida'; Ruta = 'C:\datos\x' }
            @{ Que = 'unidad con barra normal';    Ruta = 'C:/datos/x' }
            @{ Que = 'recurso de red';             Ruta = '\\equipo\recurso\x' }
            @{ Que = 'raiz POSIX';                 Ruta = '/tmp/x' }
        ) {
            # La POSIX hace falta porque la suite corre en Linux: sin ella,
            # una ruta real se tomaría por etiqueta.
            Get-ClaveExclusion -Ruta $Ruta -ModuloId 'm' -Nombre 'n' | Should -Be $Ruta
        }

        It 'sin ruta real, la clave es sintetica y lleva modulo y nombre' {
            Get-ClaveExclusion -Ruta 'docker system prune -a -f' -ModuloId 'dockerwsl' -Nombre 'Cache de Docker' |
                Should -Be 'modulo:dockerwsl|Cache de Docker'
        }

        It 'la clave sintetica lleva una barra vertical, que una ruta no puede llevar' {
            # Windows no admite "|" en nombres de archivo: ninguna exclusión
            # de carpeta puede casar con una clave sintética.
            $clave = Get-ClaveExclusion -Ruta 'Papelera de reciclaje' -ModuloId 'papelera' -Nombre 'Papelera'
            $clave | Should -BeLike '*|*'
            $clave | Should -Not -Match '^[A-Za-z]:'
        }

        It 'es estable: dos analisis dan la misma clave' {
            # Si dependiera de la ejecución, la exclusión no persistiría.
            $a = Get-ClaveExclusion -Ruta 'docker system prune' -ModuloId 'dockerwsl' -Nombre 'Cache'
            $b = Get-ClaveExclusion -Ruta 'docker system prune' -ModuloId 'dockerwsl' -Nombre 'Cache'
            $a | Should -Be $b
        }

        It 'no revienta con nulos' {
            { Get-ClaveExclusion -Ruta $null -ModuloId $null -Nombre $null } | Should -Not -Throw
            Get-ClaveExclusion -Ruta $null -ModuloId 'm' -Nombre 'n' | Should -Be 'modulo:m|n'
        }
    }

    Context 'Test-ClaveExcluida' {

        It 'una clave de ruta se compara por prefijo de carpeta' {
            Test-ClaveExcluida -Clave 'C:\Datos\sub\a.tmp' -Excluidas @('C:\Datos') | Should -BeTrue
        }

        It 'y sigue exigiendo separador: "C:\Datos" no excluye "C:\Datos Antiguos"' {
            Test-ClaveExcluida -Clave 'C:\Datos Antiguos\a.tmp' -Excluidas @('C:\Datos') | Should -BeFalse
        }

        It 'una clave sintetica solo casa EXACTA' {
            $clave = 'modulo:dockerwsl|Cache de Docker'
            Test-ClaveExcluida -Clave $clave -Excluidas @($clave)              | Should -BeTrue
            Test-ClaveExcluida -Clave $clave -Excluidas @('modulo:dockerwsl')  | Should -BeFalse
            Test-ClaveExcluida -Clave $clave -Excluidas @('modulo:dockerwsl|') | Should -BeFalse
        }

        It 'una exclusion de carpeta NO puede alcanzar a una clave sintetica' {
            # Ni "C:\" ni una cadena vacía mal normalizada deben rozar una
            # etiqueta.
            $clave = 'modulo:dockerwsl|Cache de Docker'
            foreach ($excl in @('C:\', 'C:\Datos', 'modulo:', '/', '\\')) {
                Test-ClaveExcluida -Clave $clave -Excluidas @($excl) |
                    Should -BeFalse -Because "'$excl' no deberia alcanzar a una clave sintetica"
            }
        }

        It 'sin exclusiones, ni con nulos, excluye nada' {
            Test-ClaveExcluida -Clave 'C:\x' -Excluidas @()   | Should -BeFalse
            Test-ClaveExcluida -Clave $null  -Excluidas @('C:\x') | Should -BeFalse
            { Test-ClaveExcluida -Clave $null -Excluidas $null } | Should -Not -Throw
        }
    }

    Context 'El contrato y los dos sitios que comparan' {

        It 'todo candidato nace con su ClaveExclusion' {
            $c = New-Candidato -ModuloId 'm' -Categoria 'c' -Nombre 'n' -Ruta 'C:\x\y' -Bytes 1 -Metodo 'Ruta'
            $c.ClaveExclusion | Should -Be 'C:\x\y'
        }

        It 'un candidato sin ruta real tambien, y sintetica' {
            $c = New-Candidato -ModuloId 'dockerwsl' -Categoria 'c' -Nombre 'Cache' `
                    -Ruta 'docker system prune' -Bytes 1 -Metodo 'Comando' -Comando 'docker system prune'
            $c.ClaveExclusion | Should -Be 'modulo:dockerwsl|Cache'
        }

        It 'el embudo del analisis excluye por la clave, no por la ruta' {
            # Se comprueba el comportamiento, no el texto del código: un
            # candidato sin ruta real, excluido por su clave sintética, no
            # sale del embudo.
            $sinRuta = New-Candidato -ModuloId 'dockerwsl' -Categoria 'c' -Nombre 'Cache' `
                           -Ruta 'docker system prune' -Bytes 1 -Metodo 'Comando' `
                           -Comando 'docker system prune'

            $script:EmisionContrato = @($sinRuta)
            $modulo = New-ModuloLimpieza -Id 'contrato' -Orden 99 `
                          -Nombre 'Modulo del contrato' -Descripcion 'Emite un candidato sin ruta.' `
                          -Buscar {
                              param($Configuracion, $Sync)
                              foreach ($c in $script:EmisionContrato) { $c }
                          }

            $base = [pscustomobject]@{
                Unidad = 'C:'; UnidadesSeleccionadas = @(); RutasExcluidas = @()
            }

            # Sin exclusión sale; si no saliera nunca, lo siguiente no
            # probaría nada.
            $sin = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $base
            @($sin.Candidatos).Count | Should -Be 1 -Because 'si no sale nunca, lo de abajo no prueba nada'

            # Con la clave sintetica en la lista, no sale.
            $base.RutasExcluidas = @($sinRuta.ClaveExclusion)
            $con = Invoke-ModuloLimpieza -Modulo $modulo -Configuracion $base
            @($con.Candidatos).Count | Should -Be 0 -Because 'comparado por Ruta esa etiqueta no casaria como carpeta'
        }

        It 'el motor revalida la exclusion FUERA del if de Comando' {
            # Si la revalidación quedara dentro de "if Metodo -ne Comando",
            # justo los candidatos que ejecutan un binario externo se la
            # saltarían.
            $texto = Get-Content -Raw -LiteralPath (
                Join-Path (Join-Path (Join-Path $script:RaizArq 'src') 'Core') 'Remove.ps1')

            $posExclusion = $texto.IndexOf('Test-ClaveExcluida')
            $posIfComando = $texto.IndexOf("if (`$Candidato.Metodo -ne 'Comando')")

            $posExclusion | Should -BeGreaterThan 0
            $posIfComando | Should -BeGreaterThan 0
            $posExclusion | Should -BeLessThan $posIfComando -Because 'dentro del if, un comando excluido no se revalida'
        }
    }
}
