param([ValidateSet('host','runtime')][string]$Phase)
$ErrorActionPreference = 'Stop'
function SFailure($e) { return [ordered]@{status='query-error'; error_type=$e.Exception.GetType().FullName; error_id=$e.FullyQualifiedErrorId} }
function SProbe($Exe,$Arguments) {
    $si=New-Object Diagnostics.ProcessStartInfo
    if ([IO.Path]::GetExtension($Exe) -in @('.cmd','.bat')) {
        $si.FileName=Join-Path $env:SystemRoot 'System32\cmd.exe'
        $si.Arguments='/d /s /c ""'+$Exe+'" '+$Arguments+'"'
    } else { $si.FileName=$Exe; $si.Arguments=$Arguments }
    $si.UseShellExecute=$false; $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true; $si.CreateNoWindow=$true
    foreach($pair in @(@('COREPACK_ENABLE_NETWORK','0'),@('COREPACK_ENABLE_DOWNLOAD_PROMPT','0'),@('YARN_ENABLE_NETWORK','0'),@('CARGO_NET_OFFLINE','true'),@('RUSTUP_AUTO_INSTALL','0'),@('RUSTUP_NO_UPDATE_CHECK','1'),@('GOTOOLCHAIN','local'),@('DOTNET_SKIP_FIRST_TIME_EXPERIENCE','1'),@('DOTNET_CLI_TELEMETRY_OPTOUT','1'))) { $si.EnvironmentVariables[$pair[0]]=$pair[1] }
    $p=New-Object Diagnostics.Process; $p.StartInfo=$si
    try {
        [void]$p.Start(); $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(8000)) { $p.Kill(); return [ordered]@{status='timeout'; command=$Exe; arguments=$Arguments; timeout_ms=8000} }
        $stdout=$out.Result; $stderr=$err.Result
        return [ordered]@{status='executed'; command=$Exe; arguments=$Arguments; exit_code=$p.ExitCode; stdout=$stdout.Substring(0,[Math]::Min(16000,$stdout.Length)); stderr=$stderr.Substring(0,[Math]::Min(4000,$stderr.Length)); truncated=($stdout.Length -gt 16000 -or $stderr.Length -gt 4000)}
    } catch { return SFailure $_ } finally { $p.Dispose() }
}
function SDirs($path) {
    try {
        $items=@(Get-ChildItem -LiteralPath $path -Directory -ErrorAction Stop | Select-Object -First 41)
        return [ordered]@{status='present'; path=$path; directories=@($items | Select-Object -First 40 -ExpandProperty Name); truncated=($items.Count -gt 40)}
    } catch { return SFailure $_ }
}
$pf=$env:ProgramFiles; $px=${env:ProgramFiles(x86)}; $user=[Environment]::GetFolderPath('UserProfile')
$known=[ordered]@{
    ruby=@('C:\Ruby33-x64\bin\ruby.exe','C:\Ruby34-x64\bin\ruby.exe')
    gem=@('C:\Ruby33-x64\bin\gem.cmd','C:\Ruby34-x64\bin\gem.cmd')
    rustc=@("$user\.cargo\bin\rustc.exe",'C:\ProgramData\Rust\.cargo\bin\rustc.exe')
    cargo=@("$user\.cargo\bin\cargo.exe",'C:\ProgramData\Rust\.cargo\bin\cargo.exe')
    rustup=@("$user\.cargo\bin\rustup.exe",'C:\ProgramData\Rust\.cargo\bin\rustup.exe')
    choco=@('C:\ProgramData\chocolatey\bin\choco.exe')
    npm=@("$pf\nodejs\npm.cmd",'C:\nodejs\npm.cmd')
    yarn=@("$pf\nodejs\yarn.cmd",'C:\npm\prefix\yarn.cmd')
    gcc=@('C:\mingw64\bin\gcc.exe','C:\msys64\mingw64\bin\gcc.exe','C:\msys64\ucrt64\bin\gcc.exe')
    make=@('C:\mingw64\bin\mingw32-make.exe','C:\msys64\usr\bin\make.exe')
    pacman=@('C:\msys64\usr\bin\pacman.exe')
    docker=@("$pf\Docker\Docker\resources\bin\docker.exe","$pf\Docker\docker.exe")
}
$argsByName=@{ruby='--version';gem='--version';rustc='--version';cargo='--version';rustup='show';choco='--version';npm='--version';yarn='--version';gcc='--version';make='--version';pacman='--version';docker='--version'}
$roots=@($pf,$px,'C:\tools','C:\hostedtoolcache','C:\Ruby','C:\ProgramData\chocolatey','C:\ProgramData\Rust','C:\mingw64','C:\msys64','C:\npm',"$user\.cargo", "$user\AppData\Roaming\npm")
$result=[ordered]@{schema='windows-image-supplement/v1'; phase=$Phase; tools=[ordered]@{}; note='Only local bounded version/list queries; network-disabled corepack/rustup/cargo; no package list/refresh/install, no Docker daemon query. No rust-toolchain or package manifest in fixture. Supplement is separate from unchanged core collector.'}
foreach($name in $known.Keys) {
    $resolved=@(); $lookup='not-found'
    if($name -ne 'pacman') {
        try { $resolved=@(Get-Command -Name $name -All -CommandType Application -ErrorAction Stop | Select-Object -First 8 -ExpandProperty Source); $lookup='resolved' } catch {}
    } else { $lookup='explicit-known-path-only' }
    $probes=@(); $locations=@()
    foreach($path in @(@($known[$name])+@($resolved) | Select-Object -Unique)) {
        $exists=Test-Path -LiteralPath $path -PathType Leaf
        $locations+=,[ordered]@{path=$path; exists=$exists}
        if(-not $exists) { continue }
        $allow=$false
        foreach($root in $roots) { if($root -and $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { $allow=$true } }
        if($allow -and $path -notmatch '\\WindowsApps\\') { $probes+=,(SProbe $path $argsByName[$name]) }
        else { $probes+=,[ordered]@{status='not-executed'; command=$path; reason='Outside known installation roots'} }
    }
    $result.tools[$name]=[ordered]@{lookup_status=$lookup; resolved=$resolved; known_locations=$locations; probes=$probes}
}
$result.vs_dynamic=[ordered]@{status='vswhere-not-found'; query=$null; installations=@()}
$vs="$px\Microsoft Visual Studio\Installer\vswhere.exe"
if(Test-Path -LiteralPath $vs) {
    $query=SProbe $vs '-all -products * -format json -utf8'
    $result.vs_dynamic.query=$query
    if($query.status -eq 'executed' -and $query.exit_code -eq 0 -and -not $query.truncated) {
        try {
            $installations=@($query.stdout | ConvertFrom-Json)
            $result.vs_dynamic.status='observed'
            foreach($instance in @($installations | Select-Object -First 8)) {
                $path=$instance.installationPath
                if($path -and ($path.StartsWith($pf,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($px,[StringComparison]::OrdinalIgnoreCase))) {
                    $result.vs_dynamic.installations+=,[ordered]@{installation_path=$path; installation_version=$instance.installationVersion; msvc=(SDirs (Join-Path $path 'VC\Tools\MSVC')); msbuild=(SDirs (Join-Path $path 'MSBuild\Current\Bin'))}
                }
            }
            $result.vs_dynamic.truncated=($installations.Count -gt 8)
        } catch { $result.vs_dynamic.status='parse-error' }
    } else { $result.vs_dynamic.status='query-incomplete' }
}
$result.system_dlls=[ordered]@{}
foreach($name in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','ucrtbase.dll')) {
    $path=Join-Path $env:SystemRoot ('System32\'+$name)
    try { $f=Get-Item -LiteralPath $path -ErrorAction Stop; $result.system_dlls[$path]=[ordered]@{status='present'; file_version=$f.VersionInfo.FileVersion; product_version=$f.VersionInfo.ProductVersion} } catch { $result.system_dlls[$path]=SFailure $_ }
}
$result.effective_privileges=SProbe (Join-Path $env:SystemRoot 'System32\whoami.exe') '/priv'
Write-Output ('SUPPLEMENT_JSON_BEGIN_'+$Phase)
$result | ConvertTo-Json -Depth 12 -Compress
Write-Output ('SUPPLEMENT_JSON_END_'+$Phase)
