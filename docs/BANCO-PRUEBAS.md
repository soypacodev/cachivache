# Banco de pruebas

Algunos comportamientos solo se pueden comprobar **borrando de verdad**: que un archivo que no cabe en la papelera no se borre, que las rutas de más de 260 caracteres se midan y se borren bien, que los enlaces duros no se cuenten dos veces o que los archivos de OneDrive a petición no se descarguen. El banco monta archivos de prueba (*cebos*) deterministas para comprobarlos sin arriesgar datos reales.

Hay dos formas de ejecutarlo:

- **En la integración continua**, en cada push, sobre un runner de Windows: monta el banco, analiza, simula, hace una limpieza real por consola y comprueba que solo han desaparecido los cebos. No necesita intervención.
- **A mano, en una máquina virtual**, para lo que la CI no puede ver (apartado 8). Es lo que describe este documento.

> **Solo en una máquina virtual con instantánea.** El banco crea archivos dentro de Documentos, que es donde los módulos buscan, y después se hace una limpieza real sobre ellos. `tools\Banco-Pruebas.ps1` se niega a montarse si no detecta una máquina virtual, pero la protección real es la instantánea.

---

## 1. La máquina virtual

Cualquier hipervisor que permita instantáneas (Hyper-V, VirtualBox, VMware).

- Windows 11, instalación limpia, cuenta local de administrador.
- Disco de 60 GB o más.
- **Carpetas compartidas desactivadas**: una carpeta del equipo anfitrión montada en la VM no la protege la instantánea.

Instala Cachivache como lo haría un usuario: copia el `.zip` de la versión, descomprímelo y ejecuta `Cachivache.exe`.

## 2. Bajar la cuota de la papelera

Para comprobar qué pasa cuando algo no cabe en la papelera sin fabricar un archivo de varios GB:

1. Clic derecho en la Papelera de reciclaje → **Propiedades**.
2. Selecciona la unidad `C:`.
3. **Tamaño personalizado: 100 MB**.

## 3. La instantánea

Con la VM apagada, crea una instantánea llamada `limpia`. Todo lo que sigue se deshace volviendo a ella: `-Quitar` recoge los cebos que quedan, pero no devuelve lo que Cachivache haya borrado.

## 4. Montar el banco

Dentro de la VM, en la carpeta del programa:

```powershell
.\tools\Banco-Pruebas.ps1 -WhatIf   # ver qué haría, sin tocar nada
.\tools\Banco-Pruebas.ps1           # montarlo
```

Crea `Documentos\Banco-Cachivache` con estos cebos:

| Carpeta | Contenido | Comprueba |
|---|---|---|
| `01-temporales` | 8 `salida-N.bak` y 8 `version-N.old` | El camino normal: proponer, marcar y borrar a la papelera |
| `02-ruta-larga` | Doce carpetas anidadas con `volcado-antiguo.dmp` al fondo, a más de 260 caracteres | Que el recorrido lo encuentre, lo mida y lo trate bien al borrar |
| `03-mas-grande-que-la-papelera` | `volcado-enorme.dmp`, 200 MB | Que no se borre si no cabe en la papelera (cuota de 100 MB) |
| `04-enlaces-duros` | 20 MB con dos nombres | Que el contenido se cuente una sola vez |
| `05-duplicados` | Dos archivos idénticos e independientes de 512 KB | El módulo de duplicados, y el contraste con los enlaces duros |
| `06-carpetas-vacias` | Cinco carpetas vacías | El módulo de carpetas vacías (propone solo la carpeta superior) |
| `07-muchas-filas` | 3.000 archivos `.tmp` vacíos | Desplazamiento y marcado en lote con miles de filas |
| `08-comprimido` | `volcado-comprimible.dmp`, 100 MB | Que se prometa el tamaño en disco y no el lógico, una vez comprimido |

Los cebos llevan fecha de hace 400 días porque varios módulos ignoran a propósito los archivos recientes (un `.tmp` escrito hace minutos puede estar en uso).

