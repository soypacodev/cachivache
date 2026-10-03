# Arquitectura

Guía para entender el código y para escribir módulos nuevos. El reparto de responsabilidades entre archivos se explica en [`ESTRUCTURA.md`](ESTRUCTURA.md).

---

## Idea central

Todo lo que el programa sabe limpiar vive en **módulos independientes** dentro de `src/Modules/` (hoy, 21). El resto del código no conoce ningún módulo concreto: `Get-ModulosLimpieza` los descubre al arrancar leyendo la carpeta.

Añadir una categoría de limpieza es escribir un archivo. No hay ninguna lista central que actualizar.

```
Cachivache.ps1 ──┬── src/Cli/      modo consola (-Consola, -Espacio, -Listar, -Diagnostico)
                 └── src/UI/       ventana WPF
                        │
                 src/Core/Bootstrap.ps1  ── carga el núcleo (src/Core/*.ps1)
                        │
                 src/Modules/NN-*.ps1    ── un archivo por categoría de limpieza
```

---

## Carga del núcleo

El núcleo se carga **dot-sourceando** `src/Core/Bootstrap.ps1`:

```powershell
. (Join-Path (Join-Path (Join-Path $Raiz 'src') 'Core') 'Bootstrap.ps1')
```

El cargador es un script y no una función a propósito: una función que dot-sourcea archivos los carga en su propio ámbito, y las definiciones desaparecen al terminar. Dot-sourceando el script, todo queda en el ámbito de quien llama. El mismo `Bootstrap.ps1` lo cargan el proceso principal y el runspace de trabajo, así que los dos ejecutan exactamente el mismo código.

El orden de carga es una lista explícita, no alfabética, y está comentada en el propio `Bootstrap.ps1`. Como todo se carga antes de ejecutar nada, una llamada "hacia delante" no falla; el orden sirve para que las dependencias se lean de arriba abajo (`Texto` antes que `Guard`, `Profiles` y `FileSystem` antes que `Config`, `Papelera` antes que `Remove`).

Los módulos se cargan igual, dot-sourceados dentro de `Get-ModulosLimpieza`. Por eso un módulo no puede declarar funciones auxiliares: desaparecerían al terminar esa función. La lógica compartida va en `src/Core/`.

---

## Escribir un módulo

Un módulo es un archivo `.ps1` en `src/Modules/` cuyo nombre empieza por dos dígitos que fijan el orden. El archivo **termina** devolviendo el objeto que crea `New-ModuloLimpieza`.

```powershell
<#
.SYNOPSIS
    Una frase de qué hace este módulo.
.DESCRIPTION
    Qué busca exactamente y por qué es seguro proponerlo.
#>

$BuscarLoQueSea = {
    param($Configuracion, $Sync)

    # Lista blanca de raíces: solo se podrá borrar lo que cuelgue de aquí.
    $raices = @($env:LOCALAPPDATA)

    foreach ($carpeta in @('MiApp\Cache', 'MiApp\Logs')) {
        if (Test-Cancelacion $Sync) { break }

        $ruta = Join-Path $env:LOCALAPPDATA $carpeta
        if (-not (Test-Path -LiteralPath $ruta)) { continue }

        # Preguntar a la guardia antes de medir: medir cuesta más.
        if (-not (Test-RutaSegura $ruta $raices)) { continue }

        Set-Progreso $Sync "Midiendo: $carpeta"
        $bytes = Measure-Ruta $ruta
        if ($bytes -lt ($Configuracion.MinimoMB * 1MB)) { continue }

        New-Candidato -ModuloId 'miapp' -Categoria 'Mi aplicación' `
                      -Nombre 'Caché de MiApp' -Ruta $ruta -Bytes $bytes `
                      -Info 'Se vacía el contenido; la carpeta se queda.' `
                      -Efecto 'Se regenera al abrir el programa.' `
                      -Metodo 'Contenido' -Raices $raices -Riesgo 'Bajo'
    }
}

New-ModuloLimpieza -Id 'miapp' -Orden 42 `
    -Nombre 'Caché de MiApp' `
    -Descripcion 'Explicación de una o dos líneas que se ve en la pantalla de inicio.' `
    -Riesgo 'Bajo' `
    -Perfiles @('equilibrado', 'agresivo') `
    -Buscar $BuscarLoQueSea
