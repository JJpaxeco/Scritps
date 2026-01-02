<#
.SYNOPSIS
  Busca arquivos em todos os discos/volumes locais (e opcionalmente rede), com paralelismo e alta performance.

.REQUIREMENTS
  Recomendado: PowerShell 7+ (para -Parallel). Em PowerShell 5.1, o script roda sem paralelismo.

.EXAMPLES
  # 1) Buscar por termo no caminho completo (padrão: -Mode Contains, -MatchOn FullPath)
  .\Find-FilesFast.ps1 -Query "backup"

  # 2) Buscar por termo apenas no nome do arquivo
  .\Find-FilesFast.ps1 -Query "relatorio" -MatchOn Name

  # 3) Buscar por termo apenas na extensão
  .\Find-FilesFast.ps1 -Query ".ps1" -MatchOn Extension

  # 4) Modo Wildcard (usa * e ?)
  .\Find-FilesFast.ps1 -Query "*relatorio*2025*.pdf" -Mode Wildcard -MatchOn Name

  # 5) Modo Regex (expressão regular)
  .\Find-FilesFast.ps1 -Query "^(report|relatorio).*\.(pdf|docx)$" -Mode Regex -MatchOn Name

  # 6) Filtrar por extensões (uma ou várias)
  .\Find-FilesFast.ps1 -Extensions ".json"
  .\Find-FilesFast.ps1 -Extensions ".dll",".dat"

  # 7) Combinar extensões + termo (ex.: só .log que contenham "error" no nome)
  .\Find-FilesFast.ps1 -Extensions ".log" -Query "error" -MatchOn Name

  # 8) Combinar MatchOn múltiplo (nome OU caminho)
  .\Find-FilesFast.ps1 -Query "Financeiro" -MatchOn Name,FullPath

  # 9) Regex no caminho completo (ex.: qualquer pasta Temp + .tmp)
  .\Find-FilesFast.ps1 -Query "\\Temp\\.*\.tmp$" -Mode Regex -MatchOn FullPath

  # 10) Unidades mapeadas + UNC direto (somente se informado via parâmetro)
  .\Find-FilesFast.ps1 -Extensions ".ps1" -IncludeNetworkDrives -NetworkRoots "\\SRV01\Dados","\\SRV02\Backups"

  # 11) Incluir USB/removíveis (DriveType 2)
  .\Find-FilesFast.ps1 -Extensions ".mkv" -IncludeUsbDrives
#>

