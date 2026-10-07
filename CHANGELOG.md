# Registro de cambios

Todos los cambios relevantes de este proyecto se documentan en este archivo.

El formato se basa en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto sigue [versionado semántico](https://semver.org/lang/es/).

## [2.0.1] — 2026-10-07

### Corregido

- El índice guardado del análisis de espacio se reemplaza de forma atómica también en PowerShell 5.1: un corte a mitad ya no puede dejarlo sin archivo.
- Las limpiezas terminadas anotan en el historial qué módulos han tocado, igual que las interrumpidas.
- Los enlaces duros se detectan también en PowerShell 7, con el índice de archivo de Windows en lugar de `Target`.

### Cambiado

- Cuando lo marcado no ocupa nada (carpetas vacías, accesos rotos), la barra de selección lo dice así en vez de «se recuperarían 0 B».
- La comparación con el análisis anterior explica con más claridad por qué no sirve para comparar.

## [2.0.0] — 2026-10-03

Reescritura completa y primera versión publicada. La 1.0 era un script con interfaz WinForms y varios scripts sueltos que había que ejecutar a mano y en orden; la 2.0 es un solo programa con interfaz WPF, modo consola y una guardia de seguridad probada de forma exhaustiva.

### Añadido

- Interfaz WPF con tema claro y oscuro (la primera vez sigue el de Windows), seis paneles, estado de los discos y resultados agrupados por categoría con su nivel de riesgo. Perfiles de limpieza conservador, equilibrado, exhaustivo y personalizado.
- Arquitectura modular: 21 módulos de limpieza, uno por archivo en `src/Modules/`, que el programa descubre solo. Entre ellos, cachés de aplicaciones y navegadores, restos de programas dentro y fuera de AppData, juegos y plataformas de juego, aplicaciones de la Store, duplicados por SHA-256, Windows Update, WinSxS mediante DISM, WSL y Docker, y arranque roto.
- Módulos informativos, que nunca borran y explican cómo recuperar el espacio desde Windows: archivos grandes, archivos del sistema (`hiberfil.sys`, `pagefile.sys`, puntos de restauración), arranque y perfiles de usuario abandonados.
- Modo consola (`-Consola`) con selección de módulos, informes, modo silencioso para tareas programadas, `-Listar` y `-Diagnostico`.
- Modo simulación (*Solo simular* en la ventana, `-Simular` en consola): muestra lo que se borraría sin tocar nada y sin dejar informe ni entrada en el historial.
- Exclusiones del usuario: carpetas y elementos que no se tocan nunca, gestionables desde *Ajustes* o con `-Excluir`.
- Análisis de espacio (`-Espacio`): búsqueda por comodines, mapa de árbol en SVG y un índice guardado que se reutiliza durante una semana, avisando de la antigüedad de los datos (`-Recorrer` fuerza una medición nueva).
- Informes HTML, CSV y JSON con opción de anonimizar rutas, historial de las cien últimas ejecuciones y comparación de cada análisis con el anterior.
- Tabla de resultados con menú contextual (abrir ubicación, copiar ruta, excluir, desmarcar el grupo), doble clic para abrir la carpeta y opción de ocultar lo ya eliminado.
- Atajos de teclado (`F5`, `Ctrl+F`, `Ctrl+A`, `Esc`, `Ctrl+1` a `Ctrl+6`) y nombres accesibles para lectores de pantalla en todos los controles.
- Distribución: `.zip` con `Cachivache.exe` compilado desde el código etiquetado, sumas SHA-256 y manifiestos de Scoop y winget generados en cada publicación.

### Cambiado

- El borrado envía a la papelera por defecto. Si un elemento no cabe en ella, no se borra y se explica, en lugar de dejar que Windows lo elimine de forma permanente; al terminar se indica qué se puede rescatar.
- Las unidades extraíbles se analizan e informan, pero nunca se propone borrar nada en ellas.
- En archivos comprimidos con NTFS se promete el espacio que de verdad se libera (tamaño en disco), no el tamaño lógico.
- En duplicados se conserva la copia mejor ubicada (bibliotecas antes que Descargas), no simplemente la más antigua.
- La detección de restos consulta ocho fuentes con evidencia fuerte y débil, recorre `AppData\LocalLow` y baja un segundo nivel en carpetas de editores.
- El lanzador ya no pide permisos de administrador (los módulos que los necesitan se activan con *Reiniciar como administrador*), y registros, informes, historial y preferencias viven en `%LOCALAPPDATA%\Cachivache`: el programa no escribe en su propia carpeta.
- Rendimiento: un solo runspace por análisis, recorridos con poda en carpetas vacías y proyectos, y marcado de miles de filas por tandas sin congelar la ventana.

### Corregido

- Las rutas de más de 260 caracteres se encuentran, se miden y se borran correctamente.
- Buscar duplicados ya no descarga archivos de OneDrive a petición, y esos archivos ya no prometen espacio que no está en el disco.
- Un análisis cancelado o con módulos fallidos se presenta como incompleto, y una limpieza detenida se anota en el historial como interrumpida.
- Un borrado fallido ya no se muestra como correcto ni suma bytes al total liberado.
- La simulación aplica las mismas comprobaciones que el borrado real.
- Un informe, las preferencias o el historial que no se pueden escribir ya no se dan por guardados.
- El modo consola con `-Ejecutar` fallaba al empezar a borrar.
- Varias incompatibilidades con Windows PowerShell 5.1 que dejaban sin efecto el índice de espacio y la ordenación por tamaño.
- Interfaz: la tabla ya no vuelve al principio al terminar cada módulo, los controles ya no se superponen al estrechar la ventana (que ahora cabe en un portátil con escalado al 150 %), y el diálogo de confirmación ya no dice «Eliminar definitivamente» cuando el destino es la papelera.

### Seguridad

- La pertenencia a una carpeta autorizada se comprueba con los atributos reales de cada carpeta del camino: una junction ya no permite alcanzar archivos fuera de la lista blanca.
- Cada elemento se revalida justo antes de borrarlo (guardia, exclusiones y tipo de unidad), comandos externos incluidos.
- Lista blanca de programas externos reducida a DISM, anclado a `System32`, y Docker, resuelto por sus rutas de instalación; se retira `npm`. `explorer.exe`, `powershell.exe` y las consultas de sistema se resuelven bajo `%SystemRoot%`, nunca por `PATH`.
- Las carpetas personales con tilde (`Imágenes`, `Música`, `Vídeos`) y las copias de seguridad con doble extensión (`.kdbx.bak`) quedan protegidas.
- Lo que lleva aviso nunca viene marcado, por construcción.
- La pestaña *Informes* solo abre informes `.html`, `.csv` y `.json` de la carpeta de informes, revalidados en cada clic.
- El informe CSV neutraliza las celdas que una hoja de cálculo evaluaría como fórmula.
- El nombre del equipo ya no aparece en registros ni informes.

## [1.0.0] — 2025-08-15

### Añadido

- Primera versión: `Cachivache.ps1` con interfaz WinForms y ocho pasos de limpieza, más scripts sueltos de auditoría y limpieza por fases.

[2.0.1]: https://github.com/soypacodev/cachivache/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/soypacodev/cachivache/releases/tag/v2.0.0
