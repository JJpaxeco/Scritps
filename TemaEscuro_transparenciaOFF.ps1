# Modo Escuro + Transparência desativada

$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
New-Item -Path $reg -Force | Out-Null
Set-ItemProperty -Path $reg -Name 'AppsUseLightTheme'    -Type DWord -Value 0 # Modo Escuro para apps
Set-ItemProperty -Path $reg -Name 'ColorPrevalence'      -Type DWord -Value 0 # Modo Escuro para barra de tarefas e menu iniciar
Set-ItemProperty -Path $reg -Name 'EnableTransparency'   -Type DWord -Value 0 # Desativa transparência
Set-ItemProperty -Path $reg -Name 'SystemUsesLightTheme' -Type DWord -Value 0 # Modo Escuro para sistema
# Reiniciar o explorer para aplicar imediatamente
Stop-Process -Name explorer -Force
Start-Process explorer.exe