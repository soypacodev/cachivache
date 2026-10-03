# Estructura de archivos

Por qué cada archivo contiene lo que contiene y qué se decidió deliberadamente no separar. Cómo funciona el código en conjunto está en [`ARQUITECTURA.md`](ARQUITECTURA.md).

---

## 1. El criterio

Un archivo debe tener **una sola razón para cambiar**. El criterio no es el número de líneas: `Guard.ps1` es de los más grandes y se mantiene entero; otros más pequeños se dividieron.

La señal más objetiva es **quién consume cada función**. Si las funciones de un archivo las usan grupos de archivos distintos y ninguno usa las dos mitades, ese archivo son en realidad dos. Al comprobarlo conviene no fiarse de un `grep` a secas: muchas coincidencias son menciones dentro de la ayuda de otra función, no llamadas reales.

---

## 2. El núcleo (`src/Core/`)

`Bootstrap.ps1` carga estos archivos en un orden explícito (ver [`ARQUITECTURA.md`](ARQUITECTURA.md#carga-del-núcleo)).

| Archivo | Qué contiene |
|---|---|
| `Version.ps1` | Versión, URL del repositorio y consulta de la última versión publicada (solo bajo demanda) |
| `Progreso.ps1` | `Test-Cancelacion` y `Set-Progreso`: la comunicación entre los módulos y la ventana |
| `Texto.ps1` | Normalización de texto para comparar identidad (`Remove-Tildes`, `ConvertTo-Token`) |
| `Format.ps1` | Tamaños, tiempos y rutas para mostrar; anonimización de rutas en informes |
| `EstadoVacio.ps1` | Qué decir cuando la tabla de resultados no muestra ninguna fila |
| `Extraibles.ps1` | Clase de cada unidad y si en ella se puede proponer un borrado |
| `FileSystem.ps1` | Medir rutas, rutas largas, enlaces, archivos en la nube, unidades, carpetas conocidas, exclusiones |
| `Compresion.ps1` | Tamaño en disco de archivos comprimidos con NTFS y espacio que de verdad se recupera |
| `Exclusiones.ps1` | Cómo se presenta la lista de "no tocar nunca" |
| `Guard.ps1` | El veredicto "¿se puede borrar esta ruta?". Ver [4.1](#41-guardps1-no-se-divide) |
| `Candidate.ps1` | Contrato de candidato y de módulo, regla de premarcado, `Invoke-BusquedaPorLista` |
| `Comandos.ps1` | Qué programas externos se pueden lanzar y cómo se resuelven. Ver [4.5](#45-comandosps1) |
| `Papelera.ps1` | Cuota de la papelera por volumen y textos del destino del borrado |
| `Remove.ps1` | Motor de eliminación: lo único que borra datos del usuario |
| `Registry.ps1` | Vocabulario de programas instalados (solo lectura) |
| `Steam.ps1` | Bibliotecas y juegos que Steam conoce (solo lectura) |
| `Ejecutables.ps1` | Resolver ejecutables de líneas de comando, estado de arranque, destino de accesos directos |
| `Profiles.ps1` | Perfiles de limpieza |
| `Config.ps1` | Configuración del **equipo**, descubierta en cada arranque |
| `Preferencias.ps1` | Preferencias del **usuario**, persistentes |
| `Log.ps1` | Registro de actividad (`.log`) y diagnóstico |
| `Historial.ps1` | Historial de ejecuciones (`.json`) |
| `Comparacion.ps1` | Comparación de un análisis con el anterior |
| `Inspeccion.ps1` | Qué hay dentro de una carpeta, para que el usuario decida |
| `Indice.ps1`, `VistaArchivos.ps1`, `Mapa.ps1` | Índice de espacio en disco, su capa de consulta y el cálculo del mapa de árbol |
| `IndicePersistente.ps1`, `IndiceIncremental.ps1`, `IndiceEspacio.ps1` | Guardar el índice, decidir si se puede reutilizar y avisar de que sus datos son de antes |
| `CambiosLimpieza.ps1` | Traduce el resultado de una limpieza a cambios aplicables al índice (todavía no lo usa ningún flujo del programa) |
| `Report.ps1`, `ReportEspacio.ps1` | Informes HTML, CSV y JSON; informe de espacio con mapa en SVG |
| `ModuleRegistry.ps1` | Descubrir y ejecutar módulos, y el embudo de reglas común a todos |

---

## 3. La ventana, repartida en cinco archivos

`Show-VentanaPrincipal` vive en `Window.ps1`, que construye la ventana y `$estado`, y **dot-sourcea desde dentro de sí misma** los cuatro trozos de su cuerpo: `Window.Ayudantes.ps1`, `Window.Analisis.ps1`, `Window.Eliminacion.ps1` y `Window.Eventos.ps1`.

Funciona porque un `.` **dentro** de una función carga el archivo en el ámbito de esa función: cada trozo ve `$c`, `$estado`, `$ventana` y los cierres de los demás, igual que si estuviera pegado ahí. Cargarlos desde fuera no funcionaría.

Consecuencias:

- **Los cuatro archivos no se pueden ejecutar ni analizar por separado.** PSScriptAnalyzer no ve que un cierre definido en `Ayudantes` se usa en `Eventos` y lo daría por "asignado y nunca usado"; por eso `PSScriptAnalyzerSettings.psd1` excluye `PSUseDeclaredVarsMoreThanAssignments`, con la justificación al lado. El acoplamiento es inherente al diseño de cierres de la ventana; la división solo lo reparte en archivos legibles.
- **Nada de ahí puede depender de `$PSScriptRoot`**, porque no es fiable saber en qué archivo físico se ejecuta cada fragmento. La carpeta de la interfaz está en `$estado.CarpetaUi`, resuelta una vez al principio.
- **Al cargarse, cada archivo solo define cierres.** Las referencias cruzadas (el temporizador de `Analisis` llama a `$terminarBorrado`, definido en `Eliminacion`) viven dentro de scriptblocks que no se evalúan hasta que los cuatro están cargados. El orden de carga se mantiene por legibilidad.

La lógica de interfaz que no necesita WPF está fuera de ese cuerpo, en archivos con funciones normales que las pruebas cargan en cualquier sistema: `Xaml.ps1`, `Atajos.ps1`, `Lotes.ps1`, `Posicion.ps1` y `Dialogs.ps1` (este último sí usa WPF para mostrar el diálogo, pero calcula su contenido aparte).

---

## 4. Decisiones de frontera

### 4.1. `Guard.ps1` no se divide

Todas sus funciones son caras del mismo veredicto: *¿se puede borrar esta ruta?* `Test-RutaIntocable` y `Get-MotivoBloqueo` dependen de una única fuente de verdad, `Get-MotivoIntocable`; con dos listas de comprobaciones separadas acabarían divergiendo, y repartir el archivo reintroduciría ese riesgo. Un archivo de seguridad se audita mejor entero.

El criterio para dividirlo algún día no debería ser el tamaño, sino la aparición de una segunda pregunta distinta de "¿se puede borrar esto?".

### 4.2. Un archivo por módulo de limpieza

Cada archivo de `src/Modules/` es una categoría, se registra solo y no define funciones propias fuera de su bloque `Buscar` y su `New-ModuloLimpieza` (no podría: se carga dentro de `Get-ModulosLimpieza` y sus funciones desaparecerían). Lo que comparten varios módulos va al núcleo: `Steam.ps1`, `Registry.ps1`, `Ejecutables.ps1`, `Invoke-BusquedaPorLista`.

`90-Arranque.ps1` consulta cuatro fuentes distintas (registro, carpetas de Inicio, servicios y tareas programadas) en secciones separadas y emite bajo tres categorías; si crece, esa es la frontera natural para partirlo.

### 4.3. `Report.ps1`: un archivo, funciones pequeñas

Todas sus funciones cambian por el mismo motivo (el formato de los informes), así que es un solo archivo. Dentro, el CSS del HTML (`Get-InformeEstiloCss`) y la suma de bytes (`Measure-TotalBytes`) están extraídos para que haya una sola forma de calcular cada cosa.

También contiene la lectura de informes: `Get-CarpetaInformes`, `Get-InformesGuardados` y `Resolve-InformeAbrible`. Esta última es una **guardia**: es la única puerta por la que el programa abre un archivo con el programa predeterminado del sistema, y la ruta puede venir de `historial.json`, que es texto plano en una carpeta escribible. Las condiciones que exige están en [`SECURITY.md`](../SECURITY.md).

### 4.4. `Invoke-BusquedaPorLista`

`10-Caches`, `65-LogsSistema`, `70-WindowsUpdate` y `33-Juegos` recorren listas de rutas conocidas con el mismo patrón: medir cada ruta, comprobar el umbral, pasar la guardia y emitir el candidato. Ese bucle vive en `Invoke-BusquedaPorLista` (`Candidate.ps1`). Cada módulo conserva su umbral, su categoría y sus textos.

`80-ArchivosSistema` se queda fuera a propósito: recorre archivos sueltos, no carpetas, y todos sus candidatos son informativos. Meterlo obligaría a la función común a tener un interruptor por llamante. `tests/BusquedaPorLista.Tests.ps1` fija los candidatos exactos que produce cada módulo.

### 4.5. `Comandos.ps1`

La pregunta "qué programa externo puede lanzar este código, y de dónde sale" tiene una sola respuesta, en un solo archivo, con dos puertas separadas:

- `Resolve-EjecutablePermitido`: la lista blanca cerrada del **motor de borrado** (DISM y Docker).
- `Resolve-EjecutableDeSistema`, `Get-RutaExplorador` y `Get-RutaPowerShell`: programas del sistema anclados a `%SystemRoot%`, nunca resueltos por `PATH`.

Sus pruebas están en `tests/Comandos.Tests.ps1`. La tabla completa de lo que se puede ejecutar está en [`SECURITY.md`](../SECURITY.md).

### 4.6. El XAML, partido por paneles

`MainWindow.xaml` es el armazón y cada panel vive en su `Panel.*.xaml`. Los paneles **se pegan como texto antes de interpretar** (`Expand-PanelesXaml`, en `Xaml.ps1`), no se cargan por separado: `Window.ps1` resuelve los controles con `FindName` sobre la ventana, y `FindName` solo busca en el ámbito de nombres donde se declaró cada nombre. Con paneles cargados aparte, cada uno tendría su propio ámbito y las búsquedas devolverían `$null`.

Una prueba monta el documento y lo compara byte a byte con `tests/datos/MainWindow.montado.esperado.xaml`. `Expand-PanelesXaml` vive en su propio archivo porque `Window.ps1` carga los ensamblados de WPF, que solo existen en Windows.

---

## 5. Pares que se separaron

### 5.1. `Log.ps1` y `Historial.ps1`

Dos registros con vidas distintas. El **registro de actividad** es una línea por acción, sirve para auditar, crece durante la ejecución y se rota por meses. El **historial** es una entrada por ejecución (las cien últimas), se lee y se reescribe entero al terminar, de forma atómica.

### 5.2. `Config.ps1` y `Preferencias.ps1`

`Config.ps1` describe el **equipo**: unidades, carpetas conocidas, permisos de administrador y umbrales del perfil. Se recalcula en cada arranque y nunca se guarda. `Preferencias.ps1` describe al **usuario**: tema, perfil, umbrales, módulos activos y exclusiones. Sobrevive entre sesiones en `preferencias.json` y puede haberse editado a mano, así que se lee con desconfianza.

### 5.3. `Registry.ps1`, `Ejecutables.ps1` y `Steam.ps1`

Los tres son lectores del estado del equipo, todos de solo lectura, pero con consumidores distintos:

- `Registry.ps1` construye el vocabulario de programas instalados; lo usa `30-RestosProgramas`.
- `Ejecutables.ps1` resuelve ejecutables de líneas de comando, el estado de las entradas de arranque y el destino de los accesos directos; lo usan `90-Arranque` y `45-AccesosRotos`.
- `Steam.ps1` lee las bibliotecas de Steam; lo usa `33-Juegos`.

### 5.4. `Progreso.ps1` y las funciones de unidad

`Test-Cancelacion` y `Set-Progreso` las usan todos los módulos y no miden nada del disco: son la comunicación con la ventana, así que tienen su propio archivo en lugar de vivir en `FileSystem.ps1`. En `FileSystem.ps1`, las propiedades de tamaño de una unidad se leen con una sola función (`Get-PropiedadUnidad`) en lugar de una por propiedad, para que cualquier arreglo de la consulta se haga una vez.

---

## 6. `Texto.ps1` y `Format.ps1`

Las dos trabajan con texto, pero para cosas opuestas:

- `Texto.ps1` normaliza para **comparar identidad**: decidir si dos nombres se refieren a la misma cosa. De ella dependen la guardia y la detección de restos; un cambio aquí puede hacer que la guardia deje de reconocer una carpeta protegida. Sus consumidores (`Guard.ps1`, `Registry.ps1`, `30-RestosProgramas`) no usan ninguna función de formato.
- `Format.ps1` es **presentación**: tamaños, tiempos y rutas para mostrar, sin efectos secundarios.

---

## 7. Carga por dot-sourcing, no como módulo de PowerShell

El núcleo se carga dot-sourceando archivos, no con `Import-Module`. Mover código entre archivos es así barato y reversible; con un módulo de PowerShell, cada movimiento obligaría a tocar la lista de exportación. La contrapartida es que todas las funciones del núcleo son visibles para quien lo carga.

Una función que localizase `Bootstrap.ps1` no puede vivir dentro del propio núcleo (no se podría llamar antes de cargarlo), así que cada punto de entrada construye esa ruta por su cuenta.
