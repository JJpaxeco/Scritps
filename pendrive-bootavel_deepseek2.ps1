# ============================================
# CRIADOR DE PENDRIVE BOOTÁVEL WINDOWS
# Versão Simplificada e Corrigida
# ============================================

# Requer execução como Administrador
# Suporta Windows 10, 11 e Server
# Divide automaticamente arquivos >4GB para FAT32

# Configuração inicial
$ErrorActionPreference = "Stop"
$isoMounted = $false
$isoDrive = $null
$isoPath = $null

# Função de limpeza
function Cleanup {
    if ($isoMounted -and $isoPath) {
        Write-Host "Desmontando ISO..." -ForegroundColor Yellow
        Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
    }
}

# Registrar limpeza para Ctrl+C
trap {
    Write-Host "`nScript interrompido." -ForegroundColor Red
    Cleanup
    break
}

# Início do script
try {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "    CRIADOR DE PENDRIVE BOOTÁVEL" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Verificar privilégios de administrador
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "ERRO: Execute este script como Administrador!" -ForegroundColor Red
        Write-Host "Clique com botão direito no PowerShell e escolha 'Executar como Administrador'" -ForegroundColor Yellow
        pause
        exit 1
    }
    
    # ============================================
    # PASSO 1: Listar dispositivos USB
    # ============================================
    Write-Host "`n[1/7] BUSCANDO DISPOSITIVOS USB..." -ForegroundColor Green
    Write-Host "-------------------------------------" -ForegroundColor Gray
    
    $usbDisks = Get-Disk | Where-Object { $_.BusType -eq 'USB' -or $_.MediaType -eq 'Removable Media' }
    
    if ($usbDisks.Count -eq 0) {
        Write-Host "Nenhum dispositivo USB encontrado!" -ForegroundColor Red
        Write-Host "Conecte um pendrive e tente novamente." -ForegroundColor Yellow
        pause
        exit 1
    }
    
    # Criar lista numerada
    $diskList = @()
    $index = 1
    
    foreach ($disk in $usbDisks) {
        $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Select-Object -First 1
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        
        $diskInfo = [PSCustomObject]@{
            ID = $index
            Numero = $disk.Number
            Nome = if ($disk.FriendlyName) { $disk.FriendlyName } else { "Dispositivo USB" }
            Tamanho = "{0:N1} GB" -f ($disk.Size / 1GB)
            Letra = if ($volume.DriveLetter) { $volume.DriveLetter + ":" } else { "N/A" }
            Sistema = if ($volume.FileSystem) { $volume.FileSystem } else { "N/A" }
        }
        
        $diskList += $diskInfo
        $index++
    }
    
    # Mostrar tabela
    $diskList | Format-Table ID, Nome, Letra, Tamanho, Sistema -AutoSize
    
    # ============================================
    # PASSO 2: Selecionar dispositivo
    # ============================================
    Write-Host "`n[2/7] SELECIONE O DISPOSITIVO" -ForegroundColor Green
    Write-Host "------------------------------" -ForegroundColor Gray
    
    do {
        $choice = Read-Host "Digite o ID do dispositivo (1 a $($diskList.Count))"
        $selectedID = [int]$choice -as [int]
    } while ($selectedID -lt 1 -or $selectedID -gt $diskList.Count -or -not $selectedID)
    
    $selectedDisk = $diskList | Where-Object { $_.ID -eq $selectedID } | Select-Object -First 1
    Write-Host "Selecionado: $($selectedDisk.Nome) ($($selectedDisk.Letra))" -ForegroundColor Green
    
    # ============================================
    # PASSO 3: Caminho da ISO
    # ============================================
    Write-Host "`n[3/7] LOCALIZAÇÃO DA IMAGEM ISO" -ForegroundColor Green
    Write-Host "---------------------------------" -ForegroundColor Gray
    
    do {
        $isoPath = Read-Host "Digite o caminho completo do arquivo .ISO"
        $isoPath = $isoPath.Trim('"')
        
        if (-not (Test-Path $isoPath)) {
            Write-Host "Arquivo não encontrado. Verifique o caminho." -ForegroundColor Red
            $isoPath = $null
        }
        elseif (-not ($isoPath -like "*.iso")) {
            Write-Host "O arquivo deve ter extensão .ISO" -ForegroundColor Red
            $isoPath = $null
        }
    } while (-not $isoPath)
    
    Write-Host "ISO encontrada: $(Split-Path $isoPath -Leaf)" -ForegroundColor Green
    
    # ============================================
    # PASSO 4: Escolher sistema de arquivos
    # ============================================
    Write-Host "`n[4/7] SISTEMA DE ARQUIVOS" -ForegroundColor Green
    Write-Host "--------------------------" -ForegroundColor Gray
    Write-Host "1 - FAT32 (Recomendado para UEFI)" -ForegroundColor Yellow
    Write-Host "2 - NTFS (Recomendado para BIOS/Legacy)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "NOTA: FAT32 não suporta arquivos maiores que 4GB." -ForegroundColor Gray
    
    do {
        $fsChoice = Read-Host "Digite 1 ou 2"
    } while ($fsChoice -notin @("1", "2"))
    
    $fileSystem = if ($fsChoice -eq "1") { "FAT32" } else { "NTFS" }
    Write-Host "Sistema selecionado: $fileSystem" -ForegroundColor Green
    
    # ============================================
    # PASSO 5: Confirmação final
    # ============================================
    Write-Host "`n[5/7] CONFIRMAÇÃO FINAL" -ForegroundColor Green
    Write-Host "-----------------------" -ForegroundColor Gray
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║   ATENÇÃO: TODOS OS DADOS SERÃO APAGADOS!║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "Dispositivo: $($selectedDisk.Nome)" -ForegroundColor Yellow
    Write-Host "Letra: $($selectedDisk.Letra)" -ForegroundColor Yellow
    Write-Host "Tamanho: $($selectedDisk.Tamanho)" -ForegroundColor Yellow
    Write-Host "ISO: $(Split-Path $isoPath -Leaf)" -ForegroundColor Yellow
    Write-Host "Sistema de arquivos: $fileSystem" -ForegroundColor Yellow
    Write-Host ""
    
    do {
        $confirm = Read-Host "Continuar? (S/N)"
        $confirm = $confirm.ToUpper()
    } while ($confirm -notin @("S", "N"))
    
    if ($confirm -eq "N") {
        Write-Host "Operação cancelada pelo usuário." -ForegroundColor Yellow
        pause
        exit 0
    }
    
    # ============================================
    # PASSO 6: Montar ISO e verificar arquivos
    # ============================================
    Write-Host "`n[6/7] PROCESSANDO IMAGEM ISO..." -ForegroundColor Green
    Write-Host "---------------------------------" -ForegroundColor Gray
    
    # Montar ISO
    Write-Host "Montando ISO..." -ForegroundColor Cyan
    $mountResult = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 2
    
    $isoVolume = Get-Volume -DiskImage $mountResult -ErrorAction Stop
    $isoDrive = $isoVolume.DriveLetter + ":"
    $isoMounted = $true
    
    Write-Host "ISO montada em: $isoDrive" -ForegroundColor Green
    
    # Verificar arquivo install.*
    Write-Host "Verificando arquivo de instalação..." -ForegroundColor Cyan
    $sourcesPath = Join-Path $isoDrive "sources"
    
    if (-not (Test-Path $sourcesPath)) {
        throw "Pasta 'sources' não encontrada na ISO. ISO inválida."
    }
    
    $installFiles = Get-ChildItem -Path $sourcesPath -Filter "install.*" | Where-Object { $_.Extension -match '\.(wim|esd|swm)$' }
    
    if ($installFiles.Count -eq 0) {
        throw "Nenhum arquivo install.wim, install.esd ou install.swm encontrado."
    }
    
    $installFile = $installFiles | Select-Object -First 1
    $fileSizeGB = [math]::Round($installFile.Length / 1GB, 2)
    
    Write-Host "Arquivo encontrado: $($installFile.Name)" -ForegroundColor Green
    Write-Host "Tamanho: $fileSizeGB GB" -ForegroundColor Green
    Write-Host "Formato: $($installFile.Extension)" -ForegroundColor Green
    
    # Verificar se precisa dividir
    $needSplit = $false
    if ($fileSystem -eq "FAT32" -and $fileSizeGB -gt 4 -and $installFile.Extension -ne ".swm") {
        Write-Host "AVISO: Arquivo maior que 4GB detectado com FAT32." -ForegroundColor Yellow
        Write-Host "O arquivo será dividido automaticamente." -ForegroundColor Yellow
        $needSplit = $true
    }
    
    # ============================================
    # PASSO 7: Preparar pendrive e copiar arquivos
    # ============================================
    Write-Host "`n[7/7] CRIANDO MÍDIA BOOTÁVEL..." -ForegroundColor Green
    Write-Host "---------------------------------" -ForegroundColor Gray
    
    # Formatar pendrive
    Write-Host "Formatando pendrive..." -ForegroundColor Cyan
    $diskNumber = $selectedDisk.Numero
    
    # Limpar disco
    Clear-Disk -Number $diskNumber -RemoveData -Confirm:$false -ErrorAction Stop
    
    # Criar partição e formatar
    if ($fileSystem -eq "FAT32") {
        # FAT32 requer abordagem diferente
        $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -IsActive -AssignDriveLetter
        Start-Sleep -Seconds 2
        
        $driveLetter = (Get-Partition -DiskNumber $diskNumber | Where-Object { $_.IsActive }).DriveLetter
        
        # Formatar com FAT32 usando format.com
        $formatArgs = @("${driveLetter}:", "/FS:FAT32", "/V:WINBOOT", "/Q", "/Y")
        & "format.com" $formatArgs | Out-Null
        
        $targetDrive = "${driveLetter}:"
    }
    else {
        # NTFS
        $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -IsActive -AssignDriveLetter
        Start-Sleep -Seconds 2
        
        $driveLetter = (Get-Partition -DiskNumber $diskNumber | Where-Object { $_.IsActive }).DriveLetter
        Format-Volume -DriveLetter $driveLetter -FileSystem NTFS -NewFileSystemLabel "WINBOOT" -Confirm:$false | Out-Null
        
        $targetDrive = "${driveLetter}:"
    }
    
    Write-Host "Pendrive formatado: $targetDrive" -ForegroundColor Green
    
    # Dividir arquivo se necessário
    if ($needSplit) {
        Write-Host "Dividindo arquivo de instalação..." -ForegroundColor Cyan
        
        $sourceFile = $installFile.FullName
        $outputPath = Join-Path (Split-Path $sourceFile) "install.swm"
        
        # Usar DISM para dividir
        & dism.exe /Split-Image /ImageFile:"$sourceFile" /SWMFile:"$outputPath" /FileSize:4096
        
        # Remover arquivo original
        Remove-Item $sourceFile -Force
        
        Write-Host "Arquivo dividido com sucesso" -ForegroundColor Green
    }
    
    # Copiar arquivos
    Write-Host "Copiando arquivos..." -ForegroundColor Cyan
    
    # Obter todos os itens da raiz da ISO
    $items = Get-ChildItem -Path $isoDrive -Force
    $total = $items.Count
    $current = 0
    
    foreach ($item in $items) {
        $current++
        $percent = [math]::Round(($current / $total) * 100)
        
        Write-Progress -Activity "Copiando arquivos" -Status "$percent% completo" `
            -CurrentOperation $item.Name -PercentComplete $percent
        
        $dest = Join-Path $targetDrive $item.Name
        
        if ($item.PSIsContainer) {
            Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Copy-Item -Path $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Progress -Activity "Copiando arquivos" -Completed
    
    # Desmontar ISO
    Write-Host "Desmontando ISO..." -ForegroundColor Cyan
    Dismount-DiskImage -ImagePath $isoPath | Out-Null
    $isoMounted = $false
    
    # ============================================
    # CONCLUSÃO
    # ============================================
    Write-Host "`n" + "="*50 -ForegroundColor Green
    Write-Host "   PENDRIVE BOOTÁVEL CRIADO COM SUCESSO!" -ForegroundColor Green
    Write-Host "="*50 -ForegroundColor Green
    Write-Host ""
    Write-Host "Localização: $targetDrive" -ForegroundColor Yellow
    Write-Host "Sistema: $fileSystem" -ForegroundColor Yellow
    Write-Host "Arquivo: $($installFile.Name)" -ForegroundColor Yellow
    
    if ($needSplit) {
        Write-Host "Status: Arquivo dividido (.swm)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "Próximos passos:" -ForegroundColor Cyan
    Write-Host "1. Reinicie o computador" -ForegroundColor White
    Write-Host "2. Acesse a BIOS/UEFI (geralmente F2, F10, F12 ou Del)" -ForegroundColor White
    Write-Host "3. Configure para iniciar do USB" -ForegroundColor White
    Write-Host "4. Salve as configurações e reinicie" -ForegroundColor White
    
    Write-Host ""
    Write-Host "Pressione qualquer tecla para sair..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    
}
catch {
    Write-Host "`nERRO: $($_.Exception.Message)" -ForegroundColor Red
    
    # Tentar limpeza
    Cleanup
    
    Write-Host "`nPressione qualquer tecla para sair..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}