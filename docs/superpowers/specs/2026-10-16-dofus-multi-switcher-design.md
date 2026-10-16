# Dofus Multi-Switcher — Diseño

**Fecha:** 2026-10-16
**Estado:** Aprobado para planificación de implementación

## Contexto

El usuario juega con 4 cuentas de Dofus (Ankama Launcher) en multi-cuenta ("multiboxing"), lanzando cada cuenta manualmente desde el launcher. Quiere una forma rápida de cambiar el foco entre las 4 ventanas del juego usando F2 (siguiente) y F3 (anterior), sin tener que usar Alt+Tab.

## Investigación previa (resumen)

- El Ankama Launcher es una app Electron/Chromium sin flags de línea de comandos ni URI documentados para lanzar una cuenta guardada directamente. Existe un protocolo `zaap://` registrado en el sistema, pero solo cubre flujos de instalación/apertura desde la web, no login+play automatizado.
- La función interna `startGameWithARG` del launcher no pasa tokens de sesión por línea de comandos — Ankama usa un protocolo propio local (tipo IPC/socket, el "protocolo Zaap") para autenticar al cliente del juego. Replicarlo exigiría ingeniería inversa abierta, frágil ante actualizaciones del launcher (build actual 3.15.5, con auto-update) y con riesgo de marca de cuenta por automatizar el login fuera del flujo oficial.
- **Decisión:** el usuario lanza las 4 cuentas a mano, como hoy. El script no toca el launcher ni el login en ningún momento — solo opera sobre las ventanas del juego ya abiertas.
- El ejecutable del juego es `Dofus.exe` (confirmado en `%LOCALAPPDATA%\Ankama\Dofus-dofus3\`, y también presente en las variantes `Dofus-beta` y `Dofus-experimental`). Filtrar por nombre de proceso es más preciso que por clase de ventana (`UnityWndClass`, compartida por cualquier juego Unity).
- El sistema es Windows 10 (build 10.0.19045), por lo que la barra de tareas usa la estructura "clásica" (`Shell_TrayWnd` → ... → `MSTaskListWClass`), accesible vía UI Automation (`System.Windows.Automation`, incluido en .NET Framework de Windows).

## Alcance

**Incluido:**
- Script PowerShell (`dofus-multi.ps1`) + acceso directo de escritorio como único punto de entrada.
- Detección en vivo de las ventanas de Dofus abiertas (proceso `Dofus.exe`).
- Hotkeys globales F2 (siguiente) / F3 (anterior) para ciclar el foco entre esas ventanas.
- Orden del ciclo = orden visual actual en la barra de tareas de Windows, recalculado en cada pulsación (no se fija una vez al arrancar).

**Explícitamente fuera de alcance:**
- Automatizar el Ankama Launcher o el login de cualquier cuenta.
- Ingeniería inversa del protocolo Zaap.
- Icono de bandeja del sistema (se usa acceso directo + consola minimizada).
- Asignación fija de cuentas a teclas (el ciclo es relativo, no fijo por cuenta).

## Arquitectura

Un único script PowerShell con los siguientes módulos lógicos:

### `Get-DofusWindows`
Enumera las ventanas visibles de nivel superior del sistema (`EnumWindows` vía P/Invoke) y filtra aquellas cuyo proceso propietario (`GetWindowThreadProcessId` + `Process.ProcessName`) es `Dofus`. Devuelve una lista de pares (handle de ventana, título).

### `Get-TaskbarOrder`
Usa UI Automation (`System.Windows.Automation`) para localizar la barra de tareas (`Shell_TrayWnd`) y enumerar sus botones de aplicación en orden visual izquierdo→derecho. Cruza el texto (`Name`) de cada botón contra los títulos devueltos por `Get-DofusWindows` para construir una lista ordenada de handles.

**Fallback:** si UI Automation no puede leer la barra de tareas (p. ej. tras un cambio de Windows), se usa el orden devuelto directamente por `Get-DofusWindows` (orden Z, no visual), avisando por consola de que se ha usado el modo de respaldo.

### `Switch-DofusWindow -Direction Next|Prev`
1. Recalcula la lista ordenada llamando a `Get-DofusWindows` + `Get-TaskbarOrder`.
2. Si la lista está vacía, imprime aviso y no hace nada.
3. Localiza la ventana con foco actual (`GetForegroundWindow`) dentro de la lista. Si el foco actual no es ninguna de las 4, se asume posición -1 (de forma que "siguiente" va a la primera y "anterior" a la última).
4. Calcula el índice siguiente/anterior de forma circular.
5. Llama a `Set-ForegroundWindowReliable` sobre el handle resultante.

### `Set-ForegroundWindowReliable`
Restaura la ventana si está minimizada (`ShowWindow` con `SW_RESTORE`) y fuerza el foco. Dado que el script corre en segundo plano sin su propia ventana en primer plano, se usa el truco estándar de Windows para sortear la protección anti-robo-de-foco (simular una pulsación de la tecla Alt mediante `keybd_event`/`SendInput` justo antes de `SetForegroundWindow`).

### Listener de hotkeys
Registra F2 y F3 como hotkeys globales del sistema (`RegisterHotKey`, sin modificadores) sobre una ventana de mensajes oculta, y corre un bucle de mensajes Win32 (`GetMessage`/`WM_HOTKEY`) que invoca `Switch-DofusWindow -Direction Next` (F2) o `-Direction Prev` (F3).

Si el registro de cualquiera de las dos teclas falla (ya en uso por otra aplicación), el script informa claramente cuál ha fallado y termina — no continúa con una sola tecla funcionando.

### Instancia única
Antes de arrancar, el script comprueba un mutex con nombre fijo. Si ya existe una instancia corriendo, avisa "Ya hay una instancia activa" y termina, en vez de registrar los hotkeys dos veces.

### Consola / feedback
Al arrancar: mensaje de estado ("Dofus Multi-switcher activo. F2 = siguiente, F3 = anterior. Cierra esta ventana para salir."). En cada cambio de ventana, línea de log con el título de la ventana activada. Si F2/F3 se pulsa sin ninguna ventana de Dofus detectada, aviso en consola.

## Flujo de uso

1. El usuario lanza sus 4 cuentas a mano desde el Ankama Launcher (como hoy).
2. En cualquier momento (antes, durante o después), hace doble clic en el acceso directo `Dofus Multi.lnk`.
3. Se abre una consola de PowerShell minimizada que registra F2/F3 y queda escuchando.
4. F2/F3 cambian el foco entre las ventanas de Dofus detectadas en ese instante, en el orden visual de la barra de tareas.
5. Cerrar la ventana de consola detiene el servicio (desregistra los hotkeys al salir).

## Manejo de errores y casos límite

| Caso | Comportamiento |
|---|---|
| F2 o F3 ya registrados por otra app | Aviso claro de qué tecla falló + salida inmediata |
| Ninguna ventana de Dofus al pulsar F2/F3 | Aviso en consola, sin acción |
| Una ventana de Dofus se cierra entre pulsaciones | Se recalcula en vivo; desaparece del ciclo sin configuración adicional |
| Fallo de UI Automation leyendo la barra de tareas | Fallback a orden Z de `EnumWindows`, con aviso |
| Doble lanzamiento del acceso directo | Detección por mutex, aviso de instancia ya activa |

## Notas de implementación (para el plan)

- Todo en PowerShell puro, usando `Add-Type` para P/Invoke (`user32.dll`: `EnumWindows`, `GetWindowThreadProcessId`, `GetWindowText`, `GetForegroundWindow`, `SetForegroundWindow`, `ShowWindow`, `RegisterHotKey`, `UnregisterHotKey`, `keybd_event`/`SendInput`) y el ensamblado `System.Windows.Automation` (UIAutomationClient/UIAutomationTypes) para la lectura de la barra de tareas.
- El acceso directo de escritorio debe lanzar `powershell.exe -WindowStyle Minimized -ExecutionPolicy Bypass -File dofus-multi.ps1` (o `pwsh.exe` si está disponible).
- Validar manualmente en máquina real: registro de hotkeys, cambio de foco con ventanas minimizadas, comportamiento con 2/3/4 ventanas abiertas, y el caso de reordenar la barra de tareas a mano entre pulsaciones.

## Adaptación de proceso

Este directorio de trabajo no es un repositorio git, por lo que este documento se guarda en `docs/superpowers/specs/` pero no se realiza el commit habitual del flujo de brainstorming.
