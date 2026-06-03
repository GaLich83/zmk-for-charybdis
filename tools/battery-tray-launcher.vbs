' Silently launch the Charybdis battery tray PowerShell script.
' Using wscript (GUI host) + Run intWindowStyle=0 avoids the brief
' console flash that "-WindowStyle Hidden" still produces at startup.

Set sh = CreateObject("WScript.Shell")
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ _
    & "d:\workspace\Keyboards\zmk-for-charybdis\tools\battery-tray.ps1" & """"
sh.Run ps, 0, False
