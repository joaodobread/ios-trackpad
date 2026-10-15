# Instala o TracePad no Windows: dependências (pip), atalho na pasta Inicializar (sobe no logon, sem janela) e firewall.
# Rode da pasta do projeto:  powershell -ExecutionPolicy Bypass -File windows\install.ps1
# Para remover:              powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Uninstall
param([switch]$Uninstall)
$ErrorActionPreference = "Continue"

$Dir = Split-Path -Parent $PSScriptRoot
$Script = Join-Path $Dir "windows\tracepad.py"
$Web = Join-Path $Dir "web"
$Lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "TracePad.lnk"
$Log = Join-Path $HOME ".tracepad.log"

function Stop-TracePad {
  Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*tracepad.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
  Stop-TracePad
  Remove-Item $Lnk -ErrorAction SilentlyContinue
  if (Get-NetFirewallRule -DisplayName "TracePad" -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName "TracePad" -ErrorAction SilentlyContinue
  }
  Write-Host "TracePad parado e removido da inicialização."
  exit 0
}

Write-Host "Procurando o Python…"
$PyExe = $null
foreach ($c in "py", "python", "python3") {
  if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { continue }
  $out = & $c -c "import sys; print(sys.executable)" 2>$null   # o atalho da Microsoft Store falha aqui
  if ($LASTEXITCODE -eq 0 -and $out) { $PyExe = ($out | Select-Object -Last 1).Trim(); break }
}
if (-not $PyExe) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "Python não encontrado: instalando pelo winget…"
    winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
    Write-Host "Feche e abra o PowerShell e rode este script de novo."
  } else {
    Write-Host "Instale o Python 3 (python.org ou Microsoft Store) e rode este script de novo."
  }
  exit 1
}
$PyW = Join-Path (Split-Path $PyExe) "pythonw.exe"
if (-not (Test-Path $PyW)) { $PyW = $PyExe }
Write-Host "  $PyExe"

Write-Host "Instalando dependências (psutil, bleak, pycaw, wmi, winrt, Pillow)…"
& $PyExe -m pip install --user --upgrade --disable-pip-version-check -r (Join-Path $PSScriptRoot "requirements.txt")
if ($LASTEXITCODE -ne 0) { Write-Host "⚠ pip falhou em algum pacote: o TracePad sobe mesmo assim, só sem esse recurso." }

Write-Host "Criando o atalho na pasta Inicializar (sobe sozinho ao entrar no Windows)…"
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($Lnk)
$s.TargetPath = $PyW
$s.Arguments = "`"$Script`" `"$Web`""
$s.WorkingDirectory = $Dir
$s.WindowStyle = 7
$s.Description = "TracePad (iPhone como trackpad)"
$s.Save()

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
$port = if ($env:TRACEPAD_PORT) { [int]$env:TRACEPAD_PORT } else { 8787 } # o WebSocket fica na seguinte
if ($admin) {
  Get-NetFirewallRule -DisplayName "TracePad" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName "TracePad" -Direction Inbound -Protocol TCP -LocalPort $port, ($port + 1) -Action Allow `
    -Profile Private, Domain | Out-Null
  Write-Host "Firewall: portas $port/$($port + 1) liberadas nas redes privadas (PWA por Wi-Fi)."
} else {
  Write-Host "Firewall: na primeira vez o Windows pergunta; permita em 'Redes privadas' (ou rode como administrador)."
}

if (-not (Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue)) {
  Write-Host "⚠ USB: instale o app 'Dispositivos Apple' (Microsoft Store) ou o iTunes para o cabo funcionar."
}

Write-Host "Iniciando…"
Stop-TracePad
Start-Process -FilePath $PyW -ArgumentList "`"$Script`"", "`"$Web`"" -WorkingDirectory $Dir
Start-Sleep -Seconds 3
if (Test-Path $Log) { Get-Content $Log -Tail 6 }

Write-Host ""
Write-Host "Pronto. Logs: $Log   (PIN do PWA em $HOME\.tracepad-pin)"
Write-Host "USB: com o iPhone plugado e desbloqueado, toque em Confiar (abra o app Dispositivos Apple uma vez se não pedir)."
Write-Host "Bluetooth: deixe o app aberto no iPhone; o pareamento é pedido na primeira conexão."
