# ==========================
# Compatível com Windows PowerShell 5.1 e PowerShell 7+.
# Execução (PS 5.1): powershell.exe -ExecutionPolicy Bypass -NoProfile -File "CAMINHO_DO_SCRIPT"
# Execução (PS 7+):  pwsh.exe       -ExecutionPolicy Bypass -NoProfile -File "CAMINHO_DO_SCRIPT"
#
# Logoff remoto via quser/query user/qwinsta + logoff (interativo)
# Requer permissões administrativas no host remoto, e conectividade RPC/serviços do RDS.
# ==========================

function Write-Info($m){ Write-Host $m -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host $m -ForegroundColor Green }
function Write-Err($m){ Write-Host $m -ForegroundColor Red }
function Write-Warn($m){ Write-Host $m -ForegroundColor Yellow }

function Ask-YesNo {
  param([Parameter(Mandatory)][string]$Message)
  while ($true) {
    $a = (Read-Host $Message).Trim()
    if ($a -match '^(s|sim)$') { return $true }
    if ($a -match '^(n|nao|não)$') { return $false }
    Write-Warn "Responda apenas S ou N."
  }
}

# Heurística de nome de sessão (mais segura que a regex anterior)
function Test-IsSessionName {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return $false }
  $s = $s.Trim()

  if ($s -match '^(?:console|services|-)$') { return $true }
  if ($s -match '^(?:rdp|ica|ssh|tty)[\w\-]*#\d+$') { return $true }  # ex.: rdp-tcp#12, ica-tcp#3
  return $false
}

# Guarda o último erro de listagem para mensagem mais útil no loop principal
$script:LastRemoteSessionError = $null

function Get-RemoteSessions {
  param([Parameter(Mandatory)][string]$Computer)

  $script:LastRemoteSessionError = $null

  function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Args)

    $out = & $Exe @Args 2>&1 | ForEach-Object { $_.ToString() }
    $ec = $LASTEXITCODE

    if (-not $out -or ($out.Count -eq 0)) { return $null }

    # Alguns comandos às vezes retornam texto de erro mesmo quando $LASTEXITCODE não é confiável
    $first = ($out | Select-Object -First 1)
    if ($ec -ne 0 -or $first -match '(?i)\berror\b|RPC|acesso negado|access is denied|the network path was not found|não foi possível') {
      $script:LastRemoteSessionError = $first
      return $null
    }

    return $out
  }

  # 1) Coleta bruta (ordem: quser -> query user -> qwinsta)
  $raw = Invoke-Native -Exe 'quser' -Args @("/server:$Computer")
  if (-not $raw) { $raw = Invoke-Native -Exe 'query' -Args @('user', "/server:$Computer") }
  if (-not $raw) { $raw = Invoke-Native -Exe 'qwinsta' -Args @("/server:$Computer") }
  if (-not $raw) { return @() }

  # Normaliza para lista de linhas (garante que string única não vire lista de chars)
  $lines = @()
  foreach($l in @($raw)){
    if ($null -ne $l) {
      $s = $l.ToString()
      if ($s.Trim().Length -gt 0) { $lines += $s }
    }
  }
  if ($lines.Count -le 1) { return @() }  # só cabeçalho ou vazio

  # Remove cabeçalho
  $data = $lines | Select-Object -Skip 1

  $out = @()

  foreach ($line in $data) {
    $clean = ($line -replace '^\s*>','').Trim()
    if (-not $clean) { continue }

    # Tokeniza por qualquer espaço (funciona melhor em PT-BR/EN e colunas variáveis)
    $tok = $clean -split '\s+'
    if ($tok.Count -lt 2) { continue }

    # ID = primeiro token puramente numérico
    $idTok = ($tok | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    if (-not $idTok) { continue }

    $idIdx = [Array]::IndexOf($tok, $idTok)

    $user = ''
    $sess = ''

    # Caso comum com SESSIONNAME vazio: [USERNAME] [ID] ...
    if ($idIdx -eq 1) {
      $user = $tok[0]
      $sess = ''
    }
    elseif ($idIdx -ge 2) {
      $before1 = $tok[$idIdx-1]
      $before2 = $tok[$idIdx-2]

      if (Test-IsSessionName $before2) { $sess = $before2; $user = $before1 }
      elseif (Test-IsSessionName $before1) { $sess = $before1; $user = $before2 }
      else { $user = $before2; $sess = $before1 }  # padrão típico: [user][sess][ID]
    }
    else {
      continue
    }

    if ($null -eq $user) { $user = '' }
    if ($null -eq $sess) { $sess = '' }

    $out += [pscustomobject]@{
      ID          = [int]$idTok
      Username    = $user
      SessionName = $sess
    }
  }

  return $out
}

