<#
.SYNOPSIS
    Genera Cachivache.exe, el lanzador sin consola.

.DESCRIPTION
    El .bat deja una ventana de consola abierta durante toda la sesión,
    porque PowerShell se ejecuta dentro de ella. Este script genera un
    ejecutable pequeño (unos 45 KB, casi todo el icono) que solo arranca
    PowerShell con la ventana oculta. No contiene lógica del programa.

    Se compila con csc.exe, incluido en .NET Framework de Windows; no hace
    falta instalar nada.

    El .exe no se versiona: un binario no se puede auditar leyendo el
    código, y un ejecutable pequeño sin firmar que lanza PowerShell suele
    disparar los antivirus. La CI lo compila y lo adjunta a cada versión
    publicada; desde un clon, se ejecuta este script o se usa el .bat.

.EXAMPLE
    .\tools\Compilar-Lanzador.ps1
    Deja Cachivache.exe en la raíz del proyecto.

.EXAMPLE
    .\tools\Compilar-Lanzador.ps1 -Destino C:\temp\Cachivache.exe
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Destino = ''
)

$ErrorActionPreference = 'Stop'

$raiz = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Destino)) {
    $Destino = Join-Path $raiz 'Cachivache.exe'
}

# ---------------------------------------------------------------------
#  El lanzador
# ---------------------------------------------------------------------
# Deliberadamente mínimo: localiza su carpeta, comprueba que el .ps1 está
# al lado y arranca PowerShell con la ventana oculta. -STA es
# imprescindible: WPF no arranca en un hilo MTA.
$fuente = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

// Escapado de argumentos con las reglas con que Windows (CommandLineToArgvW
// y el CRT) parte la linea de ordenes: las barras invertidas solo son
// especiales delante de una comilla. Sin esto, un argumento con una
// comilla dentro o acabado en barra invertida ("C:\carpeta\") llega
// partido o pegado al siguiente.
static class LineaDeOrdenes
{
    public static string Citar(string argumento)
    {
        if (argumento == null) { argumento = ""; }
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int barras = 0;
        foreach (char c in argumento)
        {
            if (c == '\\') { barras++; continue; }
            if (c == '"')
            {
                // Las barras que preceden a una comilla se doblan y la
                // comilla se escapa con una mas.
                sb.Append('\\', barras * 2 + 1);
                sb.Append('"');
            }
            else
            {
                sb.Append('\\', barras);
                sb.Append(c);
            }
            barras = 0;
        }
        // Las barras finales se doblan: la comilla de cierre no queda escapada.
        sb.Append('\\', barras * 2);
        sb.Append('"');
        return sb.ToString();
    }
}

