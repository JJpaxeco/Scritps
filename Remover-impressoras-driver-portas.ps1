#requires -RunAsAdministrator
# Remove TODAS as impressoras (exceto "Microsoft Print to PDF"), remove drivers (incl. tentativas via PrintUI),
# remove pacotes (Driver Store via pnputil para fornecedores nao-Microsoft) e remove portas (exceto a do PDF).

$ErrorActionPreference = 'SilentlyContinue'
$KeepPrinterName = 'Microsoft Print to PDF'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Log([string]$msg) { Write-Host $msg }

if (-not (Test-Admin)) { Log "Execute este script em PowerShell como Administrador."; exit 1 }

# Spooler
Set-Service Spooler -StartupType Automatic | Out-Null
Start-Service Spooler | Out-Null

# Validar impressora a manter
$keep = Get-Printer -Name $KeepPrinterName
if (-not $keep) {
  Log "Nao encontrei '$KeepPrinterName'. Abortando por seguranca (para nao remover tudo sem preservar o PDF)."
  Log "Printers atuais:"
  Get-Printer | Select Name,DriverName,PortName | Format-Table -Auto
  exit 1
}

$KeepDriverName = $keep.DriverName
$KeepPortName   = $keep.PortName

if ([string]::IsNullOrWhiteSpace($KeepDriverName) -or [string]::IsNullOrWhiteSpace($KeepPortName)) {
  Log "Nao consegui identificar DriverName/PortName do '$KeepPrinterName'. Abortando por seguranca."
  exit 1
}

Log "Mantendo: $KeepPrinterName | Driver: $KeepDriverName | Porta: $KeepPortName"

# -----------------------------
# 1) REMOVER IMPRESSORAS (BRUTAL)
# -----------------------------
$printersToRemove = Get-Printer | Where-Object { $_.Name -ne $KeepPrinterName }

foreach ($p in $printersToRemove) {
  Log "Removendo impressora: $($p.Name)"
  Remove-Printer -Name $p.Name -Confirm:$false | Out-Null

  # Fallbacks (tenta local e rede)
  cmd /c "rundll32 printui.dll,PrintUIEntry /dl /n `"$($p.Name)`"" | Out-Null
  cmd /c "rundll32 printui.dll,PrintUIEntry /dn /n `"$($p.Name)`"" | Out-Null
  cmd /c "rundll32 printui.dll,PrintUIEntry /gd /n `"$($p.Name)`"" | Out-Null
}

# Limpar spool na marra (fila travada)
Stop-Service Spooler -Force | Out-Null
Remove-Item "$env:windir\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue | Out-Null
Start-Service Spooler | Out-Null

# -----------------------------
# 2) REMOVER DRIVERS (BRUTAL)
# -----------------------------
$driversToRemove = Get-PrinterDriver | Where-Object { $_.Name -ne $KeepDriverName } | Select-Object -ExpandProperty Name -Unique
foreach ($d in $driversToRemove) {
  Log "Removendo driver: $d"
  Remove-PrinterDriver -Name $d | Out-Null

  # Fallback via PrintUI
  cmd /c "rundll32 printui.dll,PrintUIEntry /dd /m `"$d`"" | Out-Null
}

Restart-Service Spooler -Force | Out-Null

# -----------------------------
# 3) REMOVER DRIVER PACKAGES (Driver Store) via PNPUTIL (BRUTAL, mas evita Microsoft)
# -----------------------------
Log "Removendo driver packages (pnputil) de classe Printer/Impressora para fornecedores NAO-Microsoft..."
$raw = (pnputil /enum-drivers) 2>$null
$blocks = ($raw -join "`n") -split "(\r?\n){2,}" | Where-Object { $_ -match '\S' }

foreach ($b in $blocks) {
  $pub  = [regex]::Match($b, '(?im)^(Published Name|Nome publicado)\s*:\s*(\S+)\s*$').Groups[2].Value
  $cls  = [regex]::Match($b, '(?im)^(Class Name|Nome da classe|Class)\s*:\s*(.+)\s*$').Groups[2].Value.Trim()
  $prov = [regex]::Match($b, '(?im)^(Provider Name|Nome do provedor)\s*:\s*(.+)\s*$').Groups[2].Value.Trim()

  $isPrinterClass = ($cls -match '(?i)\bprinter\b|\bimpress')
  $isOemInf       = ($pub -match '^oem\d+\.inf$')
  $isMicrosoft    = ($prov -match '^(?i)microsoft\b')

  if ($isOemInf -and $isPrinterClass -and -not $isMicrosoft) {
    Log "  -> Removendo pacote: $pub | Class: $cls | Provider: $prov"
    cmd /c "pnputil /delete-driver $pub /uninstall /force" | Out-Null
  }
}

Restart-Service Spooler -Force | Out-Null

# -----------------------------
# 4) REMOVER PORTAS (BRUTAL) - mantém SOMENTE a porta do PDF
# -----------------------------
Log "Removendo portas (exceto a do PDF): mantendo apenas '$KeepPortName'"

# Fallback script de porta
$prnport = Get-ChildItem "$env:windir\System32\Printing_Admin_Scripts" -Recurse -Filter prnport.vbs -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName

$portsToRemove = Get-PrinterPort | Where-Object { $_.Name -ne $KeepPortName } | Select-Object -ExpandProperty Name -Unique

foreach ($port in $portsToRemove) {
  Log "Removendo porta: $port"
  Remove-PrinterPort -Name $port | Out-Null

  # Fallback (muito util para TCP/IP/WSD teimosas)
  if ($prnport) { cscript.exe //nologo "$prnport" -d -r "$port" | Out-Null }
}

Restart-Service Spooler -Force | Out-Null

# -----------------------------
# RESUMO FINAL
# -----------------------------
Log "`n=== RESULTADO FINAL ==="
Log "`nImpressoras:"
Get-Printer | Select Name,DriverName,PortName | Format-Table -Auto
Log "`nDrivers:"
Get-PrinterDriver | Select Name | Sort Name | Format-Table -Auto
Log "`nPortas:"
Get-PrinterPort | Select Name,PrinterHostAddress,PortNumber | Format-Table -Auto