[CmdletBinding()]
param(
  [string]$Query,

  [ValidateSet('Contains','Wildcard','Regex')]
  [string]$Mode = 'Contains',

  [ValidateSet('Name','Extension','FullPath')]
  [string[]]$MatchOn = @('FullPath'),

  [string[]]$Extensions,

  # Incluir dispositivos USB/removíveis (DriveType 2)
  [switch]$IncludeUsbDrives,

  # Incluir unidades de rede mapeadas (DriveType 4) - SOMENTE se informado
  [switch]$IncludeNetworkDrives,

  # Incluir CD/DVD (DriveType 5)
  [switch]$IncludeOpticalDrives,

  # Incluir volumes sem letra (Win32_Volume), quando possível
  [switch]$IncludeVolumesWithoutDriveLetter,

  # Incluir caminhos UNC diretamente (ex.: \\servidor\share)
  [string[]]$NetworkRoots,

  # Paralelismo (PowerShell 7+). Default: núcleos lógicos.
  [ValidateRange(1, 512)]
  [int]$ThrottleLimit = [Environment]::ProcessorCount,

  # Seguir Reparse Points (junction/symlink/mount point). CUIDADO: pode criar loops/duplicidade.
  [switch]$FollowReparsePoints,

  # Coletar metadados (tamanho/data). Levemente mais lento.
  [switch]$IncludeMetadata,

  # Saídas
  [string]$OutCsv,
  [string]$OutJson,
  [string]$LogErrorsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SearchRoots {
  param(
    [switch]$IncludeUsbDrives,
    [switch]$IncludeNetworkDrives,
    [switch]$IncludeOpticalDrives,
    [switch]$IncludeVolumesWithoutDriveLetter
  )

  # Por padrão: somente FIXED (3) = discos físicos instalados
  $driveTypes = @(3) # 3=Fixed
  if ($IncludeUsbDrives)      { $driveTypes += 2 } # 2=Removable (USB)
  if ($IncludeNetworkDrives)  { $driveTypes += 4 } # 4=Network (mapeadas)
  if ($IncludeOpticalDrives)  { $driveTypes += 5 } # 5=CD-ROM

  $roots = New-Object System.Collections.Generic.List[string]

  try {
    $logical = Get-CimInstance Win32_LogicalDisk | Where-Object { $driveTypes -contains $_.DriveType -and $_.DeviceID }
    foreach ($d in $logical) {
      [void]$roots.Add(($d.DeviceID.TrimEnd('\') + '\'))
    }
  } catch {
    try {
      foreach ($di in [System.IO.DriveInfo]::GetDrives()) {
        try {
          $ok = $false
          switch ($di.DriveType) {
            'Fixed'     { $ok = ($driveTypes -contains 3) }
            'Removable' { $ok = ($driveTypes -contains 2) }
            'Network'   { $ok = ($driveTypes -contains 4) }
            'CDRom'     { $ok = ($driveTypes -contains 5) }
            default     { $ok = $false }
          }

          if ($ok -and $di.IsReady -and $di.RootDirectory -and $di.RootDirectory.FullName) {
            [void]$roots.Add($di.RootDirectory.FullName)
          }
        } catch { }
      }
    } catch { }
  }

  if ($IncludeVolumesWithoutDriveLetter) {
    $volTypes = @(3)
    if ($IncludeUsbDrives) { $volTypes += 2 }

    try {
      $vols = Get-CimInstance Win32_Volume | Where-Object {
        $_.DriveLetter -eq $null -and $_.Name -and ($_.DriveType -in $volTypes)
      }
      foreach ($v in $vols) {
        $name = $v.Name
        if ($name -and $name -notmatch '\\$') { $name += '\' }
        if ($name) { [void]$roots.Add($name) }
      }
    } catch { }
  }

  $roots |
    Where-Object { $_ -and $_.Length -ge 3 } |
    ForEach-Object { $_.Trim() } |
    Sort-Object -Unique
}

function Get-TopLevelWorkItems {
  param([string[]]$Roots)

  foreach ($root in @($Roots)) {
    [pscustomobject]@{ Path = $root; Recurse = $false; Root = $root }
    try {
      foreach ($d in [System.IO.Directory]::EnumerateDirectories($root, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
        [pscustomobject]@{ Path = $d; Recurse = $true; Root = $root }
      }
    } catch {
      [pscustomobject]@{ Path = $root; Recurse = $true; Root = $root; Note = 'FallbackRootRecurse' }
    }
  }
}

function Normalize-Extensions {
  param([string[]]$Extensions)

  $exts = @($Extensions)
  if (-not $exts -or $exts.Count -eq 0) { return $null }

  $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($e in $exts) {
    if ([string]::IsNullOrWhiteSpace($e)) { continue }
    $ext = $e.Trim()
    if (-not $ext.StartsWith('.')) { $ext = '.' + $ext }
    [void]$set.Add($ext)
  }
  return $set
}

function Get-FilePatternsFromExtensionSet {
  param($ExtensionSet)

  if (-not $ExtensionSet) { return @('*') }

  $patterns = New-Object System.Collections.Generic.List[string]
  foreach ($ext in $ExtensionSet) {
    if ([string]::IsNullOrWhiteSpace($ext)) { continue }
    $patterns.Add(('*' + $ext)) | Out-Null  # ex.: *.mkv
  }
  if ($patterns.Count -eq 0) { return @('*') }
  return $patterns.ToArray()
}

function New-MatchEvaluator {
  param(
    [string]$Query,
    [string]$Mode,
    [string[]]$MatchOn,
    $ExtensionSet
  )

  $q   = $Query
  $m   = $Mode
  $mo  = @($MatchOn)
  $set = $ExtensionSet

  $rx = $null
  if ($q -and $m -eq 'Regex') { $rx = [regex]::new($q, [Text.RegularExpressions.RegexOptions]::IgnoreCase) }

  $sb = {
    param([string]$FullPath, [string]$Name, [string]$Extension)

    if ($set) { if (-not $set.Contains($Extension)) { return $false } }
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }

    foreach ($target in $mo) {
      $value = switch ($target) { 'Name' { $Name } 'Extension' { $Extension } 'FullPath' { $FullPath } }
      if ([string]::IsNullOrEmpty($value)) { continue }
      switch ($m) {
        'Contains' { if ($value.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
        'Wildcard' { if ($value -like $q) { return $true } }
        'Regex'    { if ($rx -and $rx.IsMatch($value)) { return $true } }
      }
    }
    return $false
  }

  $sb.GetNewClosure()
}

function Search-Path {
  param(
    [string]$StartPath,
    [bool]$Recurse,
    [scriptblock]$IsMatch,
    [bool]$IncludeMetadata,
    [bool]$FollowReparsePoints,
    $ExtensionSet
  )

  $results = [System.Collections.Generic.List[object]]::new()
  $errors  = [System.Collections.Generic.List[string]]::new()

  $patterns = Get-FilePatternsFromExtensionSet -ExtensionSet $ExtensionSet

  $canUseEnumOptions = $false
  try { $null = [System.IO.EnumerationOptions]; $canUseEnumOptions = $true } catch { $canUseEnumOptions = $false }

  $enumOpt = $null
  if ($canUseEnumOptions) {
    try {
      $enumOpt = [System.IO.EnumerationOptions]::new()
      $enumOpt.RecurseSubdirectories = $false
      $enumOpt.IgnoreInaccessible = $true
      $enumOpt.ReturnSpecialDirectories = $false
      if (-not $FollowReparsePoints) { $enumOpt.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint } else { $enumOpt.AttributesToSkip = [System.IO.FileAttributes]0 }
    } catch {
      $enumOpt = $null
      $canUseEnumOptions = $false
    }
  }

  $stack = [System.Collections.Generic.Stack[string]]::new()
  $stack.Push([string]$StartPath)

  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()

    # Arquivos do diretório atual (COM PADRÃO: *.ext quando Extensions foi informado)
    try {
      if ($canUseEnumOptions -and $enumOpt) {
        foreach ($pat in $patterns) {
          foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, $pat, $enumOpt)) {
            try {
              $name = [System.IO.Path]::GetFileName($f)
              $ext  = [System.IO.Path]::GetExtension($f)

              # Blindagem extra: se ExtensionSet existir, confere também (não deveria ser necessário, mas garante)
              if ($ExtensionSet) { if (-not $ExtensionSet.Contains($ext)) { continue } }

              if (& $IsMatch $f $name $ext) {
                if ($IncludeMetadata) {
                  try {
                    $fi = [System.IO.FileInfo]::new($f)
                    $results.Add([pscustomobject]@{
                      FullName         = $fi.FullName
                      Name             = $fi.Name
                      Extension        = $fi.Extension
                      LengthBytes      = $fi.Length
                      LastWriteTimeUtc = $fi.LastWriteTimeUtc
                    }) | Out-Null
                  } catch {
                    $results.Add([pscustomobject]@{ FullName=$f; Name=$name; Extension=$ext }) | Out-Null
                  }
                } else {
                  $results.Add([pscustomobject]@{ FullName=$f; Name=$name; Extension=$ext }) | Out-Null
                }
              }
            } catch { }
          }
        }
      } else {
        foreach ($pat in $patterns) {
          foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, $pat, [System.IO.SearchOption]::TopDirectoryOnly)) {
            try {
              $name = [System.IO.Path]::GetFileName($f)
              $ext  = [System.IO.Path]::GetExtension($f)

              if ($ExtensionSet) { if (-not $ExtensionSet.Contains($ext)) { continue } }

              if (& $IsMatch $f $name $ext) {
                if ($IncludeMetadata) {
                  try {
                    $fi = [System.IO.FileInfo]::new($f)
                    $results.Add([pscustomobject]@{
                      FullName         = $fi.FullName
                      Name             = $fi.Name
                      Extension        = $fi.Extension
                      LengthBytes      = $fi.Length
                      LastWriteTimeUtc = $fi.LastWriteTimeUtc
                    }) | Out-Null
                  } catch {
                    $results.Add([pscustomobject]@{ FullName=$f; Name=$name; Extension=$ext }) | Out-Null
                  }
                } else {
                  $results.Add([pscustomobject]@{ FullName=$f; Name=$name; Extension=$ext }) | Out-Null
                }
              }
            } catch { }
          }
        }
      }
    } catch {
      $errors.Add("FILES_FAIL: $dir :: $($_.Exception.Message)") | Out-Null
    }

    if (-not $Recurse) { continue }

    # Subdiretórios
    try {
      if ($canUseEnumOptions -and $enumOpt) {
        foreach ($sd in [System.IO.Directory]::EnumerateDirectories($dir, '*', $enumOpt)) { $stack.Push($sd) }
      } else {
        foreach ($sd in [System.IO.Directory]::EnumerateDirectories($dir, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
          if (-not $FollowReparsePoints) {
            try {
              $attr = [System.IO.File]::GetAttributes($sd)
              if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            } catch { continue }
          }
          $stack.Push($sd)
        }
      }
    } catch {
      $errors.Add("DIRS_FAIL: $dir :: $($_.Exception.Message)") | Out-Null
    }
  }

  [pscustomobject]@{ Results = $results.ToArray(); Errors = $errors.ToArray() }
}

# ---------------- MAIN ----------------

if (-not $Query -and (-not $Extensions -or @($Extensions).Count -eq 0)) {
  throw 'Informe -Query e/ou -Extensions. Ex.: -Query "report" ou -Extensions ".dll",".dat".'
}

$roots = @(Get-SearchRoots `
  -IncludeUsbDrives:$IncludeUsbDrives `
  -IncludeNetworkDrives:$IncludeNetworkDrives `
  -IncludeOpticalDrives:$IncludeOpticalDrives `
  -IncludeVolumesWithoutDriveLetter:$IncludeVolumesWithoutDriveLetter
)

if (-not $roots -or $roots.Count -eq 0) { throw "Não foi possível identificar discos/volumes para busca." }

if ($NetworkRoots -and @($NetworkRoots).Count -gt 0) {
  foreach ($nr in @($NetworkRoots)) {
    if ([string]::IsNullOrWhiteSpace($nr)) { continue }
    $p = $nr.Trim()
    if ($p -notmatch '\\$') { $p += '\' }
    $roots += $p
  }
  $roots = @($roots | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object -Unique)
}

$workItems = @(Get-TopLevelWorkItems -Roots $roots)

# --- Progresso ---
$totalWork = $workItems.Count
$doneWork  = 0
$progressEvery = if ($totalWork -le 200) { 1 } else { 25 }
$activity = "Find-FilesFast - Pesquisando"
# ---------------

$allResults = [System.Collections.Generic.List[object]]::new()
$allErrors  = [System.Collections.Generic.List[string]]::new()

if ($PSVersionTable.PSVersion.Major -ge 7) {
  $queryLocal  = $Query
  $modeLocal   = $Mode
  $matchLocal  = @($MatchOn)
  $extLocal    = @($Extensions)
  $metaLocal   = [bool]$IncludeMetadata
  $followLocal = [bool]$FollowReparsePoints

  $workItems |
    ForEach-Object -Parallel {
      $wi = $_
      if (-not $wi -or [string]::IsNullOrWhiteSpace([string]$wi.Path)) {
        return [pscustomobject]@{ WorkItemPath = ''; Results=@(); Errors=@("WORKITEM_INVALID") }
      }

      $q      = $using:queryLocal
      $m      = $using:modeLocal
      $mo     = @($using:matchLocal)
      $exts   = @($using:extLocal)
      $meta   = [bool]$using:metaLocal
      $follow = [bool]$using:followLocal

      $extSet = $null
      if ($exts -and $exts.Count -gt 0) {
        $extSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($e in $exts) {
          if ([string]::IsNullOrWhiteSpace($e)) { continue }
          $ex = $e.Trim()
          if (-not $ex.StartsWith('.')) { $ex = '.' + $ex }
          [void]$extSet.Add($ex)
        }
      }

      $patterns = @('*')
      if ($extSet) {
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($x in $extSet) { $list.Add(('*' + $x)) | Out-Null }  # *.mkv
        if ($list.Count -gt 0) { $patterns = $list.ToArray() }
      }

      $rx = $null
      if ($q -and $m -eq 'Regex') { $rx = [regex]::new($q, [Text.RegularExpressions.RegexOptions]::IgnoreCase) }

      $IsMatch = {
        param([string]$FullPath, [string]$Name, [string]$Extension)
        if ($extSet) { if (-not $extSet.Contains($Extension)) { return $false } }
        if ([string]::IsNullOrWhiteSpace($q)) { return $true }

        foreach ($target in $mo) {
          $value = switch ($target) { 'Name' { $Name } 'Extension' { $Extension } 'FullPath' { $FullPath } }
          if ([string]::IsNullOrEmpty($value)) { continue }
          switch ($m) {
            'Contains' { if ($value.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
            'Wildcard' { if ($value -like $q) { return $true } }
            'Regex'    { if ($rx -and $rx.IsMatch($value)) { return $true } }
          }
        }
        return $false
      }

      $results = [System.Collections.Generic.List[object]]::new()
      $errors  = [System.Collections.Generic.List[string]]::new()

      $enumOpt = [System.IO.EnumerationOptions]::new()
      $enumOpt.RecurseSubdirectories = $false
      $enumOpt.IgnoreInaccessible = $true
      $enumOpt.ReturnSpecialDirectories = $false
      if (-not $follow) { $enumOpt.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint } else { $enumOpt.AttributesToSkip = [System.IO.FileAttributes]0 }

      $stack = [System.Collections.Generic.Stack[string]]::new()
      $stack.Push([string]$wi.Path)

      while ($stack.Count -gt 0) {
        $dir = $stack.Pop()

        # Arquivos: usa *.ext quando houver Extensions
        try {
          foreach ($pat in $patterns) {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, $pat, $enumOpt)) {
              try {
                $name = [System.IO.Path]::GetFileName($f)
                $ext  = [System.IO.Path]::GetExtension($f)

                if ($extSet) { if (-not $extSet.Contains($ext)) { continue } }

                if (& $IsMatch $f $name $ext) {
                  if ($meta) {
                    try {
                      $fi = [System.IO.FileInfo]::new($f)
                      $results.Add([pscustomobject]@{ FullName=$fi.FullName; Name=$fi.Name; Extension=$fi.Extension; LengthBytes=$fi.Length; LastWriteTimeUtc=$fi.LastWriteTimeUtc }) | Out-Null
                    } catch {
                      $results.Add([pscustomobject]@{ FullName=$f; Name=$name; Extension=$ext }) | Out-Null
                    }
                  } else {
                    $results.Add([pscustomobject]@{ FullName=$f; Name=$name; Extension=$ext }) | Out-Null
                  }
                }
              } catch { }
            }
          }
        } catch {
          $errors.Add("FILES_FAIL: $dir :: $($_.Exception.Message)") | Out-Null
        }

        if (-not [bool]$wi.Recurse) { continue }

        try {
          foreach ($sd in [System.IO.Directory]::EnumerateDirectories($dir, '*', $enumOpt)) { $stack.Push($sd) }
        } catch {
          $errors.Add("DIRS_FAIL: $dir :: $($_.Exception.Message)") | Out-Null
        }
      }

      [pscustomobject]@{
        WorkItemPath = [string]$wi.Path
        Results      = $results.ToArray()
        Errors       = $errors.ToArray()
      }

    } -ThrottleLimit $ThrottleLimit |
    ForEach-Object {
      $doneWork++
      if (($doneWork -eq 1) -or ($doneWork -eq $totalWork) -or ($doneWork % $progressEvery -eq 0)) {
        $pct = if ($totalWork -gt 0) { [int](($doneWork / $totalWork) * 100) } else { 100 }
        $statusPath = if ([string]::IsNullOrWhiteSpace($_.WorkItemPath)) { '(item inválido)' } else { $_.WorkItemPath }
        Write-Progress -Id 1 -Activity $activity -Status ("{0}/{1} | {2}" -f $doneWork, $totalWork, $statusPath) -PercentComplete $pct
      }
      foreach ($r in @($_.Results)) { $allResults.Add($r) | Out-Null }
      foreach ($e in @($_.Errors))  { $allErrors.Add([string]$e) | Out-Null }
    }

  Write-Progress -Id 1 -Activity $activity -Completed
}
else {
  $extSet  = Normalize-Extensions -Extensions $Extensions
  $matcher = New-MatchEvaluator -Query $Query -Mode $Mode -MatchOn $MatchOn -ExtensionSet $extSet

  foreach ($wi in $workItems) {
    $o = Search-Path `
      -StartPath $wi.Path `
      -Recurse ([bool]$wi.Recurse) `
      -IsMatch $matcher `
      -IncludeMetadata:$IncludeMetadata `
      -FollowReparsePoints:$FollowReparsePoints `
      -ExtensionSet $extSet

    foreach ($r in @($o.Results)) { $allResults.Add($r) | Out-Null }
    foreach ($e in @($o.Errors))  { $allErrors.Add([string]$e) | Out-Null }

    $doneWork++
    if (($doneWork -eq 1) -or ($doneWork -eq $totalWork) -or ($doneWork % $progressEvery -eq 0)) {
      $pct = if ($totalWork -gt 0) { [int](($doneWork / $totalWork) * 100) } else { 100 }
      $statusPath = if ([string]::IsNullOrWhiteSpace([string]$wi.Path)) { '(item inválido)' } else { [string]$wi.Path }
      Write-Progress -Id 1 -Activity $activity -Status ("{0}/{1} | {2}" -f $doneWork, $totalWork, $statusPath) -PercentComplete $pct
    }
  }

  Write-Progress -Id 1 -Activity $activity -Completed
}

$final = $allResults | Sort-Object FullName -Unique

# --- SAÍDA TXT AUTOMÁTICA (na mesma pasta do script) ---
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$searchTag = if (-not [string]::IsNullOrWhiteSpace($Query)) {
  $Query
} elseif (@($Extensions).Count -gt 0) {
  (@($Extensions) | ForEach-Object { $_.Trim().TrimStart('.') }) -join '_'
} else {
  'sem_filtro'
}

$searchTag = $searchTag -replace '[\\/:*?"<>|]', '_'
$searchTag = $searchTag -replace '\s+', '_'
$searchTag = $searchTag.Trim('_')
if ($searchTag.Length -gt 80) { $searchTag = $searchTag.Substring(0, 80) }

$outTxtPath = Join-Path $scriptDir ("Find-FilesFast-{0}-Result_{1}.txt" -f $searchTag,(Get-Date -Format 'dd-MM-yyyy_HH-mm-ss'))

$queryLabel = if ([string]::IsNullOrWhiteSpace($Query)) { '(vazio)' } else { $Query }
$extensionsLabel = if ($Extensions -and @($Extensions).Count -gt 0) { ((@($Extensions) | Where-Object { $_ }) -join ', ') } else { '(nenhuma)' }

@(
  'Find-FilesFast - Resultado'
  ("Data/Hora: {0}" -f (Get-Date -Format 'dd-MM-yyyy HH:mm:ss'))
  ("Query: {0}" -f $queryLabel)
  ("Mode: {0}" -f $Mode)
  ("MatchOn: {0}" -f (@($MatchOn) -join ', '))
  ("Extensions: {0}" -f $extensionsLabel)
  ("Total encontrados: {0}" -f @($final).Count)
  ''
  '=== ARQUIVOS ==='
) | Set-Content -LiteralPath $outTxtPath -Encoding utf8

if (@($final).Count -gt 0) {
  $final | Sort-Object FullName | ForEach-Object { $_.FullName } | Add-Content -LiteralPath $outTxtPath -Encoding utf8
} else {
  '(nenhum arquivo encontrado)' | Add-Content -LiteralPath $outTxtPath -Encoding utf8
}

if (@($allErrors).Count -gt 0) {
  '' | Add-Content -LiteralPath $outTxtPath -Encoding utf8
  '=== ERROS (enumeração/acesso) ===' | Add-Content -LiteralPath $outTxtPath -Encoding utf8
  $allErrors | Add-Content -LiteralPath $outTxtPath -Encoding utf8
}
# ------------------------------------------------------

if ($LogErrorsPath) { try { $allErrors | Set-Content -LiteralPath $LogErrorsPath -Encoding UTF8 } catch { } }
if ($OutCsv) { $final | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8 }
if ($OutJson) { $final | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutJson -Encoding UTF8 }

$final | Select-Object -Property FullName