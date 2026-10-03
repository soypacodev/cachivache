# Empaquetado: winget y Scoop

Esta carpeta no guarda ningún manifiesto, a propósito: los manifiestos se generan en cada publicación a partir del paquete real.

## Por qué se generan

Un manifiesto de winget y uno de Scoop declaran cuatro datos que cambian en **cada** versión:

| Dato | winget | Scoop |
|---|---|---|
| La versión, sin la `v` | `PackageVersion` | `version` |
| La URL de descarga | `InstallerUrl` | `url` |
| La carpeta que hay **dentro** del `.zip` | `NestedInstallerFiles` → `RelativeFilePath` | `extract_dir` |
| El SHA-256 del `.zip` | `InstallerSha256` | `hash` |

Un manifiesto escrito a mano con los datos de la versión anterior pasa las pruebas y el analizador, y falla en el equipo de quien instala: su gestor de paquetes informa de que el archivo descargado no coincide con lo declarado. Por eso cada dato se obtiene una sola vez, del archivo real.

La carpeta interior es la que más fácilmente se olvida: `Compress-Archive` comprime la carpeta, no su contenido, así que al descomprimir aparece `Cachivache-v2.0.0\Cachivache.exe`, con la versión en el nombre.

## Cómo se generan

- `tools/Manifiestos.ps1` decide el formato. Es cálculo puro y está probado en `tests/Paquetes.Tests.ps1`.
- `tools/Publicar-Manifiestos.ps1` escribe los archivos calculando el hash del `.zip` real; no admite un hash por parámetro, para que no se pueda pasar uno copiado a mano.
- `.github/workflows/publicar.yml` lo ejecuta al publicar una etiqueta, comprueba que lo escrito declara el paquete que se va a subir y adjunta los manifiestos a la versión junto con `SHA256SUMS.txt`.

Para generarlos en local sin publicar nada:

```powershell
.\tools\Publicar-Manifiestos.ps1 -Etiqueta v2.0.0 -Paquete .\Cachivache-v2.0.0.zip
```

Se escriben en `packaging\winget\` y `packaging\cachivache.json`. **Son artefactos: no se versionan.**

## Cómo se envían

Los dos canales requieren un paso manual por versión, con los archivos ya generados.

**winget.** Los tres `.yaml` van a `microsoft/winget-pkgs`, en `manifests/f/FranciscoLopez/Cachivache/<versión>/`; lo más cómodo es `wingetcreate submit packaging\winget`. El paquete es un `.zip` portable (`InstallerType: zip` con `NestedInstallerType: portable`): no se ejecuta ningún instalador, se descomprime y se crea un alias, así que no hace falta firma de código para que se acepte. Hasta que se envíe, `winget install` no lo encuentra.

**Scoop.** `cachivache.json` va a un *bucket* (un repositorio git de manifiestos). Mientras no exista, el JSON adjunto a cada versión se instala directamente:

```powershell
scoop install https://github.com/soypacodev/cachivache/releases/latest/download/cachivache.json
```

El manifiesto incluye `checkver` y `autoupdate` aunque se regenere en cada publicación: si alguien lo incorpora a un bucket y deja de regenerarlo, Scoop sigue las versiones de GitHub y toma el hash del `SHA256SUMS.txt` de cada versión.
