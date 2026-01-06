# Scripts PowerShell

Este repositorio contem tres scripts PowerShell voltados para tarefas comuns no Windows:

- **Find-FilesFast.ps1**: busca de arquivos em **todos os discos/volumes** com foco em desempenho (paralelismo no PowerShell 7+), com **barra de progresso** e **salvamento automatico** dos resultados em TXT.
- **TemaEscuro_transparenciaOFF.ps1**: aplica **Modo Escuro** e **desativa transparencia** (perfil do usuario), reiniciando o Explorer para aplicar imediatamente.
- **pendrive-bootavel.ps1**: cria pendrive bootavel do Windows a partir de uma ISO (FAT32/NTFS), com split automatico de `install.wim` em `install.swm` quando necessario, deteccao de `install*.swm` e **log automatico** no diretorio do script.

---

## Requisitos

### Find-FilesFast.ps1
- Windows
- **Recomendado: PowerShell 7+** (usa `ForEach-Object -Parallel`)
- Em PowerShell 5.1 funciona, porem **sem paralelismo** (mais lento)

### TemaEscuro_transparenciaOFF.ps1
- Windows 10/11
- PowerShell 5.1+ ou 7+
- Atua em `HKCU` (usuario atual), normalmente **nao requer admin**
- Reinicia o `explorer.exe` (pode fechar janelas do Explorer temporariamente)

### pendrive-bootavel.ps1
- Windows 10/11 e Windows Server (DISM e Robocopy disponiveis por padrao)
- PowerShell 5.1+ ou 7+
- **Requer Administrador** (`#requires -RunAsAdministrator`)
- Usa cmdlets do modulo **Storage** (`Get-Disk`, `Clear-Disk`, `New-Partition`, `Format-Volume`, etc.)
- (Opcional) Pode usar seletor de arquivo via **OpenFileDialog**; se indisponivel, cai para entrada por console
- **Operacao destrutiva**: apaga completamente o disco selecionado (confirmacao obrigatoria, a menos que use `-Force`)
- `sdasdasdasdasdasdasdasdasdasd`
---

## Como executar (basico)

1. Abra o PowerShell na pasta dos scripts.
2. Rode o script desejado:

```powershell
.\Find-FilesFast.ps1 -Extensions ".ps1"
.\TemaEscuro_transparenciaOFF.ps1
.\pendrive-bootavel.ps1
```

Se sua politica de execucao bloquear scripts, uma opcao comum e liberar apenas na sessao atual:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```
```txt
asdasd
asdasd
a
aasdasdaddas
Commit
Get-FileHash
`Print`

```
`Print`
---

# 1) Find-FilesFast.ps1

## O que ele faz
- Identifica automaticamente os discos/volumes disponiveis para busca.
- Faz enumeracao rapida via .NET (`System.IO.Directory.EnumerateFiles/Directories` + `EnumerationOptions`).
- Paraleliza por “work items” (root e diretorios de 1o nivel) em PowerShell 7+.
- Exibe **barra de progresso** (por work item concluido).
- Salva automaticamente um TXT com os resultados na **mesma pasta do script**.
- Retorna no console **apenas a coluna `FullName`** (caminho completo).

## Saida automatica em TXT
O script gera um arquivo TXT no diretorio do script com este padrao:

- `Find-FilesFast-{TAG}-Result_{dd-MM-yyyy_HH-mm-ss}.txt`

Onde **TAG** vem de:
- `-Query` (se informado), ou
- lista de extensoes (sem o ponto), ex.: `ps1_json`, ou
- `sem_filtro` (quando aplicavel)

## Parametros principais (filtros de busca)

### -Extensions
Filtra por extensao(oes). Aceita uma ou varias:
```powershell
.\Find-FilesFast.ps1 -Extensions ".json"
.\Find-FilesFast.ps1 -Extensions ".dll",".dat"
```

### -Query / -Mode / -MatchOn
Define o criterio principal de busca e como ele e avaliado.

Exemplos:
```powershell
# Contains (padrao)
.\Find-FilesFast.ps1 -Query "relatorio" -MatchOn Name

# Wildcard
.\Find-FilesFast.ps1 -Query "*relatorio*2025*.pdf" -Mode Wildcard -MatchOn Name

