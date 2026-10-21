# Dofus Multi Organizer

Pequeña utilidad para Windows que facilita jugar a **Dofus en multicuenta**: cambia entre las ventanas del juego con una tecla y las coloca en mosaico 2x2 o pantalla completa.

No toca el Ankama Launcher ni el login: tú abres tus cuentas como siempre y el programa solo trabaja con las ventanas de `Dofus.exe` que ya estén abiertas.

## Atajos

| Tecla | Acción |
|-------|--------|
| **F2** | Pasa a la siguiente ventana de Dofus |
| **F3** | Vuelve a la ventana anterior de Dofus |
| **F4** | Alterna entre mosaico 2x2 y pantalla completa |

El orden de las ventanas es el de la **barra de tareas**: arrastra los iconos en la barra para elegir el orden. Si cambias el orden o abres o cierras cuentas, usa **Actualizar** en el menú del icono de la bandeja.

## Descarga y uso (recomendado)

1. Descarga **[DofusMulti.exe](https://github.com/JoelDiazClem/DofusMultiOrganizer/raw/main/release/DofusMulti.exe)**.
2. Guárdalo donde quieras (por ejemplo, en el escritorio) y haz doble clic.
3. Aparece un icono en la bandeja del sistema, junto al reloj. Desde ahí puedes **Actualizar** el orden o **Salir**.

No necesita instalación ni permisos de administrador. Solo puede haber una instancia abierta a la vez.

> **Aviso de Windows SmartScreen / antivirus:** el ejecutable no está firmado digitalmente, así que Windows puede mostrar "Windows protegió su PC". Pulsa *Más información → Ejecutar de todas formas*. Si prefieres no fiarte de un `.exe`, usa la opción de abajo: es exactamente el mismo código, en scripts de PowerShell que puedes leer.

## Uso desde el código fuente (alternativa)

1. Descarga el repositorio (*Code → Download ZIP*) y descomprímelo.
2. Dentro de la carpeta `dofus-multi`, haz clic derecho en `dofus-multi.ps1` → *Ejecutar con PowerShell*.
   También puedes lanzarlo así:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\dofus-multi\dofus-multi.ps1
   ```
3. Opcional: crea un acceso directo en el escritorio, que lo lanza sin ventana de consola:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\dofus-multi\New-DesktopShortcut.ps1
   ```

## Requisitos

- Windows 10 o Windows 11 (Windows PowerShell 5.1 y .NET Framework 4 vienen de serie).
- Dofus 3 (`Dofus.exe`).

Probado en Windows 10. En Windows 11 la barra de tareas tiene otra estructura interna. Si el programa no consigue leer el orden, usa un orden alternativo y F2/F3 siguen funcionando, pero puede que el orden no coincida con el de la barra.

## Compilar el ejecutable

`DofusMulti.exe` se genera a partir de los scripts con:

```powershell
powershell -ExecutionPolicy Bypass -File .\dofus-multi\build\Build-Exe.ps1
```

El script junta todas las librerías de `dofus-multi/lib` y el punto de entrada en un único script, y lo incrusta junto con el icono en un lanzador mínimo en C# (`build/Launcher.cs`). Ese lanzador se compila con el `csc.exe` que incluye .NET Framework, así que no hace falta instalar nada. El resultado queda en `release/DofusMulti.exe`.

Al ejecutarse, el `.exe` extrae el script a `%TEMP%\DofusMulti\` y lo lanza con el `powershell.exe` de Windows, sin ventana de consola.

## Estructura

```
dofus-multi/
  dofus-multi.ps1          Punto de entrada (instancia única + icono de bandeja + hotkeys)
  New-DesktopShortcut.ps1  Crea un acceso directo en el escritorio
  New-TrayIcon.ps1         Regenera el icono a partir del Dofus.exe instalado
  assets/dofus-tray.ico    Icono de la bandeja
  lib/                     Lógica (ventanas, orden de la barra de tareas, mosaico, hotkeys...)
  build/                   Script de compilación y lanzador C#
  tests/                   Tests de Pester
release/
  DofusMulti.exe           Ejecutable listo para descargar
```

## Tests

```powershell
Invoke-Pester .\dofus-multi\tests
```