```

Si el módulo recorre una lista fija de carpetas conocidas (como `caches`, `logs` o `windowsupdate`), usa `Invoke-BusquedaPorLista` en lugar de escribir el bucle.

### Reglas del contrato

Las comprueba `tests/Modules.Tests.ps1`; si te saltas alguna, la CI falla.

- **`Id`**: solo letras minúsculas, único.
- **`Orden`**: único. Fija la posición en la interfaz y el orden de ejecución.
- **`Buscar`** declara siempre dos parámetros, `$Configuracion` y `$Sync`, aunque no use alguno.
- **`Perfiles`** solo admite `conservador`, `equilibrado` y `agresivo`. Un módulo de riesgo alto nunca está en `conservador`.
- **`-SoloInforma`** marca un módulo que nunca borra; **`-RequiereAdmin`**, uno que se omite sin permisos de administrador.

### El embudo: lo que el registro garantiza

`Invoke-ModuloLimpieza` pasa todos los candidatos de un módulo por una lista de reglas (`Get-ReglasFiltroCandidato`) antes de entregarlos. Están en el registro y no en cada módulo para que ninguno pueda olvidarse de respetarlas y un módulo nuevo las herede sin escribir nada:

| Regla | Qué descarta |
|---|---|
| Candidato existente | Entradas nulas |
| Unidad seleccionada | Lo que cae en un disco que el usuario ha desmarcado (`Test-UnidadSeleccionada`) |
| Exclusiones del usuario | Lo que el usuario ha marcado como "no tocar nunca" (`Test-ClaveExcluida`) |
| Unidad donde se puede borrar | Lo que está en una unidad analizada que no es fija (extraíble, óptica, de red o sin clasificar): entra en el informe, pero no se propone borrarlo |
| Guardia de rutas | Lo que no pasa `Test-RutaSegura` contra las raíces del candidato |

Propiedades del embudo:

- **Una regla solo puede quitar candidatos, nunca añadirlos.** El resultado es la intersección, así que el orden no cambia lo que sobrevive; se ordenan de barata a cara y la guardia, la única que toca el disco, va la última.
- **Los predicados reciben `($Contexto, $Candidato)` como parámetros**, no `$_` ni cierres con `GetNewClosure()`: un cierre se ejecuta en un módulo dinámico donde no se ven las funciones del núcleo. Hay una invariante que lo vigila.
- **Ante la duda, una regla de unidad no filtra.** Si no hay lista de unidades, o la ruta no tiene letra (un recurso de red, la etiqueta de un comando), el candidato pasa. La guardia sigue aplicándose.
- Los métodos `Informativo`, `Papelera` y `Comando` no tienen una ruta que validar y quedan fuera de las reglas de unidad y de guardia.
- Los descartes se cuentan en `Resultado.Descartados`. La ventana los anota en el registro (`Window.Analisis.ps1`); el modo consola no.

**Si tu módulo razona por unidad, filtra además por su cuenta.** Es el caso de `papelera`: mide varias unidades pero emite un único candidato con la ruta de la unidad del sistema, así que el embudo lo dejaría pasar entero. Ese módulo consulta `Test-UnidadSeleccionada` al medir, y `Clear-Papelera` vacía exactamente las mismas unidades: se vacía lo que se midió.

El motor de borrado (`Invoke-EliminacionCandidato` en `Remove.ps1`) vuelve a comprobar las exclusiones, la existencia de la ruta, la guardia y la clase de unidad justo antes de borrar: entre el análisis y el borrado el disco puede haber cambiado (por ejemplo, una llave USB enchufada después de arrancar).

### Elegir el método de eliminación

| Método | Qué hace | Cuándo usarlo |
|---|---|---|
| `Contenido` | Vacía la carpeta y la deja en su sitio | Cachés. Es el caso normal: muchos programas fallan si su carpeta desaparece |
| `Ruta` | Borra el archivo o la carpeta entera | Archivos sueltos, carpetas que sobran del todo |
| `CarpetaVacia` | Borra un árbol de carpetas vacías, comprobando otra vez que sigue sin archivos | Cadenas de carpetas vacías anidadas |
| `Informativo` | No borra nada | Cuando lo correcto es que lo haga Windows o una persona |
| `Comando` | Ejecuta un programa externo de la lista blanca (`Comandos.ps1`) | DISM, `docker system prune` |
| `Papelera` | Vacía la papelera mediante la API del shell | Solo el módulo `papelera` |
| `FirefoxCache`, `Miniaturas` | Casos especiales con lógica propia | Ver `src/Core/Remove.ps1` |

Por defecto, los métodos que borran archivos los envían a la papelera de reciclaje; `-Permanente` (o la casilla equivalente) borra sin pasar por ella. Antes de enviar un elemento entero (`Ruta`, `CarpetaVacia`), el motor comprueba que cabe en la papelera (`Test-IraAPapelera`): si no cabe, no lo borra y lo explica, en lugar de dejar que Windows lo elimine de forma permanente sin avisar.

### Elegir el riesgo

- **Bajo**: se regenera solo, sin intervención y sin pérdida. Se marca por defecto.
- **Medio**: se puede recuperar, pero cuesta algo (volver a descargar, volver a compilar). No se marca por defecto.
- **Alto**: el programa hace una conjetura sobre la intención del usuario. Nunca se marca por defecto.

La regla de premarcado vive en un solo sitio, `Test-DebeVenirMarcado`: solo se marca lo de riesgo bajo, sin aviso y que no sea informativo. Rellenar `-Aviso` fuerza que el elemento salga en rojo y sin marcar, sea cual sea el riesgo; úsalo cuando haya algo concreto que el usuario debe saber (partidas guardadas dentro, un programa abierto que bloquea archivos, un comprimido que puede contener cualquier cosa).

Para el tamaño, pasa `-TamanoEnDisco` cuando lo conozcas (archivos comprimidos con NTFS): `Bytes` pasa a ser lo que de verdad se liberará, calculado por `Get-EspacioRecuperable`. `$null` significa "no lo sé", no cero.

---

## Concurrencia

El análisis y la eliminación no pueden ejecutarse en el hilo de la ventana: lo bloquearían durante minutos.

```
Hilo de la interfaz                    Runspace de trabajo
───────────────────                    ───────────────────
lanzarTrabajo ──────────────────────►  carga Bootstrap.ps1
                                       Initialize-Guardia
