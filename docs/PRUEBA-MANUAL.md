# Prueba manual en Windows

La suite de Pester, el analizador y la integración continua cubren el núcleo, los módulos y el modo consola. La ventana WPF no se puede ejecutar en esas pruebas, así que lo que el usuario ve y toca se comprueba a mano con esta lista.

**Cuándo pasarla:** después de tocar algo en `src/UI/` y antes de publicar una versión. Cada bloque es independiente; si hay poco tiempo, haz los bloques 1, 2 y 5.

**Reglas:**

- No actives el **borrado permanente**: todo lo borrado durante la prueba debe poder recuperarse de la papelera.
- Si algo falla, guarda una captura y el registro de `%LOCALAPPDATA%\Cachivache\registros\`, que incluye el tipo de excepción y la línea.
- Si algo se ve raro aunque no esté en la lista, anótalo igualmente.

Para el borrado real sobre archivos preparados, en una máquina virtual, ver [`BANCO-PRUEBAS.md`](BANCO-PRUEBAS.md).

---

## Antes de empezar

Anota la versión de PowerShell. El programa arranca con Windows PowerShell 5.1, y las diferencias con la 7 son la fuente más habitual de fallos que las pruebas automáticas no ven:

```powershell
$PSVersionTable.PSVersion
```

Si conservas informes de análisis anteriores, tenlos a mano como referencia: un análisis nuevo con el mismo perfil debería proponer aproximadamente lo mismo.

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Cachivache\informes" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, LastWriteTime, Length
```

---

## 1. Arranque

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | Doble clic en `tools\Crear-ejecutable.bat` | Compila `Cachivache.exe` sin pedir abrir PowerShell ni cambiar la política de ejecución. La ventana se queda abierta al terminar y muestra un tamaño de unas decenas de KB |
| ☐ | Doble clic en `Cachivache.exe` | Se abre la ventana **sin ninguna consola detrás** |
| ☐ | Mira el icono del `.exe` en el Explorador y el de la barra de tareas | El icono de Cachivache en los dos, no el genérico de .NET ni el de PowerShell |
| ☐ | Mira el tema con el que abre | La primera vez coincide con el de Windows (claro u oscuro); después, recuerda la última elección |
| ☐ | En **Acerca de** (`Ctrl+6`), mira la versión | Es la que se está probando |

Si Windows muestra un aviso de SmartScreen al abrir el `.exe`, es porque no está firmado. Se puede usar `Cachivache.bat` en su lugar.

---

## 2. Primera ejecución sin riesgo: simular

Analiza con el perfil **Equilibrado**. En el pie de Resultados, marca **Solo simular** y pulsa el botón.

| | Qué tiene que pasar |
|---|---|
| ☐ | Al marcar la casilla, el botón pasa a decir **Simular limpieza** y deja de ser rojo |
| ☐ | Al pulsarlo no aparece el diálogo de confirmación |
| ☐ | Durante la simulación la barra dice *Midiendo…*, no *Eliminando…* |
| ☐ | Al terminar, Resultados muestra un cartel con las cifras y el registro dice **NO SE HA BORRADO NADA** |
| ☐ | Las filas siguen marcadas y ninguna aparece como eliminada |
| ☐ | En **Informes** no hay un informe de limpieza nuevo ni una entrada nueva en el historial |
| ☐ | Si cambias la selección, el cartel de la simulación desaparece |
| ☐ | Al cerrar y reabrir el programa, *Solo simular* vuelve a estar desmarcada |

---

