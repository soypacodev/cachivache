<#
.SYNOPSIS
    Hace que la ventana maximizada respete la barra de tareas.

.DESCRIPTION
    Una ventana con WindowStyle="None" (barra de título propia) se maximiza
    ocupando la pantalla entera en vez del área de trabajo, y queda por
    debajo de la barra de tareas. Cuando Windows no dibuja el marco tampoco
    calcula los límites: la ventana debe responder a WM_GETMINMAXINFO.

    Se calcula por monitor, porque el área de trabajo varía entre pantallas
    (barra oculta, vertical, lateral o ausente).
#>

function Initialize-InteropVentana {
    <#
    .SYNOPSIS
        Compila una sola vez los tipos de Win32 que hacen falta.
    #>
    [CmdletBinding()]
    param()

    if ('Cachivache.Interop' -as [type]) { return }

    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Cachivache
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PUNTO { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECTANGULO { public int Izq; public int Arriba; public int Der; public int Abajo; }

    /// <summary>Lo que Windows pide en WM_GETMINMAXINFO. El orden y el
    /// tamaño de los campos son los de la estructura MINMAXINFO de la
    /// API: no se pueden reordenar.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct MINMAXINFO
    {
        public PUNTO Reservado;
        public PUNTO MaxSize;
        public PUNTO PosicionMaxima;
        public PUNTO SeguimientoMinimo;
        public PUNTO SeguimientoMaximo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INFOMONITOR
    {
        public int Size;
        public RECTANGULO Monitor;      // toda la pantalla
        public RECTANGULO AreaTrabajo;  // lo que queda libre sin la barra de tareas
        public uint Banderas;
    }

    public static class Interop
    {
        public const int WM_GETMINMAXINFO = 0x0024;
        private const int MONITOR_MAS_CERCANO = 0x00000002;

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr ventana, int banderas);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref INFOMONITOR info);

        /// <summary>Reescribe la MINMAXINFO que apunta lParam para que la
        /// ventana se maximice sobre el área de trabajo de su monitor.</summary>
        public static void AjustarAlAreaDeTrabajo(IntPtr ventana, IntPtr lParam)
        {
            IntPtr monitor = MonitorFromWindow(ventana, MONITOR_MAS_CERCANO);
            if (monitor == IntPtr.Zero) { return; }

            INFOMONITOR info = new INFOMONITOR();
            info.Size = Marshal.SizeOf(typeof(INFOMONITOR));
            if (!GetMonitorInfo(monitor, ref info)) { return; }

            MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(lParam, typeof(MINMAXINFO));

            // Coordenadas relativas al monitor, no a la pantalla virtual:
            // las absolutas fallan con un monitor a la izquierda del principal.
            mmi.PosicionMaxima.X = info.AreaTrabajo.Izq   - info.Monitor.Izq;
            mmi.PosicionMaxima.Y = info.AreaTrabajo.Arriba - info.Monitor.Arriba;
            mmi.MaxSize.X  = info.AreaTrabajo.Der   - info.AreaTrabajo.Izq;
            mmi.MaxSize.Y  = info.AreaTrabajo.Abajo - info.AreaTrabajo.Arriba;

            Marshal.StructureToPtr(mmi, lParam, true);
        }
    }
}
'@
}

function Register-LimiteMaximizado {
    <#
    .SYNOPSIS
        Engancha el ajuste a una ventana ya creada.

    .DESCRIPTION
        Se hace en SourceInitialized, cuando ya existe el HWND. Si falla, se
        registra un aviso y la ventana se abre igualmente.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ventana)

    $Ventana.Add_SourceInitialized({
        try {
            Initialize-InteropVentana
            $fuente = [Windows.Interop.HwndSource]::FromHwnd(
                (New-Object Windows.Interop.WindowInteropHelper($Ventana)).Handle)
            if ($null -eq $fuente) { return }

            $fuente.AddHook([Windows.Interop.HwndSourceHook] {
                param($hwnd, $mensaje, $wParam, $lParam, $manejado)
                if ($mensaje -eq [Cachivache.Interop]::WM_GETMINMAXINFO) {
                    [Cachivache.Interop]::AjustarAlAreaDeTrabajo($hwnd, $lParam)
                }
                # No se marca como manejado: Windows sigue procesando el mensaje.
                return [IntPtr]::Zero
            })
        } catch {
            Write-Registro -Nivel 'AVISO' -Mensaje (
                'No se ha podido ajustar el maximizado a la barra de tareas: {0}' -f $_.Exception.Message)
        }
    }.GetNewClosure())
}
