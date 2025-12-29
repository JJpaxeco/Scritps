#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Stop-Script([string]$Message) {
  Write-Host ""
  Write-Host $Message
  Write-Host ""
  Read-Host "Pressione ENTER para sair" | Out-Null
  exit 1
}

function Get-UsbDisks {
  Get-Disk |
    Where-Object {
      $_.BusType -eq 'USB' -and
      -not $_.IsBoot -and
      -not $_.IsSystem
    } |
    Sort-Object Number
}

function Read-IntInRange([string]$Prompt, [int]$Min, [int]$Max) {
  while ($true) {
    $raw = Read-Host $Prompt
    $val = 0
    if ([int]::TryParse($raw, [ref]$val) -and $val -ge $Min -and $val -le $Max) { return $val }
    Write-Host "Valor inválido. Informe um número entre $Min e $Max."
  }
}

function Read-YesNo([string]$Prompt) {
  while ($true) {
    $raw = Read-Host $Prompt
    if ($raw -match '^[Ss]$') { return $true }
    if ($raw -match '^[Nn]$') { return $false }
    Write-Host "Resposta inválida. Use S ou N."
  }
}

function Get-IsoDriveLetter([string]$IsoPath) {
  $img = Get-DiskImage -ImagePath $IsoPath -ErrorAction Stop
  $vol = $img | Get-Disk | Get-Partition | Get-Volume | Select-Object -First 1
  if (-not $vol -or -not $vol.DriveLetter) { throw "Não foi possível determinar a letra da unidade da ISO montada." }
  return $vol.DriveLetter
}

function Set-DiskOnlineWritable([int]$DiskNumber) {
  $d = Get-Disk -Number $DiskNumber
  if ($d.IsOffline) { Set-Disk -Number $DiskNumber -IsOffline:$false | Out-Null }
  if ($d.IsReadOnly) { Set-Disk -Number $DiskNumber -IsReadOnly:$false | Out-Null }
}

function Initialize-UsbDisk([int]$DiskNumber, [ValidateSet('FAT32','NTFS')] [string]$FileSystem) {
  Set-DiskOnlineWritable -DiskNumber $DiskNumber

  Write-Host "Limpando o disco USB (Disk $DiskNumber)..."
  Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false

  Write-Host "Inicializando (MBR) e criando partição..."
  Initialize-Disk -Number $DiskNumber -PartitionStyle MBR | Out-Null
  $part = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -IsActive
  $dl = $part.DriveLetter

  Write-Host "Formatando em $FileSystem..."
  Format-Volume -DriveLetter $dl -FileSystem $FileSystem -NewFileSystemLabel "WIN_BOOT" -Confirm:$false | Out-Null

  return $dl
}

function Get-InstallPayloadInfo([string]$IsoRoot) {
  $src = Join-Path $IsoRoot "sources"

  $swm = Get-ChildItem -Path $src -Filter "install*.swm" -ErrorAction SilentlyContinue
  if ($swm) {
    return [pscustomobject]@{
      Type     = 'swm'
      Primary  = $null
      SwmFiles = $swm
    }
  }

  $install = Get-ChildItem -Path $src -Filter "install.*" -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -in '.wim','.esd' } |
             Select-Object -First 1

  if (-not $install) {
    throw "Não foi encontrado 'sources\install.wim', 'sources\install.esd' ou 'sources\install*.swm' na ISO."
  }

  return [pscustomobject]@{
    Type     = $install.Extension.TrimStart('.').ToLowerInvariant() # wim|esd
    Primary  = $install
    SwmFiles = $null
  }
}

function Invoke-Robocopy([string]$Source, [string]$Destination, [string[]]$ExcludeFiles) {
  $roboArgs = @(
    $Source, $Destination,
    "/E", "/COPY:DAT", "/DCOPY:DAT",
    "/R:2", "/W:1", "/NP"
  )

  if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) {
    $roboArgs += "/XF"
    $roboArgs += $ExcludeFiles
  }

  & robocopy @roboArgs | Out-Host

  if ($LASTEXITCODE -ge 8) {
    throw "Falha ao copiar arquivos (Robocopy ExitCode=$LASTEXITCODE)."
  }
}

