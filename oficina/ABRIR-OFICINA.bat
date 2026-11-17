@echo off
rem Abre la Oficina Estrella: servidor local de solo lectura en 127.0.0.1:8765.
rem Se cierra con Ctrl+C, cerrando la consola o tras 2 minutos sin clientes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0servidor.ps1" %*
