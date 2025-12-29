# ==========================================
# SCRIPT DE CRIAÇÃO DE PENDRIVE BOOTÁVEL
# Compatível com Windows 10, 11 e Server
# ==========================================

# Limpar a tela inicial
Clear-Host

# --- Bloco 1: Listagem de Dispositivos Removíveis ---
Write-Host "--- DETECÇÃO DE DISPOSITIVOS REMOVÍVEIS ---" -ForegroundColor Cyan

# Filtra discos que são USB ou 'Removable'
$disks = Get-Disk | Where-Object { $_.BusType -eq 'USB' -or $_.BusType -eq 'UAS' }

if ($disks.Count -eq 0) {
    Write-Host "Nenhum dispositivo removível encontrado." -ForegroundColor Red
    Return
}

# Cria um array personalizado para exibir com ID
$diskList = @()
$counter = 1

foreach ($disk in $disks) {
    # Tenta pegar o FriendlyName e o tamanho
    $sizeGB = [math]::Round($disk.Size / 1GB, 2)
    $info =@{
        ID = $counter
        Nome = $disk.FriendlyName
        Tamanho = "$sizeGB GB"
        NumeroDisco = $disk.Number
    }
    $diskList += $info
    Write-Host "ID: [$counter] - $($disk.FriendlyName) - Tamanho: $sizeGB GB" -ForegroundColor Yellow
    $counter++
}
Write-Host ""

# --- Bloco 2: Seleção do Usuário ---
$selectionId = Read-Host "Digite o ID do dispositivo que deseja utilizar"
$selectedDiskInfo = $diskList | Where-Object { $_.ID -eq $selectionId }

if ($null -eq $selectedDiskInfo) {
    Write-Host "ID Inválido. O script será encerrado." -ForegroundColor Red
    Return
}

$targetDiskNumber = $selectedDiskInfo.NumeroDisco
Write-Host "Dispositivo selecionado: $($selectedDiskInfo.Nome)" -ForegroundColor Green
Write-Host ""

# --- Bloco 3: Caminho da ISO ---
$isoPath = Read-Host "Digite ou cole o caminho completo do arquivo.ISO (Ex: C:\Win11.iso)"
# Remove aspas se o usuário tiver colado com aspas ("")
$isoPath = $isoPath -replace '"', ''

if (-not (Test-Path $isoPath)) {
    Write-Host "Arquivo ISO não encontrado em: $isoPath" -ForegroundColor Red
    Return
}
Write-Host ""

# --- Bloco 4: Escolha do Sistema de Arquivos ---
Write-Host "Escolha a formatação:" -ForegroundColor Cyan
Write-Host "1 - FAT32 (Recomendado para UEFI/Win11, limita arquivos a 4GB)"
Write-Host "2 - NTFS (Para Legacy BIOS ou arquivos grandes sem divisão)"
$fsSelection = Read-Host "Digite a opção (1 ou 2)"

switch ($fsSelection) {
    '1' { $fsType = "FAT32"; $fsLabel = "WIN_BOOT_FAT" }
    '2' { $fsType = "NTFS";  $fsLabel = "WIN_BOOT_NTFS" }
    Default { Write-Host "Opção inválida. Usando FAT32 como padrão."; $fsType = "FAT32"; $fsLabel = "WIN_BOOT" }
}
Write-Host "Sistema de arquivos escolhido: $fsType" -ForegroundColor Green
Write-Host ""

# --- Bloco 5: Confirmação de Segurança ---
Write-Host "ATENÇÃO: TODOS OS DADOS EM '$($selectedDiskInfo.Nome)' SERÃO APAGADOS PERMANENTEMENTE." -ForegroundColor Red -BackgroundColor Black
$confirmation = Read-Host "Deseja continuar? (S/N)"

if ($confirmation -notin @("S", "s")) {
    Write-Host "Operação cancelada pelo usuário." -ForegroundColor Yellow
    Return
}

# Variável para controlar se a ISO foi montada para desmontar no Finally
$isoMounted = $false
$isoImageObj = $null

