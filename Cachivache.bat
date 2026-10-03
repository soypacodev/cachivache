@echo off
rem =====================================================================
rem  Cachivache - lanzador de respaldo y de diagnostico
rem
rem  El lanzador habitual es Cachivache.exe, que no deja consola abierta
rem  (se genera con tools\Compilar-Lanzador.ps1 o se descarga de la
rem  pagina de versiones). Este .bat funciona sin compilar nada y deja la
rem  consola visible, que es donde se lee un error que ocurra antes de que
rem  exista la ventana.
rem
rem  Arranca sin permisos de administrador a proposito: los modulos que
rem  los necesitan se activan desde Ajustes > Reiniciar como administrador.
rem =====================================================================

title Cachivache
cd /d "%~dp0"

rem  Ruta completa a PowerShell: cmd busca primero en el directorio actual
rem  (la carpeta del .bat, a menudo Descargas), donde un powershell.exe
rem  ajeno se ejecutaria en lugar del de Windows.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS%" (
    echo No se ha encontrado Windows PowerShell en:
    echo   %PS%
    echo Cachivache necesita PowerShell 5.1 o superior.
    pause
    exit /b 1
)

"%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Cachivache.ps1" %*
if errorlevel 1 (
    echo.
    echo El programa ha terminado con errores.
    echo Revisa el registro en %%LOCALAPPDATA%%\Cachivache\registros
    echo.
    pause
)
