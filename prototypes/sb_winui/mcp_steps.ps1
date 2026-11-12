param([string]$Pipe, [string]$Steps, [string]$Out, [string]$FlagDir, [int]$ReplyMs = 5000, [int]$ArtistMs = 30000)
# A stepped agent client for (A) W2. $Steps is one JSON array; each element is
#   {"client": <JSON-RPC object>}  -- sent; the client then waits for the reply
#                                     with that id (notifications are kept too)
#   {"artist": "<act>", ...}       -- the driver's turn: this writes
#                                     <FlagDir>\ready-<n> and waits for
#                                     <FlagDir>\done-<n>, then collects what the
#                                     shell sends for 1.5 s
# Every line received is written to $Out as {"step":n,"line":<raw>}. ASCII only.
$ErrorActionPreference = 'Stop'
# 5.1 emits a top-level JSON array as ONE pipeline object, and @() wraps
# rather than unrolls it: unroll it through the pipeline.
$plan = @((Get-Content -Raw $Steps | ConvertFrom-Json) | ForEach-Object { $_ })
$c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
$c.Connect(20000)
"connected pipe=$Pipe steps=$($plan.Count)"
$buf = New-Object byte[] 65536
$pending = New-Object System.Text.StringBuilder
$got = New-Object System.Collections.Generic.List[string]
$t = $c.ReadAsync($buf, 0, $buf.Length)
function Receive-SbLines([int]$Ms, [int]$Step, $WantId) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        if ($script:t.Wait(100)) {
            $n = $script:t.Result
            if ($n -le 0) { return $false }
            [void]$script:pending.Append([Text.Encoding]::UTF8.GetString($script:buf, 0, $n))
            $script:t = $script:c.ReadAsync($script:buf, 0, $script:buf.Length)
            $text = $script:pending.ToString()
            $nl = $text.LastIndexOf("`n")
            if ($nl -ge 0) {
                # Consume EVERY complete line before returning (a return inside
                # the loop left them in the buffer, recorded again next step).
                [void]$script:pending.Clear(); [void]$script:pending.Append($text.Substring($nl + 1))
                $seen = $false
                foreach ($l in $text.Substring(0, $nl).Split("`n")) {
                    if ($l.Trim().Length -eq 0) { continue }
                    $script:got.Add((@{ step = $Step; line = $l.TrimEnd("`r") } | ConvertTo-Json -Compress -Depth 2))
                    if ($null -ne $WantId) {
                        try { $o = $l | ConvertFrom-Json; if ($o.id -eq $WantId -and $null -eq $o.method) { $seen = $true } } catch { }
                    }
                }
                if ($seen) { return $true }
            }
        }
    }
    return ($null -eq $WantId)
}
for ($i = 0; $i -lt $plan.Count; $i++) {
    $s = $plan[$i]
    if ($null -ne $s.client) {
        $line = ($s.client | ConvertTo-Json -Compress -Depth 20) + "`n"
        $b = [Text.Encoding]::UTF8.GetBytes($line)
        $c.Write($b, 0, $b.Length); $c.Flush()
        $ok = Receive-SbLines $ReplyMs $i $s.client.id
        "step $i client id=$($s.client.id) answered=$ok"
    } else {
        Set-Content -Path (Join-Path $FlagDir "ready-$i") -Value $s.artist -Encoding ascii
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path (Join-Path $FlagDir "done-$i")) -and $sw.ElapsedMilliseconds -lt $ArtistMs) { Start-Sleep -Milliseconds 100 }
        [void](Receive-SbLines 1500 $i $null)
        "step $i artist=$($s.artist) done=$(Test-Path (Join-Path $FlagDir "done-$i"))"
    }
}
[IO.File]::WriteAllLines($Out, $got)
"received lines=$($got.Count)"
$c.Dispose()