function Logoff-Session {
  param([Parameter(Mandatory)][string]$Computer, [Parameter(Mandatory)][int]$Id)
  try {
    & logoff $Id "/server:$Computer" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

# ---------------- Loop principal ----------------
while ($true) {

  $computer = Read-Host "Digite o HOSTNAME ou IP da máquina remota (ex.: PC-JUNIOR ou 192.168.0.10)"
  if ([string]::IsNullOrWhiteSpace($computer)) { Write-Warn "Entrada vazia. Encerrando."; break }

  Write-Info "Consultando sessões em $computer ..."
  $sessions = Get-RemoteSessions -Computer $computer

  if (-not $sessions -or $sessions.Count -eq 0) {
    $extra = $script:LastRemoteSessionError
    if ($extra) { Write-Err "Não foi possível listar sessões em $computer. Detalhe: $extra" }
    else { Write-Err "Não foi possível listar sessões em $computer. Verifique permissões (admin), serviço RDS/TermService e regras de firewall para gerenciamento remoto (RPC/Serviços do Terminal)." }

    if (Ask-YesNo "Tentar outro computador? (S/N)") { continue } else { break }
  }

  $sessions | Sort-Object ID | Format-Table ID,Username,SessionName -Auto | Out-Host

  $choice = Read-Host "Finalizar (A) todas as sessões com usuário ou (E) uma específica? [A/E]"
  if ($choice -match '^(a|A)$') {

    $targets = $sessions | Where-Object { $_.Username }  # evita 'services' etc.
    if (-not $targets) { Write-Warn "Não há sessões de usuário para desconectar."; continue }

    if (-not (Ask-YesNo ("Deseja desconectar TODOS os {0} usuário(s) em {1}? (S/N)" -f $targets.Count, $computer))) { continue }

    foreach ($t in $targets) {
      $who = (if ($t.Username) { $t.Username } else { '(sem usuário)' })
      $ok = Logoff-Session -Computer $computer -Id $t.ID
      if ($ok) { Write-Ok ("Sucesso! ID {0} ({1})" -f $t.ID, $who) }
      else     { Write-Err ("Falha! ID {0} ({1})" -f $t.ID, $who) }
    }

  } elseif ($choice -match '^(e|E)$') {

    $sel = Read-Host "Digite o ID da sessão OU o NOME do usuário a encerrar"
    if ([string]::IsNullOrWhiteSpace($sel)) { Write-Warn "Nada informado."; continue }

    $target = $null
    if ($sel -match '^\d+$') {

      $target = $sessions | Where-Object { $_.ID -eq [int]$sel } | Select-Object -First 1
      if (-not $target) { Write-Err "ID $sel não encontrado."; continue }

    } else {

      $matches = $sessions | Where-Object { $_.Username -and $_.Username -ieq $sel }
      if (-not $matches) { $matches = $sessions | Where-Object { $_.Username -and $_.Username -ilike "*$sel*" } }
      if (-not $matches) { Write-Err "Usuário '$sel' não encontrado."; continue }

      if ($matches.Count -gt 1) {
        Write-Warn "Várias sessões encontradas:"
        $matches | Sort-Object ID | Format-Table ID,Username,SessionName -Auto | Out-Host
        $id = Read-Host "Informe o ID exato"
        if ($id -notmatch '^\d+$') { Write-Err "ID inválido."; continue }
        $target = $matches | Where-Object { $_.ID -eq [int]$id } | Select-Object -First 1
        if (-not $target) { Write-Err "ID não encontrado."; continue }
      } else {
        $target = $matches[0]
      }
    }

    $label = $target.Username
    if (-not $label) { $label = "ID $($target.ID)" }

    if (-not (Ask-YesNo "Deseja desconectar o usuário $label ? (S/N)")) { continue }

    $ok = Logoff-Session -Computer $computer -Id $target.ID
    if ($ok) { Write-Ok "Sucesso!" } else { Write-Err "Falha!" }

  } else {
    Write-Warn "Opção inválida. Use 'A' ou 'E'."
    continue
  }

  if (Ask-YesNo "Deseja desconectar mais usuários? (S/N)") { continue } else { break }
}

Write-Info "Fim."
