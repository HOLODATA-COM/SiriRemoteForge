$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$release = Join-Path $project 'src-tauri/target/x86_64-pc-windows-msvc/release'
$installer = Get-ChildItem (Join-Path $release 'bundle/nsis') -Filter '*.exe' | Select-Object -First 1
if (!$installer) { throw 'Windows installer was not produced.' }
$destination = Join-Path $env:RUNNER_TEMP 'VoiceInk-install-smoke'
$install = Start-Process -FilePath $installer.FullName -ArgumentList @('/S', "/D=$destination") -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "Silent installation failed: $($install.ExitCode)" }
$executable = Join-Path $destination 'voiceink.exe'
if (!(Test-Path $executable)) { throw 'Installed app executable is missing.' }
if ((Get-FileHash $executable).Hash -ne (Get-FileHash (Join-Path $release 'voiceink.exe')).Hash) {
    throw 'Installed executable differs from the packaged build.'
}
$notices = Get-ChildItem $destination -Recurse -Filter 'THIRD_PARTY_NOTICES.txt'
if (!$notices) { throw 'Dependency license notices are missing from the installation.' }
$app = $null
try {
    $app = Start-Process -FilePath $executable -PassThru
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        Start-Sleep -Seconds 1
        $app.Refresh()
        if ($app.HasExited) { throw "App exited during startup: $($app.ExitCode)" }
        if ($app.MainWindowHandle -ne 0) { break }
    }
    if ($app.MainWindowHandle -eq 0) { throw 'App did not create its main window.' }
    $second = Start-Process -FilePath $executable -PassThru
    if (!$second.WaitForExit(10000)) { throw 'Second launch did not converge on the existing instance.' }
    $running = @(Get-Process -Name 'voiceink' -ErrorAction SilentlyContinue)
    if ($running.Count -ne 1) { throw "Expected one app process, found $($running.Count)." }
    Write-Output 'WINDOWS_SMOKE_PASS: silent install, executable equality, bundled notices, window startup, single instance.'
    Write-Output 'Microphone, provider transcription and editor insertion still require real-user acceptance.'
} finally {
    Get-Process -Name 'voiceink' -ErrorAction SilentlyContinue | Stop-Process -Force
}