function Split-WimToSwm([string]$WimPath, [string]$UsbSourcesPath) {
  $swmTarget = Join-Path $UsbSourcesPath "install.swm"
  Write-Host "Gerando SWM: $swmTarget"
  & dism.exe /English /Split-Image /ImageFile:"$WimPath" /SWMFile:"$swmTarget" /FileSize:3800 | Out-Host
}

function Convert-EsdToWim([string]$EsdPath, [string]$TempWimPath) {
  $images = $null
  try { $images = Get-WindowsImage -ImagePath $EsdPath } catch { $images = $null }

  if (-not $images) {
    $info = & dism.exe /English /Get-WimInfo /WimFile:"$EsdPath"
    $idx = @()
    foreach ($line in $info) {
      if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') { $idx += [int]$Matches[1] }
    }
    if (-not $idx) { throw "Não foi possível enumerar índices do install.esd." }
    $images = $idx | ForEach-Object { [pscustomobject]@{ ImageIndex = $_ } }
  }

  if (Test-Path $TempWimPath) { Remove-Item -Force $TempWimPath }

  $first = $true
  foreach ($img in $images) {
    if ($first) {
      Write-Host "Exportando índice $($img.ImageIndex) do ESD para WIM (criação inicial)..."
      & dism.exe /English /Export-Image /SourceImageFile:"$EsdPath" /SourceIndex:$($img.ImageIndex) /DestinationImageFile:"$TempWimPath" /Compress:Max /CheckIntegrity | Out-Host
      $first = $false
    } else {
      Write-Host "Exportando índice $($img.ImageIndex) do ESD para WIM (append)..."
      & dism.exe /English /Export-Image /SourceImageFile:"$EsdPath" /SourceIndex:$($img.ImageIndex) /DestinationImageFile:"$TempWimPath" /CheckIntegrity | Out-Host
    }
  }
}

# -------------------- INÍCIO DO FLUXO --------------------

$usbDisks = Get-UsbDisks
if (-not $usbDisks -or $usbDisks.Count -eq 0) {
  Stop-Script "Nenhum disco USB removível foi encontrado."
}

Write-Host "Dispositivos removíveis externos encontrados:"
Write-Host "-------------------------------------------"
for ($i = 0; $i -lt $usbDisks.Count; $i++) {
  $d = $usbDisks[$i]
  $id = $i + 1
  $sizeGB = [Math]::Round(($d.Size / 1GB), 2)
  Write-Host ("[{0}] Disk {1} | {2} | {3} GB" -f $id, $d.Number, $d.FriendlyName, $sizeGB)
}
Write-Host "-------------------------------------------"

$selectedId = Read-IntInRange -Prompt "Digite o ID do dispositivo que será usado (1-$($usbDisks.Count))" -Min 1 -Max $usbDisks.Count
$targetDisk = $usbDisks[$selectedId - 1]

$isoPath = Read-Host "Cole/digite o caminho completo do arquivo .ISO"
$isoPath = $isoPath.Trim('"')
if (-not (Test-Path $isoPath)) { Stop-Script "ISO não encontrada: $isoPath" }
if ([IO.Path]::GetExtension($isoPath).ToLowerInvariant() -ne ".iso") { Stop-Script "O arquivo informado não tem extensão .ISO." }

Write-Host ""
Write-Host "Selecione o sistema de arquivos:"
Write-Host "  [1] FAT32"
Write-Host "  [2] NTFS"
$fsChoice = Read-IntInRange -Prompt "Opção (1 ou 2)" -Min 1 -Max 2
$fileSystem = if ($fsChoice -eq 1) { "FAT32" } else { "NTFS" }

