<#
.SYNOPSIS
    Tipos de datos que consume la interfaz.

.DESCRIPTION
    WPF necesita objetos que implementen INotifyPropertyChanged para que la
    casilla de una fila y el resumen del pie se mantengan sincronizados. Un
    PSCustomObject no lo hace, así que se compilan estas clases al arrancar.

    Las clases no dependen de WPF: los colores y las visibilidades viajan
    como cadenas y el motor de enlace de datos las convierte al tipo real.
#>

function Initialize-TiposInterfaz {
    [CmdletBinding()]
    param()

    if ('Cachivache.ItemVista' -as [type]) { return }

    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;

namespace Cachivache
{
    /// <summary>Base con notificación de cambios para el enlace de datos.</summary>
    public abstract class Notificable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;

        protected void Avisar(string propiedad)
        {
            PropertyChangedEventHandler manejador = PropertyChanged;
            if (manejador != null)
            {
                manejador(this, new PropertyChangedEventArgs(propiedad));
            }
        }
    }

    /// <summary>Un módulo de limpieza tal y como se muestra en Inicio.</summary>
    public class ModuloVista : Notificable
    {
        private bool _seleccionado;

        public string Id { get; set; }
        public string Nombre { get; set; }
        public string Descripcion { get; set; }
        public string Riesgo { get; set; }
        public string ColorRiesgo { get; set; }
        public string Nota { get; set; }
        public bool Disponible { get; set; }

        public bool Seleccionado
        {
            get { return _seleccionado; }
            set
            {
                if (_seleccionado == value) { return; }
                _seleccionado = value;
                Avisar("Seleccionado");
            }
        }

        public string VisibilidadNota
        {
            get { return string.IsNullOrEmpty(Nota) ? "Collapsed" : "Visible"; }
        }
    }

    /// <summary>Un elemento encontrado, tal y como se muestra en Resultados.</summary>
    public class ItemVista : Notificable
    {
        private bool _seleccionado;
        private bool _hecho;
        private string _estado = "";

        public string Categoria { get; set; }
        public string Nombre { get; set; }
        public string Ruta { get; set; }
        public string Info { get; set; }
        public string Efecto { get; set; }
        public string Aviso { get; set; }
        public string Metodo { get; set; }
        public string Comando { get; set; }
        public string Riesgo { get; set; }
        public string ColorRiesgo { get; set; }
        public string Tamano { get; set; }
        public double Bytes { get; set; }
        public bool Borrable { get; set; }

        /// <summary>Referencia al candidato original de PowerShell.</summary>
        public object Origen { get; set; }

        public bool Seleccionado
        {
            get { return _seleccionado; }
            set
            {
                if (_seleccionado == value) { return; }
                _seleccionado = value;
                Avisar("Seleccionado");
            }
        }

        public bool Hecho
        {
            get { return _hecho; }
            set
            {
                if (_hecho == value) { return; }
                _hecho = value;
                Avisar("Hecho");
                // EstadoEsFallo también depende de Hecho.
                Avisar("EstadoEsFallo");
            }
        }

        public string Estado
        {
            get { return _estado; }
            set
            {
                if (_estado == value) { return; }
                _estado = value;
                Avisar("Estado");
                // WPF no deduce las dependencias: hay que notificar también
                // las propiedades derivadas de Estado.
                Avisar("VisibilidadEstado");
                Avisar("EstadoEsFallo");
                Avisar("TextoCompleto");
            }
        }

        /// <summary>Visible siempre que haya un estado que mostrar, tanto si
        /// el borrado salió bien como si falló. No depende de Hecho: un
        /// elemento que no se pudo borrar también debe mostrar su estado.</summary>
        public string VisibilidadEstado
        {
            get { return string.IsNullOrEmpty(Estado) ? "Collapsed" : "Visible"; }
        }

        /// <summary>Indica si el estado es un fallo; decide el color del texto.
        /// Se deriva de Hecho, y no de una bandera aparte, para que ambos no
        /// puedan contradecirse.</summary>
        public bool EstadoEsFallo
        {
            get { return !Hecho && !string.IsNullOrEmpty(Estado); }
        }

        /// <summary>Los textos de la columna "qué pasa si se borra" juntos,
        /// para la ayuda emergente: permite leerlos completos aunque la
        /// celda se recorte.</summary>
        public string TextoCompleto
        {
            get
            {
                var partes = new System.Collections.Generic.List<string>();
                if (!string.IsNullOrWhiteSpace(Aviso))   { partes.Add("Atención: " + Aviso); }
                if (!string.IsNullOrWhiteSpace(Efecto))  { partes.Add(Efecto); }
                if (!string.IsNullOrWhiteSpace(Comando)) { partes.Add("Ejecuta: " + Comando); }
                if (!string.IsNullOrWhiteSpace(Estado))  { partes.Add(Estado); }
                if (!string.IsNullOrWhiteSpace(MotivoMarcado)) { partes.Add(MotivoMarcado); }
                return string.Join("\n\n", partes.ToArray());
            }
        }

        /// <summary>Por qué el programa lo marcó automáticamente, o por qué no.
        /// Lo rellena quien construye la fila con Get-MotivoPremarcado, la
        /// misma función que toma la decisión.</summary>
        public string MotivoMarcado { get; set; }

        /// <summary>Clave con la que el elemento se compara con las
        /// exclusiones del usuario. Viene del candidato sin modificar (la
        /// calcula Get-ClaveExclusion: la ruta si existe, o una clave
        /// sintética con barra vertical para comandos y papelera).
        /// "Excluir siempre esto" guarda exactamente esta cadena; no debe
        /// recalcularse en la ventana.</summary>
        public string ClaveExclusion { get; set; }

        /// <summary>Si Ruta es una ruta real y no una etiqueta (comandos,
        /// papelera); evita que "Copiar ruta" copie algo que no lo es.
        /// Reutiliza la regla de Get-ClaveExclusion, que devuelve la ruta sin
        /// modificar cuando existe: "la clave es la ruta" equivale a "la
        /// ruta es real".</summary>
        public bool TieneRutaReal
        {
            get
            {
                return !string.IsNullOrWhiteSpace(Ruta) &&
                       string.Equals(Ruta, ClaveExclusion, StringComparison.Ordinal);
            }
        }

        /// <summary>El riesgo como número, para ordenar Alto, Medio, Bajo
        /// (el orden alfabético de la cadena no tiene sentido).</summary>
        public int OrdenRiesgo
        {
            get
            {
                if (Riesgo == "Alto")  { return 0; }
                if (Riesgo == "Medio") { return 1; }
                return 2;
            }
        }

        public string VisibilidadAviso
        {
            get { return string.IsNullOrEmpty(Aviso) ? "Collapsed" : "Visible"; }
        }

        /// <summary>Solo el método 'Comando' declara un comando externo, y
        /// SECURITY.md exige que sea siempre visible en la interfaz.</summary>
        public string VisibilidadComando
        {
            get { return string.IsNullOrEmpty(Comando) ? "Collapsed" : "Visible"; }
        }
    }

    /// <summary>Una unidad de disco en el panel lateral.</summary>
    public class DiscoVista : Notificable
    {
        private bool _seleccionado = true;

        public string Letra { get; set; }
        public string Titulo { get; set; }
        public string Detalle { get; set; }
        public string Porcentaje { get; set; }
        public string ColorBarra { get; set; }
        public double AnchoUsado { get; set; }

        /// <summary>Si la unidad entra en el análisis. Notifica cambios
        /// porque el usuario marca la casilla en cualquier momento.</summary>
        public bool Seleccionado
        {
            get { return _seleccionado; }
            set
            {
                if (_seleccionado == value) { return; }
                _seleccionado = value;
                Avisar("Seleccionado");
            }
        }
    }

    /// <summary>Un perfil de limpieza en el selector de Inicio.</summary>
    public class PerfilVista : Notificable
    {
        private bool _activo;

        public string Id { get; set; }
        public string Nombre { get; set; }
        public string Resumen { get; set; }

        public bool Activo
        {
            get { return _activo; }
            set
            {
                if (_activo == value) { return; }
                _activo = value;
                Avisar("Activo");
            }
        }
    }

    /// <summary>Una ejecución anterior en el historial.</summary>
    public class HistorialVista
    {
        public string Tipo { get; set; }
        public string Titulo { get; set; }
        public string Detalle { get; set; }
        public string Tamano { get; set; }
        public string ColorTipo { get; set; }

        /// <summary>Informe de esta ejecución, ya validado contra la carpeta
        /// de informes. Cadena vacía si no hay ninguno que se pueda abrir
        /// (entradas antiguas sin informe, o informe borrado a mano).</summary>
        public string Informe { get; set; }

        /// <summary>Texto del pie de la tarjeta; distingue si hay informe
        /// que abrir o no.</summary>
        public string PieInforme
        {
            get
            {
                return string.IsNullOrEmpty(Informe)
                    ? "Sin informe guardado de esta ejecución."
                    : "Pulsa para abrir el informe.";
            }
        }
    }

    /// <summary>Una exclusión del usuario, en la tarjeta de Ajustes. Los
    /// textos vienen ya calculados de Get-ExclusionVista.</summary>
    public class ExclusionVista
    {
        /// <summary>La cadena exacta guardada en RutasExcluidas; viaja en el
        /// Tag del botón "Quitar". Difiere de Titulo en comandos y papelera,
        /// cuya clave es "modulo:&lt;Id&gt;|&lt;Nombre&gt;".</summary>
        public string Clave { get; set; }

        /// <summary>Lo que el usuario lee: la ruta, o el nombre del
        /// elemento cuando la clave es sintética.</summary>
        public string Titulo { get; set; }

        /// <summary>Qué clase de exclusión es y hasta dónde llega.</summary>
        public string Detalle { get; set; }

        /// <summary>'carpeta', 'modulo' o 'texto'. No lo usa el XAML; sirve
        /// para las pruebas.</summary>
        public string Tipo { get; set; }
    }

    /// <summary>Un informe ya generado, en la lista de Informes.</summary>
    public class InformeVista
    {
        public string Nombre { get; set; }
        public string Ruta { get; set; }
        public string Detalle { get; set; }
        public string Tamano { get; set; }
    }
}
'@
}
