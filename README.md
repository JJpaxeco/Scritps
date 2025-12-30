# Scripts PowerShell

Este repositório contém três scripts PowerShell voltados para tarefas comuns no Windows:

- **Find-FilesFast.ps1**: busca de arquivos em **todos os discos/volumes** com foco em desempenho (paralelismo no PowerShell 7+), com **barra de progresso** e **salvamento automático** dos resultados em TXT.
- **TemaEscuro_transparenciaOFF.ps1**: aplica **Modo Escuro** e **desativa transparência** (perfil do usuário), reiniciando o Explorer para aplicar imediatamente.
- **pendrive-bootavel_gemini.ps1**: cria pendrive bootável do Windows a partir de uma ISO (FAT32/NTFS), com split automático de `install.wim` em `install.swm` quando necessário.

---

## Requisitos

### Find-FilesFast.ps1
- Windows
- **Recomendado: PowerShell 7+** (usa `ForEach-Object -Parallel`)
- Em PowerShell 5.1 funciona, porém **sem paralelismo** (mais lento)

### TemaEscuro_transparenciaOFF.ps1
- Windows 10/11
- PowerShell 5.1+ ou 7+
- Atua em `HKCU` (usuário atual), normalmente **não requer admin**
- Reinicia o `explorer.exe` (pode fechar janelas do Explorer temporariamente)

### pendrive-bootavel.ps1
- Windows 10/11 e Windows Server (DISM e Robocopy disponíveis por padrão)
- PowerShell 5.1+ ou 7+
- **Requer Administrador** (`#requires -RunAsAdministrator`)
- Usa cmdlets do módulo **Storage** (`Get-Disk`, `Clear-Disk`, `New-Partition`, `Format-Volume`, etc.)
- **Operação destrutiva**: apaga completamente o disco selecionado (confirmação obrigatória, a menos que use `-Force`)

---

## Como executar (básico)

1. Abra o PowerShell na pasta dos scripts.
2. Rode o script desejado:

```powershell
.\Find-FilesFast.ps1 -Extensions ".ps1"
.\TemaEscuro_transparenciaOFF.ps1
.\pendrive-bootavel_gemini.ps1
```

Se sua política de execução bloquear scripts, uma opção comum é liberar apenas na sessão atual:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

---

# 1) Find-FilesFast.ps1

## O que ele faz
- Identifica automaticamente os discos/volumes disponíveis para busca.
- Faz enumeração rápida via `.NET` (`System.IO.Directory.EnumerateFiles/Directories` + `EnumerationOptions`).
- Paraleliza por “work items” (root e diretórios de 1º nível) em PowerShell 7+.
- Exibe **barra de progresso** (por work item concluído).
- Salva automaticamente um TXT com os resultados na **mesma pasta do script**.
- Retorna no console **apenas a coluna `FullName`** (caminho completo).

## Saída automática em TXT
O script gera um arquivo TXT no diretório do script com este padrão:

- `Search-{TAG}-Result_{dd-MM-yyyy_HH-mm-ss}.txt`

Onde **TAG** vem de:
- `-Query` (se informado), ou
- lista de extensões (sem o ponto), ex.: `ps1_json`, ou
- `sem_filtro` (caso raro: sem Query e sem Extensions não é permitido)

Exemplos:
- `Search-backup-Result_27-12-2025_10-15-30.txt`
- `Search-ps1-Result_27-12-2025_10-16-02.txt`
- `Search-dll_dat-Result_27-12-2025_10-17-44.txt`

## Parâmetros principais (filtros de busca)

### -Extensions
Filtra por extensão(ões). Aceita uma ou várias:
```powershell
.\Find-FilesFast.ps1 -Extensions ".json"
.\Find-FilesFast.ps1 -Extensions ".dll",".dat"
```

### -Query
Texto/padrão principal. Funciona em conjunto com `-Mode` e `-MatchOn`:
```powershell
.\Find-FilesFast.ps1 -Query "backup"
```

### -Mode
Define como `-Query` é avaliado:
- `Contains` (padrão)
- `Wildcard`
- `Regex`

Exemplos:
```powershell
# Contains
.\Find-FilesFast.ps1 -Query "relatorio" -MatchOn Name

# Wildcard
.\Find-FilesFast.ps1 -Query "*relatorio*2025*.pdf" -Mode Wildcard -MatchOn Name

# Regex
.\Find-FilesFast.ps1 -Query "^(report|relatorio).*\.(pdf|docx)$" -Mode Regex -MatchOn Name
```

### -MatchOn
Define onde aplicar `-Query` (um ou vários):
- `Name` (nome do arquivo)
- `Extension` (extensão)
- `FullPath` (padrão)

Exemplos:
```powershell
# Apenas nome
.\Find-FilesFast.ps1 -Query "relatorio" -MatchOn Name

# Apenas extensão (quando você quer casar texto na extensão)
.\Find-FilesFast.ps1 -Query ".ps1" -MatchOn Extension

# Nome OU caminho
.\Find-FilesFast.ps1 -Query "Financeiro" -MatchOn Name,FullPath
```

### Combinações comuns
```powershell
# Somente .log que tenham "error" no nome
.\Find-FilesFast.ps1 -Extensions ".log" -Query "error" -MatchOn Name

# Regex no caminho completo: qualquer pasta Temp + .tmp
.\Find-FilesFast.ps1 -Query "\\Temp\\.*\.tmp$" -Mode Regex -MatchOn FullPath
```

