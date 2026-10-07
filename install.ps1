# Install the Curiosity Orchestrator from the latest GitHub release.
#
#   irm https://raw.githubusercontent.com/curiosity-ai/orchestrator/main/install.ps1 | iex
#
# Unpacks the self-contained release (the server, its native RocksDB library and the front-end) into
# ~\.curiosity\orchestrator and adds that folder to the user PATH. Runs on Windows PowerShell 5.1 and on
# PowerShell 7 on Windows, macOS and Linux; outside Windows the program goes to ~/.curiosity/orchestrator and
# a launcher to ~/.curiosity/bin, as install.sh does.
#
# Settings, all optional, as environment variables (or parameters when the script is run as a file):
#   $env:ORC_VERSION = 'v26.10.4242'          a release tag instead of the latest release
#   $env:ORC_INSTALL = 'D:\tools\curiosity'   where to install; the program goes in its orchestrator folder
#   $env:ORC_NO_MODIFY_PATH = '1'             leave PATH alone
#   $env:GITHUB_TOKEN = '...'                 a GitHub token (GH_TOKEN works too); lifts the API's anonymous
#                                             rate limit
#
# Everything is inside Install-Orchestrator, called on the last line: a download cut off halfway runs nothing.

param(
    [string] $Version     = $env:ORC_VERSION,
    [string] $InstallRoot = $env:ORC_INSTALL,
    [switch] $NoModifyPath
)