## 3. Análisis

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | Mira la lista de discos en **Inicio** | Aparecen todas las unidades, con letra, etiqueta y espacio usado. El espacio libre coincide con el Explorador |
| ☐ | Analiza con el perfil **Equilibrado** y cronométralo | Termina sin franja de aviso. Anota el tiempo para compararlo entre versiones |
| ☐ | Mira el texto bajo la barra de progreso mientras analiza | Indica el módulo en curso, el tiempo transcurrido y los elementos encontrados |
| ☐ | Desmarca un disco y vuelve a analizar | No aparece ningún candidato de esa unidad |
| ☐ | Pulsa **Cancelar** a mitad de un análisis | Se detiene en el acto, la ventana responde y Resultados indica que el análisis está incompleto |
| ☐ | Lanza dos análisis seguidos sin cerrar el programa | El segundo funciona igual que el primero. La memoria del proceso en el Administrador de tareas no crece sin parar entre análisis |
| ☐ | Mira el resumen del segundo análisis | Se compara con el anterior (*«hace N días eran…»*). En el primer análisis no se compara nada |
| ☐ | Cambia de tema durante un análisis | Los colores cambian y el análisis continúa |

### Unidades extraíbles

Con una llave USB o un disco externo conectado **antes de abrir el programa**:

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | Mira la lista de discos | La unidad aparece y se puede analizar |
| ☐ | Analiza y filtra Resultados por su letra | Lo que aparezca indica que se ha medido pero no se borra nada en esa unidad |
| ☐ | Intenta eliminar algo de esa unidad | No se borra |

Un disco externo que Windows declare como *fijo* se trata como un disco interno: es una limitación del sistema, no del programa.

### Archivos comprimidos con NTFS

Comprime una carpeta (*Propiedades → Opciones avanzadas → Comprimir contenido*) que contenga algo que el programa proponga:

| | Qué tiene que pasar |
|---|---|
| ☐ | El elemento muestra lo que ocupa y lo que de verdad se liberará |
| ☐ | La cifra que promete liberar coincide con el *Tamaño en disco* del Explorador, no con el *Tamaño* |
| ☐ | El total del pie suma las cifras de liberación, no los tamaños |

---

## 4. La tabla de resultados

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | Escribe `cache` en el filtro | La lista se reduce un instante después de dejar de escribir, sin perder letras |
| ☐ | Escribe `*` y luego `[` | Se buscan como texto literal, no como comodines |
| ☐ | Cambia el desplegable de riesgo | Filtra al momento |
| ☐ | Marca y desmarca casillas | El pie actualiza número de elementos y bytes al instante |
| ☐ | Pulsa *Marcar todo* sin filtro y después escribe un filtro | El pie indica cuántos marcados no se están mostrando |
| ☐ | Pon un filtro, pulsa *Marcar todo* y quita el filtro | Solo quedan marcadas las filas que estaban a la vista |
| ☐ | Escribe `zzzzz` en el filtro y elige *Solo riesgo alto* | La tabla explica que el filtro no deja pasar nada y ofrece **Quitar los dos filtros**; al pulsarlo vuelve la tabla entera |
| ☐ | Abre Resultados antes de analizar | Se ve un mensaje explicativo, no un rectángulo en blanco |
| ☐ | Durante un análisis largo (perfil **Exhaustivo**), baja hasta la fila 200 y selecciona una fila | Al terminar cada módulo, la tabla no vuelve al principio y la fila sigue seleccionada |
| ☐ | Con la tabla desplazada, cambia de tema | Los colores cambian y la posición se mantiene |
| ☐ | Clic derecho sobre una fila | La fila queda seleccionada y el menú (*Abrir ubicación · Copiar ruta · Excluir siempre esto · Desmarcar el grupo*) se lee bien en los dos temas |
| ☐ | *Copiar ruta* en una fila normal y pégala en el Explorador | Llega a la carpeta |
| ☐ | *Copiar ruta* sobre algo sin ruta real (la papelera, un comando) | Aparece un aviso y el portapapeles no cambia |
| ☐ | Doble clic en una fila | Abre su carpeta. Sobre una cabecera de columna, ordena |
| ☐ | Con miles de filas, pulsa *Marcar todo* | La ventana no se congela y los botones de eliminar se desactivan mientras dura |

Si la posición de la tabla no se restaura, el registro debe contener un aviso *«No se ha podido restaurar la posición de la tabla»*.

---