DispatcherTimer (200 ms)               Invoke-ModuloLimpieza
  lee $sync.Mensaje  ◄─────────────┐     escribe $sync.Mensaje
  actualiza etiquetas              │
  ¿$sync.Terminado? ───────────────┴───  $sync.Resultado
       │                                 $sync.Terminado = $true
       ▼
  limpiarTrabajo, siguiente módulo
```

`$sync` es una `[hashtable]::Synchronized(@{})` creada por `New-EstadoSincronizado`. **Nada que toque un control de WPF ocurre fuera del hilo de la interfaz**: el runspace solo escribe datos en la tabla y el temporizador es el que pinta.

**Un solo runspace por operación.** Se abre al empezar el análisis, carga `Bootstrap.ps1` y llama a `Initialize-Guardia` una vez, y ese mismo runspace ejecuta todos los módulos seleccionados, uno detrás de otro. `$limpiarTrabajo` suelta el trabajo de cada módulo; `$cerrarRunspace` cierra el runspace y lo llaman los tres finales posibles: fin de análisis, fin de borrado y cierre de la ventana.

**Cancelación.** La interfaz pone `$sync.Cancelar = $true` y cada bucle de módulo lo consulta con `Test-Cancelacion`. Como un módulo puede pasar minutos midiendo una carpeta sin volver a consultarlo, el botón *Cancelar* además detiene el trabajo en curso y cierra la operación en el acto. Al detenerlo, la línea `$sync.Terminado = $true` del final del guion puede no ejecutarse nunca, así que quien cancela se encarga de cerrar el trabajo.

**Configuración compartida.** La configuración se pasa por referencia al runspace y vive toda la operación, así que modificarla durante un trabajo sería una carrera de datos. Por eso Ajustes, los perfiles y el botón de tema se inhiben mientras `$estado.Ocupado` vale `$true`.

Los módulos se ejecutan **en serie**, no en paralelo: medir tamaños satura el disco, y varios módulos compitiendo por él serían más lentos y harían el progreso incomprensible.

El modo consola (`src/Cli/Cli.ps1`) ejecuta los mismos módulos con las mismas funciones del núcleo, en el propio proceso y sin runspace.

---

## La interfaz

WPF cargado con `XamlReader.Parse`, sin `x:Class` ni manejadores en línea. Los controles se resuelven con un único bucle de `FindName` en `Window.ps1` y los eventos se conectan desde `Window.Eventos.ps1`.

**El XAML está partido por paneles.** `MainWindow.xaml` es el armazón (ventana, barra de título, barra lateral) y cada panel vive en un `Panel.*.xaml`. `Expand-PanelesXaml` (`src/UI/Xaml.ps1`) sustituye cada marca `<!--#panel Archivo.xaml-->` por el contenido del archivo **antes** de interpretar, de modo que WPF ve un único documento con un único ámbito de nombres. Una prueba compara el documento montado con `tests/datos/MainWindow.montado.esperado.xaml` byte a byte.

