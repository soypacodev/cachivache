# Política de seguridad

## Qué se considera un fallo de seguridad aquí

Este proyecto no maneja credenciales ni expone servicios de red. Su riesgo es de otro tipo: **borrar algo que no debía**.

Se considera un fallo de seguridad, por orden de gravedad:

1. **Una ruta del sistema operativo que el programa llega a proponer.** Cualquier cosa dentro de Windows, Archivos de programa, WinSxS o la raíz de una unidad.
2. **Datos personales propuestos como borrables.** Documentos, fotos, partidas guardadas, correo, certificados, monederos, bases de datos de contraseñas.
3. **Una forma de saltarse la guardia.** Enlaces simbólicos que se siguen, travesías con `..`, rutas UNC, nombres construidos para engañar a las comprobaciones.
4. **Que la revalidación previa al borrado no se ejecute** en algún camino del código.

Un módulo que propone una caché algo antes de lo ideal es un fallo normal. Un módulo que propone `C:\Windows\System32` es un fallo de seguridad.

---

## Cómo reportarlo

**No abras una incidencia pública** si has encontrado una forma de que el programa borre algo que no debe.

Usa la pestaña **Security → Report a vulnerability** del repositorio ([enlace directo](https://github.com/soypacodev/cachivache/security/advisories/new)), que abre un canal privado con el mantenedor.

Incluye:

- La ruta exacta que se proponía.
- El módulo que la propuso y el perfil con el que se ejecutó.
- Tu configuración: versión de Windows, idioma, si usas OneDrive con redirección de carpetas, si el perfil está en una unidad distinta de `C:`.
- La entrada correspondiente de `%LOCALAPPDATA%\Cachivache\registros\`.

Los casos de redirección de carpetas y de Windows en otros idiomas son especialmente valiosos, porque son los más difíciles de cubrir con pruebas.

### Antes de adjuntar nada: tu privacidad

**Un informe de Cachivache es, sin quererlo, un retrato de tu equipo.** Cada fila lleva una ruta, y casi todas empiezan por `C:\Users\<tu nombre de usuario>`. Un informe de mil filas publica ese nombre mil veces. El registro `.log` tiene el mismo problema.

Para reportar un fallo sin exponer tu privacidad:

- **Genera el informe anonimizado**: casilla *Anonimizar rutas* en la ventana, o `-InformeAnonimo` en consola. Sustituye tu carpeta de perfil, tu nombre de usuario y el nombre del equipo por `<perfil>`, `<usuario>` y `<equipo>`, y el informe sigue sirviendo para diagnosticar.

      .\Cachivache.ps1 -Consola -Informe informe.html -InformeAnonimo

- **Revisa la salida de `-Diagnostico` antes de pegarla.** No lista el contenido de tus discos, pero incluye la ruta de la carpeta de datos (que contiene tu nombre de usuario) y las últimas líneas del registro, que pueden contener rutas.
- **Lee cualquier adjunto antes de publicarlo.** La anonimización sustituye lo que puede reconocer (perfil, usuario, equipo), pero el nombre de una carpeta de trabajo, de un cliente o de un proyecto puede identificarte igual, y eso solo lo sabes tú.

El nombre del equipo no se guarda en ningún informe ni en el registro.

---

## Qué esperar

- **Acuse de recibo en 72 horas.**
- **Una prueba en `tests/Guard.Tests.ps1` que reproduzca el caso**, antes de escribir el arreglo.
- Corrección y publicación en cuanto esté lista y verde.
- Crédito en el [`CHANGELOG.md`](CHANGELOG.md), salvo que prefieras el anonimato.

---

## Versiones con soporte

Solo la última versión publicada. El proyecto es un único árbol de archivos sin instalación: actualizar es reemplazar la carpeta.

---

## Lo que el programa nunca hace

Sirve como referencia rápida para auditar. Si observas alguna de estas cosas, es un fallo:

- Escribir en el registro de Windows.
- Desinstalar programas o detener servicios.
- Borrar archivos dentro de `WinSxS` o `System32`.
- Borrar `Windows.old`, perfiles de usuario o puntos de restauración.
- Seguir un enlace simbólico o un junction al borrar, ni llegar a un archivo a través de uno. La pertenencia a una carpeta autorizada no se decide comparando texto: `Test-CadenaSinEnlaces` sube de la ruta hasta la raíz autorizada comprobando los atributos reales de cada carpeta del camino. Así, un `mklink /J` creado dentro de una zona analizada (no requiere permisos de administrador) no puede meter lo que hay al otro lado en el territorio borrable.
- Enviar datos por la red. **El programa no envía ningún dato tuyo y no tiene telemetría.** Hace una única petición de red, y solo si la pides: al pulsar *Buscar si hay una versión nueva* en *Acerca de*, consulta en `api.github.com` cuál es la última versión publicada. No ocurre al arrancar, ni al abrir ese panel, ni en segundo plano; una prueba exige que la consulta se lance desde un solo sitio.
- Ejecutar código descargado, o cualquier programa que no sea uno de estos. Los programas externos que el código puede llegar a lanzar son exactamente:

  | Programa | Para qué | Cómo se resuelve |
  |---|---|---|
  | DISM, Docker | los únicos que puede lanzar el **motor de borrado** | lista blanca `Resolve-EjecutablePermitido` (`src/Core/Comandos.ps1`). `dism` se resuelve bajo `System32`; `docker`, solo en sus rutas de instalación bajo Archivos de programa. Nunca por `PATH`. Los argumentos van por separado y son literales escritos en el código, declarados en el candidato, visibles enteros en la interfaz y sujetos a confirmación |
  | DISM, `vssadmin` | consultas de **solo lectura** durante el análisis | `Resolve-EjecutableDeSistema` (`src/Core/Comandos.ps1`): anclados a `System32` del propio equipo, **nunca por `PATH`** |
  | `explorer.exe` | abrir una carpeta cuando lo pides | `Get-RutaExplorador`: anclado a `%SystemRoot%`, sin argumentos del usuario más allá de la carpeta |
  | El programa asociado a `.html`, `.csv` y `.json` | abrir un informe desde la pestaña Informes | `Resolve-InformeAbrible`, ver el punto siguiente |
  | `powershell.exe` | reiniciar como administrador cuando lo pides | `Get-RutaPowerShell`: anclado a `%SystemRoot%\System32\WindowsPowerShell\v1.0`, con `-NoProfile`. Es la única línea que ejecuta algo elevado, así que el anclaje aquí importa más que en ningún otro sitio |
  | Tu navegador | abrir el enlace al repositorio cuando lo pides | una única URL fija |

  Una prueba impide añadir un nombre a la lista blanca del motor sin darle también su forma de resolverse.
- Abrir un archivo cualquiera con el programa predeterminado del sistema. La pestaña Informes abre solo los informes que el propio programa ha generado: `Resolve-InformeAbrible` (en `src/Core/Report.ps1`) exige que la extensión sea `.html`, `.csv` o `.json`, que la ruta ya canonizada cuelgue de la carpeta de informes, que el archivo exista y que no sea un enlace ni un punto de reanálisis. Una de esas rutas viene de `historial.json`, texto plano en una carpeta escribible, así que se trata como entrada no fiable y se revalida en cada clic.
