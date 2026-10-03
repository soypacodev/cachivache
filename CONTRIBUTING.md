# Cómo contribuir

Gracias por querer echar una mano. Este documento es corto a propósito.

---

## Antes de nada

Este es un programa que **borra archivos en el equipo de otra persona**. Esa frase gobierna todas las decisiones del proyecto. Si una aportación mejora la potencia a costa de la prudencia, la respuesta va a ser que no.

Tres principios que no se negocian:

1. **Ante la duda, no se borra.**
2. **El usuario tiene que entender qué está aceptando.** Todo candidato explica qué es y qué pasa si desaparece.
3. **Nada arriesgado viene marcado.** Si hace falta criterio humano, hace falta un humano.

---

## Preparar el entorno

No hay nada que instalar para ejecutar el programa. Para desarrollar:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

Antes de abrir un pull request:

```powershell
.\tools\Probar.ps1          # suite, analizador y suelo de cobertura
.\tools\Probar.ps1 -Rapido  # mientras iteras: sin medir cobertura
```

Tiene que terminar en verde. El informe queda en `pruebas\ultima-pasada.txt`. La CI ejecuta este mismo guion y, además, la suite en Windows con PowerShell 5.1 y 7, una comprobación de arranque, un sondeo de la ventana y el [banco de pruebas](docs/BANCO-PRUEBAS.md) con un borrado real.

Si añades una función a `src/`, escribe una prueba que la nombre. Si de verdad no se puede probar sin una ventana de WPF, añádela a `tests/datos/deuda-de-pruebas.txt` con su motivo. La lista solo puede encoger.

### Desarrollar fuera de Windows

La suite pasa en Linux y en macOS con PowerShell 7, y es el bucle de desarrollo más rápido. Por ejemplo, en Linux:

```bash
# PowerShell 7 desde el paquete oficial, sin permisos de administrador
curl -sL -o ps.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/powershell-7.6.5-linux-x64.tar.gz
mkdir -p ~/pwsh && tar -xzf ps.tar.gz -C ~/pwsh && chmod +x ~/pwsh/pwsh
~/pwsh/pwsh -Command "Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck"
```

Las pruebas que necesitan el registro de Windows, `Get-AppxPackage` o rutas de Archivos de programa sustituyen esas dependencias por variables de entorno controladas o por `Mock`. Al escribir pruebas:

- **Nada de `Join-Path` con una letra de unidad.** `Join-Path` resuelve la unidad a través del proveedor de PowerShell y falla si `C:` no existe. Concatena texto, como hacen `Get-EjecutableDeComando` y `Resolve-EjecutablePermitido`.
- **Construye por código los caracteres acentuados que pongas a prueba** (`[char]0x00E1`), para que la codificación del archivo no cambie lo que se comprueba.
- **Ten presente PowerShell 5.1**, que es con el que arranca el programa: `$IsWindows` no existe, `.Count` de un único elemento puede ser `$null`, y `Get-ChildItem -Recurse` se detiene en rutas de más de 260 caracteres sin avisar.

Lo que no se puede comprobar fuera de Windows (WPF, el registro real, la papelera, DISM) lo cubre la CI. **Si has tocado la interfaz, pasa además [`docs/PRUEBA-MANUAL.md`](docs/PRUEBA-MANUAL.md)**: las pruebas automáticas no pueden abrir la ventana.

---

## Añadir un módulo de limpieza

Es un archivo nuevo en `src/Modules/`, sin tocar nada más. La guía, con plantilla, está en [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md#escribir-un-módulo).

En la revisión se mira:

- [ ] ¿Las raíces declaradas son lo más específicas posible?
- [ ] ¿Se llama a `Test-RutaSegura` antes de medir y proponer cada candidato?
- [ ] ¿Los bucles largos comprueban `Test-Cancelacion`?
- [ ] ¿El campo `Efecto` explica la consecuencia en castellano llano?
- [ ] ¿El riesgo asignado es honesto? Ante la duda, sube un nivel.
- [ ] ¿Hay algún caso en que esto podría borrar trabajo de alguien? Si lo hay, `-Aviso`.
- [ ] ¿Está documentado en [`docs/MODULOS.md`](docs/MODULOS.md)?

---

## Tocar la guardia de seguridad

`src/Core/Guard.ps1` es el archivo más delicado del proyecto. Si lo modificas:

- **Escribe la prueba antes que el código**, en `tests/Guard.Tests.ps1`.
- **Todas las pruebas existentes tienen que seguir pasando.** Ninguna se relaja para que pase un cambio nuevo.
- **Explica el porqué en el pull request**: qué ruta se bloqueaba de más o de menos y cómo lo reprodujiste.

Ampliar las listas de protección es bienvenido. Reducirlas necesita una justificación muy buena. Las listas de palabras de la guardia son lógica de seguridad, no texto de interfaz: no se mueven a archivos de idioma.

---

## Estilo

El código está en castellano: nombres de función, variables, comentarios y mensajes.

- Verbos aprobados de PowerShell: `Get-`, `Set-`, `New-`, `Test-`, `Invoke-`, `Export-`, `Import-`, `Remove-`, `Clear-`, `Measure-`, `Format-`…
- Cuatro espacios de sangría, nunca tabuladores. Líneas de hasta 100 caracteres. Finales de línea LF.
- Ayuda (`.SYNOPSIS`, `.DESCRIPTION`) en toda función pública.
- **Los comentarios explican el porqué, no el qué.** `# incrementa el contador` sobra; `# Windows tarda un instante en soltar los descriptores` no.
- Compatible con PowerShell 5.1: nada de operador ternario, `??`, `ForEach-Object -Parallel` ni otra sintaxis exclusiva de 7.
- Los `.ps1` y `.xaml` se guardan en **UTF-8 con BOM**: sin él, PowerShell 5.1 los lee como ANSI y estropea las tildes. Una prueba lo exige.

---

## Informar de un fallo

Abre una incidencia con:

- La salida de `.\Cachivache.ps1 -Diagnostico` (versión, entorno, unidades y el final del registro).
- Perfil y módulos con los que ocurrió.
- Qué esperabas y qué pasó.

**Si el programa propone una ruta que no debería, no es un fallo normal: es lo más importante que puedes reportar.** Lee [`SECURITY.md`](SECURITY.md) antes de publicarla.