# Regex
.\Find-FilesFast.ps1 -Query "^(report|relatorio).*\.(pdf|docx)$" -Mode Regex -MatchOn Name
```

## Parametros de escopo (onde buscar)
- `-IncludeNetworkDrives` : inclui unidades de rede (DriveType 4)
- `-IncludeOpticalDrives` : inclui CD/DVD (DriveType 5)
- `-IncludeVolumesWithoutDriveLetter` : tenta incluir volumes sem letra via `Win32_Volume`
- `-FollowReparsePoints` : segue junction/symlink/mount points (pode causar loops/duplicidade)

Exemplos:
```powershell
.\Find-FilesFast.ps1 -Extensions ".iso" -IncludeOpticalDrives
.\Find-FilesFast.ps1 -Extensions ".ps1" -IncludeNetworkDrives
```

## Exportacoes opcionais
- `-OutCsv` : exporta CSV
- `-OutJson` : exporta JSON
- `-LogErrorsPath` : grava erros de enumeracao/acesso em arquivo

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
  - **Desativa transparencia**
- Reinicia o Explorer para aplicar imediatamente:
  - `Stop-Process explorer -Force`
  - `Start-Process explorer.exe`

## Como executar
```powershell
.\TemaEscuro_transparenciaOFF.ps1
```

## Observacoes
- O Explorer reiniciara; isso pode “piscar” a barra de tarefas e fechar janelas abertas do Explorer.
- Como altera `HKCU`, aplica-se ao **usuario atual**.

---

# 3) pendrive-bootavel.ps1

## O que ele faz
- Lista discos USB/UAS removiveis e impede selecao de discos de sistema/boot.
- Seleciona a ISO por 3 caminhos (nesta ordem):
  1) Janela de selecao de arquivo (OpenFileDialog), quando disponivel
  2) Entrada via console (permite colar o caminho; em alguns ambientes o arrastar/soltar pode nao funcionar quando o PowerShell esta elevado)
  3) Parametro `-IsoPath` (execucao nao interativa)
- Sempre exibe no console a confirmacao do caminho escolhido apos validacao:
  - `ISO selecionada: C:\caminho\arquivo.iso`
- Prepara o pendrive via cmdlets (`Clear-Disk`, `Initialize-Disk` quando `RAW`, `New-Partition`, `Format-Volume`) para reduzir falhas do DiskPart.
- Copia a ISO para o pendrive via **Robocopy** (com retentativas).
- Em **FAT32**:
  - Se `sources\install.wim` for >= 4GB, divide automaticamente em `install.swm`, `install2.swm`, etc. (DISM `Split-Image`).
  - Se a ISO tiver `sources\install.esd` >= 4GB, converte **ESD -> WIM** (exporta todos os indexes) e depois divide em SWM.
  - Se a ISO ja contiver `sources\install*.swm`, o script reconhece o cenario e **nao tenta converter/dividir**, apenas copia normalmente.
- Aplica `bootsect /nt60` (se disponivel) para melhorar compatibilidade com boot **Legacy/BIOS** (nao e necessario para UEFI puro).
- Se nao houver dispositivos USB para listar, o script exibe aviso e **aguarda uma tecla** para finalizar.
- Sempre grava um **LOG (Transcript)** no **mesmo diretorio do script**, com o padrao:
  - `pendrive-bootavel_dd-MM-yyyy_HH-mm-ss.txt`

## Como executar

### Interativo (recomendado)
```powershell
.\pendrive-bootavel.ps1
```

Durante a execucao interativa, o script tenta abrir a janela de selecao de ISO. Se nao estiver disponivel, ele solicita o caminho no console.
Ao final da selecao (por qualquer metodo), o script imprime:
- `ISO selecionada: <caminho>`

### Nao interativo (com parametros)
```powershell
# ISO + filesystem (selecao do disco ainda sera solicitada)
.\pendrive-bootavel.ps1 -IsoPath "C:\ISO\Win10.iso" -FileSystem FAT32

# Totalmente nao interativo (CUIDADO: apaga o disco informado)
.\pendrive-bootavel.ps1 -IsoPath "C:\ISO\Win11.iso" -DiskNumber 1 -FileSystem FAT32 -Force
```

## Parametros
- `-IsoPath` (string): caminho completo do arquivo ISO.
- `-DiskNumber` (int): numero do disco (conforme `Get-Disk`).
- `-FileSystem` (FAT32|NTFS): sistema de arquivos do pendrive.
- `-Force` (switch): pula a confirmacao de seguranca.

## Observacoes e comportamento
- Confirmacao de seguranca: o script exige digitar exatamente `SIM` antes de apagar.
- Observacao sobre arrastar/soltar: em janelas elevadas (Administrador), o Windows pode bloquear drag-and-drop do Explorer para o console. Nesses casos, use a janela de selecao (quando disponivel) ou copie/cole o caminho.
- FAT32 tem limite de arquivo de ~4GB. O split em SWM e feito com `FileSize:3800` (margem segura).
- Se a ISO usar `install.esd` grande, a conversao pode exigir espaco livre no `%TEMP%` de aproximadamente **3x** o tamanho do ESD.
- Robocopy: `ExitCode` **0..7** = sucesso (com variacoes); **>= 8** = falha. Exemplo comum: `ExitCode=3` indica sucesso com copia + extras detectados.
- Se houver bloqueio por EDR/Device Control, operacoes como `Clear-Disk` podem falhar com `AccessDenied`.


---

## Notas e limitacoes (geral)
- A busca completa (Find-FilesFast) pode levar tempo dependendo do tamanho dos discos, quantidade de arquivos e permissoes.
- Pastas inacessiveis sao ignoradas; detalhes podem aparecer no log (`-LogErrorsPath`) e/ou no TXT gerado.
- Habilitar `-FollowReparsePoints` pode aumentar muito o tempo e gerar duplicidades.

---