static class Lanzador
{
    [STAThread]
    static int Main(string[] argumentos)
    {
        string carpeta = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string guion   = Path.Combine(carpeta, "Cachivache.ps1");

        if (!File.Exists(guion))
        {
            MessageBox.Show(
                "No se encuentra Cachivache.ps1 junto a este ejecutable.\n\n" +
                "El lanzador tiene que estar en la misma carpeta que el programa.",
                "Cachivache", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        // Cada argumento se cita y escapa (LineaDeOrdenes.Citar): llega al
        // otro lado tal cual, con espacios, comillas o barras finales.
        string extra = "";
        foreach (string a in argumentos) { extra += " " + LineaDeOrdenes.Citar(a); }

        // RUTA COMPLETA, no "powershell.exe" a secas. Con
        // UseShellExecute=false, CreateProcess busca PRIMERO en la carpeta
        // del ejecutable que llama, y este .exe se descomprime donde el
        // usuario quiera: normalmente Descargas, que esta llena de cosas
        // que ha bajado de internet. Un powershell.exe ajeno ahi se
        // ejecutaria en lugar del de Windows.
        string psExe = Path.Combine(Environment.SystemDirectory,
                                    @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(psExe))
        {
            MessageBox.Show(
                "No se encuentra Windows PowerShell en:\n" + psExe,
                "Cachivache", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        ProcessStartInfo inicio = new ProcessStartInfo();
        inicio.FileName = psExe;
        inicio.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File " + LineaDeOrdenes.Citar(guion) + extra;
        inicio.WorkingDirectory = carpeta;
        inicio.UseShellExecute = false;
        inicio.CreateNoWindow = true;

        try
        {
            Process proceso = Process.Start(inicio);
            proceso.WaitForExit();
            return proceso.ExitCode;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "No se ha podido iniciar PowerShell.\n\n" + ex.Message,
                "Cachivache", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
'@

# ---------------------------------------------------------------------
#  Compilación
# ---------------------------------------------------------------------
# Salida detallada a propósito: si falla en otro equipo, es el único
# diagnóstico disponible.
Write-Host ''
Write-Host '  Compilando el lanzador...' -ForegroundColor Cyan
Write-Host ''
Write-Host ('    PowerShell : {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Host ('    Destino    : {0}' -f $Destino)

# --- 1. Localizar csc.exe --------------------------------------------
# Ambas arquitecturas y cualquier versión 4.x, sin fijar el número de
# compilación.
$candidatos = @()
foreach ($marco in @('Framework64', 'Framework')) {
    $carpeta = Join-Path $env:SystemRoot "Microsoft.NET\$marco"
    if (-not (Test-Path -LiteralPath $carpeta)) { continue }
    $candidatos += @(Get-ChildItem -LiteralPath $carpeta -Directory -Filter 'v4.*' -ErrorAction SilentlyContinue |
                     Sort-Object Name -Descending |
                     ForEach-Object { Join-Path $_.FullName 'csc.exe' } |
                     Where-Object { Test-Path -LiteralPath $_ })
}

if ($candidatos.Count -eq 0) {
    Write-Host ''
    Write-Host '  No se encuentra el compilador de C# de .NET Framework.' -ForegroundColor Red
    Write-Host ('  Se ha buscado csc.exe en {0}\Microsoft.NET\Framework[64]\v4.*' -f $env:SystemRoot)
    Write-Host ''
    Write-Host '  Viene de serie con Windows 10 y 11. Si de verdad no esta, el .bat'
    Write-Host '  hace exactamente lo mismo dejando la consola a la vista:'
    Write-Host '      .\Cachivache.bat'
    exit 1
}

$csc = $candidatos[0]
Write-Host ('    csc.exe    : {0}' -f $csc)

# --- 1b. El icono ------------------------------------------------------
# Opcional: sin assets\cachivache.ico se compila con el icono genérico.
$icono = Join-Path (Join-Path $raiz 'assets') 'cachivache.ico'
$argumentosIcono = @()
if (Test-Path -LiteralPath $icono) {
    $argumentosIcono = @("/win32icon:$icono")
    Write-Host ('    Icono      : {0}' -f $icono)
} else {
    Write-Host '    Icono      : (no esta assets\cachivache.ico; se compila sin el)'
}

# --- 2. Compilar ------------------------------------------------------
$archivoFuente = Join-Path ([IO.Path]::GetTempPath()) ('Lanzador_' + [Guid]::NewGuid() + '.cs')
Set-Content -LiteralPath $archivoFuente -Value $fuente -Encoding UTF8

$salida  = @()
$codigo  = -1
try {
    if (-not $PSCmdlet.ShouldProcess($Destino, 'Compilar el lanzador')) { return }

    # Con ErrorActionPreference = 'Stop', cada línea que csc escribe en la
    # salida de error se vuelve un error terminante al redirigir con 2>&1,
    # y un simple aviso abortaría el script. Se relaja solo durante la
    # llamada y se decide por el código de salida.
    $preferenciaAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    # /target:winexe: subsistema Windows, sin consola.
    $salida = @(& $csc /nologo /target:winexe /optimize+ `
                       /reference:System.dll /reference:System.Windows.Forms.dll `
                       @argumentosIcono `
                       "/out:$Destino" $archivoFuente 2>&1 |
                ForEach-Object { $_.ToString() })
    $codigo = $LASTEXITCODE

    $ErrorActionPreference = $preferenciaAnterior
} finally {
    Remove-Item -LiteralPath $archivoFuente -Force -ErrorAction SilentlyContinue
}

Write-Host ('    Codigo     : {0}' -f $codigo)

if ($codigo -ne 0) {
    Write-Host ''
    Write-Host '  La compilacion ha fallado. Esto es lo que ha dicho csc:' -ForegroundColor Red
    if ($salida.Count -eq 0) { Write-Host '    (no ha dicho nada)' }
    $salida | ForEach-Object { Write-Host "    $_" }
    exit 1
}

# --- 3. Comprobar que el archivo existe ------------------------------
# csc puede terminar con código 0 sin dejar nada si un antivirus pone en
# cuarentena el .exe recién creado.
if (-not (Test-Path -LiteralPath $Destino)) {
    Write-Host ''
    Write-Host '  csc ha terminado sin errores PERO el archivo no esta.' -ForegroundColor Red
    Write-Host '  Casi siempre es el antivirus, que lo ha puesto en cuarentena nada'
    Write-Host '  más crearse. Mira el historial de protección de Windows Defender.'
    Write-Host ''
    Write-Host '  Mientras tanto, el .bat hace lo mismo dejando la consola a la vista:'
    Write-Host '      .\Cachivache.bat'
    exit 1
}

# --- 4. Comprobar el subsistema --------------------------------------
# Cabecera PE: 2 = ventana, 3 = consola. La CI también lo comprueba.
$bytes      = [IO.File]::ReadAllBytes($Destino)
$inicioPE   = [BitConverter]::ToInt32($bytes, 0x3C)
$subsistema = [BitConverter]::ToUInt16($bytes, $inicioPE + 0x5C)

if ($subsistema -ne 2) {
    Write-Host ''
    Write-Host ('  El ejecutable ha salido de CONSOLA (subsistema {0}, se esperaba 2).' -f $subsistema) -ForegroundColor Red
    Write-Host '  Así seguiria apareciendo la ventana negra. No lo uses; avisa del fallo.'
    exit 1
}

$sizeBytes = (Get-Item -LiteralPath $Destino).Length
Write-Host ('    Subsistema : {0} (ventana)' -f $subsistema)
Write-Host ''
Write-Host ('  Listo: {0} ({1:N0} bytes)' -f $Destino, $sizeBytes) -ForegroundColor Green
Write-Host '  Doble clic y el programa se abre sin ninguna consola detras.'
Write-Host ''
