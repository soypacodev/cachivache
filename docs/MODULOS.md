# Módulos

Qué mira cada módulo, qué propone y qué consecuencias tiene aceptarlo.

**Leyenda:** *admin* = necesita permisos de administrador · **solo informa** = nunca borra nada, únicamente señala.

**Sobre los perfiles:** el perfil que en la interfaz se llama *Exhaustivo* tiene por identificador `agresivo`, que es el valor que admite `-Perfil` en modo consola (`-Perfil exhaustivo` da un error de parámetro). Las fichas usan los identificadores.

**Para todos los módulos:** cada candidato pasa por la guardia de seguridad, por la lista de exclusiones del usuario y por el filtro de unidades antes de mostrarse, y se vuelve a comprobar justo antes de borrar. En unidades extraíbles se analiza y se informa, pero nunca se propone borrar nada. Ver [`ARQUITECTURA.md`](ARQUITECTURA.md#el-embudo-lo-que-el-registro-garantiza).

---

## `caches` · Cachés de aplicaciones y desarrollo · riesgo bajo

Perfiles: conservador, equilibrado, agresivo

Vacía el contenido de cachés que el programa correspondiente regenera solo. **Siempre se vacía el contenido y la carpeta se queda**, porque muchas aplicaciones fallan si su carpeta de caché desaparece.

Cubre gestores de paquetes (npm, Yarn, pnpm, Gradle, Maven, pip, NuGet, Cargo, Go, Composer), cachés de shaders (NVIDIA DXCache y GLCache, D3DSCache, AMD DxCache), plataformas de juego (Steam, Epic), aplicaciones de escritorio (Discord, Spotify, Teams, VS Code, Slack, Postman, Zoom, Obsidian, Adobe Media Cache, Office File Cache), IDEs de JetBrains producto a producto, y temporales del sistema.

Firefox tiene tratamiento propio: se tocan **solo** las subcarpetas `cache2` de cada perfil, nunca la carpeta del perfil, donde viven contraseñas, marcadores e historial.

Si detecta que un programa está abierto, lo avisa: los archivos en uso se saltan solos y la caché no se vacía del todo.

---

## `navegadores` · Cachés de navegadores · riesgo bajo

Perfiles: conservador, equilibrado, agresivo

Recorre Chrome, Edge, Brave, Opera, Opera GX, Vivaldi, Yandex y Chromium, **perfil por perfil** (Default, Profile 1, Profile 2, Guest Profile…), y propone solo las subcarpetas que son caché pura: `Cache`, `Code Cache`, `GPUCache`, `Service Worker\CacheStorage` y equivalentes.

No toca contraseñas, marcadores, cookies, historial, sesiones abiertas ni extensiones. Nunca propone la carpeta del perfil entera.

---

## `proyectos` · Carpetas regenerables de proyectos · riesgo bajo

Perfiles: equilibrado, agresivo

Busca en Escritorio, Documentos y en las carpetas de desarrollo habituales (`source`, `repos`, `dev`, `Proyectos`, `Projects`) las carpetas que vuelven con un comando: `node_modules`, `.next`, `.nuxt`, `.svelte-kit`, `.turbo`, `.parcel-cache`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.tox`, `.gradle`, `Pods`.

Las carpetas ambiguas (`dist`, `build`, `out`, `obj`, `bin`, `target`, `vendor`, `venv`, `.venv`) **solo se proponen si junto a ellas hay un manifiesto de proyecto** que lo justifique: `package.json`, `pom.xml`, `build.gradle`, `CMakeLists.txt`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `requirements.txt`, `composer.json` o `Gemfile`. Sin manifiesto, `build` podría ser código de alguien y no se toca.

No desciende dentro de un `node_modules`, así que no propone por separado los `dist` o `build` de los paquetes que contiene: esos bytes ya están contados en el `node_modules`. Un proyecto tocado en los últimos siete días sube a riesgo medio y avisa de que está activo.

---

## `papelera` · Papelera de reciclaje · riesgo medio

Perfiles: conservador, equilibrado, agresivo

Mide lo que ocupa la papelera en las unidades fijas que tengas marcadas y cuenta los elementos consultando al shell. **Nunca viene marcado por defecto**: vaciarla es irreversible y ya no se podrá restaurar nada.

---

## `restos` · Restos de programas desinstalados · riesgo alto

Perfiles: equilibrado, agresivo

Es el módulo con más posibilidad de falso positivo, y por eso el más cauto.

Construye un vocabulario con los nombres de **ocho fuentes**, y las separa en dos grupos según cuánta evidencia aporten:

- **Fuertes** — el `DisplayName` de la lista de desinstalación, la carpeta de `InstallLocation`, las carpetas de Archivos de programa y los paquetes de la Store. Valen para coincidencia exacta **y** por prefijo.
- **Débiles** — nombres de servicio, de proceso, de editor, de acceso directo del menú Inicio y de entrada de arranque. Valen **solo** para coincidencia exacta.

La distinción importa: con un único conjunto comparado por subcadena, cualquier carpeta que contuviera una palabra genérica (`games`, `launcher`, `power`) parecería de un programa instalado y no se revisaría nunca, y los restos de juegos, que son los que más ocupan, son justo los que más fácilmente coinciden.

Zonas que recorre: `AppData\Local`, `AppData\Roaming`, **`AppData\LocalLow`** —donde deja sus datos todo juego hecho con Unity— y `ProgramData`.

**Baja un segundo nivel cuando hace falta.** Si una carpeta de primer nivel corresponde a algo instalado pero contiene subcarpetas, se evalúa cada hija: es el caso de un editor con varios productos del que solo queda uno instalado, y donde vive la mayoría de los restos de juegos. Para no convertir eso en un falso positivo, a cada hija se le prueban dos nombres: el suyo y el del editor pegado delante, porque un producto suele figurar como "Adobe Acrobat" y no como "Acrobat".

Antes de proponer nada, inspecciona el interior en busca de subcarpetas tipo `saves`, `worlds`, `profiles`, `proyectos`, `screenshots` y de archivos con extensiones personales. Si encuentra algo, lo dice en el aviso y el elemento sube a riesgo alto. Todo en **una sola pasada de disco**.

**Nada viene marcado por defecto.** Revisa los nombres antes de borrar.

---

## `restosregistro` · Restos fuera de AppData · riesgo medio

Perfiles: equilibrado, agresivo

Lo que `restos` no cubre porque no está en AppData. Cuatro fuentes, de más segura a menos:

- **Versiones antiguas de aplicaciones Electron.** Discord, Slack, Teams y GitHub Desktop guardan cada versión en `app-<número>` y conservan las anteriores: 150-400 MB cada una, y se acumulan solas. Que sobra la vieja es comprobable: hay otra más nueva al lado. Las versiones se comparan **como versiones y no como texto**, porque `app-1.0.10` es posterior a `app-1.0.9` y al revés se propondría borrar la que está en uso.
- **Instaladores de controladores ya aplicados** — `C:\NVIDIA`, `C:\AMD`, `C:\Intel`, `C:\SWSetup`. Es el paquete descomprimido, no el controlador. El `DriverStore` sigue vetado por la guardia.
- **Entradas de desinstalación fantasma**, que apuntan a carpetas que ya no existen. **Solo informativo:** el programa no escribe jamás en el registro. Aparte del ruido en "Aplicaciones instaladas", estas entradas hacen que Cachivache dé por instalados programas que ya no lo están.
- **Huérfanos de Archivos de programa**, sin entrada de desinstalación, sin servicio y sin acceso del menú Inicio. Es lo más incierto —un programa portable copiado a mano tampoco deja entrada—, así que va con riesgo alto, con aviso y sin marcar.

---

## `juegos` · Juegos y plataformas de juego · riesgo medio

Perfiles: conservador, equilibrado, agresivo

Dos clases de candidato que no se mezclan:

- **Basura regenerable** — cachés, registros, descargas a medias y volcados de Steam, Epic, Battle.net, GOG, EA, Ubisoft y Riot. La plataforma los vuelve a crear sola: riesgo bajo, se proponen marcados.
- **Instalaciones huérfanas** — carpetas de `steamapps\common` sin su `appmanifest`, cachés de sombreadores y contenido del taller de juegos que ya no están. Aquí se recupera espacio de verdad, decenas de GB, pero **nunca vienen marcadas**.

Lee las bibliotecas de `libraryfolders.vdf`, así que encuentra también las que están en otros discos, que es donde suelen estar los juegos grandes. Si una biblioteca no tiene **ni un solo** manifiesto no declara nada huérfano: podría ser que Steam no haya terminado de escribir, y equivocarse ahí sería proponer borrar la colección entera.

**Las partidas guardadas no se proponen jamás.** `My Games`, `Saved Games`, `Ubisoft Game Launcher\savegames` y `userdata\<id>\<appid>\remote` solo se informan. De dentro sí se proponen `Logs`, `Crashes`, `ShaderCache` y `DerivedDataCache`, que el motor del juego regenera solo.

---

## `appsuwp` · Aplicaciones de la Store · riesgo medio

Perfiles: equilibrado, agresivo

Cada aplicación de la Store guarda sus datos en `%LOCALAPPDATA%\Packages\<familia>`. Al desinstalarla, Windows borra la aplicación y muchas veces deja esa carpeta.

Dentro de cada paquete hay carpetas con contratos distintos, y la diferencia manda: `LocalCache`, `TempState` y `AC\INetCache` son regenerables y se proponen con riesgo bajo; `LocalState`, `RoamingState` y `Settings` son **datos del usuario** y no se proponen por separado nunca.

Una carpeta de paquete huérfana va con aviso y sin marcar: no hay forma barata de saber si su `LocalState` guarda algo que haga falta. Y si no se puede consultar la lista de aplicaciones instaladas, **no declara huérfano nada**: una lista vacía no es "no hay nada instalado".

---

## `descargas` · Instaladores y descargas antiguas · riesgo medio

Perfiles: equilibrado, agresivo

Busca archivos más antiguos que el umbral de días configurado y de tipos que casi siempre se pueden volver a descargar: instaladores y paquetes (`.exe`, `.msi`, `.msix`, `.appx`, sus variantes `bundle`, `.msu`, `.msp`, `.jar`, `.apk`, `.dmg`, `.pkg`, `.deb`, `.rpm`), imágenes de disco (`.iso`, `.img`, `.vhd`, `.vhdx`, `.esd`) y comprimidos (`.zip`, `.rar`, `.7z`, `.tar`, `.gz`, `.bz2`, `.cab`…).

**Nunca propone documentos, fotos ni vídeos**, por antiguos y grandes que sean. Los comprimidos llevan aviso porque pueden contener cualquier cosa dentro.

---

## `vacias` · Carpetas vacías · riesgo bajo

Perfiles: equilibrado, agresivo

Carpetas sin un solo archivo dentro, ni siquiera en subcarpetas. **No liberan espacio: ordenan.**

Excluye las carpetas espejo del sistema (Mis imágenes, Favoritos, Vínculos, Partidas guardadas…), que parecen vacías pero son enlaces heredados cuya desaparición rompe cuadros de diálogo antiguos, y se salta los junctions. De una cadena de carpetas vacías anidadas propone solo la de arriba.

Solo vienen marcadas las que están dentro de AppData o ProgramData, o las creadas hace más días que el umbral configurado: una carpeta vacía reciente fuera de AppData puede ser una que el usuario acaba de crear para ordenar.

---

## `accesos` · Accesos directos rotos · riesgo bajo

Perfiles: equilibrado, agresivo

Archivos `.lnk` cuyo destino ya no existe: no abren nada. Se descartan los accesos de la Store (`shell:`, `ms-`) y los enlaces web, que no tienen ruta en disco y darían falso positivo.

Si el destino está en una carpeta que el usuario actual no puede leer (otro perfil, `WindowsApps`), no se puede saber si existe: el acceso sale con aviso y sin marcar.

---

## `temporales` · Temporales sueltos y miniaturas · riesgo bajo

Perfiles: conservador, equilibrado, agresivo

`.tmp`, `.temp`, `.bak`, `.old`, `.dmp`, `.chk`, `.gid`, descargas a medias (`.crdownload`, `.partial`, `.download`), archivos de bloqueo de Office (`~$…`) y bases de datos de miniaturas (`Thumbs.db`, `ehthumbs.db`, `.DS_Store`) repartidos por las carpetas del usuario.

**`.log` se excluye a propósito**: hay programas que guardan ahí información útil. Los `.bak` y `.old` suben a riesgo medio, y si tienen menos de una semana llevan aviso: podrían ser la única copia de algo. Los temporales, descargas a medias y bloqueos de Office escritos en la última media hora no se proponen, porque pueden estar en uso; los bloqueos de Office tampoco mientras Word, Excel o PowerPoint estén abiertos.

---

## `duplicados` · Archivos duplicados · riesgo medio

Perfiles: agresivo

Para no calcular el hash de todo el disco, primero agrupa por tamaño exacto en bytes, después compara un fragmento del principio y del final, y solo entonces calcula el SHA-256 de los archivos enteros.

**Decide qué copia se conserva por su ubicación**: una copia en Documentos, Imágenes, Música o Vídeos gana a una en Descargas o en una carpeta temporal; a igualdad de sitio, la menos anidada; y solo después, la más antigua. Las demás se proponen. Nada viene marcado por defecto: comprueba que la copia que se conserva es la que quieres.

Dos enlaces duros al mismo contenido son un solo archivo, no duplicados, y no se proponen. Los archivos que están solo en la nube (OneDrive a petición) se saltan para no descargarlos, y el módulo dice cuántos.

Es el **único módulo del programa autorizado a proponer archivos con extensión personal** (fotos, documentos, vídeo). La excepción está justificada y acotada: se ha comprobado por hash SHA-256 que existe otra copia byte a byte idéntica, así que borrar esta no pierde información. Todos los demás filtros de la guardia siguen aplicándose igual.

---

## `grandes` · Archivos grandes sin usar · riesgo alto · **solo informa**

Perfiles: agresivo

Lista los archivos que más ocupan y llevan más tiempo sin abrirse. Como Windows puede tener desactivado el seguimiento de último acceso, usa la fecha más reciente entre acceso y modificación.

**Este módulo no borra nada.** Su trabajo es enseñarte dónde se está yendo el disco para que decidas tú si mover algo a un disco externo.

---

## `logs` · Registros y volcados del sistema · riesgo bajo · *admin*

Perfiles: conservador, equilibrado, agresivo

Registros CBS, DISM y Windows Update, carpeta Panther de la instalación, volcados del kernel y minivolcados de pantallazos azules, informes de error de WER, caché de Prefetch y el `MEMORY.DMP` completo, que puede ocupar tanto como la RAM instalada.

Nada de esto hace falta para que el equipo funcione: es material de diagnóstico que Windows conserva indefinidamente.

---

## `windowsupdate` · Caché de Windows Update · riesgo bajo · *admin*

Perfiles: conservador, equilibrado, agresivo

Paquetes de actualización ya aplicados en `SoftwareDistribution\Download`, la base de datos del historial de actualizaciones y la caché de optimización de entrega. **En equipos que llevan años sin formatear esto suele ser lo que más espacio recupera.**

Vaciar la base de datos borra el historial de actualizaciones que muestra Windows, así que lleva aviso y no viene marcado.

Si encuentra `Windows.old` lo informa pero **no lo toca**: la forma correcta de quitarlo es *Configuración → Sistema → Almacenamiento → Archivos temporales*, y en cualquier caso Windows lo borra solo a los diez días.

---

## `componentes` · Almacén de componentes (WinSxS) · riesgo medio · *admin*

Perfiles: agresivo

WinSxS **nunca se toca a mano**: borrar algo de ahí rompe Windows Update y puede impedir el arranque. La única forma correcta de reducirlo es que lo haga el propio Windows.

Este módulo le pregunta a DISM cuánto se podría recuperar (`/AnalyzeComponentStore`) y, si merece la pena, ofrece ejecutar el comando oficial `/StartComponentCleanup`. Puede tardar entre diez y cuarenta minutos y no se debe interrumpir. Después ya no se podrán desinstalar las actualizaciones instaladas.

---

## `sistema` · Archivos gigantes del sistema · riesgo alto · **solo informa**

Perfiles: equilibrado, agresivo

`hiberfil.sys`, `pagefile.sys`, `swapfile.sys` y el espacio que ocupan los puntos de restauración. Ninguno se borra a mano: se desactivan o se ajustan desde Windows.

El módulo mide cuánto ocupan y explica cómo reducirlos correctamente: `powercfg /hibernate off` para la hibernación (avisando de que también apaga el Inicio rápido), la configuración de memoria virtual para el archivo de paginación, y *Protección del sistema* para los puntos de restauración.

---

## `dockerwsl` · WSL y Docker · riesgo alto

Perfiles: agresivo

Los discos virtuales de WSL crecen pero **no se encogen solos**: aunque borres archivos dentro de la distribución, el `.vhdx` sigue ocupando lo mismo en Windows.

Localiza los `.vhdx` de las distribuciones instaladas y de Docker Desktop, y explica la secuencia correcta para reclamar el espacio (`docker system prune`, `wsl --shutdown`, `Optimize-VHD`). El archivo en sí es **solo informativo**: contiene todo el sistema de archivos de esa distribución.

La limpieza de imágenes y contenedores de Docker sí se ofrece como comando ejecutable, con su aviso.

---

## `arranque` · Arranque, servicios y tareas rotas · riesgo medio · **solo informa**

Perfiles: equilibrado, agresivo

Entradas que Windows intenta ejecutar en cada arranque y cuyo programa ya no existe: claves `Run` y `RunOnce` (HKLM, HKLM de 32 bits y HKCU), accesos directos de las carpetas de Inicio, servicios sin binario y tareas programadas de terceros.

Un ejecutable se declara roto **solo si fallan las tres comprobaciones**: la ruta tal cual, la ruta con `.exe` añadido (hay servicios registrados sin extensión) y la resolución por PATH. Las tareas del árbol `\Microsoft\` se excluyen enteras: son del sistema.

Para las entradas de registro lee además `StartupApproved`, de modo que te dice si esa entrada está activada o si ya la habías desactivado desde el Administrador de tareas.

**No modifica el registro.** Se limita a decirte qué quitar y desde dónde.

---

## `perfiles` · Perfiles de usuario abandonados · riesgo alto · *admin* · **solo informa**

Perfiles: agresivo

Perfiles de otras cuentas que siguen ocupando disco, con su tamaño y su fecha de último uso. Contienen todos los documentos y ajustes de esa persona, así que **este programa nunca los borra**: la forma correcta es *Propiedades del sistema → Configuración avanzada → Perfiles de usuario*, que además limpia el registro.