Write-Host ""
Write-Host "ATENÇÃO: TODOS os dados do dispositivo USB selecionado serão apagados permanentemente."
Write-Host ("Você selecionou: Disk {0} | {1}" -f $targetDisk.Number, $targetDisk.FriendlyName)
$go = Read-YesNo "Deseja continuar? (S/N)"
if (-not $go) { Write-Host "Operação cancelada pelo usuário."; exit 0 }

$diskImage = $null
$tempDir = $null

try {
  Write-Host ""
  Write-Host "Montando a ISO..."
  $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru
  Start-Sleep -Milliseconds 500

  $isoDriveLetter = Get-IsoDriveLetter -IsoPath $isoPath
  $isoRoot = "$isoDriveLetter`:\"
  Write-Host "ISO montada em: $isoRoot"

  Write-Host ""
  Write-Host "Preparando o disco USB..."
  $usbDriveLetter = Initialize-UsbDisk -DiskNumber $targetDisk.Number -FileSystem $fileSystem
  $usbRoot = "$usbDriveLetter`:\"
  Write-Host "USB preparado em: $usbRoot"

  $bootsect = Join-Path $isoRoot "boot\bootsect.exe"
  if (Test-Path $bootsect) {
    try {
      Write-Host "Aplicando bootsect (se aplicável)..."
      & $bootsect /nt60 "${usbDriveLetter}:" /force /mbr | Out-Null   # <- CORREÇÃO DO ERRO FATAL
    } catch {
      Write-Warning "bootsect falhou: $($_.Exception.Message). Continuando..."
    }
  }

  Write-Host ""
  Write-Host "Verificando install.* na ISO..."
  $payload = Get-InstallPayloadInfo -IsoRoot $isoRoot

  $needsSplit = $false
  if ($fileSystem -eq 'FAT32') {
    if ($payload.Type -in @('wim','esd')) {
      if ($payload.Primary.Length -gt (4GB - 1MB)) { $needsSplit = $true }
    }
  }

  Write-Host ""
  if ($needsSplit) {
    Write-Host ("FAT32 selecionado e {0} excede 4GB: será gerado install*.swm." -f $payload.Primary.Name)
  } else {
    Write-Host "Não será necessário gerar SWM."
  }

  Write-Host ""
  Write-Host "Copiando arquivos para o USB..."
  if ($needsSplit) {
    Invoke-Robocopy -Source $isoRoot -Destination $usbRoot -ExcludeFiles @($payload.Primary.Name)

    $usbSources = Join-Path $usbRoot "sources"
    if (-not (Test-Path $usbSources)) { New-Item -ItemType Directory -Path $usbSources | Out-Null }

    if ($payload.Type -eq 'wim') {
      Split-WimToSwm -WimPath $payload.Primary.FullName -UsbSourcesPath $usbSources
    }
    elseif ($payload.Type -eq 'esd') {
      $tempDir = Join-Path $env:TEMP ("USB_BOOT_" + [guid]::NewGuid().ToString("N"))
      New-Item -ItemType Directory -Path $tempDir | Out-Null
      $tempWim = Join-Path $tempDir "install.wim"

      Write-Host "Convertendo install.esd para WIM temporário..."
      Convert-EsdToWim -EsdPath $payload.Primary.FullName -TempWimPath $tempWim

      Write-Host "Dividindo WIM temporário em SWM..."
      Split-WimToSwm -WimPath $tempWim -UsbSourcesPath $usbSources
    }
    else {
      throw "Tipo inesperado para split: $($payload.Type)"
    }
  }
  else {
    Invoke-Robocopy -Source $isoRoot -Destination $usbRoot -ExcludeFiles @()
  }

  Write-Host ""
  Write-Host "Processo concluído. Pendrive/disco USB bootável criado com sucesso em $usbRoot"
}
finally {
  if ($diskImage) {
    try {
      Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop
      Write-Host ""
      Write-Host "ISO desmontada com sucesso."
    } catch {
      Write-Warning "Não foi possível desmontar a ISO automaticamente: $($_.Exception.Message)"
    }
  }

  if ($tempDir -and (Test-Path $tempDir)) {
    try { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}
