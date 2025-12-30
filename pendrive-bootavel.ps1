#requires -RunAsAdministrator
<#
.SYNOPSIS
  Script de criacao de pendrive bootavel do Windows (10/11/Server) a partir de uma ISO.

.DESCRIPTION
  - Lista discos USB/UAS e permite selecionar com seguranca.
  - Prepara o disco via cmdlets (Clear-Disk/New-Partition/Format-Volume) para evitar falhas do DiskPart.
  - Copia arquivos da ISO com robocopy.
  - FAT32: se install.wim >= 4GB, divide em install.swm.
  - FAT32: se install.esd >= 4GB, converte ESD -> WIM (todos os indexes) e depois divide em SWM.
  - Aplica bootsect (se disponivel) para compatibilidade com Legacy BIOS.

.NOTES
  - Textos do script sem acentos/cedilha para evitar problemas no console.
  - Label FAT32 max 11 caracteres.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$IsoPath,

  [Parameter(Mandatory = $false)]
  [int]$DiskNumber,

  [Parameter(Mandatory = $false)]
  [ValidateSet('FAT32','NTFS')]
  [string]$FileSystem,

  [Parameter(Mandatory = $false)]
  [switch]$Force,

  [Parameter(Mandatory = $false)]
  [string]$LogPath
)

Set-StrictMode -Version 2.0

function Write-Info([string]$Msg) { Write-Host $Msg -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host $Msg -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host $Msg -ForegroundColor Yellow }
function Write-Err([string]$Msg)  { Write-Host $Msg -ForegroundColor Red }

function Assert-Admin {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Este script precisa ser executado como Administrador."
  }
}

