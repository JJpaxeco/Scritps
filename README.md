# Scripts PowerShell — Find-FilesFast + Tema Escuro

Este repositório contém dois scripts PowerShell voltados para tarefas comuns no Windows:

- **Find-FilesFast.ps1**: busca de arquivos em **todos os discos/volumes** com foco em desempenho (paralelismo no PowerShell 7+), com **barra de progresso** e **salvamento automático** dos resultados em TXT.
- **TemaEscuro_transparenciaOFF.ps1**: aplica **Modo Escuro** e **desativa transparência** (perfil do usuário), reiniciando o Explorer para aplicar imediatamente.

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

---

## Como executar (básico)

1. Abra o PowerShell na pasta dos scripts.
2. Rode o script desejado:

```powershell
.\Find-FilesFast.ps1 -Extensions ".ps1"
.\TemaEscuro_transparenciaOFF.ps1