try {
    # --- Bloco 6: Montagem da ISO ---
    Write-Host "`n[1/5] Montando imagem ISO..." -ForegroundColor Cyan
    
    # Monta a ISO e captura o objeto retornado
    $isoImageObj = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $isoVolume = $isoImageObj | Get-Volume
    $isoDriveLetter = "$($isoVolume.DriveLetter):"
    $isoMounted = $true
    
    Write-Host "ISO montada em: $isoDriveLetter" -ForegroundColor Green

    # --- Bloco 7: Verificação do arquivo install.* e decisão de Split ---
    Write-Host "`n[2/5] Analisando arquivos de instalação..." -ForegroundColor Cyan
    
    $installFile = Get-ChildItem -Path "$isoDriveLetter\sources\install.*" -ErrorAction SilentlyContinue
    
    if (-not $installFile) {
        throw "Não foi possível encontrar o arquivo install.wim ou install.esd na pasta sources da ISO."
    }

    $fileSizeGB = [math]::Round($installFile.Length / 1GB, 2)
    $fileExtension = $installFile.Extension.ToLower() #.wim,.esd,.swm
    Write-Host "Arquivo de instalação encontrado: $($installFile.Name) ($fileSizeGB GB)"

    $needsSplit = $false

    # Lógica de decisão
    if ($fsType -eq "FAT32") {
        # FAT32 tem limite de 4GB (aprox 4.29GB bytes, usamos 4GB para margem)
        if ($installFile.Length -ge 4GB) {
            if ($fileExtension -eq ".wim") {
                Write-Host "DECISÃO: O arquivo WIM é maior que 4GB e o destino é FAT32. O arquivo SERÁ DIVIDIDO." -ForegroundColor Yellow
                $needsSplit = $true
            } elseif ($fileExtension -eq ".esd") {
                Write-Host "ALERTA: O arquivo ESD é maior que 4GB e o destino é FAT32." -ForegroundColor Red
                Write-Host "O DISM não pode dividir arquivos ESD diretamente. O script tentará copiar, mas pode falhar se exceder o limite."
                Write-Host "Recomendação: Use NTFS para este ISO ou converta o ESD para WIM manualmente."
                Start-Sleep -Seconds 3
            }
        } else {
            Write-Host "DECISÃO: O arquivo cabe em FAT32. Cópia direta." -ForegroundColor Green
        }
    } else {
        Write-Host "DECISÃO: Destino NTFS. Divisão não necessária." -ForegroundColor Green
    }

    # --- Bloco 8: Preparação do Pendrive (Limpar e Formatar) ---
    Write-Host "`n[3/5] Formatando unidade USB (Isso pode demorar um pouco)..." -ForegroundColor Cyan
    
    # Limpa o disco
    Clear-Disk -Number $targetDiskNumber -RemoveData -Confirm:$false -ErrorAction Stop
    # Cria partição primária
    $partition = New-Partition -DiskNumber $targetDiskNumber -UseMaximumSize -IsActive -AssignDriveLetter -ErrorAction Stop
    # Formata
    Format-Volume -Partition $partition -FileSystem $fsType -NewFileSystemLabel $fsLabel -Confirm:$false -Force -ErrorAction Stop | Out-Null
    
    $usbDriveLetter = "$($partition.DriveLetter):"
    Write-Host "Unidade USB formatada e montada em: $usbDriveLetter" -ForegroundColor Green

    # --- Bloco 9: Cópia dos Arquivos ---
    Write-Host "`n[4/5] Copiando arquivos..." -ForegroundColor Cyan
    
    # Configurações do Robocopy
    $robocopyOptions = @("/E", "/Z", "/R:3", "/W:3", "/NFL", "/NDL") 
    # /NFL e /NDL reduzem o "spam" no log, mostrando apenas progresso geral, remova se quiser ver arquivo por arquivo
    
    if ($needsSplit) {
        # Se precisa dividir, copiamos tudo EXCETO o install.wim
        Write-Host "Copiando estrutura (excluindo install.wim)..."
        robocopy $isoDriveLetter $usbDriveLetter $robocopyOptions /XF "install.wim" | Out-Null
        
        # Agora dividimos o WIM
        Write-Host "Dividindo e copiando install.wim (Isso vai demorar)..." -ForegroundColor Yellow
        $sourceWim = "$isoDriveLetter\sources\install.wim"
        $destSwm = "$usbDriveLetter\sources\install.swm"
        
        # Comando DISM para dividir em partes de 3800MB (seguro para FAT32)
        $dismArgs = "/Split-Image /ImageFile:`"$sourceWim`" /SWMFile:`"$destSwm`" /FileSize:3800"
        Start-Process -FilePath "Dism.exe" -ArgumentList $dismArgs -Wait -NoNewWindow
        
    } else {
        # Cópia direta normal
        Write-Host "Iniciando cópia completa (Robocopy)..."
        robocopy $isoDriveLetter $usbDriveLetter $robocopyOptions | Out-Null
    }

    # --- Bloco 10: Tornar Bootável (Bootsect) ---
    Write-Host "`n[5/5] Finalizando setor de boot..." -ForegroundColor Cyan
    
    # Aplica o código de boot compatível com Bootmgr (NT60)
    # Isso ajuda na compatibilidade híbrida (Legacy/UEFI)
    if (Test-Path "$isoDriveLetter\boot\bootsect.exe") {
        $bootsectPath = "$isoDriveLetter\boot\bootsect.exe"
        Start-Process -FilePath $bootsectPath -ArgumentList "/nt60 $usbDriveLetter" -Wait -NoNewWindow
    } else {
        # Tenta usar o bootsect do sistema se não achar na ISO
        bootsect /nt60 $usbDriveLetter
    }

    Write-Host "`nSUCESSO: Pendrive bootável criado em $usbDriveLetter" -ForegroundColor Green -BackgroundColor Black

}
catch {
    Write-Host "`nERRO CRÍTICO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "O script foi interrompido."
}
finally {
    # --- Bloco Final: Limpeza e Desmontagem ---
    # Este bloco SEMPRE roda, mesmo se você der Ctrl+C ou ocorrer erro
    if ($isoMounted) {
        Write-Host "`n[Limpeza] Desmontando imagem ISO..." -ForegroundColor DarkGray
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
            Write-Host "ISO desmontada com sucesso." -ForegroundColor DarkGray
        } catch {
            Write-Host "Aviso: Não foi possível desmontar a ISO automaticamente. Verifique o Explorer." -ForegroundColor Yellow
        }
    }
    Write-Host "Processo finalizado."
}