**La ventana está repartida en cinco archivos.** `Show-VentanaPrincipal` vive en `Window.ps1`, construye la ventana y la tabla `$estado`, y dot-sourcea **desde dentro de sí misma** `Window.Ayudantes.ps1`, `Window.Analisis.ps1`, `Window.Eliminacion.ps1` y `Window.Eventos.ps1`. Así cada trozo se ejecuta en el ámbito de la función y ve `$c`, `$estado`, `$ventana` y los cierres de los demás. Esos cuatro archivos no se pueden ejecutar ni razonar por separado; ver [`ESTRUCTURA.md`](ESTRUCTURA.md#3-la-ventana-repartida-en-cinco-archivos).

**Lógica de interfaz sin WPF.** Lo que se puede calcular sin una ventana vive en archivos aparte que las pruebas cargan en cualquier sistema: `Atajos.ps1` (atajos de teclado), `Lotes.ps1` (marcar miles de filas por tandas), `Posicion.ps1` (restaurar el desplazamiento de la tabla y la altura máxima de los diálogos) y `Xaml.ps1`.

**Temas.** `Theme.Dark.xaml` y `Theme.Light.xaml` definen las mismas claves con distintos valores. `Styles.xaml` las consume con `DynamicResource`, así que cambiar de tema es sustituir un diccionario en `Application.Resources`. Los colores que viajan como cadenas en los objetos de vista (las etiquetas de riesgo) se recalculan a mano.

**Tipos.** WPF necesita `INotifyPropertyChanged` para que una casilla marcada actualice el resumen del pie. Un `PSCustomObject` no lo implementa, así que `src/UI/Types.ps1` compila con `Add-Type` la clase `Cachivache.ItemVista`. No depende de WPF: colores y visibilidades viajan como cadenas y el enlace de datos las convierte. La correspondencia entre las propiedades del candidato y las de `ItemVista` la vigila `tests/Contrato.Tests.ps1`.

---

## Análisis de espacio (`-Espacio`)

Además de proponer limpiezas, el programa responde a "dónde se ha ido el espacio" sin proponer nada:

- `Indice.ps1` recorre las carpetas una sola vez y construye el índice en memoria (`New-IndiceDisco`).
- `IndicePersistente.ps1` lo guarda y lo lee en binario, con escritura atómica, en `%LOCALAPPDATA%\Cachivache\indices`.
- `IndiceEspacio.ps1` e `IndiceIncremental.ps1` deciden si un índice guardado se puede reutilizar: solo para las mismas carpetas, del mismo volumen y con menos de una semana. Reutilizarlo no renueva su fecha, y la salida avisa de que los datos son de cuando se guardó (`-Recorrer` fuerza una medición nueva).
- `VistaArchivos.ps1` es la capa de consulta (archivos por tamaño, búsqueda por comodines sin `-like`), y `Mapa.ps1` calcula el mapa de árbol que `ReportEspacio.ps1` dibuja en SVG.

El índice solo sirve para mostrar: **nunca decide qué se borra**.

---

## Dónde tocar cada cosa

| Quiero… | Archivo |
|---|---|
| Añadir una categoría de limpieza | `src/Modules/NN-Loquesea.ps1` |
| Cambiar qué se puede borrar | `src/Core/Guard.ps1` **y sus pruebas** |
| Cambiar los filtros comunes a todos los módulos | `Get-ReglasFiltroCandidato` en `src/Core/ModuleRegistry.ps1` |
| Cambiar cómo se borra | `src/Core/Remove.ps1` |
| Cambiar la comprobación de cuota de la papelera | `src/Core/Papelera.ps1` |
| Cambiar qué programas externos se pueden lanzar | `src/Core/Comandos.ps1` |
| Cambiar cómo se comparan nombres (guardia, restos) | `src/Core/Texto.ps1` **y sus pruebas** |
| Cambiar cómo se muestran tamaños, fechas o rutas | `src/Core/Format.ps1` |
| Cambiar qué unidades se analizan y dónde se puede borrar | `src/Core/Extraibles.ps1`, `src/Core/FileSystem.ps1` |
| Cambiar el aspecto | `src/UI/Styles.xaml`, `Theme.*.xaml` |
| Cambiar la disposición | `src/UI/MainWindow.xaml`, `src/UI/Panel.<Panel>.xaml` |
| Cambiar qué hace un botón o un control | `src/UI/Window.Eventos.ps1` |
| Cambiar cómo se refresca una lista, el filtro o el tema | `src/UI/Window.Ayudantes.ps1` |
| Cambiar el análisis, el runspace o el temporizador | `src/UI/Window.Analisis.ps1` |
| Cambiar la preparación o el cierre del borrado | `src/UI/Window.Eliminacion.ps1` |
| Cambiar el arranque de la ventana o el estado inicial | `src/UI/Window.ps1` |
| Cambiar el diálogo de confirmación | `src/UI/ConfirmDialog.xaml`, `src/UI/Dialogs.ps1` |
| Cambiar los perfiles | `src/Core/Profiles.ps1` |
| Cambiar los informes | `src/Core/Report.ps1`, `src/Core/ReportEspacio.ps1` |
| Cambiar qué se anota en el registro | `src/Core/Log.ps1` |
| Cambiar el historial de ejecuciones | `src/Core/Historial.ps1` |
| Cambiar qué se recuerda entre sesiones | `src/Core/Preferencias.ps1` |
| Añadir un parámetro de consola | `Cachivache.ps1` y `src/Cli/Cli.ps1` |

Los archivos de `src/Core/` están pensados para tener **una sola razón de cambio** cada uno. Si un cambio obliga a tocar tres, merece la pena preguntarse si falta una pieza compartida.
