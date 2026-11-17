param(
    [string] $Emacs = 'emacs',
    [string] $Tools = (Join-Path $PSScriptRoot '../var/multi-vcs/tools'),
    [switch] $Unicode
)
# Uses only a disposable local P4D and workspace under this checkout's var/.
# Put p4.exe and p4d.exe in var/multi-vcs/tools before running this script.
$ErrorActionPreference = 'Stop'
$repoPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$toolsPath = (Resolve-Path -LiteralPath $Tools).Path
$varPath = [IO.Path]::GetFullPath((Join-Path $repoPath 'var/multi-vcs'))
if (-not $toolsPath.StartsWith($varPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test binaries must be stored under this checkout''s var/multi-vcs/.'
}
$p4Path = (Resolve-Path -LiteralPath (Join-Path $toolsPath 'p4.exe')).Path
$p4dPath = (Resolve-Path -LiteralPath (Join-Path $toolsPath 'p4d.exe')).Path
$emacsPath = (Get-Command $Emacs -ErrorAction Stop).Source
$testPath = Join-Path $varPath ('p4-check-' + [guid]::NewGuid().ToString('N'))
$serverRoot = (New-Item -ItemType Directory -Path (Join-Path $testPath 'server') -Force).FullName
$clientRoot = (New-Item -ItemType Directory -Path (Join-Path $testPath 'client')).FullName
$savedEnvironment = @{}
Get-ChildItem Env: | Where-Object { $_.Name -like 'P4*' -or $_.Name -like 'NEO_P4_TEST_*' } | ForEach-Object {
    $savedEnvironment[$_.Name] = $_.Value
}
$serverProcess = $null
Push-Location -LiteralPath $repoPath
try {
    Get-ChildItem Env: | Where-Object { $_.Name -like 'P4*' -or $_.Name -like 'NEO_P4_TEST_*' } | ForEach-Object {
        Remove-Item -LiteralPath ('Env:' + $_.Name)
    }
    $env:P4ENVIRO = Join-Path $testPath 'p4enviro'
    $env:P4TICKETS = Join-Path $testPath 'p4tickets'
    $env:P4TRUST = Join-Path $testPath 'p4trust'
    $env:P4ALIASES = Join-Path $testPath 'p4aliases'
    $env:P4CONFIG = '.neo-p4-test-config'
    $env:P4IGNORE = '.neo-p4-test-ignore'
    $env:P4CLIENT = 'neo-ws'
    $env:P4USER = 'neo-user'
    if ($Unicode) {
        & $p4dPath -r $serverRoot -xi
        if ($LASTEXITCODE -ne 0) { throw 'Isolated Unicode database initialization failed.' }
        $env:P4CHARSET = 'utf8'
        $env:P4COMMANDCHARSET = 'utf8'
        $env:NEO_P4_TEST_UNICODE = '1'
    }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $env:P4PORT = "127.0.0.1:$port"
    $serverProcess = Start-Process -FilePath $p4dPath -ArgumentList "-r `"$serverRoot`" -p $env:P4PORT -J off -L p4d.log -v dm.user.noautocreate=0 -v dm.user.setinitialpasswd=1" -WorkingDirectory $serverRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $serverRoot 'stdout') -RedirectStandardError (Join-Path $serverRoot 'stderr')
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $serverProcess.Refresh()
        if ($serverProcess.HasExited) { throw 'The isolated P4D exited during startup.' }
        $socket = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($socket) {
            if ($socket.OwningProcess -ne $serverProcess.Id) { throw 'Another process owns the test port.' }
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw 'The isolated P4D did not start listening.' }
    # Explicit flags and verified port ownership precede every server mutation.
    $password = 'Neo!' + [guid]::NewGuid().ToString('N')
    "$password`n$password" | & $p4Path -p $env:P4PORT -u $env:P4USER passwd
    if ($LASTEXITCODE -ne 0) { throw 'Test user password setup failed.' }
    $password | & $p4Path -p $env:P4PORT -u $env:P4USER login
    if ($LASTEXITCODE -ne 0) { throw 'Test login failed.' }
    "Client: neo-ws`nOwner: neo-user`nRoot: $clientRoot`nView:`n    //depot/... //neo-ws/..." | & $p4Path -p $env:P4PORT -u $env:P4USER -c $env:P4CLIENT -d $clientRoot client -i
    if ($LASTEXITCODE -ne 0) { throw 'Test workspace setup failed.' }
    $env:NEO_P4_TEST_WORKSPACE = $clientRoot
    $env:NEO_P4_TEST_TOOLS = $toolsPath
    # Load before backend tests so temporary files and Emacs caches stay local.
    $bootstrap = Join-Path $testPath 'bootstrap.el'
    @'
;;; Isolated P4 checks. -*- lexical-binding: t; -*-
(setq temporary-file-directory (file-name-directory load-file-name)
      user-emacs-directory (expand-file-name "emacs/" temporary-file-directory)
      native-comp-jit-compilation nil native-comp-deferred-compilation nil
      create-lockfiles nil)
(make-directory user-emacs-directory t)
(when (fboundp 'startup-redirect-eln-cache)
  (startup-redirect-eln-cache (expand-file-name "eln" user-emacs-directory)))
'@ | Set-Content -LiteralPath $bootstrap -Encoding utf8
    & $emacsPath -Q --batch -l $bootstrap -L . -l check-vcs-p4.el -f ert-run-tests-batch-and-exit
    if ($LASTEXITCODE -ne 0) { throw 'Perforce ERT checks failed.' }
} finally {
    if ($serverProcess) {
        $serverProcess.Refresh()
        if (-not $serverProcess.HasExited) {
            Stop-Process -InputObject $serverProcess
            $serverProcess.WaitForExit(5000) | Out-Null
        }
    }
    $ticketPath = Join-Path $testPath 'p4tickets'
    if (Test-Path -LiteralPath $ticketPath) { Remove-Item -LiteralPath $ticketPath -Force }
    Get-ChildItem Env: | Where-Object { $_.Name -like 'P4*' -or $_.Name -like 'NEO_P4_TEST_*' } | ForEach-Object {
        Remove-Item -LiteralPath ('Env:' + $_.Name)
    }
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        Set-Item -LiteralPath ('Env:' + $entry.Key) -Value $entry.Value
    }
    Pop-Location
}