## Parâmetros de escopo (onde buscar)
- `-IncludeNetworkDrives` : inclui unidades de rede (DriveType 4)
- `-IncludeOpticalDrives` : inclui CD/DVD (DriveType 5)
- `-IncludeVolumesWithoutDriveLetter` : tenta incluir volumes sem letra via `Win32_Volume`
- `-FollowReparsePoints` : segue junction/symlink/mount points (**pode causar loops/duplicidade**)

Exemplos:
```powershell
.\Find-FilesFast.ps1 -Extensions ".iso" -IncludeOpticalDrives
.\Find-FilesFast.ps1 -Extensions ".ps1" -IncludeNetworkDrives
```

## Parâmetros de performance e dados
- `-ThrottleLimit` : número de tarefas paralelas (default: núcleos lógicos)
- `-IncludeMetadata` : inclui metadados (tamanho/data) nos objetos internos (útil para CSV/JSON)

Exemplos:
```powershell
.\Find-FilesFast.ps1 -Extensions ".ps1" -ThrottleLimit 16
.\Find-FilesFast.ps1 -Extensions ".log" -IncludeMetadata -OutCsv "C:\Temp\logs.csv"
```

## Exportações opcionais
- `-OutCsv` : exporta CSV
- `-OutJson` : exporta JSON
- `-LogErrorsPath` : grava erros de enumeração/acesso em arquivo

Exemplo:
```powershell
.\Find-FilesFast.ps1 -Query "invoice" -MatchOn FullPath -OutCsv "C:\Temp\resultado.csv" -LogErrorsPath "C:\Temp\erros.txt"
```

---

# 2) TemaEscuro_transparenciaOFF.ps1

## O que ele faz
- Ajusta chaves em:
  - `HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`
- Aplica:
  - **Modo escuro para Apps**
  - **Modo escuro para Sistema**
  - **Desativa transparência**
- Reinicia o Explorer para aplicar imediatamente:
  - `Stop-Process explorer -Force`
  - `Start-Process explorer.exe`

## Como executar
```powershell
.\TemaEscuro_transparenciaOFF.ps1
```

## Observações
- O Explorer reiniciará; isso pode “piscar” a barra de tarefas e fechar janelas abertas do Explorer.
- Como altera `HKCU`, aplica-se ao **usuário atual**.

---

# 3) pendrive-bootavel.ps1

## O que ele faz
- Lista discos USB/UAS removíveis e impede seleção de discos de sistema/boot.
- Prepara o pendrive via cmdlets (`Clear-Disk`, `Initialize-Disk` quando `RAW`, `New-Partition`, `Format-Volume`) para reduzir falhas do DiskPart.
- Copia a ISO para o pendrive via **Robocopy** (com retentativas).
- Em **FAT32**:
  - Se `sources\install.wim` for >= 4GB, divide automaticamente em `install.swm`, `install2.swm`, etc. (DISM `Split-Image`).
  - Se a ISO tiver `sources\install.esd` >= 4GB, converte **ESD -> WIM** (exporta todos os indexes) e depois divide em SWM.
- Aplica `bootsect /nt60` (se disponível) para melhorar compatibilidade com boot **Legacy/BIOS** (não é necessário para UEFI puro).

## Como executar

### Interativo (recomendado)
```powershell
.\pendrive-bootavel_gemini.ps1
```

### Não interativo (com parâmetros)
```powershell
# ISO + filesystem (selecao do disco ainda sera solicitada)
.\pendrive-bootavel_gemini.ps1 -IsoPath "C:\ISO\Win10.iso" -FileSystem FAT32

# Totalmente nao interativo (CUIDADO: apaga o disco informado)
.\pendrive-bootavel_gemini.ps1 -IsoPath "C:\ISO\Win11.iso" -DiskNumber 1 -FileSystem FAT32 -Force

# Com log completo via Transcript
.\pendrive-bootavel_gemini.ps1 -IsoPath "C:\ISO\Win10.iso" -DiskNumber 1 -FileSystem NTFS -Force -LogPath "C:\Temp\pendrive-bootavel.log"
```

## Parâmetros
- `-IsoPath` (string): caminho completo do arquivo ISO.
- `-DiskNumber` (int): número do disco (conforme `Get-Disk`).
- `-FileSystem` (FAT32|NTFS): sistema de arquivos do pendrive.
- `-Force` (switch): pula a confirmação de segurança.
- `-LogPath` (string): salva um transcript (log completo) em arquivo.

## Observações e comportamento
- Confirmação de segurança: o script exige digitar exatamente `CONFIRMO` antes de apagar.
- FAT32 tem limite de arquivo de ~4GB. O split em SWM é feito com `FileSize:3800` (margem segura).
- Se a ISO usar `install.esd` grande, a conversão pode exigir espaço livre no `%TEMP%` de aproximadamente **3x** o tamanho do ESD.
- Robocopy: `ExitCode` **0..7** = sucesso (com variações); **>= 8** = falha. Exemplo comum: `ExitCode=3` indica sucesso com cópia + extras detectados.
- Se houver bloqueio por EDR/Device Control, operações como `Clear-Disk` podem falhar com `AccessDenied`.

---

## Notas e limitações

- A busca completa pode levar tempo dependendo do tamanho dos discos, quantidade de arquivos e permissões.
- Pastas inacessíveis são ignoradas; detalhes podem aparecer no log (`-LogErrorsPath`) e/ou no TXT gerado.
- Habilitar `-FollowReparsePoints` pode aumentar muito o tempo e gerar duplicidades.

---