## 5. Borrado

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | Comprueba los elementos con aviso | Salen en rojo y sin marcar |
| ☐ | Marca dos o tres elementos de riesgo Bajo sin aviso y pulsa *Eliminar lo marcado* | El diálogo indica *Papelera de reciclaje* como destino, el botón dice **Enviar a la papelera** y pide escribir `SI` |
| ☐ | Confirma y abre la papelera de Windows | Los elementos están ahí y se pueden restaurar. El programa ofrece **Abrir la papelera** e indica qué se puede rescatar |
| ☐ | Marca algo de riesgo Medio o Alto y pulsa *Eliminar lo marcado* | La confirmación exige escribir `ELIMINAR`, y los elementos de riesgo aparecen listados. **Cancela** |
| ☐ | Con muchos elementos marcados, abre el diálogo | Los botones *Cancelar* y *Eliminar* quedan dentro de la pantalla; `Esc` cancela desde cualquier foco |
| ☐ | Si hay un comando externo marcado (DISM, Docker), abre el diálogo | El comando se muestra completo, sin recortar. **Cancela** |
| ☐ | Provoca un fallo (un archivo abierto en otro programa) y elimina | Lo que falla sale en rojo con su motivo y sigue marcado; el resumen no lo cuenta como liberado |
| ☐ | Marca **Ocultar lo ya eliminado** | Desaparece lo borrado; lo que falló sigue visible |
| ☐ | Cierra la ventana durante una limpieza y vuelve a abrir | El historial tiene una entrada de limpieza interrumpida con lo que llegó a borrarse |
| ☐ | Mira `%LOCALAPPDATA%\Cachivache\registros` | Hay una línea por acción, con el identificador de sesión |

---

## 6. Exclusiones

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | *Excluir siempre esto* sobre algo inofensivo | Pide confirmación e indica que se puede quitar en Ajustes. Al aceptar, la fila se desmarca |
| ☐ | **Ajustes → Lo que no se toca nunca** | La exclusión aparece con la ruta completa |
| ☐ | Excluye algo que no es una carpeta (la papelera, la caché de Docker) | En Ajustes se lee con su nombre legible, no con la clave interna |
| ☐ | Pulsa **Quitar** en una exclusión | Desaparece sin pedir confirmación y el registro lo anota |
| ☐ | Cierra y reabre el programa | Las exclusiones se conservan |

---

## 7. Disposición, temas y ventana

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | Recorre los seis paneles: Inicio, Resultados, Registro, Informes, Ajustes y Acerca de | Ninguno aparece vacío, descolocado ni a medias |
| ☐ | Estrecha la ventana hasta su mínimo | Nada se superpone: en Resultados, *Ocultar lo ya eliminado* baja de línea; en el pie, el recuento de marcados y *Solo simular* no se pisan; en Registro y Ajustes, los textos y los botones no se cruzan |
| ☐ | Prueba en una pantalla de 1366×768 con escalado al 150 % | La ventana cabe y el botón de eliminar se alcanza |
| ☐ | Maximiza la ventana, también con la barra de tareas en otro borde o en otro monitor | No queda por debajo de la barra de tareas |
| ☐ | Cambia de tema en cada panel | Todo legible en claro y en oscuro; los niveles de riesgo se distinguen bien |
| ☐ | Pasa el ratón por botones y filas | Se ven los estados de hover y foco; el botón de cerrar se pone rojo |

---

