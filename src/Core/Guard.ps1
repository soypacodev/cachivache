<#
.SYNOPSIS
    Guardia de seguridad: decide qué rutas no se pueden tocar nunca.

.DESCRIPTION
    Todo borrado pasa por aquí durante el análisis y otra vez justo antes de
    ejecutarse (revalidación en vivo), porque entre ambos momentos el usuario
    puede haber movido cosas.

    El modelo es de lista blanca: una ruta solo es borrable si cuelga de una
    raíz autorizada por el módulo que la propone. Todo lo demás se rechaza.

    Get-MotivoIntocable aplica cinco filtros incondicionales; cualquiera veta:
      1. Forma de la ruta: poco profunda, raíz de unidad, recurso de red o
         travesía con "..".
      2. Lista negra de rutas exactas y de sus antepasados.
      3. Fragmentos prohibidos en cualquier punto (WinSxS, System32, claves
         criptográficas, credenciales...).
      4. La ruta es una carpeta personal por su último segmento, esté donde
         esté: D:\Documentos, E:\Fotos\Imágenes...
      5. Cualquier cosa bajo una carpeta de copias de seguridad.

    Test-RutaSegura añade la lista blanca de raíces del módulo, el veto de
    enlaces y el veto por extensión personal. El README agrupa los filtros de
    otra forma e incluye Test-NombreSensible, que no es universal: solo lo
    invocan los módulos de más riesgo.

    El filtro 4 mira solo el último segmento a propósito: vetar cualquier ruta
    que contenga "\descargas\" dejaría sin función a los módulos que trabajan
    ahí dentro. Ese contenido lo protegen la lista blanca y el veto por
    extensión.
#>

# Profundidad mínima (en separadores) para que una ruta sea candidata. Se mide
# profundidad y no longitud: "D:\Juegos\Steam" es corta pero legítima.
$script:SeparadoresMinimos = 2

