@echo off
rem =====================================================================
rem  Crea Cachivache.exe con doble clic.
rem
rem  Invoca Compilar-Lanzador.ps1 sin tener que abrir PowerShell ni
rem  conocer la politica de ejecucion. No es necesario para usar el
rem  programa: Cachivache.bat lo abre igual; el .exe solo evita la
rem  consola de fondo.
rem
rem  El pause final mantiene la ventana abierta para leer el resultado.
rem =====================================================================

title Crear Cachivache.exe

rem  Ruta completa a PowerShell: cmd busca primero en el directorio actual,
rem  donde un powershell.exe ajeno se ejecutaria en lugar del de Windows.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS%" (
    echo.
    echo   No se ha encontrado Windows PowerShell en:
    echo     %PS%
    echo   Cachivache necesita PowerShell 5.1 o superior, que viene de
    echo   serie con Windows 10 y 11.
    echo.
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Compilar-Lanzador.ps1"
set CODIGO=%ERRORLEVEL%

if not "%CODIGO%"=="0" (
    echo.
    echo   No se ha podido crear el ejecutable. El motivo esta arriba.
    echo.
    echo   Mientras tanto puedes usar el programa igualmente: haz doble
    echo   clic en Cachivache.bat, en la carpeta de arriba.
    echo.
)

pause
exit /b %CODIGO%