function Install-Orchestrator {
    param([string] $Version, [string] $InstallRoot, [bool] $NoModifyPath)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads many times slower with the progress bar on.
    $repo = 'curiosity-ai/orchestrator'
    $name = 'curiosity-orchestrator'

    # Windows PowerShell 5.1 does not offer TLS 1.2 by default, and GitHub accepts nothing older.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    $tokenHint = if ($token) { '' } else { ' If the GitHub API rate limit was hit, set $env:GITHUB_TOKEN and try again.' }

    # $IsWindows only exists from PowerShell 6; Windows PowerShell 5.1 is Windows by definition.
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    if ($onWindows)  { $os = 'win' }
    elseif ($IsMacOS) { $os = 'osx' }
    elseif ($IsLinux) { $os = 'linux' }
    else { throw "unsupported operating system. Run it in Docker instead: see https://github.com/$repo#docker" }

    # The OS architecture, not the process's: a 32-bit or emulated PowerShell should still get the native build.
    $arch = $null
    try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { $arch = $null }
    if (-not $arch -and $onWindows) {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    if ($os -eq 'osx' -and $arch -eq 'X64') {
        # A PowerShell running under Rosetta on an Apple silicon Mac.
        if ((& sysctl -n sysctl.proc_translated 2>$null) -eq '1') { $arch = 'Arm64' }
    }
    switch -Regex ($arch) {
        '^(X64|AMD64)$'   { $arch = 'x64' }
        '^(Arm64|ARM64)$' { $arch = 'arm64' }
        default { throw "unsupported CPU architecture: $arch. Run it in Docker instead: see https://github.com/$repo#docker" }
    }
    $rid = "$os-$arch"
    $ext = if ($os -eq 'win') { 'zip' } else { 'tar.gz' }
    $exe = if ($os -eq 'win') { "$name.exe" } else { $name }

    if (-not $InstallRoot) { $InstallRoot = Join-Path $HOME '.curiosity' }
    $appDir = Join-Path $InstallRoot 'orchestrator'
    $binDir = if ($os -eq 'win') { $appDir } else { Join-Path $InstallRoot 'bin' }

    Write-Host "Installing the Curiosity Orchestrator ($rid)"

    $tag = $null
    if ($Version) {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        $api = "https://api.github.com/repos/$repo/releases/tags/$tag"
    } else {
        $api = "https://api.github.com/repos/$repo/releases/latest"
    }

    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers $headers
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int] $_.Exception.Response.StatusCode }
        if ($status -eq 404 -and $tag -and $token) { throw "there is no release $tag; see https://github.com/$repo/releases" }
        Write-Warning "could not read the release from the GitHub API ($($_.Exception.Message))"
    }

    if ($release) {
        $tag = $release.tag_name
    } elseif (-not $tag) {
        # The API refused (rate limit, proxy): the latest-release page redirects to the tag, which names the
        # archive. Asset names carry the version, so there is nothing to download without one.
        try {
            $page = Invoke-WebRequest -Uri "https://github.com/$repo/releases/latest" -UseBasicParsing
            $final = if ($page.BaseResponse.ResponseUri) { $page.BaseResponse.ResponseUri } else { $page.BaseResponse.RequestMessage.RequestUri }
            if ("$final" -match '/releases/tag/([^/?#]+)') { $tag = $Matches[1] }
        } catch { $tag = $null }
        if (-not $tag) { throw "could not find the latest release of $repo.$tokenHint" }
    }

    $versionNumber = $tag.TrimStart('v')
    $folder = "$name-$versionNumber-$rid"
    $asset  = "$folder.$ext"
    $digest = $null
    $apiUrl = $null

    if ($release) {
        $found = $release.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1
        if (-not $found -and $os -eq 'win' -and $arch -eq 'arm64') {
            # Windows on Arm runs x64 programs through its emulator.
            $rid    = 'win-x64'
            $folder = "$name-$versionNumber-$rid"
            $asset  = "$folder.$ext"
            $found  = $release.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1
            if ($found) { Write-Warning "no Windows Arm64 build in $tag; installing the x64 one, which Windows runs emulated" }
        }
        if (-not $found) {
            $names = ($release.assets | ForEach-Object { $_.name }) -join ', '
            throw "release $tag has no build for $rid (it has: $names). Run it in Docker instead: see https://github.com/$repo#docker"
        }
        $url    = $found.browser_download_url
        $apiUrl = $found.url
        if ($found.digest -and $found.digest.StartsWith('sha256:')) { $digest = $found.digest.Substring(7) }
    } else {
        Write-Warning "downloading $asset directly"
        $url = "https://github.com/$repo/releases/download/$tag/$asset"
    }

    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    # Unpacked next to the destination, so the final move stays on one volume.
    $work = Join-Path $InstallRoot ".orchestrator-download-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $archive = Join-Path $work $asset

        # With a token the asset comes through its API URL, which is what a token authenticates against.
        function Get-Asset([string] $browserUrl, [string] $assetApiUrl, [string] $outFile) {
            if ($token -and $assetApiUrl) {
                Invoke-WebRequest -Uri $assetApiUrl -OutFile $outFile -UseBasicParsing -Headers @{ Accept = 'application/octet-stream'; Authorization = "Bearer $token" }
            } else {
                Invoke-WebRequest -Uri $browserUrl -OutFile $outFile -UseBasicParsing
            }
        }

        Write-Host "  downloading ${tag}: $url"
        try { Get-Asset $url $apiUrl $archive }
        catch { throw "download failed: $url ($($_.Exception.Message)).$tokenHint Releases: https://github.com/$repo/releases" }

        if (-not $digest) {
            # Older releases and the no-API path: every release also carries SHA256SUMS.
            $sums = Join-Path $work 'SHA256SUMS'
            $sumsAsset = if ($release) { $release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1 } else { $null }
            try {
                Get-Asset "https://github.com/$repo/releases/download/$tag/SHA256SUMS" $(if ($sumsAsset) { $sumsAsset.url } else { $null }) $sums
                foreach ($line in Get-Content -LiteralPath $sums) {
                    $parts = $line -split '\s+', 2
                    if ($parts.Length -eq 2 -and $parts[1].TrimStart('*') -eq $asset) { $digest = $parts[0]; break }
                }
            } catch { Write-Warning "could not read SHA256SUMS ($($_.Exception.Message))" }
        }

        if ($digest) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
            if ($actual -ne $digest.ToLowerInvariant()) { throw "checksum mismatch for ${asset}: expected $digest, got $actual" }
            Write-Host '  sha256 verified'
        } else {
            Write-Warning "no checksum published for $asset; installing it unverified"
        }

        if ($os -eq 'win') {
            Expand-Archive -LiteralPath $archive -DestinationPath $work -Force
        } else {
            & tar -xzf $archive -C $work
            if ($LASTEXITCODE -ne 0) { throw "could not unpack $asset" }
        }
        $unpacked = Join-Path $work $folder
        if (-not (Test-Path -LiteralPath (Join-Path $unpacked $exe))) { throw "$asset does not hold $folder/$exe" }
        if ($os -eq 'osx') { & xattr -dr com.apple.quarantine $unpacked 2>$null }

        # Swapped in whole. The data is not in here (ORC_STORAGE), so nothing but the program is replaced.
        $old = "$appDir.old"
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
        if (Test-Path -LiteralPath $appDir) {
            try { Move-Item -LiteralPath $appDir -Destination $old }
            catch { throw "could not replace $appDir ($($_.Exception.Message)). Stop the running orchestrator and run the installer again." }
        }
        Move-Item -LiteralPath $unpacked -Destination $appDir
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  installed $appDir"

    if ($os -ne 'win') {
        # A launcher rather than a symbolic link: the server finds wwwroot/ and its native library beside the real file.
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        $launcher = Join-Path $binDir $name
        Set-Content -LiteralPath $launcher -Value "#!/bin/sh`nexec `"$(Join-Path $appDir $name)`" `"`$@`"" -NoNewline
        & chmod 755 $launcher
        Write-Host "  launcher  $launcher"
    }

    $sep     = [IO.Path]::PathSeparator
    $onPath  = ($env:PATH -split [regex]::Escape($sep)) -contains $binDir
    $newPath = $false

    if (-not $onPath -and -not $NoModifyPath) {
        if ($os -eq 'win') {
            # Read and written raw, so %VARIABLES% other installers left in the user PATH stay unexpanded.
            $key  = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            $user = [string] $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $parts = @($user -split ';' | Where-Object { $_ })
            if ($parts -notcontains $binDir) {
                $key.SetValue('Path', (($parts + $binDir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
                # Setting any user variable through .NET broadcasts WM_SETTINGCHANGE, so new terminals see the PATH.
                [Environment]::SetEnvironmentVariable('ORC_INSTALLER', '1', 'User')
                [Environment]::SetEnvironmentVariable('ORC_INSTALLER', $null, 'User')
                Write-Host "  added $binDir to your user PATH"
            }
            $key.Close()
        } else {
            # PowerShell on macOS and Linux has no persistent user PATH; its profile is the place.
            $profileFile = $PROFILE.CurrentUserAllHosts
            $line = "`$env:PATH = '$binDir' + [IO.Path]::PathSeparator + `$env:PATH"
            if (-not ((Test-Path -LiteralPath $profileFile) -and (Select-String -LiteralPath $profileFile -SimpleMatch $line -Quiet))) {
                New-Item -ItemType Directory -Force -Path (Split-Path $profileFile) | Out-Null
                Add-Content -LiteralPath $profileFile -Value "`n# curiosity`n$line"
                Write-Host "  added $binDir to PATH in $profileFile"
            }
            Write-Host "  for bash or zsh, add this to your shell profile: export PATH=`"$binDir`:`$PATH`""
        }
        $newPath = $true
    }
    # This session, too.
    if (-not $onPath) { $env:PATH = "$binDir$sep$env:PATH" }

    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning 'Docker was not found. The orchestrator runs every workspace as a Docker container: install Docker (Docker Desktop on Windows and macOS) before starting it.'
    }

    Write-Host ''
    Write-Host "The Curiosity Orchestrator $tag is installed."
    if ($newPath) { Write-Host 'It is on PATH in this window now; other open terminals need restarting.' }
    $here = if ($os -eq 'win') { '.\storage' } else { './storage' }
    Write-Host "Start it with a management password (data goes to $here unless ORC_STORAGE says otherwise):"
    $dataDir = Join-Path $InstallRoot 'orchestrator-data'
    Write-Host "  `$env:ORC_ADMIN_PASSWORD = 'choose-a-password'; `$env:ORC_STORAGE = '$dataDir'; $name"
}

Install-Orchestrator -Version $Version -InstallRoot $InstallRoot -NoModifyPath ($NoModifyPath.IsPresent -or $env:ORC_NO_MODIFY_PATH -eq '1')