function Initialize-Guardia {
    <#
    .SYNOPSIS
        Prepara las listas negras a partir de la configuración del equipo.
    .PARAMETER Configuracion
        Objeto devuelto por New-Configuracion.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuracion)

    # La bandera se baja al empezar y se sube en la última sentencia: si algo
    # falla a mitad, la guardia queda sin inicializar y lo bloquea todo.
    $script:GuardiaLista = $false

    $script:RutasIntocables = @(
        # --- Raíz y sistema operativo -----------------------------------
        $env:SystemDrive
        "$env:SystemDrive\"
        $env:SystemRoot
        "$env:SystemRoot\System32"
        "$env:SystemRoot\SysWOW64"
        "$env:SystemRoot\WinSxS"
        "$env:SystemRoot\Boot"
        "$env:SystemRoot\Fonts"
        "$env:SystemDrive\Windows"
        "$env:SystemDrive\Users"
        "$env:SystemDrive\Recovery"
        "$env:SystemDrive\System Volume Information"

        # --- Programas ---------------------------------------------------
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:ProgramData
        "$env:ProgramData\Package Cache"
        "$env:ProgramFiles\WindowsApps"
        "$env:ProgramData\Microsoft"
        "$env:ProgramData\USOShared"

        # --- Perfil del usuario ------------------------------------------
        $env:USERPROFILE
        $env:LOCALAPPDATA
        $env:APPDATA
        "$env:LOCALAPPDATA\Microsoft"
        "$env:APPDATA\Microsoft"
        "$env:LOCALAPPDATA\Packages"
        "$env:USERPROFILE\.ssh"
        "$env:USERPROFILE\OneDrive"

        # --- Carpetas personales resueltas en tiempo de ejecución ---------
        $Configuracion.Escritorio
        $Configuracion.Documentos
        $Configuracion.Descargas
        $Configuracion.Imagenes
        $Configuracion.Musica
        $Configuracion.Videos
        $Configuracion.CarpetaDatos
    ) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { ConvertTo-RutaNormalizada $_ } |
    Where-Object { $_ } |
    Select-Object -Unique

    # =================================================================
    # NO TRADUCIR: lógica de seguridad. Estas listas no son
    # texto de interfaz.
    #
    # Contienen a propósito las dos mitades, castellano e inglés
    # ("documentos"/"documents", "respaldo"/"backup"). Si una extracción de
    # textos las lleva a un recurso de idioma, una de las mitades desaparece
    # y la guardia deja de reconocer esas carpetas sin ningún error visible.
    # tests/Guardia.Idioma.Tests.ps1 lo comprueba para FragmentosProhibidos,
    # NombresSensibles, ExtensionesPersonales, NombresBasuraConocida,
    # CarpetasEspejo, RegexCarpetaPersonal y RegexCopiaSeguridad.
    #
    # Para soportar otros idiomas de Windows se añaden nombres; nunca se
    # sustituyen los existentes.
    # =================================================================
    $script:FragmentosProhibidos = @(
        'windowsapps', 'package cache', 'winsxs', 'driverstore', 'catroot',
        '\system32\', '\syswow64\', '\config\systemprofile\', '\assembly\',
        'systemcertificates', '\microsoft\crypto\', '\microsoft\protect\',
        '\microsoft\vault\', '\microsoft\credentials\', '\windows defender',
        '\.ssh\', '\gnupg\', '\.gnupg\', '\.aws\', '\.kube\', '\.docker\config',
        '\system volume information', '\$recycle.bin\', '\recovery\'
    )

    $script:NombresSensibles = @(
        # Seguridad del equipo
        'defender', 'antivir', 'bitdefender', 'kaspersky', 'eset', 'avast', 'avg',
        'norton', 'mcafee', 'malwarebytes', 'sophos', 'trendmicro', 'firewall',
        'seguridad', 'security'
        # Identidad digital
        'certific', 'fnmt', 'pki', 'smartcard', 'dnie', 'autofirma', 'clave', 'token'
        # Gestores de contraseñas
        'keepass', 'bitwarden', 'lastpass', '1password', 'dashlane', 'password',
        'contrasen', 'authenticator'
        # Monederos y criptomonedas
        'wallet', 'ledger', 'trezor', 'metamask', 'exodus', 'electrum', 'bitcoin', 'crypto'
        # Sincronización en la nube
        'onedrive', 'dropbox', 'gdrive', 'googledrive', 'mega', 'icloud',
        'nextcloud', 'syncthing', 'resilio', 'sincroniz'
        # Copias de seguridad
        'backup', 'respaldo', 'veeam', 'acronis', 'macrium', 'restic', 'borg'
        # Comunicaciones y banca
        'thunderbird', 'outlook', 'mailstore', 'signal', 'whatsapp', 'telegram',
        'bank', 'banco', 'hacienda', 'aeat'
    )

    $script:ExtensionesPersonales = @(
        # Ofimática
        '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.odt', '.ods',
        '.rtf', '.txt', '.md', '.csv'
        # Imagen y vídeo
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.raw', '.heic',
        '.cr2', '.nef', '.arw', '.mp4', '.mov', '.avi', '.mkv', '.webm'
        # Audio
        '.mp3', '.wav', '.flac', '.ogg', '.m4a', '.aac'
        # Correo y comprimidos con datos
        '.pst', '.ost', '.eml', '.msg', '.mbox'
        # Partidas guardadas y proyectos creativos
        '.sav', '.save', '.world', '.blend', '.psd', '.ai', '.indd', '.dwg',
        '.prproj', '.aep', '.sketch', '.fig'
        # Bases de datos y llaves
        '.kdbx', '.db', '.sqlite', '.mdb', '.accdb', '.pem', '.key', '.pfx', '.p12'
    )

    # Basura conocida con extensión "personal" (Thumbs.db es un .db).
    $script:NombresBasuraConocida = @(
        'thumbs.db', 'ehthumbs.db', 'ethumbs.db', '.ds_store',
        'iconcache.db', 'desktop.ini.bak'
    )

    # Carpetas que parecen vacías pero son enlaces heredados del sistema;
    # borrarlas rompe cuadros de diálogo antiguos.
    $script:CarpetasEspejo = @(
        'misimagenes', 'mimusica', 'misvideos', 'misdocumentos', 'mypictures',
        'mymusic', 'myvideos', 'mydocuments', 'documentos', 'documents',
        'descargas', 'downloads', 'escritorio', 'desktop', 'favoritos', 'favorites',
        'contactos', 'contacts', 'vinculos', 'links', 'busquedas', 'searches',
        'partidasguardadas', 'savedgames', 'onedrive', 'applicationdata',
        'datosdeprograma', 'configuracionlocal', 'localsettings'
    )

    # --- Nombres sensibles: dos formas de comparar ----------------------
    # Las palabras largas (6 o más) se buscan como subcadena: son inequívocas
    # y algunas son raíces ("certific", "contrasen") que deben casar con sus
    # derivados. Las cortas exigen empezar en un límite de palabra, para que
    # "eset" no case con "Presets" ni "mega" con "Omega". Un acierto hace que
    # el módulo de restos no examine la carpeta, así que pecar de laxo aquí
    # oculta basura; pecar de estricto no borra nada (la guardia sigue delante).
    $script:NombresSensiblesLargos = @($script:NombresSensibles | Where-Object { $_.Length -ge 6 })

    $cortas = @($script:NombresSensibles | Where-Object { $_.Length -lt 6 } |
                ForEach-Object { [regex]::Escape($_) })
    $script:NombresSensiblesCortos = if ($cortas.Count -gt 0) {
        [regex]::new('(^|[^a-z])(' + ($cortas -join '|') + ')',
                     [Text.RegularExpressions.RegexOptions]::Compiled)
    } else { $null }

    # --- Precálculo para la ruta caliente --------------------------------
    # Get-MotivoIntocable se llama por cada candidato y, en
    # Clear-ContenidoCarpeta, por cada archivo; lo que se puede calcular una
    # sola vez se calcula aquí.

    # Conjunto de todos los antepasados de las rutas protegidas: "¿es $r
    # antecesora de algo protegido?" pasa a ser una consulta O(1).
    $script:AntepasadosProtegidos = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($protegida in $script:RutasIntocables) {
        $trozos = $protegida.Split('\', [StringSplitOptions]::RemoveEmptyEntries)
        for ($i = 1; $i -lt $trozos.Count; $i++) {
            [void]$script:AntepasadosProtegidos.Add(($trozos[0..($i - 1)] -join '\'))
        }
    }

    $script:RegexFragmentos = [regex]::new(
        '(' + (($script:FragmentosProhibidos | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')',
        [Text.RegularExpressions.RegexOptions]::Compiled -bor
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $script:RegexCarpetaPersonal = [regex]::new(
        '^(documents?|documentos?|desktop|escritorio|downloads?|descargas?|pictures?|imagenes?|fotos|music|musica|videos?|onedrive)$',
        [Text.RegularExpressions.RegexOptions]::Compiled -bor
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $script:RegexCopiaSeguridad = [regex]::new(
        '(\\|^)(backups?|respaldos?|copias|copias de seguridad)\\',
        [Text.RegularExpressions.RegexOptions]::Compiled -bor
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)

    # Debe seguir siendo la última sentencia (ver el inicio de la función).
    $script:GuardiaLista = $true
}

function ConvertTo-RutaNormalizada {
    <#
    .SYNOPSIS
        Deja una ruta en minúsculas, con barra invertida y sin barra final.
    .DESCRIPTION
        Todas las comparaciones de la guardia pasan por aquí. Unificar el
        separador evita que una ruta con barra normal, que Windows acepta, se
        salte los filtros.

        También quita el prefijo de ruta larga "\\?\" como defensa en
        profundidad: con él, "\\?\C:\Windows" no coincidiría con la lista
        negra y en cambio parecería un recurso de red.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return '' }
    $sinPrefijo = ConvertFrom-RutaLarga -Ruta $Ruta
    return $sinPrefijo.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function Test-GuardiaLista {
    <#
    .SYNOPSIS
        Comprueba que Initialize-Guardia se ha ejecutado entera en este ámbito.
    .DESCRIPTION
        Consulta la bandera que Initialize-Guardia sube en su última
        sentencia, no una de las listas: si la inicialización falla a mitad,
        listas como ExtensionesPersonales quedarían a $null y su veto
        desaparecería en silencio ("$null -contains $x" es $false).
    #>
    [OutputType([bool])]
    param()
    return $script:GuardiaLista -eq $true
}

function Get-MotivoIntocable {
    <#
    .SYNOPSIS
        Explica por qué una ruta está vetada sin condiciones, o devuelve
        cadena vacía si ningún filtro incondicional la veta.
    .DESCRIPTION
        Única implementación de los filtros incondicionales. Test-RutaIntocable
        es su envoltorio booleano y Get-MotivoBloqueo la reutiliza, de modo que
        el veredicto y el motivo registrado no pueden desincronizarse.

        Ante la duda bloquea: un falso positivo solo deja algo sin limpiar; un
        falso negativo puede romper el equipo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Ruta)

    if (-not (Test-GuardiaLista)) {
        return 'La guardia no se ha inicializado en este ámbito: se bloquea todo por seguridad.'
    }
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return 'Ruta vacía.' }

    $r = ConvertTo-RutaNormalizada $Ruta

    # 1. Formas de ruta que nunca son un candidato válido.
    if ($r -match '^[a-z]:\\?$') { return 'Es la raíz de una unidad.' }
    if ($r -match '^\\\\')       { return 'Es un recurso de red.' }
    if (($r.Split('\', [StringSplitOptions]::RemoveEmptyEntries).Count - 1) -lt $script:SeparadoresMinimos) {
        return 'Ruta demasiado cerca de la raíz para ser un candidato.'
    }
    # Una travesía es un segmento que vale exactamente "..": nombres como
    # "proyecto v1..2" o "notas...txt" son legítimos.
    if ($r.Contains('\..\') -or $r.EndsWith('\..') -or $r -eq '..' -or $r.StartsWith('..\')) {
        return 'Contiene una travesía de rutas (..).'
    }

    # 2. Coincidencia exacta con la lista negra.
    if ($script:RutasIntocables -contains $r) { return 'Está en la lista de rutas protegidas.' }

    # 3. La ruta es antecesora de algo intocable (borrarla se lo llevaría).
    #    El conjunto usa comparación ordinal: la comparación por cultura ignora
    #    caracteres como el guion suave o ZWJ, y una comprobación de seguridad
    #    debe comparar caracteres, no idioma.
    if ($script:AntepasadosProtegidos.Contains($r)) {
        return 'Contiene una ruta protegida.'
    }

    # 4. Fragmentos prohibidos en cualquier punto de la ruta.
    $conBarra = $r + '\'
    $fragmento = $script:RegexFragmentos.Match($conBarra)
    if ($fragmento.Success) { return "Contiene un fragmento prohibido: $($fragmento.Value)" }

    # 5a. La ruta es una carpeta personal por su último segmento, esté donde
    #     esté (D:\Documentos, un Escritorio de otro perfil...).
    #     - Solo el último segmento: ver la cabecera del archivo.
    #     - Se exceptúa lo que cuelga de la carpeta de Windows, donde no hay
    #       datos del usuario y el nombre coincide por casualidad
    #       (C:\Windows\SoftwareDistribution\Download). Los demás filtros
    #       siguen aplicándose ahí.
    #     - Se compara sin tildes ("Imágenes", "Música", "Vídeos"), pero solo
    #       en el último segmento: los filtros 2 a 4 comparan con rutas reales
    #       y dejarían de casar.
    $ultimoSegmento = $r.Substring($r.LastIndexOfAny([char[]]@('\', '/')) + 1)
    $segmentoSinTildes = (Remove-Tildes $ultimoSegmento).ToLowerInvariant()
    if ($script:RegexCarpetaPersonal.IsMatch($segmentoSinTildes)) {
        $raizWindows = ''
        if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
            $raizWindows = (ConvertTo-RutaNormalizada $env:SystemRoot).TrimEnd('\') + '\'
        }
        if ([string]::IsNullOrWhiteSpace($raizWindows) -or
            -not $r.StartsWith($raizWindows, [StringComparison]::OrdinalIgnoreCase)) {
            return "Es una carpeta personal por su nombre: $ultimoSegmento"
        }
    }

    # 5b. Carpetas de copia de seguridad en cualquier punto de la ruta.
    if ($script:RegexCopiaSeguridad.IsMatch($conBarra)) {
        return 'Cuelga de una carpeta de copias de seguridad.'
    }

    return ''
}

function Test-RutaIntocable {
    <#
    .SYNOPSIS
        Devuelve $true si la ruta no se puede borrar bajo ningún concepto.
    .DESCRIPTION
        Envoltorio booleano de Get-MotivoIntocable.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Ruta)

    return -not [string]::IsNullOrEmpty((Get-MotivoIntocable $Ruta))
}

function Test-NombreSensible {
    <#
    .SYNOPSIS
        Detecta nombres que sugieren datos críticos o irrecuperables.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Nombre)

    if (-not (Test-GuardiaLista)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Nombre)) { return $true }

    $n = (Remove-Tildes $Nombre).ToLowerInvariant()

    # Largas por subcadena; cortas solo en límite de palabra (ver
    # Initialize-Guardia).
    foreach ($palabra in $script:NombresSensiblesLargos) {
        if ($n.Contains($palabra)) { return $true }
    }

    if ($null -ne $script:NombresSensiblesCortos -and $script:NombresSensiblesCortos.IsMatch($n)) {
        return $true
    }

    return $false
}

function Test-ArchivoPersonal {
    <#
    .SYNOPSIS
        Decide si un archivo parece trabajo del usuario y no basura.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Ruta)

    if (-not (Test-GuardiaLista)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $true }

    # Se parte a mano: fuera de Windows, [IO.Path]::GetFileName no reconoce
    # la barra invertida (pruebas en Linux).
    $corte     = $Ruta.LastIndexOfAny([char[]]@('\', '/'))
    $nombre    = if ($corte -ge 0) { $Ruta.Substring($corte + 1) } else { $Ruta }
    $extension = [IO.Path]::GetExtension($nombre).ToLowerInvariant()

    if ($script:NombresBasuraConocida -contains $nombre.ToLowerInvariant()) { return $false }

    # "~$nombre.ext" es el archivo de bloqueo que Office crea mientras el
    # documento está abierto; el documento real es "nombre.ext". El prefijo
    # debe ser exacto: "~ideas.docx" sigue protegido.
    if ($nombre.StartsWith('~$', [StringComparison]::Ordinal)) { return $false }

    if ($script:ExtensionesPersonales -contains $extension) { return $true }

    # Doble extensión: "Contrasenas.kdbx.bak" o "datos.sqlite.old" son copias
    # de algo importante. Si la extensión es de descarte se decide por la de
    # debajo; un ".bak" sin extensión personal debajo sigue siendo proponible.
    if ($extension -in @('.bak', '.old', '.tmp')) {
        $interior = [IO.Path]::GetExtension(
                        [IO.Path]::GetFileNameWithoutExtension($nombre)).ToLowerInvariant()
        if ($script:ExtensionesPersonales -contains $interior) { return $true }
    }

    # El patrón debe cerrar con separador, dígito o fin de nombre: sin eso
    # "image" protegería imagecache.dat y "cv" cualquier cv*.tmp.
    if ($nombre -match '(?i)^(documento|document|foto|photo|imagen|image|backup|respaldo|copia|export|factura|contrato|curriculum|cv)([0-9 _\-.]|$)') {
        return $true
    }
    return $false
}

function Test-CarpetaEspejo {
    <#
    .SYNOPSIS
        Carpeta del sistema que parece vacía pero es un enlace heredado.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Nombre)

    if (-not (Test-GuardiaLista)) { return $true }
    return $script:CarpetasEspejo -contains (ConvertTo-Token $Nombre)
}

function Get-RaizQueContiene {
    <#
    .SYNOPSIS
        Devuelve la raíz autorizada de la que cuelga una ruta, o cadena vacía
        si no cuelga de ninguna.
    .DESCRIPTION
        La comparación exige la barra final, de modo que la propia raíz nunca
        resulta borrable: solo su contenido. Devuelve la raíz, y no un
        booleano, porque Test-CadenaSinEnlaces necesita saber dónde parar.
        Test-BajoRaiz es su envoltorio booleano, usado por las pruebas.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]   $Ruta,
        [string[]] $Raices
    )

    if ([string]::IsNullOrWhiteSpace($Ruta)) { return '' }
    if ($null -eq $Raices -or $Raices.Count -eq 0) { return '' }

    $r = ConvertTo-RutaNormalizada $Ruta
    foreach ($raiz in $Raices) {
        if ([string]::IsNullOrWhiteSpace($raiz)) { continue }
        $base = ConvertTo-RutaNormalizada $raiz
        # Ordinal, como el filtro 3 de Get-MotivoIntocable.
        if ($base -and $r.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return $base }
    }
    return ''
}

function Test-BajoRaiz {
    <#
    .SYNOPSIS
        Comprueba que una ruta cuelga de alguna de las raíces autorizadas.
    .DESCRIPTION
        Comprobación solo de texto: acepta rutas con ".." y no detecta
        enlaces. No debe usarse suelta; Test-RutaSegura la combina con
        Test-RutaIntocable y Test-CadenaSinEnlaces.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]   $Ruta,
        [string[]] $Raices
    )

    return -not [string]::IsNullOrEmpty((Get-RaizQueContiene -Ruta $Ruta -Raices $Raices))
}

function Test-CadenaSinEnlaces {
    <#
    .SYNOPSIS
        Comprueba que ninguna carpeta entre la raíz autorizada y la ruta es un
        punto de reanálisis.

    .DESCRIPTION
        La lista blanca y la lista de fragmentos comparan texto, pero una
        junction dentro de una zona autorizada (que cualquier usuario puede
        crear sin ser administrador) haría que lo que hay al otro lado
        pareciera estar dentro. Get-ChildItem -Recurse de Windows PowerShell
        5.1 además desciende por ellas.

        Por eso se sube de la hoja a la raíz autorizada consultando los
        atributos reales de cada carpeta; cualquier reparse point en el camino
        rechaza la ruta. Cuesta un Get-Item por nivel.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Ruta,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Raiz
    )

    # AllowEmptyString hace alcanzables estas guardas: sin él, "" haría
    # lanzar al enlazador de parámetros en vez de devolver $false, y una
    # función de seguridad debe responder "no", no lanzar.
    if ([string]::IsNullOrWhiteSpace($Raiz)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $false }
    $tope = ConvertTo-RutaNormalizada $Raiz

    $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    # Lo que no se puede leer no se puede dar por seguro: se falla cerrado.
    if ($null -eq $item)     { return $false }
    if (Test-EsEnlace $item) { return $false }

    # Se sube con .Parent y no partiendo texto: así lo resuelve el propio
    # sistema de archivos, sin adivinar separadores.
    $carpeta = if ($item.PSIsContainer) { $item } else { $item.Directory }

    # Tope de niveles para no quedar en bucle si un enlace apunta a un ancestro.
    for ($nivel = 0; $nivel -lt 260 -and $null -ne $carpeta; $nivel++) {
        if (Test-EsEnlace $carpeta) { return $false }
        if ((ConvertTo-RutaNormalizada $carpeta.FullName) -eq $tope) { return $true }
        $carpeta = $carpeta.Parent
    }
    # Se llegó a la raíz del disco sin pasar por la raíz autorizada.
    return $false
}

function Test-RutaSegura {
    <#
    .SYNOPSIS
        Veredicto final: esta ruta se puede borrar con estas raíces.
    .DESCRIPTION
        Es la única función que los módulos deben llamar. Combina la lista
        blanca de raíces con todos los filtros de la lista negra y consulta el
        estado real del disco (enlaces, tipo de elemento).

    .PARAMETER PermitirPersonales
        Levanta únicamente el veto por extensión personal. Existe para el
        módulo de duplicados, donde se ha comprobado por hash que hay otra
        copia idéntica y siempre se conserva la más antigua. Ningún otro
        módulo debe usarlo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]   $Ruta,
        [string[]] $Raices,
        [switch]   $PermitirPersonales
    )

    if (Test-RutaIntocable $Ruta) { return $false }

    $raizQueVale = Get-RaizQueContiene -Ruta $Ruta -Raices $Raices
    if ([string]::IsNullOrEmpty($raizQueVale)) { return $false }

    $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    if ($null -eq $item)     { return $false }
    if (Test-EsEnlace $item) { return $false }

    # Sin esto, pertenecer a una raíz sería una afirmación sobre texto, no
    # sobre dónde están los datos.
    if (-not (Test-CadenaSinEnlaces -Ruta $Ruta -Raiz $raizQueVale)) { return $false }

    if (-not $PermitirPersonales -and
        -not $item.PSIsContainer -and
        (Test-ArchivoPersonal $item.FullName)) { return $false }
    return $true
}

