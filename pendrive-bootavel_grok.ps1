#Requires -RunAsAdministrator

# Função para listar dispositivos USB removíveis
function Get-USBDrives {
    $usbDisks = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.IsOffline -eq $false }
    if ($usbDisks.Count -eq 0) {
        Write-Host "Nenhum dispositivo USB removível encontrado."
        exit
    }
    Write-Host "Dispositivos USB removíveis encontrados:"
    $id = 1
    $driveMap = @{}
    foreach ($disk in $usbDisks) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 2)
        Write-Host "$id - Disco $($disk.Number): $($disk.FriendlyName) - Tamanho: $sizeGB GB"
        $driveMap[$id] = $disk.Number
        $id++
    }
    return $driveMap
}

# Listar e selecionar dispositivo
$driveMap = Get-USBDrives
$selectedID = Read-Host "Digite o ID do dispositivo que deseja usar"
if (-not $driveMap.ContainsKey([int]$selectedID)) {
    Write-Host "ID inválido."
    exit
}
$diskNumber = $driveMap[[int]$selectedID]
$usbDisk = Get-Disk -Number $diskNumber

# Solicitar caminho da ISO
$isoPath = Read-Host "Digite ou cole o caminho completo do arquivo .ISO"

# Solicitar formato
$formatChoice = Read-Host "Escolha o formato: 1 para FAT32, 2 para NTFS"
if ($formatChoice -eq '1') {
    $fileSystem = 'FAT32'
    $partitionStyle = 'GPT'
    $isActive = $false
} elseif ($formatChoice -eq '2') {
    $fileSystem = 'NTFS'
    $partitionStyle = 'MBR'
    $isActive = $true
} else {
    Write-Host "Escolha inválida."
    exit
}

# Confirmação de perda de dados
Write-Host "ATENÇÃO: Todos os dados no dispositivo USB serão apagados permanentemente!"
$confirm = Read-Host "Deseja continuar? (S/s para sim, N/n para não)"
if ($confirm -inotmatch '^s$') {
    Write-Host "Operação cancelada."
    exit
}

# Montar ISO
try {
    $mountedIso = Mount-DiskImage -ImagePath $isoPath -PassThru -StorageType ISO
    $isoLetter = ($mountedIso | Get-Volume).DriveLetter
} catch {
    Write-Host "Erro ao montar a ISO: $_"
    exit
}

# Trap para desmontar ISO em caso de interrupção
trap {
    Dismount-DiskImage -ImagePath $isoPath
    Write-Host "ISO desmontada devido a interrupção."
    exit
}

# Limpar e formatar o disco USB
$usbDisk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false -PassThru | Set-Disk -PartitionStyle $partitionStyle
$usbPartition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter
$usbLetter = $usbPartition.DriveLetter
Format-Volume -DriveLetter $usbLetter -FileSystem $fileSystem -NewFileSystemLabel "BootUSB" -Confirm:$false -Force
if ($isActive) {
    Set-Partition -DriveLetter $usbLetter -IsActive $true
}

# Verificar arquivo install.*
$installFiles = Get-ChildItem "${isoLetter}:\sources\install.*" -ErrorAction SilentlyContinue
if ($installFiles.Count -eq 0) {
    Write-Host "Arquivo install.* não encontrado na ISO."
    Dismount-DiskImage -ImagePath $isoPath
    exit
}

$installFile = $installFiles[0]  # Assume o principal
$extension = $installFile.Extension.ToLower()
$fileSizeGB = $installFile.Length / 1GB

$needSplit = ($fileSystem -eq 'FAT32' -and $fileSizeGB -gt 4 -and $extension -ne '.swm')

# Copiar arquivos exceto install.*
robocopy "${isoLetter}:\" "${usbLetter}:\" /E /COPY:DAT /R:3 /W:3 /XF "${isoLetter}:\sources\install.*"

# Lidar com install.*
if ($needSplit) {
    $tempDir = "$env:TEMP\ISOConvert"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    
    if ($extension -eq '.esd') {
        # Converter ESD para WIM
        $esdPath = $installFile.FullName
        $wimPath = "$tempDir\install.wim"
        Dism /Export-Image /SourceImageFile:$esdPath /SourceIndex:1 /DestinationImageFile:$wimPath /Compress:max /CheckIntegrity
        $installPath = $wimPath
    } else {
        $installPath = $installFile.FullName
    }
    
    # Split para SWM
    Dism /Split-Image /ImageFile:$installPath /SWMFile:"${usbLetter}:\sources\install.swm" /FileSize:3800
    
    # Limpar temp
    Remove-Item -Path $tempDir -Recurse -Force
} else {
    # Copiar direto
    Copy-Item -Path "${isoLetter}:\sources\install.*" -Destination "${usbLetter}:\sources\" -Force
}

# Tornar bootável
Set-Location "${usbLetter}:\efi\microsoft\boot"
bootsect /nt60 "${usbLetter}:" /force /mbr

# Desmontar ISO
Dismount-DiskImage -ImagePath $isoPath

Write-Host "Pendrive bootável criado com sucesso!"