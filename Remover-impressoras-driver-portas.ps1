#requires -RunAsAdministrator
# "BRUTAL": remove TODAS as impressoras nao-padrao, drivers (nao-Microsoft), pacotes do Driver Store (nao-Microsoft)
# e portas (nao usadas), mantendo apenas impressoras padrao do Windows:
# - Microsoft Print to PDF (obrigatoria)
# - Microsoft XPS Document Writer (se existir)
# - Fax (se existir)

$ErrorActionPreference = 'SilentlyContinue'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Log([string]$m) { Write-Host $m }

if (-not (Test-Admin)) { Log "Execute este script em PowerShell como Administrador."; exit 1 }

# Spooler
Set-Service Spooler -StartupType Automatic | Out-Null
Start-Service Spooler | Out-Null

# Impressoras padrao (por nome)
$KeepPrinterPatterns = @(
  '^Microsoft Print to PDF$',
  '^Microsoft XPS Document Writer$',
  '^Fax$'
)

$allPrinters = Get-Printer
$keepPrinters = foreach ($p in $allPrinters) {
  if ($KeepPrinterPatterns | Where-Object { $p.Name -match $_ }) { $p }
}

# Seguranca: exige que "Microsoft Print to PDF" exista
if (-not ($keepPrinters | Where-Object { $_.Name -eq 'Microsoft Print to PDF' })) {
  Log "Nao encontrei 'Microsoft Print to PDF'. Abortando por seguranca."
  Log "Dica: ative o recurso (se estiver desabilitado) e rode novamente."
  Log "Impressoras atuais:"
  $allPrinters | Select Name,DriverName,PortName | Format-Table -Auto
  exit 1
}

$keepPrinterNames = $keepPrinters.Name | Select-Object -Unique
Log "Mantendo impressoras padrao detectadas:"
$keepPrinters | Select Name,DriverName,PortName | Format-Table -Auto

# -----------------------------
# 1) REMOVER IMPRESSORAS (todas exceto padrao)
# -----------------------------
$printersToRemove = $allPrinters | Where-Object { $keepPrinterNames -notcontains $_.Name }

foreach ($p in $printersToRemove) {
  Log "Removendo impressora: $($p.Name)"
  Remove-Printer -Name $p.Name -Confirm:$false | Out-Null

  # Fallbacks (local/rede/per-machine)
  cmd /c "rundll32 printui.dll,PrintUIEntry /dl /n `"$($p.Name)`"" | Out-Null
  cmd /c "rundll32 printui.dll,PrintUIEntry /dn /n `"$($p.Name)`"" | Out-Null
  cmd /c "rundll32 printui.dll,PrintUIEntry /gd /n `"$($p.Name)`"" | Out-Null
}

# Limpeza "na marra" de spool (fila travada)
Stop-Service Spooler -Force | Out-Null
Remove-Item "$env:windir\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue | Out-Null
Start-Service Spooler | Out-Null

# Recarrega estado
$remainingPrinters = Get-Printer

# -----------------------------
# 2) REMOVER DRIVERS (nao-Microsoft e nao usados por impressoras remanescentes)
# -----------------------------
$driversInUse = $remainingPrinters | Select-Object -ExpandProperty DriverName -Unique
$allDrivers   = Get-PrinterDriver

$driversToRemove = $allDrivers | Where-Object {
  ($driversInUse -notcontains $_.Name) -and
  ($_.Manufacturer -notmatch '^(?i)microsoft\b') -and
  ($_.Name -notmatch '^(?i)microsoft\b')
} | Select-Object -ExpandProperty Name -Unique

foreach ($d in $driversToRemove) {
  Log "Removendo driver: $d"
  Remove-PrinterDriver -Name $d | Out-Null

  # Fallback via PrintUI
  cmd /c "rundll32 printui.dll,PrintUIEntry /dd /m `"$d`"" | Out-Null
}

Restart-Service Spooler -Force | Out-Null

# -----------------------------
# 3) REMOVER DRIVER PACKAGES do Driver Store (pnputil) - apenas classe Printer/Impressora e fornecedores NAO-Microsoft
# -----------------------------
Log "Removendo driver packages (pnputil) - classe Printer/Impressora e fornecedores NAO-Microsoft..."
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
# 4) REMOVER PORTAS (mantem as usadas pelas impressoras padrao remanescentes + portas internas)
# -----------------------------
$remainingPrinters = Get-Printer
$portsInUse = $remainingPrinters | Select-Object -ExpandProperty PortName -Unique

# Portas internas comuns (nao tente "zerar" isso, pode quebrar recursos do sistema)
$internalKeepPorts = @('PORTPROMPT:','FILE:','XPSPort:','FAX:','SHRFAX:','NUL:') | Select-Object -Unique
$keepPorts = @($portsInUse + $internalKeepPorts) | Select-Object -Unique

# Fallback prnport.vbs (para TCP/IP/WSD teimosas)
$prnport = Get-ChildItem "$env:windir\System32\Printing_Admin_Scripts" -Recurse -Filter prnport.vbs -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName

$portsToRemove = Get-PrinterPort | Where-Object { $keepPorts -notcontains $_.Name } | Select-Object -ExpandProperty Name -Unique

foreach ($port in $portsToRemove) {
  Log "Removendo porta: $port"
  Remove-PrinterPort -Name $port | Out-Null
  if ($prnport) { cscript.exe //nologo "$prnport" -d -r "$port" | Out-Null }
}

Restart-Service Spooler -Force | Out-Null

# -----------------------------
# RESUMO FINAL
# -----------------------------
Log "`n=== RESULTADO FINAL ==="
Log "`nImpressoras:"
Get-Printer | Select Name,DriverName,PortName | Format-Table -Auto
Log "`nDrivers (restantes):"
Get-PrinterDriver | Select Name,Manufacturer | Sort Name | Format-Table -Auto
Log "`nPortas (restantes):"
Get-PrinterPort | Select Name,PrinterHostAddress,PortNumber | Format-Table -Auto