**Antes de analizar, comprime el cebo `08-comprimido`** siguiendo el [apartado 8](#8-lo-que-solo-se-comprueba-a-mano). Si te lo saltas, el cebo sigue sirviendo como un `.dmp` normal, pero la comprobación 5.11 no comprueba nada.

---

## 5. Comprobaciones

Hazlas en orden: si una falla, las siguientes pierden sentido. Ante cualquier fallo, guarda el registro de `%LOCALAPPDATA%\Cachivache\registros\`.

### 5.1. El análisis encuentra los cebos y nada del sistema

Perfil **Exhaustivo**, analizar.

- [ ] Aparecen los `.bak` y `.old` de `01-temporales`.
- [ ] Aparece `volcado-antiguo.dmp`, el de la ruta larga.
- [ ] Aparecen los 3.000 archivos de `07-muchas-filas`.
- [ ] **No aparece nada de `C:\Windows`, Archivos de programa ni perfiles de otros usuarios.** Si esto falla, detente: es un fallo de seguridad.

### 5.2. Dos análisis seguidos

Analiza otra vez sin cerrar el programa.

- [ ] Termina igual que la primera vez.
- [ ] La memoria del proceso no crece sin volver a bajar.

### 5.3. Miles de filas

- [ ] Desplazarse con la rueda es fluido.
- [ ] La columna *qué pasa si se borra* muestra el texto completo en lugar de recortarlo.
- [ ] **Marcar todo** (o `Ctrl+A`) no congela la ventana más de un segundo o dos, y el resumen del pie cuadra.

### 5.4. Un archivo que no cabe en la papelera

Marca **solo** `volcado-enorme.dmp` y elimina sin borrado permanente.

- [ ] **No se borra.** Se explica con las dos cifras: lo que ocupa y lo que cabe.
- [ ] Se ofrece el borrado permanente como decisión aparte.
- [ ] El registro **no** anota ese archivo como enviado a la papelera.

### 5.5. La ruta larga

Marca **solo** `volcado-antiguo.dmp` y elimina.

- [ ] O va a la papelera, o el programa explica que no puede ir y por qué. Lo que no vale es borrarlo de forma permanente diciendo que fue a la papelera.

### 5.6. Los enlaces duros

- [ ] `04-enlaces-duros` cuenta **20 MB**, no 40.
- [ ] Ninguno de los dos nombres se propone como duplicado del otro.

### 5.7. Los duplicados

- [ ] Los dos archivos de `05-duplicados` salen como duplicados entre sí.
- [ ] Ninguno viene marcado.

### 5.8. Accesibilidad

Con el Narrador (`Ctrl+Win+Enter`):

- [ ] Los botones de la barra de título anuncian su función.
- [ ] Al cambiar de panel (`Ctrl+2`, `Ctrl+5`) se anuncia el panel.
- [ ] La casilla de una fila anuncia el nombre del elemento.
- [ ] Tab no se detiene en ningún sitio vacío.

### 5.9. La limpieza real

Marca todo lo del banco y elimina.

- [ ] El diálogo de confirmación muestra la lista completa y cualquier comando externo entero.
- [ ] Al terminar se indica cuántos elementos fueron a la papelera y cuántos no tienen vuelta atrás, y aparece **Abrir la papelera**.
- [ ] Lo que falla sale en rojo, con su motivo, y sigue marcado.
- [ ] El espacio liberado se parece al que muestran las propiedades del disco.

### 5.10. Detener a mitad

Vuelve a la instantánea, monta el banco de nuevo, marca los 3.000 archivos y **detén** la eliminación a mitad.

- [ ] Lo borrado sigue borrado y el resto sigue en la lista.
- [ ] El historial anota la limpieza como interrumpida.

### 5.11. La compresión NTFS

Requiere haber comprimido `08-comprimido` (apartado 8) y hacerse **antes** de la limpieza real.

- [ ] `volcado-comprimible.dmp` no promete 100 MB, sino lo que ocupa en disco, parecido a lo que indica `compact`.
- [ ] El total del pie también usa esa cifra.
- [ ] Ningún archivo comprimido aparece con 0 B: si el tamaño en disco no se puede medir, se usa el tamaño lógico.

---

## 6. Variantes

Cada una en su propia instantánea.

### 6.1. Windows en inglés

Las listas de nombres protegidos de la guardia comparan contra palabras en castellano y en inglés; en otros idiomas protegen menos.

- [ ] Un análisis completo no propone nada del sistema.
- [ ] Los módulos que leen la salida de DISM (`windowsupdate`, `componentes`) no muestran cifras absurdas: esa salida está traducida.

### 6.2. Cuenta sin privilegios

- [ ] La interfaz indica el modo estándar y ofrece reiniciar como administrador.
- [ ] Los módulos que necesitan permisos aparecen como omitidos, no como fallidos.
- [ ] Al eliminar, lo que no se puede por permisos sale en rojo con su motivo.

### 6.3. OneDrive con archivos a petición

Inicia sesión en OneDrive, sube una carpeta con archivos grandes y libera espacio (clic derecho → *Liberar espacio*).

- [ ] Un análisis completo no dispara descargas.
- [ ] El módulo de duplicados indica cuántos archivos se saltó por estar solo en la nube.
- [ ] El módulo de archivos grandes no promete espacio que no está en el disco.

---

## 7. Al terminar

```powershell
.\tools\Banco-Pruebas.ps1 -Quitar
```

Y restaura la instantánea igualmente.

---

## 8. Lo que solo se comprueba a mano

La CI ejecuta el banco completo en cada push (`.github/workflows/ci.yml`, trabajo *Banco de pruebas*), con `tools\Banco-Comprobar.ps1` verificando cada fase. Quedan fuera, y necesitan esta guía:

1. **Un archivo que no cabe en la papelera** (5.4). Leer la cuota exige permisos elevados; si el runner dejara de tenerlos, la comprobación se invertiría sin avisar.
2. **OneDrive a petición** (6.3): necesita una cuenta.
3. **Todo lo visual** (5.3, 5.8, 5.9, 5.10): desplazamiento, marcado en lote, diálogo de confirmación, fallos en rojo, detener a mitad.
4. **Cuenta sin privilegios** (6.2): el runner se ejecuta elevado.
5. **La memoria entre dos análisis** (5.2): la CI la muestra pero no falla por ella, porque el recolector de basura no garantiza cuándo libera memoria.
6. **La compresión NTFS** (5.11): la CI monta el cebo pero no lo comprime, porque depender de que el disco del runner admita compresión haría la comprobación frágil.

Para comprimir el cebo, antes de analizar:

```powershell
$cebo = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Banco-Cachivache\08-comprimido'
compact /C /S $cebo
compact (Join-Path $cebo 'volcado-comprimible.dmp')   # muestra tamaño, tamaño comprimido y proporción
```

Si las dos cifras de la segunda orden coinciden, la compresión no se ha aplicado (probablemente el disco no es NTFS).