## 8. Teclado y lector de pantalla

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | `Ctrl+1` … `Ctrl+6` (fila de números y teclado numérico) | Cambian de panel |
| ☐ | `F5` | Analiza; con un análisis en marcha no hace nada |
| ☐ | `Esc` durante un análisis | Lo cancela |
| ☐ | `Ctrl+F` | Va a Resultados con el foco en el filtro |
| ☐ | `Ctrl+A` dentro del filtro y fuera de él | Dentro selecciona el texto; fuera marca la tabla |
| ☐ | Escribe en el filtro | Las letras llegan al cuadro |
| ☐ | `Supr` en la tabla | No elimina nada |
| ☐ | Flechas sobre la barra lateral | No cambian de panel: Tab recorre y Espacio activa |
| ☐ | Tab por toda la ventana | No hay paradas vacías |
| ☐ | Narrador (`Ctrl+Win+Enter`) en la barra de título | Anuncia *Cambiar entre tema oscuro y claro*, *Minimizar la ventana*, *Maximizar o restaurar la ventana*, *Cerrar Cachivache* |
| ☐ | Narrador al cambiar de panel y sobre la casilla de una fila | Anuncia el panel mostrado y el nombre del elemento |

---

## 9. Acerca de, diagnóstico e informes

| | Qué hacer | Qué tiene que pasar |
|---|---|---|
| ☐ | Pulsa **Buscar si hay una versión nueva** y arrastra la ventana mientras consulta | La ventana se mueve. Termina con la última versión publicada o con *No se ha podido comprobar* |
| ☐ | Abre y cierra **Acerca de** sin pulsar ese botón | No se hace ninguna consulta de red |
| ☐ | **Copiar diagnóstico** y compáralo con `.\Cachivache.ps1 -Diagnostico` | Es el mismo texto |
| ☐ | Marca **Anonimizar rutas**, guarda un informe HTML y busca tu nombre de usuario | No aparece. Repite con CSV y JSON |
| ☐ | En **Informes**, abre un informe de cada formato | Se abre con el programa predeterminado |

---

## 10. Enlaces duros

La CI no puede comprobarlo: el disco de los runners de GitHub no admite enlaces duros y esas pruebas se omiten. Desde un símbolo del sistema:

```
mkdir %TEMP%\cachivache-enlaces
cd /d %TEMP%\cachivache-enlaces
fsutil file createnew original.bin 10000000
mklink /H copia.bin original.bin
```

| | Qué tiene que pasar |
|---|---|
| ☐ | Medido desde el programa, el contenido cuenta **10 MB, no 20** |
| ☐ | El módulo de duplicados **no** propone `copia.bin`: es el mismo archivo con otro nombre |

Al terminar: `rmdir /s /q %TEMP%\cachivache-enlaces`. La respuesta que cuenta es la de Windows PowerShell 5.1; en PowerShell 7 la detección de enlaces duros no está disponible.

---

## 11. Modo consola

En la consola `$ErrorActionPreference` vale `Stop`, así que un error no terminante se comporta distinto que en la ventana.

```powershell
.\Cachivache.ps1 -Listar
.\Cachivache.ps1 -Consola -Perfil conservador -Informe .\informe.html
.\Cachivache.ps1 -Consola -Ejecutar -Simular
.\Cachivache.ps1 -Espacio
.\Cachivache.ps1 -Diagnostico
```

| | Qué tiene que pasar |
|---|---|
| ☐ | `-Listar` muestra los 21 módulos |
| ☐ | El análisis termina sin excepciones y escribe `informe.html`; sus cifras cuadran con las de la ventana |
| ☐ | `-Simular` anota cada elemento en el registro con el nivel `SIMULACION` y termina con **NO SE HA BORRADO NADA** |
| ☐ | La segunda ejecución de `-Espacio` reutiliza el índice guardado y lo dice; `-Recorrer` fuerza una medición nueva |
| ☐ | `-Diagnostico` muestra versión, entorno, unidades y las últimas líneas del registro |

`Cachivache.exe` se compila como aplicación de ventana y no muestra salida de consola: para el modo consola usa `Cachivache.bat` o PowerShell directamente.

---

## Si algo falla

Lo que hace falta para localizarlo:

1. El mensaje completo, con la línea `archivo: línea` si la hay. Una captura vale.
2. La salida de `.\Cachivache.ps1 -Diagnostico`.
3. Qué esperabas y qué pasó.

Si el fallo es que el programa **propone borrar algo que no debería**, no lo publiques como incidencia: sigue [`SECURITY.md`](../SECURITY.md).