function Get-MotivoBloqueo {
    <#
    .SYNOPSIS
        Explica en castellano por qué la guardia ha rechazado una ruta.
    .DESCRIPTION
        Equivalente a Test-RutaSegura, pero devuelve el motivo en vez de un
        booleano. Se usa en el registro y los informes para auditar el
        comportamiento sin leer el código.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]   $Ruta,
        [string[]] $Raices
    )

    $motivo = Get-MotivoIntocable $Ruta
    if ($motivo) { return $motivo }

    $raizQueVale = Get-RaizQueContiene -Ruta $Ruta -Raices $Raices
    if ([string]::IsNullOrEmpty($raizQueVale)) { return 'No cuelga de ninguna raíz autorizada por el módulo.' }

    $item = Get-Item -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    if ($null -eq $item)     { return 'La ruta ya no existe.' }
    if (Test-EsEnlace $item) { return 'Es un enlace simbólico o junction.' }
    if (-not (Test-CadenaSinEnlaces -Ruta $Ruta -Raiz $raizQueVale)) {
        return 'Alguna carpeta del camino es un enlace: la ruta no está donde parece.'
    }
    if (-not $item.PSIsContainer -and (Test-ArchivoPersonal $item.FullName)) {
        return 'Parece un archivo personal por su extensión o su nombre.'
    }
    return 'Sin bloqueo.'
}
