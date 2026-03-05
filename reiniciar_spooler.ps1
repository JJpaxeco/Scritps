# Reinicia o Spooler e limpa a fila local de impressão, idempotente
$spoolPath = Join-Path $env:windir 'System32\spool\PRINTERS'
$svc = Get-Service -Name Spooler -ErrorAction Stop
if ($svc.Status -ne 'Stopped') {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    (Get-Service -Name Spooler).WaitForStatus('Stopped', '00:01:00')
}
if (Test-Path $spoolPath) {
    Remove-Item -Path (Join-Path $spoolPath '*') -Force -ErrorAction SilentlyContinue
}
$svc = Get-Service -Name Spooler -ErrorAction Stop
if ($svc.Status -ne 'Running') {
    Start-Service -Name Spooler -ErrorAction Stop
    (Get-Service -Name Spooler).WaitForStatus('Running', '00:01:00')
}
