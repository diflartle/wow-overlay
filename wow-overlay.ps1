<#
.SYNOPSIS
    Tails the World of Warcraft combat log and writes data.js for overlay.html (OBS chat blocker).

.DESCRIPTION
    Watches the newest WoWCombatLog*.txt, tracks the current dungeon, keystone level, timer and
    party, and writes the result to data.js next to this script. overlay.html polls data.js.
    Party members' Mythic+ scores come from raider.io, looked up only when the group changes.

    In game: turn on Advanced Combat Logging (Options > System > Network) and type /combatlog
    each session, or use an addon that turns logging on automatically in dungeons.

.PARAMETER LogDir
    Your WoW Logs folder.

.PARAMETER OutFile
    Where to write data.js. Must sit next to overlay.html.

.PARAMETER CatchUpMB
    On startup, how much of the end of the current log to read, so a key that's already
    running when you start the script is still picked up.

.PARAMETER FinishedHoldSeconds
    How long the finished-key screen (final time, timed/over) stays up before the overlay
    switches to "Between keys". 0 switches straight away. Zoning out also switches it.

.PARAMETER Title
    Text shown in place of "Between keys" while you're not in a key, e.g. "Farming crests with Ulk".
    Saved to title.txt next to data.js. Edit and save that file while the script runs to change
    the title on the fly; empty the file (or delete it) to go back to "Between keys".
    Leave -Title off to keep whatever title.txt already says.

.PARAMETER Region
    Region used for raider.io lookups when the combat log doesn't say (us, eu, kr or tw).

.PARAMETER NoScores
    Don't look up party members' Mythic+ scores on raider.io.

.PARAMETER Demo
    Cycle through fake data so you can position and style the overlay without WoW running.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\wow-overlay.ps1

.EXAMPLE
    .\wow-overlay.ps1 -LogDir 'D:\Games\World of Warcraft\_retail_\Logs'

.EXAMPLE
    .\wow-overlay.ps1 -Title 'Farming crests with Ulk'

.EXAMPLE
    .\wow-overlay.ps1 -Demo
#>
[CmdletBinding()]
param(
    [string]$LogDir    = 'C:\Program Files (x86)\World of Warcraft\_retail_\Logs',
    [string]$OutFile   = (Join-Path $PSScriptRoot 'data.js'),
    [int]   $CatchUpMB = 20,
    [int]   $FinishedHoldSeconds = 30,
    [string]$Title,
    [ValidateSet('us', 'eu', 'kr', 'tw')]
    [string]$Region = 'us',
    [switch]$NoScores,
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Spec ID -> class token, spec name, role
# ---------------------------------------------------------------------------------------------
$Specs = @{
    250  = 'DEATHKNIGHT', 'Blood', 'TANK';         251 = 'DEATHKNIGHT', 'Frost', 'DAMAGER';        252 = 'DEATHKNIGHT', 'Unholy', 'DAMAGER'
    577  = 'DEMONHUNTER', 'Havoc', 'DAMAGER';      581 = 'DEMONHUNTER', 'Vengeance', 'TANK'
    1480 = 'DEMONHUNTER', 'Devourer', 'DAMAGER'   # Midnight spec; ID worth double-checking
    102  = 'DRUID', 'Balance', 'DAMAGER';          103 = 'DRUID', 'Feral', 'DAMAGER'
    104  = 'DRUID', 'Guardian', 'TANK';            105 = 'DRUID', 'Restoration', 'HEALER'
    1467 = 'EVOKER', 'Devastation', 'DAMAGER';     1468 = 'EVOKER', 'Preservation', 'HEALER';     1473 = 'EVOKER', 'Augmentation', 'DAMAGER'
    253  = 'HUNTER', 'Beast Mastery', 'DAMAGER';   254 = 'HUNTER', 'Marksmanship', 'DAMAGER';      255 = 'HUNTER', 'Survival', 'DAMAGER'
    62   = 'MAGE', 'Arcane', 'DAMAGER';            63  = 'MAGE', 'Fire', 'DAMAGER';                64  = 'MAGE', 'Frost', 'DAMAGER'
    268  = 'MONK', 'Brewmaster', 'TANK';           270 = 'MONK', 'Mistweaver', 'HEALER';           269 = 'MONK', 'Windwalker', 'DAMAGER'
    65   = 'PALADIN', 'Holy', 'HEALER';            66  = 'PALADIN', 'Protection', 'TANK';          70  = 'PALADIN', 'Retribution', 'DAMAGER'
    256  = 'PRIEST', 'Discipline', 'HEALER';       257 = 'PRIEST', 'Holy', 'HEALER';               258 = 'PRIEST', 'Shadow', 'DAMAGER'
    259  = 'ROGUE', 'Assassination', 'DAMAGER';    260 = 'ROGUE', 'Outlaw', 'DAMAGER';             261 = 'ROGUE', 'Subtlety', 'DAMAGER'
    262  = 'SHAMAN', 'Elemental', 'DAMAGER';       263 = 'SHAMAN', 'Enhancement', 'DAMAGER';       264 = 'SHAMAN', 'Restoration', 'HEALER'
    265  = 'WARLOCK', 'Affliction', 'DAMAGER';     266 = 'WARLOCK', 'Demonology', 'DAMAGER';       267 = 'WARLOCK', 'Destruction', 'DAMAGER'
    71   = 'WARRIOR', 'Arms', 'DAMAGER';           72  = 'WARRIOR', 'Fury', 'DAMAGER';             73  = 'WARRIOR', 'Protection', 'TANK'
}

# Normal, Heroic, Mythic Keystone, Mythic
$DungeonDifficulties = 1, 2, 8, 23

# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-DataJs($data) {
    $data['updated'] = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $data['title']   = if ($Title) { $Title } else { $null }
    $json = ConvertTo-Json -InputObject $data -Depth 6 -Compress
    $tmp  = "$OutFile.tmp"
    [IO.File]::WriteAllText($tmp, "window.__wowOverlay = $json;", $Utf8NoBom)

    # Swap in the finished file so OBS never reads a half-written one.
    for ($i = 0; $i -lt 10; $i++) {
        try   { Move-Item -LiteralPath $tmp -Destination $OutFile -Force; return }
        catch { Start-Sleep -Milliseconds 50 }
    }
    Write-Warning "Couldn't replace $OutFile (file locked?)"
}

