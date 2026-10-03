<#
.SYNOPSIS
    Carga todo el núcleo en el ámbito de quien lo invoca.

.DESCRIPTION
    Se carga con dot-sourcing, nunca se ejecuta:

        . (Join-Path $raiz 'src\Core\Bootstrap.ps1')

    Es un script y no una función porque una función cargaría los archivos
    en su propio ámbito y las funciones desaparecerían al terminar. Así
    quedan en el ámbito del llamante (proceso principal o runspace).

    La lista es explícita porque el orden refleja las dependencias (Guard
    necesita Texto, Remove necesita Guard y Log, Historial necesita
    Config...). Como todo se carga antes de ejecutar nada, el orden no es
    estrictamente necesario, pero permite cargar solo una parte.
#>

$OrdenNucleoCachivache = @(
    'Version.ps1'         # versión y constantes
    'Progreso.ps1'        # progreso y cancelación (lo usan todos los módulos)
    'Texto.ps1'           # normalización de texto para comparar identidad
    'Format.ps1'          # formato de tamaños, tiempos y rutas para mostrar
    'EstadoVacio.ps1'     # qué decir cuando la tabla no muestra ninguna fila
    'Extraibles.ps1'      # tipo de cada unidad; FileSystem lo usa para decidir cuáles analizar
    'FileSystem.ps1'      # medición, unidades, carpetas conocidas
    'Compresion.ps1'      # compresión NTFS: lo que realmente se libera
    'Exclusiones.ps1'     # presentación de la lista de exclusiones; usa la clave de FileSystem
    'Guard.ps1'           # guardia de seguridad
    'Candidate.ps1'       # contrato de candidato y de módulo
    'Comandos.ps1'        # qué programas externos se pueden lanzar y desde dónde
    'Papelera.ps1'        # cuota de la papelera; antes de Remove, que la consulta
    'Remove.ps1'          # motor de eliminación
    'Registry.ps1'        # vocabulario de programas instalados (solo lectura)
    'Steam.ps1'           # bibliotecas y juegos que Steam conoce (solo lectura)
    'Ejecutables.ps1'     # resolución de ejecutables, arranque y accesos directos
    'Profiles.ps1'        # perfiles de limpieza
    'Config.ps1'          # configuración del equipo (se descubre al arrancar)
    'Preferencias.ps1'    # preferencias del usuario (persisten entre sesiones)
    'Log.ps1'             # registro de actividad (.log)
    'Historial.ps1'       # historial de ejecuciones (.json)
    'Comparacion.ps1'     # comparación con el análisis anterior (usa Historial y Format)
    'Inspeccion.ps1'      # contenido de una carpeta, para decidir
    'Indice.ps1'          # índice de espacio en disco (una sola pasada)
    'VistaArchivos.ps1'   # consulta del índice: archivos por tamaño, con comodines
    'IndicePersistente.ps1' # guardar y leer el índice en binario
    'IndiceIncremental.ps1' # validez del índice guardado y aplicación de cambios
    'IndiceEspacio.ps1'   # reutilización del índice: huella del volumen, nombre por zonas y aviso de antigüedad
    'CambiosLimpieza.ps1' # lo borrado por el programa como cambios del índice (necesita Guard y Candidate)
    'Mapa.ps1'            # disposición del mapa de árbol (cálculo puro)
    'Report.ps1'          # informes HTML, CSV y JSON
    'ReportEspacio.ps1'   # informe de espacio con mapa de árbol en SVG
    'ModuleRegistry.ps1'  # descubrimiento y ejecución de módulos
)

foreach ($ArchivoNucleoCachivache in $OrdenNucleoCachivache) {
    $RutaNucleoCachivache = Join-Path $PSScriptRoot $ArchivoNucleoCachivache
    if (-not (Test-Path -LiteralPath $RutaNucleoCachivache)) {
        throw "Falta un archivo del núcleo: $RutaNucleoCachivache"
    }
    . $RutaNucleoCachivache
}

# Las variables de este script quedan en el ámbito del llamante y se
# eliminan aquí. Llevan el sufijo "Cachivache" para no borrar variables
# del llamante con nombres corrientes.
Remove-Variable -Name 'ArchivoNucleoCachivache', 'RutaNucleoCachivache', 'OrdenNucleoCachivache' `
                -ErrorAction SilentlyContinue