function Normalize-Path([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  return ($p -replace '"','').Trim()
}

function Ensure-TrailingSlash([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  if ($p.EndsWith('\')) { return $p }
  return ($p + '\')
}

function Get-VolumeLabel([string]$fs) {
  # FAT32 label: max 11 chars
  if ($fs -eq 'FAT32') { return 'WINBOOTFAT' }  # 9
  return 'WINBOOTNTFS'                          # 11
}

function Get-UsbDisks {
  $all = Get-Disk

  $usb = $all | Where-Object {
    ($_.BusType -in @('USB','UAS')) -or (
      ($_.PSObject.Properties.Name -contains 'IsRemovable') -and ($_.IsRemovable -eq $true)
    )
  }

  # Safety: nao listar discos de boot/sistema
  $usb = $usb | Where-Object { -not $_.IsBoot -and -not $_.IsSystem }

  return @($usb)
}

function Select-UsbDiskInteractive {
  $disks = Get-UsbDisks
  if (@($disks).Count -eq 0) { throw "Nenhum dispositivo removivel (USB/UAS) encontrado." }

  Write-Info "--- DETECCAO DE DISPOSITIVOS REMOVIVEIS ---"
  $list = @()
  $i = 1

  foreach ($d in $disks) {
    $sizeGB = [math]::Round($d.Size / 1GB, 2)

    $partCount = 0
    try { $partCount = @((Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)).Count } catch { $partCount = 0 }

    $obj = [pscustomobject]@{
      ID             = $i
      DiskNumber     = $d.Number
      FriendlyName   = $d.FriendlyName
      SizeGB         = $sizeGB
      Partitions     = $partCount
      BusType        = $d.BusType
    }
    $list += $obj

    Write-Host ("ID: {0} | Disco: {1} - Nome: {2} - Tamanho: {3} GB - Conectado via: {4}" -f `
      $obj.ID, $obj.DiskNumber, $obj.FriendlyName, $obj.SizeGB, $obj.BusType) -ForegroundColor Yellow

    $i++
  }

  Write-Host ""
  [int]$sel = 0
  while ($sel -lt 1 -or $sel -gt $list.Count) {
    [void][int]::TryParse((Read-Host "Digite o ID do dispositivo que deseja utilizar"), [ref]$sel)
  }

  return ($list | Where-Object { $_.ID -eq $sel })
}

function Select-FileSystemInteractive {
  Write-Info "Escolha a formatacao:"
  Write-Host "1 - FAT32 (Recomendado para UEFI; limita arquivos a ~4GB)"
  Write-Host "2 - NTFS  (Pode falhar em UEFI puro; bom para arquivos grandes)"
  $opt = Read-Host "Digite a opcao (1 ou 2):"
  switch ($opt) {
    '1' { return 'FAT32' }
    '2' { return 'NTFS' }
    default { Write-Warn "Opcao invalida. Usando FAT32 como padrao."; return 'FAT32' }
  }
}

function Confirm-Destructive([int]$DiskNum, [string]$DiskName, [double]$SizeGB) {
  if ($Force) { return }

  Write-Err "ATENCAO: TODOS OS DADOS NO DISCO SERAO APAGADOS PERMANENTEMENTE."
  Write-Host ("Alvo: Disk {0} | {1} | {2} GB" -f $DiskNum, $DiskName, $SizeGB) -ForegroundColor Red -BackgroundColor Black
  Write-Host ""

  $mustType = "CONFIRMO"
  $typed = (Read-Host ("Para continuar, digite {0}" -f $mustType)).Trim()
  if ($typed -ne $mustType) { throw "Operacao cancelada pelo usuario." }
}

function Mount-IsoAndGetDrive([string]$path) {
  Write-Info "`n[1/6] Montando imagem ISO..."
  $isoObj = Mount-DiskImage -ImagePath $path -PassThru -ErrorAction Stop

  $driveLetter = $null
  for ($t = 0; $t -lt 25 -and -not $driveLetter; $t++) {
    try {
      $vols = $isoObj | Get-Volume -ErrorAction SilentlyContinue
      $v = $vols | Where-Object { $_.DriveLetter } | Select-Object -First 1
      if ($v -and $v.DriveLetter) { $driveLetter = $v.DriveLetter }
    } catch { }
    if (-not $driveLetter) { Start-Sleep -Milliseconds 250 }
  }

  if (-not $driveLetter) { throw "Falha ao obter letra de unidade da ISO montada." }

  $isoRoot = "$driveLetter`:"
  Write-Ok ("ISO montada em: {0}" -f $isoRoot)
  return @{ IsoObj = $isoObj; IsoRoot = $isoRoot }
}

function Get-InstallImageInfo([string]$isoRoot) {
  Write-Info "`n[2/6] Analisando arquivos de instalacao..."

  $wimPath = Join-Path $isoRoot "sources\install.wim"
  $esdPath = Join-Path $isoRoot "sources\install.esd"

  $install = $null
  if (Test-Path $wimPath) { $install = Get-Item $wimPath -ErrorAction Stop }
  elseif (Test-Path $esdPath) { $install = Get-Item $esdPath -ErrorAction Stop }
  else { throw "Nao foi possivel encontrar install.wim ou install.esd em sources da ISO." }

  $sizeGB = [math]::Round($install.Length / 1GB, 2)
  Write-Host ("Arquivo encontrado: {0} ({1} GB)" -f $install.Name, $sizeGB)

  return @{
    File      = $install
    IsWim     = ($install.Extension.ToLower() -eq ".wim")
    IsEsd     = ($install.Extension.ToLower() -eq ".esd")
    SizeBytes = $install.Length
    SizeGB    = $sizeGB
  }
}

function Invoke-External([string]$FilePath, [string]$Arguments, [string]$FailMessage) {
  $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
  if ($p.ExitCode -ne 0) { throw ("{0} ExitCode={1}" -f $FailMessage, $p.ExitCode) }
}

function Convert-EsdToWimAllIndexes([string]$EsdPath, [string]$WimOutPath, [string]$ScratchDir) {
  Write-Warn "ESD grande detectado para FAT32. Convertendo ESD -> WIM (todos os indexes)..."

  if (Test-Path $WimOutPath) { Remove-Item -Path $WimOutPath -Force -ErrorAction SilentlyContinue }
  if (-not (Test-Path $ScratchDir)) { New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null }

  $getInfoArgs = "/English /Get-WimInfo /WimFile:`"$EsdPath`""
  $out = & dism.exe $getInfoArgs 2>&1
  $text = ($out | Out-String)

  $indexes = @()
  foreach ($m in [regex]::Matches($text, "Index\s*:\s*(\d+)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $indexes += [int]$m.Groups[1].Value
  }
  $indexes = $indexes | Sort-Object -Unique
  if ($indexes.Count -eq 0) { throw "Nao foi possivel identificar indexes no ESD (Get-WimInfo)." }

  foreach ($idx in $indexes) {
    Write-Host ("Exportando index {0}..." -f $idx)
    $args = "/English /Export-Image /SourceImageFile:`"$EsdPath`" /SourceIndex:$idx /DestinationImageFile:`"$WimOutPath`" /Compress:Max /CheckIntegrity /ScratchDir:`"$ScratchDir`""
    Invoke-External -FilePath "dism.exe" -Arguments $args -FailMessage ("Falha ao exportar index {0} do ESD para WIM." -f $idx)
  }

  if (-not (Test-Path $WimOutPath)) { throw "Conversao ESD -> WIM falhou (arquivo WIM nao foi criado)." }
  return (Get-Item $WimOutPath -ErrorAction Stop)
}

function Prepare-UsbDisk([int]$DiskNum, [string]$FsType, [string]$Label) {
  Write-Info "`n[3/6] Preparando disco USB (Clear-Disk/New-Partition/Format-Volume)..."

  # Garantir online e nao readonly
  try { Set-Disk -Number $DiskNum -IsOffline $false -ErrorAction SilentlyContinue | Out-Null } catch { }
  try { Set-Disk -Number $DiskNum -IsReadOnly $false -ErrorAction SilentlyContinue | Out-Null } catch { }

  # Remover letras e desmontar o maximo possivel
  try {
    $parts = Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue
    foreach ($p in $parts) {
      if ($p.DriveLetter) {
        try {
          Remove-PartitionAccessPath -DiskNumber $DiskNum -PartitionNumber $p.PartitionNumber -AccessPath ("{0}:\\" -f $p.DriveLetter) -ErrorAction SilentlyContinue | Out-Null
        } catch { }
      }
    }
  } catch { }

  # Remover particoes (melhora estabilidade antes do Clear-Disk)
  try {
    $parts2 = Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue
    foreach ($p in $parts2) {
      try { Remove-Partition -DiskNumber $DiskNum -PartitionNumber $p.PartitionNumber -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
  } catch { }

  # Limpar disco
  try {
    Clear-Disk -Number $DiskNum -RemoveData -Confirm:$false -ErrorAction Stop
  } catch {
    throw ("Falha em Clear-Disk. Possivel bloqueio por politica/EDR/DeviceControl ou midia protegida. Detalhe: {0}" -f $_.Exception.Message)
  }

  Start-Sleep -Milliseconds 300

  # Inicializar somente se estiver RAW
  $disk = Get-Disk -Number $DiskNum -ErrorAction Stop
  if ($disk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $DiskNum -PartitionStyle MBR -ErrorAction Stop | Out-Null
  } elseif ($disk.PartitionStyle -eq 'GPT') {
    # Em midia removivel, normalmente nao ocorre, mas deixa claro se acontecer.
    throw "Disco esta GPT. Para forcar MBR sem DiskPart, ajuste manualmente ou use uma midia que nao esteja GPT."
  }

  # Criar particao e formatar
  $part = New-Partition -DiskNumber $DiskNum -UseMaximumSize -AssignDriveLetter -IsActive -ErrorAction Stop
  Format-Volume -Partition $part -FileSystem $FsType -NewFileSystemLabel $Label -Confirm:$false -Force -ErrorAction Stop | Out-Null

  $usbRoot = "$($part.DriveLetter):"
  Write-Ok ("Unidade USB pronta em: {0}" -f $usbRoot)
  return @{ UsbRoot = $usbRoot }
}

function Copy-FilesToUsb([string]$IsoRoot, [string]$UsbRoot, [string[]]$ExcludeFiles) {
  Write-Info "`n[4/6] Copiando arquivos (robocopy)..."

  $src = Ensure-TrailingSlash $IsoRoot
  $dst = Ensure-TrailingSlash $UsbRoot

  $opts = @("/E","/Z","/R:3","/W:3","/NFL","/NDL")
  $args = @($src, $dst) + $opts

  if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) {
    $args += "/XF"
    foreach ($xf in $ExcludeFiles) { $args += $xf }
  }

  & robocopy @args | Out-Null
  $rc = $LASTEXITCODE
  if ($rc -ge 8) { throw ("Robocopy falhou. ExitCode={0}" -f $rc) }

  Write-Ok ("Copia concluida. Robocopy ExitCode={0}" -f $rc)
}

function Split-WimToSwm([string]$SourceWim, [string]$DestSwm, [int]$FileSizeMB) {
  Write-Warn "Dividindo WIM em SWM (dism Split-Image)..."
  $args = "/English /Split-Image /ImageFile:`"$SourceWim`" /SWMFile:`"$DestSwm`" /FileSize:$FileSizeMB"
  Invoke-External -FilePath "dism.exe" -Arguments $args -FailMessage "DISM Split-Image falhou."
}

function Apply-Bootsect([string]$IsoRoot, [string]$UsbRoot) {
  Write-Info "`n[6/6] Finalizando setor de boot (bootsect se disponivel)..."

  $bootsectIso = Join-Path $IsoRoot "boot\bootsect.exe"
  $bootsectArgs = "/nt60 $UsbRoot"

  if (Test-Path $bootsectIso) {
    Invoke-External -FilePath $bootsectIso -Arguments $bootsectArgs -FailMessage "bootsect falhou (ISO)."
    Write-Ok "bootsect aplicado (ISO)."
    return
  }

  $bootsectSys = Join-Path $env:WINDIR "System32\bootsect.exe"
  if (Test-Path $bootsectSys) {
    Invoke-External -FilePath $bootsectSys -Arguments $bootsectArgs -FailMessage "bootsect falhou (System32)."
    Write-Ok "bootsect aplicado (System32)."
    return
  }

  Write-Warn "bootsect.exe nao encontrado. Boot legacy BIOS pode falhar."
}

# --------------------- MAIN ---------------------
Clear-Host

$isoMounted = $false
$isoObj = $null
$tempWimPath = $null
$tempScratch = $null
$transcriptStarted = $false

try {
  Assert-Admin

  if ($LogPath) {
    $LogPath = Normalize-Path $LogPath
    Start-Transcript -Path $LogPath -Force | Out-Null
    $transcriptStarted = $true
  }

  # Selecionar disco
  $selected = $null
  if ($PSBoundParameters.ContainsKey('DiskNumber')) {
    $d = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ($d.IsBoot -or $d.IsSystem) { throw "DiskNumber parece ser disco de sistema/boot. Abortando por seguranca." }

    $selected = [pscustomobject]@{
      DiskNumber   = $d.Number
      FriendlyName = $d.FriendlyName
      SizeGB       = [math]::Round($d.Size / 1GB, 2)
    }
    Write-Ok ("Disco selecionado via parametro: Disk {0} | {1} | {2} GB" -f $selected.DiskNumber, $selected.FriendlyName, $selected.SizeGB)
  } else {
    $picked = Select-UsbDiskInteractive
    $selected = [pscustomobject]@{
      DiskNumber   = [int]$picked.DiskNumber
      FriendlyName = [string]$picked.FriendlyName
      SizeGB       = [double]$picked.SizeGB
    }
    Write-Ok ("Dispositivo selecionado: Disk {0} | {1}" -f $selected.DiskNumber, $selected.FriendlyName)
  }

  # ISO
  if (-not $IsoPath) { $IsoPath = Read-Host "Digite ou cole o caminho completo do arquivo ISO (ex: C:\Win11.iso)" }
  $IsoPath = Normalize-Path $IsoPath
  if (-not (Test-Path $IsoPath)) { throw ("Arquivo ISO nao encontrado em: {0}" -f $IsoPath) }

  # FileSystem
  if (-not $FileSystem) { $FileSystem = Select-FileSystemInteractive }
  Write-Ok ("Sistema de arquivos escolhido: {0}" -f $FileSystem)

  # Confirmacao
  Confirm-Destructive -DiskNum $selected.DiskNumber -DiskName $selected.FriendlyName -SizeGB $selected.SizeGB

  # Montar ISO
  $m = Mount-IsoAndGetDrive -path $IsoPath
  $isoObj = $m.IsoObj
  $isoRoot = $m.IsoRoot
  $isoMounted = $true

  # Verificar install.*
  $img = Get-InstallImageInfo -isoRoot $isoRoot
  $installFile = $img.File
  $needsSplit = $false
  $needsEsdConvert = $false

  if ($FileSystem -eq 'FAT32') {
    if ($img.IsWim -and $img.SizeBytes -ge 4GB) {
      $needsSplit = $true
      Write-Warn "Arquivo install.wim >= 4GB e destino e FAT32. Precisara ser dividido em arquivos install.swm."
    } elseif ($img.IsEsd -and $img.SizeBytes -ge 4GB) {
      $needsEsdConvert = $true
      $needsSplit = $true
      Write-Warn "Arquivo install.esd >= 4GB e destino e FAT32. Sera convertido para WIM e dividido em arquivos install.swm."
    } else {
      Write-Ok "Arquivo install.esd cabe em FAT32. Divisao nao necessaria, copia direta."
    }
  } else {
    Write-Ok "Arquivo install.wim cabe em NTFS. Divisao nao necessaria, copia direta."
  }

  # Preparar USB (label seguro)
  $label = Get-VolumeLabel -fs $FileSystem
  $prep = Prepare-UsbDisk -DiskNum $selected.DiskNumber -FsType $FileSystem -Label $label
  $usbRoot = $prep.UsbRoot

  # Copiar arquivos
  if ($needsSplit) {
    Copy-FilesToUsb -IsoRoot $isoRoot -UsbRoot $usbRoot -ExcludeFiles @("install.wim","install.esd")
  } else {
    Copy-FilesToUsb -IsoRoot $isoRoot -UsbRoot $usbRoot -ExcludeFiles @()
  }

  # Garantir pasta sources no destino
  $destSources = Join-Path $usbRoot "sources"
  if (-not (Test-Path $destSources)) { New-Item -ItemType Directory -Path $destSources -Force | Out-Null }

  # Split/convert se necessario
  if ($needsSplit) {
    Write-Info "`n[5/6] Preparando imagem de instalacao para FAT32..."

    $sourceWimPath = $null

    if ($needsEsdConvert) {
      $tempDir = Join-Path $env:TEMP ("usb_boot_{0}" -f ([Guid]::NewGuid().ToString("N")))
      $tempScratch = Join-Path $tempDir "scratch"
      New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

      $tempWimPath = Join-Path $tempDir "install.wim"

      $tempDrive = (Get-Item $tempDir).PSDrive
      $needBytes = [int64]($installFile.Length * 3)
      if ($tempDrive -and $tempDrive.Free -lt $needBytes) {
        throw ("Espaco insuficiente em TEMP. Necessario aprox: {0} GB. Livre: {1} GB." -f `
          [math]::Round($needBytes/1GB,2), [math]::Round($tempDrive.Free/1GB,2))
      }

      $tempWim = Convert-EsdToWimAllIndexes -EsdPath $installFile.FullName -WimOutPath $tempWimPath -ScratchDir $tempScratch
      $sourceWimPath = $tempWim.FullName
    } else {
      $sourceWimPath = $installFile.FullName
    }

    $destSwm = Join-Path $usbRoot "sources\install.swm"
    Split-WimToSwm -SourceWim $sourceWimPath -DestSwm $destSwm -FileSizeMB 3800

    Write-Ok "Imagem dividida e copiada (install.swm, install2.swm, ...)."
  }

  # Bootsect
  Apply-Bootsect -IsoRoot $isoRoot -UsbRoot $usbRoot

  Write-Host ""
  Write-Host ("SUCESSO: Pendrive bootavel criado em {0}" -f $usbRoot) -ForegroundColor Green -BackgroundColor Black
}
catch {
  Write-Host ""
  Write-Err ("ERRO CRITICO: {0}" -f $_.Exception.Message)
  Write-Err "O script foi interrompido."
}
finally {
  if ($isoMounted -and $IsoPath) {
    Write-Host ""
    Write-Host "[Cleanup] Desmontando imagem ISO..." -ForegroundColor DarkGray
    try {
      Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
      Write-Host "ISO desmontada." -ForegroundColor DarkGray
    } catch {
      Write-Warn "Aviso: nao foi possivel desmontar a ISO automaticamente."
    }
  }

  if ($tempWimPath) {
    try {
      $tempDir2 = Split-Path -Path $tempWimPath -Parent
      Remove-Item -Path $tempDir2 -Recurse -Force -ErrorAction SilentlyContinue
    } catch { }
  }

  if ($transcriptStarted) {
    try { Stop-Transcript | Out-Null } catch { }
  }

  Write-Host "Processo finalizado."
}