# ---------------------------------------------------------------------------------------------
# Title (title.txt next to data.js, re-read whenever it changes)
# ---------------------------------------------------------------------------------------------
$TitleFile  = Join-Path (Split-Path -Parent $OutFile) 'title.txt'
$TitleStamp = $null

if ($PSBoundParameters.ContainsKey('Title')) {
    [IO.File]::WriteAllText($TitleFile, $Title, $Utf8NoBom)
}

# Returns $true if the title changed since the last check.
function Update-Title {
    $stamp = if (Test-Path -LiteralPath $TitleFile) { (Get-Item -LiteralPath $TitleFile).LastWriteTimeUtc } else { $null }
    if ($stamp -eq $script:TitleStamp) { return $false }

    $new = $null
    if ($stamp) {
        try   { $new = ([IO.File]::ReadAllText($TitleFile) -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -First 1) }
        catch { return $false }   # still being saved; try again next pass
        if ($new) { $new = $new.Trim() }
    }
    $script:TitleStamp = $stamp
    if ($new -eq $script:Title) { return $false }
    $script:Title = $new
    Write-Host $(if ($new) { "Title: $new" } else { "Title cleared" })
    return $true
}
[void](Update-Title)
Write-Host "Title file: $TitleFile"

# ---------------------------------------------------------------------------------------------
# Demo mode
# ---------------------------------------------------------------------------------------------
if ($Demo) {
    $party = @(
        [pscustomobject]@{ name = 'Brewtank';    realm = 'Area52';    class = 'MONK';   spec = 'Brewmaster';  role = 'TANK';    self = $false; score = 3105;  scoreColor = '#ff8000' }
        [pscustomobject]@{ name = 'Leafwhisper'; realm = 'Stormrage'; class = 'DRUID';  spec = 'Restoration'; role = 'HEALER';  self = $false; score = 2876;  scoreColor = '#e268a8' }
        [pscustomobject]@{ name = 'Emberlash';   realm = 'Area52';    class = 'MAGE';   spec = 'Fire';        role = 'DAMAGER'; self = $false; score = 2699;  scoreColor = '#5698b3' }
        [pscustomobject]@{ name = 'Nightveil';   realm = 'Illidan';   class = 'ROGUE';  spec = 'Outlaw';      role = 'DAMAGER'; self = $false; score = $null; scoreColor = $null }
        [pscustomobject]@{ name = 'Totemtom';    realm = 'Area52';    class = 'SHAMAN'; spec = 'Enhancement'; role = 'DAMAGER'; self = $true;  score = 2412;  scoreColor = '#9e8ae4' }
    )
    $start = [DateTimeOffset]::Now.AddMinutes(-14.5).ToUnixTimeMilliseconds()

    function New-DemoBoss($id, $name, $result, $pullOffsetMs, $fightMs, $wipes) {
        $pulled = $start + $pullOffsetMs
        $ended  = $null
        if ($fightMs) { $ended = $pulled + $fightMs }
        # Kept out of the [ordered]@{} literal: an if inside one trips a Windows PowerShell 5.1 bug.
        [ordered]@{
            id = $id; name = $name; result = $result; pulledAt = $pulled
            endedAt = $ended; fightMs = $fightMs; wipes = $wipes
        }
    }
    $nowOffset = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $start
    $bossesRunning = @(
        New-DemoBoss 2583 'Avanoxx'                   'killed'  125000              136000 0
        New-DemoBoss 2584 "Anub'zekt"                 'pulling' ($nowOffset - 50000) $null 1
    )
    $bossesDone = @(
        New-DemoBoss 2583 'Avanoxx'                   'killed'  125000  136000 0
        New-DemoBoss 2584 "Anub'zekt"                 'killed'  820000  142000 1
        New-DemoBoss 2585 "Ki'katal the Harvester"    'killed'  1470000 205000 0
    )
    $last = @{ dungeon = 'Ara-Kara, City of Echoes'; level = 12; startedAt = $start; durationMs = 1694000; timed = $true; bosses = $bossesDone }

    $frames = @(
        @{ status = 'running';  dungeon = 'Ara-Kara, City of Echoes';   level = 12;    startedAt = $start; durationMs = $null;   timed = $null;  party = $party; bosses = $bossesRunning; last = $null }
        @{ status = 'finished'; dungeon = 'Ara-Kara, City of Echoes';   level = 12;    startedAt = $start; durationMs = 1694000; timed = $true;  party = $party; bosses = $bossesDone;    last = $last }
        @{ status = 'finished'; dungeon = 'Priory of the Sacred Flame'; level = 14;    startedAt = $start; durationMs = 2071000; timed = $false; party = $party; bosses = @();           last = $last }
        @{ status = 'waiting';  dungeon = 'Priory of the Sacred Flame'; level = $null; startedAt = $null;  durationMs = $null;   timed = $null;  party = $party; bosses = @();           last = $last }
        @{ status = 'idle';     dungeon = $null;                        level = $null; startedAt = $null;  durationMs = $null;   timed = $null;  party = $party; bosses = @();           last = $last }
        @{ status = 'idle';     dungeon = $null;                        level = $null; startedAt = $null;  durationMs = $null;   timed = $null;  party = @();    bosses = @();           last = $null }
    )

    Write-Host "Demo mode: cycling overlay states every 8 seconds. Ctrl+C to stop."
    while ($true) {
        foreach ($f in $frames) {
            Write-Host "  showing: $($f.status)"
            Write-DataJs $f
            for ($s = 0; $s -lt 8; $s++) {
                Start-Sleep -Seconds 1
                if (Update-Title) { Write-DataJs $f }
            }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Mythic+ scores from raider.io
# ---------------------------------------------------------------------------------------------
# raider.io is rate limited, so lookups only happen when the group changes, and only for members
# without a recent score. Requests go out one at a time, a couple of seconds apart, and run in
# the background so a slow reply never holds up the combat log.
$ScoreFreshMinutes = 60       # a score this old is looked up again the next time the group changes
$ScoreGapSeconds   = 2        # minimum time between requests

$Scores     = @{}             # 'region|realm|name' -> @{ score; color; fresh (datetime) }
$ScoreGroup = ''              # party the queue was last built for
$ScoreQueue = [System.Collections.Generic.List[string]]::new()
$ScoreReq   = $null           # @{ key; task } for the request in flight
$ScoreNext  = [datetime]::MinValue
$Http       = $null

if (-not $NoScores) {
    Add-Type -AssemblyName System.Net.Http
    # Windows PowerShell 5.1 doesn't offer TLS 1.2 by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Http = [System.Net.Http.HttpClient]::new()
    $Http.Timeout = [TimeSpan]::FromSeconds(15)
    $Http.DefaultRequestHeaders.UserAgent.ParseAdd('wow-overlay/1.0')
    Write-Host "Looking up party M+ scores on raider.io (-NoScores to turn off)"
}

function Get-ScoreKey($p) {
    if (-not $Http -or -not $p.name -or -not $p.realm) { return $null }
    $r = if ($p.region -in 'us', 'eu', 'kr', 'tw') { $p.region } else { $Region }
    "$r|$($p.realm)|$($p.name)"
}

# Called with the party's keys every time the overlay is written. Rebuilds the queue only when
# the members actually change.
function Update-ScoreQueue([string[]]$keys) {
    $group = ($keys | Sort-Object) -join ','
    if ($group -eq $script:ScoreGroup) { return }
    $script:ScoreGroup = $group
    $ScoreQueue.Clear()
    foreach ($k in $keys) {
        $e = $Scores[$k]
        if (-not $e -or $e.fresh -lt (Get-Date)) { $ScoreQueue.Add($k) }
    }
}

# Collects a finished request and starts the next one. Returns $true if a score changed.
function Update-Scores {
    if (-not $Http) { return $false }
    $changed = $false
    if ($script:ScoreReq) {
        if (-not $script:ScoreReq.task.IsCompleted) { return $false }
        $changed = Receive-Score $script:ScoreReq
        $script:ScoreReq = $null
    }
    if ($ScoreQueue.Count -eq 0 -or (Get-Date) -lt $script:ScoreNext) { return $changed }

    $key = $ScoreQueue[0]
    $ScoreQueue.RemoveAt(0)
    $r, $realm, $name = $key.Split('|')
    $url = 'https://raider.io/api/v1/characters/profile?region={0}&realm={1}&name={2}&fields=mythic_plus_scores_by_season%3Acurrent' -f
        $r, [uri]::EscapeDataString($realm), [uri]::EscapeDataString($name)
    $script:ScoreReq  = @{ key = $key; task = $Http.GetAsync($url) }
    $script:ScoreNext = (Get-Date).AddSeconds($ScoreGapSeconds)
    return $changed
}

function Receive-Score($req) {
    $now   = Get-Date
    $old   = $Scores[$req.key]
    $label = ($req.key.Split('|')[2, 1]) -join '-'
    $res   = $null
    try {
        $res  = $req.task.GetAwaiter().GetResult()
        $body = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $code = [int]$res.StatusCode

        if ($res.IsSuccessStatusCode) {
            $season = @((ConvertFrom-Json $body).mythic_plus_scores_by_season)[0]
            $score  = $null
            $color  = $null
            if ($season -and $season.segments.all.score -gt 0) {
                $score = [int][math]::Floor($season.segments.all.score)
                $color = $season.segments.all.color
            }
            $Scores[$req.key] = @{ score = $score; color = $color; fresh = $now.AddMinutes($ScoreFreshMinutes) }
            Write-Host "Score: $label $(if ($score) { $score } else { 'none this season' })"
            return ($score -ne $old.score -or $color -ne $old.color)
        }
        if ($code -eq 429) {
            # Rate limited: put them back at the front of the queue and pause.
            $wait = 60
            if ($res.Headers.RetryAfter -and $res.Headers.RetryAfter.Delta) { $wait = [int]$res.Headers.RetryAfter.Delta.Value.TotalSeconds }
            $ScoreQueue.Insert(0, $req.key)
            $script:ScoreNext = $now.AddSeconds($wait)
            Write-Host "raider.io rate limit reached; pausing score lookups for $wait seconds"
            return $false
        }
        if ($code -eq 400) {
            # raider.io's answer for an unknown character or realm. Don't ask again this session.
            $msg = $body
            try { $msg = (ConvertFrom-Json $body).message } catch { }
            $Scores[$req.key] = @{ score = $null; color = $null; fresh = [datetime]::MaxValue }
            Write-Host "No raider.io score for ${label}: $msg"
            return ($null -ne $old.score)
        }
        throw "HTTP $code"
    }
    catch {
        # Network trouble or a server error: keep any score we had and retry on the next group change.
        $Scores[$req.key] = @{ score = $old.score; color = $old.color; fresh = [datetime]::MinValue }
        Write-Host "Couldn't get raider.io score for ${label}: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($res) { $res.Dispose() }
    }
}

# ---------------------------------------------------------------------------------------------
# Log parsing state
# ---------------------------------------------------------------------------------------------
$ord = [StringComparison]::Ordinal
$opt = [Text.RegularExpressions.RegexOptions]::Compiled

$rxTime  = [regex]::new('^(\d{1,2})/(\d{1,2})(?:/(\d{4}))? (\d{1,2}):(\d{2}):(\d{2})\.(\d+)', $opt)
$rxStart = [regex]::new('^CHALLENGE_MODE_START,"([^"]*)",(\d+),(\d+),(\d+)', $opt)
$rxEnd   = [regex]::new('^CHALLENGE_MODE_END,(\d+),(\d+),(\d+),(\d+)', $opt)
$rxZone  = [regex]::new('^ZONE_CHANGE,(\d+),"([^"]*)",(\d+)', $opt)
# ENCOUNTER_START,encounterID,"name",difficultyID,groupSize,instanceID
# ENCOUNTER_END,encounterID,"name",difficultyID,groupSize,success,fightTimeMs
$rxEncStart = [regex]::new('^ENCOUNTER_START,(\d+),"([^"]*)",(\d+),(\d+)', $opt)
$rxEncEnd   = [regex]::new('^ENCOUNTER_END,(\d+),"([^"]*)",(\d+),(\d+),(\d+),(\d+)', $opt)
# Standard event prefix: source GUID, name, flags, raid flags, dest GUID, name, flags, raid flags.
# Captures source (1-3) and dest (4-6) only when they're players.
$rxUnits = [regex]::new(
    '^[A-Z_]+,(?:(Player-[^,]+),"([^"]*)",(0x[0-9A-Fa-f]+)|[^,]*,(?:"[^"]*"|[^,]*),[^,]*),[^,]*,(?:(Player-[^,]+),"([^"]*)",(0x[0-9A-Fa-f]+))?',
    $opt)

$State = @{
    status     = 'idle'      # idle | waiting | running | finished
    dungeon    = $null
    instanceId = $null
    level      = $null
    startedAt  = $null       # epoch ms
    durationMs = $null
    timed      = $null
    finishedAt = $null       # epoch ms of CHALLENGE_MODE_END, for the hold before "Between keys"
    last       = $null       # summary of the last finished key, including its bosses
    bosses     = [System.Collections.Generic.List[object]]::new()   # one entry per boss this run
}

$Players   = @{}   # GUID -> @{ name; realm; region; specId }
$Party     = @{}   # GUIDs currently believed to be in your group (including you)
$FlagCache = @{}   # GUID -> last flags string seen, so unchanged units are skipped cheaply
$SelfGuid  = $null
$dirty     = $true
$prevCI    = $false
$burst     = $null

function Get-OrAddPlayer([string]$guid) {
    $p = $Players[$guid]
    if (-not $p) {
        $p = @{ name = $null; realm = $null; region = $null; specId = $null }
        $Players[$guid] = $p
    }
    return $p
}

function Update-Unit([string]$guid, [string]$fullName, [string]$flagsHex) {
    $flags = [Convert]::ToInt64($flagsHex.Substring(2), 16)
    $p = Get-OrAddPlayer $guid

    if (-not $p.name -and $fullName -and $fullName -ne 'nil') {
        $parts   = $fullName.Split('-')        # Name-Realm-Region
        $p.name  = $parts[0]
        if ($parts.Length -gt 1) { $p.realm = $parts[1] }
        if ($parts.Length -gt 2) { $p.region = $parts[2].ToLower() }
        if ($Party.ContainsKey($guid)) { $script:dirty = $true }
    }

    if ($flags -band 0x1) {                   # affiliation: mine
        $script:SelfGuid = $guid
        if (-not $Party.ContainsKey($guid)) { $Party[$guid] = $true; $script:dirty = $true }
    }
    elseif ($flags -band 0x2) {               # affiliation: party
        if (-not $Party.ContainsKey($guid)) { $Party[$guid] = $true; $script:dirty = $true }
    }
    elseif ($Party.ContainsKey($guid)) {      # seen outside the party: they left
        $Party.Remove($guid)
        $script:dirty = $true
    }
}

function Get-LineEpochMs([string]$line) {
    $m = $rxTime.Match($line)
    if (-not $m.Success) { return [DateTimeOffset]::Now.ToUnixTimeMilliseconds() }
    $year = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { (Get-Date).Year }
    $ms   = [int]$m.Groups[7].Value.PadRight(3, '0').Substring(0, 3)
    $dt   = [datetime]::new($year, [int]$m.Groups[1].Value, [int]$m.Groups[2].Value,
                            [int]$m.Groups[4].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value,
                            $ms, [DateTimeKind]::Local)
    return ([DateTimeOffset]$dt).ToUnixTimeMilliseconds()
}

function Get-PartyList {
    $roleOrder = @{ TANK = 0; HEALER = 1; DAMAGER = 2 }
    $rows = foreach ($g in @($Party.Keys)) {
        $p = $Players[$g]
        if (-not $p) { continue }
        $spec = $null
        if ($p.specId) { $spec = $Specs[[int]$p.specId] }
        $role = if ($spec) { $spec[2] } else { $null }
        $key  = Get-ScoreKey $p
        $score = if ($key) { $Scores[$key] } else { $null }
        [pscustomobject]@{
            name  = $p.name
            realm = $p.realm
            class = if ($spec) { $spec[0] } else { $null }
            spec  = if ($spec) { $spec[1] } else { $null }
            role  = $role
            self  = ($g -eq $SelfGuid)
            sort  = if ($role) { $roleOrder[$role] } else { 3 }
            key   = $key
            score      = $score.score
            scoreColor = $score.color
        }
    }
    $list = @($rows | Sort-Object sort, name | Select-Object -First 5)
    Update-ScoreQueue @($list | ForEach-Object { $_.key } | Where-Object { $_ })
    @($list | Select-Object name, realm, class, spec, role, self, score, scoreColor)
}

function Write-Overlay {
    # Arrays are built first and passed in as plain variables: an expression like @(...) inside
    # an [ordered]@{} literal can fail with "Argument types do not match".
    [object[]]$partyList = @(Get-PartyList)
    [object[]]$bossList  = $State.bosses.ToArray()
    Write-DataJs ([ordered]@{
        status     = $State.status
        dungeon    = $State.dungeon
        level      = $State.level
        startedAt  = $State.startedAt
        durationMs = $State.durationMs
        timed      = $State.timed
        party      = $partyList
        bosses     = $bossList
        last       = $State.last
    })
}

function Clear-Run {
    $State.level = $null; $State.startedAt = $null; $State.durationMs = $null; $State.timed = $null
    $State.finishedAt = $null
    $State.bosses.Clear()
}

# Once a finished key has been on screen for $FinishedHoldSeconds, switch to "Between keys".
# Uses the log timestamp of the key's end, so a key replayed during startup catch-up goes
# straight to "Between keys" instead of waiting.
function Test-FinishedHold {
    if ($State.status -ne 'finished' -or -not $State.finishedAt) { return }
    $age = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $State.finishedAt
    if ($age -lt $FinishedHoldSeconds * 1000) { return }
    $State.status  = 'idle'
    $State.dungeon = $null
    Clear-Run
    $script:dirty = $true
    Write-Host "Between keys"
}

# Returns the entry for this encounter, adding it the first time it's pulled.
# Re-pulls after a wipe reuse the same entry so each boss is one row on the overlay.
function Get-OrAddBoss([int]$id, [string]$name) {
    foreach ($b in $State.bosses) { if ($b.id -eq $id) { return $b } }
    $b = [ordered]@{
        id       = $id
        name     = $name
        result   = $null      # pulling | killed | wipe
        pulledAt = $null      # epoch ms, from the log line timestamp
        endedAt  = $null      # epoch ms
        fightMs  = $null      # fight length as reported by ENCOUNTER_END
        wipes    = 0
    }
    $State.bosses.Add($b)
    return $b
}

function Format-Span([long]$ms) {
    $t = [TimeSpan]::FromMilliseconds($ms)
    '{0}:{1:00}' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds
}

# Console text: time into the key if one is running, otherwise the clock time.
function Format-When([long]$epochMs) {
    if ($State.startedAt -and $epochMs -ge $State.startedAt) {
        return "$(Format-Span ($epochMs - $State.startedAt)) into the key"
    }
    [DateTimeOffset]::FromUnixTimeMilliseconds($epochMs).ToLocalTime().ToString('HH:mm:ss')
}

# ---------------------------------------------------------------------------------------------
# File handling
# ---------------------------------------------------------------------------------------------
function Get-NewestLog {
    Get-ChildItem -LiteralPath $LogDir -Filter 'WoWCombatLog*.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
}

function Open-Log($file) {
    # Share flags let WoW keep writing (and rotate the file) while we read.
    $fs = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                               [IO.FileShare]'ReadWrite, Delete')
    $skip   = [long]$CatchUpMB * 1MB
    $seeked = $false
    if ($fs.Length -gt $skip) {
        [void]$fs.Seek($fs.Length - $skip, [IO.SeekOrigin]::Begin)
        $seeked = $true
    }
    $r = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
    if ($seeked) { [void]$r.ReadLine() }   # drop the partial line we landed in
    return $r
}

# ---------------------------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------------------------
Write-Host "Writing overlay data to $OutFile"
Write-Overlay

$reader    = $null
$current   = $null
$carry     = ''
$lastCheck = [datetime]::MinValue
$warned    = $false

try {
    while ($true) {
        # Look for a newer log file every few seconds (WoW starts a new one per /combatlog session).
        if (-not $reader -or ((Get-Date) - $lastCheck).TotalSeconds -ge 5) {
            $lastCheck = Get-Date
            $newest = Get-NewestLog
            if ($newest -and $newest.FullName -ne $current) {
                if ($reader) { $reader.Dispose() }
                $reader  = Open-Log $newest
                $current = $newest.FullName
                $carry   = ''
                $warned  = $false
                Write-Host "Reading $($newest.Name)"
            }
            elseif (-not $reader) {
                if (-not $warned) {
                    Write-Host "No combat log in $LogDir yet. In game, type /combatlog. Waiting..."
                    $warned = $true
                }
                if (Update-Title) { Write-Overlay }
                Start-Sleep -Seconds 2
                continue
            }
        }

        $chunk = $reader.ReadToEnd()
        if ($chunk.Length -eq 0) {
            if (Update-Title) { $dirty = $true }
            if (Update-Scores) { $dirty = $true }
            Test-FinishedHold
            if ($dirty) { Write-Overlay; $dirty = $false }
            Start-Sleep -Milliseconds 250
            continue
        }

        # Only process complete lines; keep any partial last line for the next read.
        $text = $carry + $chunk
        $nl   = $text.LastIndexOf([char]10)
        if ($nl -lt 0) { $carry = $text; continue }
        $carry = $text.Substring($nl + 1)

        foreach ($raw in $text.Substring(0, $nl).Split([char]10)) {
            # "<timestamp>  EVENT,fields..."  (two spaces separate the timestamp)
            $sp = $raw.IndexOf('  ', $ord)
            if ($sp -lt 0) { continue }
            $ev   = $raw.Substring($sp + 2).TrimEnd([char]13)
            $isCI = $false

            if ($ev.StartsWith('COMBATANT_INFO,', $ord)) {
                # Fires for each group member at key start and boss pulls: the authoritative roster.
                $isCI = $true
                if (-not $prevCI) { $burst = New-Object System.Collections.Generic.List[string] }
                $f    = $ev.Split(',')
                $guid = $f[1]
                $p    = Get-OrAddPlayer $guid
                for ($k = 2; $k -lt $f.Length; $k++) {
                    if ($f[$k].StartsWith('[', $ord)) {          # talents start; spec ID is just before
                        if ($f[$k - 1] -match '^\d+$') { $p.specId = [int]$f[$k - 1] }
                        break
                    }
                }
                if (-not $burst.Contains($guid)) { $burst.Add($guid) }
                if ($burst.Count -le 5) {                         # ignore raid-sized bursts
                    $Party.Clear()
                    foreach ($g in $burst) { $Party[$g] = $true }
                }
                $dirty = $true
            }
            elseif ($ev.StartsWith('CHALLENGE_MODE_START,', $ord)) {
                $m = $rxStart.Match($ev)
                if ($m.Success) {
                    $State.status     = 'running'
                    $State.dungeon    = $m.Groups[1].Value
                    $State.instanceId = $m.Groups[2].Value
                    $State.level      = [int]$m.Groups[4].Value
                    $State.startedAt  = Get-LineEpochMs $raw
                    $State.durationMs = $null
                    $State.timed      = $null
                    $State.bosses.Clear()
                    $dirty = $true
                    Write-Host "Key started: $($State.dungeon) +$($State.level)"
                }
            }
            elseif ($ev.StartsWith('CHALLENGE_MODE_END,', $ord)) {
                $m = $rxEnd.Match($ev)
                if ($m.Success) {
                    $total = [long]$m.Groups[4].Value
                    if ($total -le 0) {
                        # Key abandoned or reset: back to waiting in the same dungeon.
                        $State.status = 'waiting'
                        Clear-Run
                        Write-Host "Key abandoned"
                    }
                    else {
                        $State.status     = 'finished'
                        $State.level      = [int]$m.Groups[3].Value
                        $State.durationMs = $total
                        $State.timed      = ($m.Groups[2].Value -eq '1')
                        $State.finishedAt = Get-LineEpochMs $raw
                        [object[]]$lastBosses = $State.bosses.ToArray()
                        $State.last = @{
                            dungeon    = $State.dungeon
                            level      = $State.level
                            startedAt  = $State.startedAt
                            durationMs = $total
                            timed      = $State.timed
                            bosses     = $lastBosses
                        }
                        Write-Host ("Key finished: {0} +{1}, {2}" -f $State.dungeon, $State.level,
                                    $(if ($State.timed) { 'timed' } else { 'over time' }))
                    }
                    $dirty = $true
                }
            }
            elseif ($ev.StartsWith('ENCOUNTER_START,', $ord)) {
                $m = $rxEncStart.Match($ev)
                if ($m.Success) {
                    $at   = Get-LineEpochMs $raw
                    $boss = Get-OrAddBoss $m.Groups[1].Value $m.Groups[2].Value
                    $boss.result   = 'pulling'
                    $boss.pulledAt = $at
                    $boss.endedAt  = $null
                    $boss.fightMs  = $null
                    $dirty = $true
                    Write-Host "Pulled $($boss.name) at $(Format-When $at)"
                }
            }
            elseif ($ev.StartsWith('ENCOUNTER_END,', $ord)) {
                $m = $rxEncEnd.Match($ev)
                if ($m.Success) {
                    $at   = Get-LineEpochMs $raw
                    $boss = Get-OrAddBoss $m.Groups[1].Value $m.Groups[2].Value
                    $boss.endedAt = $at
                    $boss.fightMs = [long]$m.Groups[6].Value
                    if (-not $boss.pulledAt) { $boss.pulledAt = $at - $boss.fightMs }   # started before our catch-up window
                    if ($m.Groups[5].Value -eq '1') {
                        $boss.result = 'killed'
                        Write-Host "Killed $($boss.name) at $(Format-When $at) ($(Format-Span $boss.fightMs) fight)"
                    }
                    else {
                        $boss.result = 'wipe'
                        $boss.wipes  = $boss.wipes + 1
                        Write-Host "Wiped on $($boss.name) at $(Format-When $at) ($(Format-Span $boss.fightMs) fight)"
                    }
                    $dirty = $true
                }
            }
            elseif ($ev.StartsWith('ZONE_CHANGE,', $ord)) {
                $m = $rxZone.Match($ev)
                if ($m.Success -and $m.Groups[1].Value -ne $State.instanceId) {
                    $State.instanceId = $m.Groups[1].Value
                    if ($DungeonDifficulties -contains [int]$m.Groups[3].Value) {
                        $State.status  = 'waiting'
                        $State.dungeon = $m.Groups[2].Value
                    }
                    else {
                        $State.status  = 'idle'
                        $State.dungeon = $null
                    }
                    Clear-Run
                    $dirty = $true
                }
            }
            elseif ($ev.IndexOf('Player-', $ord) -ge 0) {
                $m = $rxUnits.Match($ev)
                if ($m.Success) {
                    if ($m.Groups[1].Success) {
                        $g = $m.Groups[1].Value; $fl = $m.Groups[3].Value
                        if ($FlagCache[$g] -ne $fl) { $FlagCache[$g] = $fl; Update-Unit $g $m.Groups[2].Value $fl }
                    }
                    if ($m.Groups[4].Success) {
                        $g = $m.Groups[4].Value; $fl = $m.Groups[6].Value
                        if ($FlagCache[$g] -ne $fl) { $FlagCache[$g] = $fl; Update-Unit $g $m.Groups[5].Value $fl }
                    }
                }
            }

            $prevCI = $isCI
        }

        if (Update-Title) { $dirty = $true }
        if (Update-Scores) { $dirty = $true }
        Test-FinishedHold
        if ($dirty) { Write-Overlay; $dirty = $false }
    }
}
finally {
    if ($reader) { $reader.Dispose() }
    if ($Http) { $Http.Dispose() }
}