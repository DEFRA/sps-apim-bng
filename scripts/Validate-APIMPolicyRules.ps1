
<#
SYNOPSIS
 APIM Policy validator aligned with APIM’s lenient parsing:
 - Accepts inner double-quotes inside @(... ) attributes (optional WARN can be suppressed).
 - Continues functional validations even if XML parsing fails (regex-based fallback).
 - Enforces rules: validate-jwt children, rate-limit settings (incl. External presence), cache-store duration, retry/trace disallowed.

PARAMETERS
 -RootPath Root of repo (default '.').
 -Journey 'external' | 'internal' | 'both' (default 'external').
 -Environments String[] or comma-separated (e.g. base,dev,pre,tst).
 -ApiName API folder filter (default '*').
 -FailOnError Exit 1 if any FAIL exists; WARN does not fail.
 -ContextRadius Context lines for debug when XML fails (default 5).
 -SuppressQuoteLint Do not warn about inner quotes inside @(... ) attributes.

BEHAVIOR
 1) Optionally lints for unescaped inner " inside double-quoted attributes containing @(... ) → WARN (can be suppressed).
 2) Preprocesses the text to make XML parse-friendly (escapes only inner " within @(... ) when attribute is double-quoted), then loads DOM.
 3) If DOM parse still fails → runs regex-based checks so rules still apply.
#>
[CmdletBinding()]
param(
    [string]$RootPath = ".",
    [ValidateSet('external','internal','both')][string]$Journey = 'external',
    [string[]]$Environments = @('base','dev','pre','tst'),
    [string]$ApiName = "*",
    [switch]$FailOnError,
    [ValidateRange(0,50)][int]$ContextRadius = 5,
    [switch]$SuppressQuoteLint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- helpers ----------
function Add-Result {
    param(
        [ref]$bag,
        [string]$journey,
        [string]$env,
        [string]$api,
        [string]$file,
        [string]$rule,
        [ValidateSet('PASS','FAIL','WARN','INFO')][string]$status,
        [string]$details
    )
    $bag.Value += [PSCustomObject]@{
        Journey = $journey
        Env     = $env
        Api     = $api
        File    = $file
        Rule    = $rule
        Status  = $status
        Details = $details
    }
}

function Get-PolicyFiles {
    param(
        [string]$root,
        [string[]]$journeys,
        [string[]]$envs,
        [string]$apiFilter
    )
    $files = @()
    foreach ($j in $journeys) {
        foreach ($e in $envs) {
            $apisDir = Join-Path (Join-Path (Join-Path $root $j) $e) 'apis'
            if (-not (Test-Path -LiteralPath $apisDir)) { continue }
            Get-ChildItem -LiteralPath $apisDir -Directory -Filter $apiFilter -ErrorAction SilentlyContinue |
            ForEach-Object {
                $apiFolder = $_.FullName
                $policy = $null
                $policy = Get-Item -LiteralPath (Join-Path $apiFolder 'Policy.xml') -ErrorAction SilentlyContinue
                if (-not $policy) { $policy = Get-Item -LiteralPath (Join-Path $apiFolder 'policy.xml') -ErrorAction SilentlyContinue }
                if ($policy) {
                    $files += [PSCustomObject]@{
                        Journey = $j
                        Env     = $e
                        Api     = $_.Name
                        Path    = $policy.FullName
                    }
                }
            }
        }
    }
    return $files
}

function Read-TextUtf8 {
    param([string]$path)
    return Get-Content -LiteralPath $path -Raw
}

function Show-XmlErrorContext {
    param(
        [string]$path,
        [int]$line,
        [int]$pos,
        [int]$radius
    )
    if ($line -le 0 -or -not (Test-Path -LiteralPath $path)) { return }
    $content = Get-Content -LiteralPath $path
    $start = [Math]::Max(1, $line - $radius)
    $end   = [Math]::Min($content.Count, $line + $radius)
    Write-Host "`n--- XML Error Context (Line $line, Position $pos) ---" -ForegroundColor Cyan
    for ($i = $start; $i -le $end; $i++) {
        $marker = if ($i -eq $line) { ">>" } else { "  " }
        if ($i -eq $line -and $pos -gt 0) {
            $ln = $content[$i-1]
            "{0} {1,4}: {2}" -f $marker, $i, $ln | Write-Host
            "{0} {1}" -f $marker, (' ' * ([Math]::Max(0,$pos-1))) + '^' | Write-Host
        } else {
            "{0} {1,4}: {2}" -f $marker, $i, $content[$i-1] | Write-Host
        }
    }
}

# Escapes only inner " inside @(... ) whose attribute is double-quoted, to make XML parsing succeed.
function Make-XmlParseFriendly {
    param([string]$text)
    # Match attr="@( ... )" (non-greedy inside the parentheses), attribute name kept, value captured as @(...)
    $pattern = '(?<attr>\w+)\s*=\s*"(?<val>@\(.+?\))"'
    $sb = New-Object System.Text.StringBuilder
    $idx = 0

    foreach ($m in [regex]::Matches($text, $pattern, 'Singleline')) {
        # Append the text before this attribute
        [void]$sb.Append($text.Substring($idx, $m.Index - $idx))
        $attrName = $m.Groups['attr'].Value
        $val      = $m.Groups['val'].Value

        # Escape inner quotes inside the @(... ) only
        $valEsc = $val -replace '"', '&quot;'

        # Reconstruct: attr="(escaped-value)"
        [void]$sb.Append($attrName)
        [void]$sb.Append('="')
        [void]$sb.Append($valEsc)
        [void]$sb.Append('"')

        $idx = $m.Index + $m.Length
    }

    # Append remaining tail
    [void]$sb.Append($text.Substring($idx))
    return $sb.ToString()
}

# ---------- LINT (WARN only, optional) ----------
function Lint-UnescapedQuotesInExpressionAttributes {
    param(
        [string]$text,
        [string]$file,
        [string]$journey,
        [string]$env,
        [string]$api,
        [ref]$results
    )
    # Pattern: double-quoted attribute with @(...) where an inner literal " appears before attribute closes.
    $regex = [regex]'(?s)(?<attr>\w+)\s*=\s*"@\([^"]*"'
    $matches = $regex.Matches($text)
    foreach ($m in $matches) {
        $quoteIdx = $m.Index + $m.Length - 1
        $prefix = $text.Substring(0, [Math]::Min($quoteIdx, $text.Length))
        $line = ($prefix -split "`r?`n").Length
        $lastNL = ($prefix.LastIndexOf("`n"))
        $col = if ($lastNL -ge 0) { $quoteIdx - $lastNL } else { $quoteIdx + 1 }
        $attrName = $m.Groups['attr'].Value
        $snippet = $m.Value
        $hint = "Unescaped quote inside double-quoted attribute '$attrName' containing @(...). " +
                "APIM accepts this, but for XML tooling use single-quoted attributes or &quot; inside the value."
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "Lint: unescaped quote in @(...) attribute" -status "WARN" `
            -details ("Line {0}, Pos {1}: {2} :: {3}" -f $line,$col,$snippet,$hint)
    }
}

# ---------- Functional rule checks (DOM) ----------
function Check-Rules-Dom {
    param(
        [xml]$xml,
        [string]$journey,
        [string]$env,
        [string]$api,
        [string]$file,
        [ref]$results
    )

    # External journey must include at least one rate limiter
    $rateLimitNodes      = $xml.SelectNodes('//rate-limit')
    $rateLimitByKeyNodes = $xml.SelectNodes('//rate-limit-by-key')
    $hasAnyRateLimiter   = ($rateLimitNodes.Count -gt 0) -or ($rateLimitByKeyNodes.Count -gt 0)

    if ($journey -eq 'external' -and -not $hasAnyRateLimiter) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "rate-limit presence (External)" -status "FAIL" `
            -details "External Publisher policies must include rate limiting: <rate-limit/> or <rate-limit-by-key/>."
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "rate-limit presence (External)" -status "PASS" `
            -details "At least one rate limiter present or journey is not 'external'."
    }

    # Validation 1: validate-jwt children
    $jwtNodes = $xml.SelectNodes('//validate-jwt')
    if ($jwtNodes -and $jwtNodes.Count -gt 0) {
        foreach ($jwt in $jwtNodes) {
            $openid = $jwt.SelectSingleNode('openid-config')
            if (-not ($openid -and ($openid.GetAttribute('url') -as [string]).Trim())) {
                Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                    -rule "validate-jwt: openid-config" -status "FAIL" -details "Missing <openid-config url='...'>."
            } else {
                Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                    -rule "validate-jwt: openid-config" -status "PASS" -details "Present."
            }

            $aud = $jwt.SelectNodes('audiences/audience')
            if (-not $aud -or $aud.Count -eq 0) {
                Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                    -rule "validate-jwt: audiences" -status "FAIL" -details "Missing <audiences><audience/>."
            } else {
                Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                    -rule "validate-jwt: audiences" -status "PASS" -details "Present."
            }

            $vals = $jwt.SelectNodes('required-claims//value')
            if (-not $vals -or $vals.Count -eq 0) {
                Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                    -rule "validate-jwt: required-claims" -status "FAIL" -details "Missing <value> under <required-claims>."
            } else {
                Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                    -rule "validate-jwt: required-claims" -status "PASS" -details "Present."
            }
        }
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "validate-jwt presence" -status "INFO" -details "No <validate-jwt> found."
    }

    # Validation 2: rate-limit specifics
    foreach ($rl in $rateLimitNodes) {
        $calls = $rl.GetAttribute('calls')
        $renew = $rl.GetAttribute('renewal-period')
        if (($calls -as [int]) -eq 100 -and ($renew -as [int]) -ne 60) {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "rate-limit (calls=100)" -status "FAIL" -details "Expected renewal-period='60'. Found '$renew'."
        } else {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "rate-limit check" -status "PASS" -details "OK."
        }
    }

    foreach ($rk in $rateLimitByKeyNodes) {
        $rkRenew = $rk.GetAttribute('renewal-period')
        $rkKey   = $rk.GetAttribute('counter-key')
        if (-not (($rkRenew -as [int]) -ge 0) -or -not ($rkKey -and $rkKey.Trim() -match '^@\(.+\)$')) {
            $missing = @()
            if (-not (($rkRenew -as [int]) -ge 0)) { $missing += 'renewal-period' }
            if (-not ($rkKey -and $rkKey.Trim() -match '^@\(.+\)$')) { $missing += "counter-key '@(...)'" }
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "rate-limit-by-key" -status "FAIL" -details ("Missing/invalid: " + ($missing -join ", "))
        } else {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "rate-limit-by-key" -status "PASS" -details "OK."
        }
    }

    # Validation 3: cache-store duration <= 60
    foreach ($c in $xml.SelectNodes('//cache-store')) {
        $dur = $c.GetAttribute('duration') -as [int]
        if ($dur -gt 60) {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "cache-store" -status "FAIL" -details ("duration must be <= 60. Found " + $dur)
        } else {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "cache-store" -status "PASS" -details "OK or not present."
        }
    }

    # Validation 4/5: retry/trace disallowed
    if ($xml.SelectNodes('//retry').Count -gt 0) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "retry" -status "FAIL" -details "<retry> is not allowed."
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "retry" -status "PASS" -details "Not present."
    }

    if ($xml.SelectNodes('//trace').Count -gt 0) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "trace" -status "FAIL" -details "<trace> is not allowed."
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "trace" -status "PASS" -details "Not present."
    }
}

# ---------- Functional rule checks (regex fallback) ----------
function Check-Rules-Regex {
    param(
        [string]$text,
        [string]$journey,
        [string]$env,
        [string]$api,
        [string]$file,
        [ref]$results
    )

    # Normalize whitespace for simple matching
    $t = $text -replace '\s+',' '

    # Helper: check existence
    function Exists { param($pattern) return [regex]::IsMatch($t, $pattern, 'IgnoreCase') }

    # Rough patterns (lenient, text-based)
    $hasPolicies         = Exists '<policies'
    $hasInbound          = Exists '<inbound'
    $hasValidateJwt      = Exists '<validate-jwt'
    $hasOpenIdUrl        = Exists '<openid-config[^>]*\surl\s*=\s*"[^"]+"'
    $hasAudience         = Exists '<audiences[^>]*>.*?<audience[^>]*>.*?</audience>.*?</audiences>'
    $hasReqClaims        = Exists '<required-claims[^>]*>.*?<value[^>]*>.*?</value>.*?</required-claims>'

    $hasRateLimitAny     = Exists '<rate-limit\b'
    $hasRateByKeyAny     = Exists '<rate-limit-by-key\b'
    $hasRateLimit100     = Exists '<rate-limit[^>]*\scalls\s*=\s*"100"'
    $hasRenew60          = Exists '<rate-limit[^>]*\srenewal-period\s*=\s*"60"'
    $hasRateByKeyRenew   = Exists '<rate-limit-by-key[^>]*\srenewal-period\s*=\s*"\d+"'
    $hasRateByKeyCounter = [regex]::IsMatch($t, '<rate-limit-by-key[^>]*\scounter-key\s*=\s*"@\(.+\)"', 'IgnoreCase')

    $hasCacheStore       = Exists '<cache-store[^>]*\sduration\s*=\s*"\d+"'
    $cacheTooHigh        = [regex]::Matches($t, '<cache-store[^>]*\sduration\s*=\s*"(?<d>\d+)"', 'IgnoreCase') |
                           Where-Object { [int]$_.Groups['d'].Value -gt 60 } |
                           Select-Object -First 1
    $hasRetry            = Exists '<retry\b'
    $hasTrace            = Exists '<trace\b'

    # External journey: require at least one rate limiter
    $hasAnyRateLimiter = $hasRateLimitAny -or $hasRateByKeyAny
    if ($journey -eq 'external' -and -not $hasAnyRateLimiter) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "rate-limit presence (External)" -status "FAIL" `
            -details "External Publisher policies must include rate limiting: <rate-limit/> or <rate-limit-by-key/> (text)."
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "rate-limit presence (External)" -status "PASS" `
            -details "At least one rate limiter present or journey is not 'external' (text)."
    }

    # Policy structure hint
    if (-not $hasPolicies -or -not $hasInbound) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "policy structure" -status "WARN" -details "Missing <policies>/<inbound> (text check)."
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "policy structure" -status "INFO" -details "Basic sections detected (text check)."
    }

    # Validation 1 (text)
    if ($hasValidateJwt) {
        if (-not $hasOpenIdUrl) {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "validate-jwt: openid-config" -status "FAIL" -details "Missing <openid-config url='...'> (text)."
        } else {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "validate-jwt: openid-config" -status "PASS" -details "Present (text)."
        }

        if (-not $hasAudience) {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "validate-jwt: audiences" -status "FAIL" -details "Missing audience (text)."
        } else {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "validate-jwt: audiences" -status "PASS" -details "Present (text)."
        }

        if (-not $hasReqClaims) {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "validate-jwt: required-claims" -status "FAIL" -details "Missing <value> (text)."
        } else {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "validate-jwt: required-claims" -status "PASS" -details "Present (text)."
        }
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "validate-jwt presence" -status "INFO" -details "No <validate-jwt> (text)."
    }

    # Validation 2 specifics (text)
    if ($hasRateLimit100 -and -not $hasRenew60) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "rate-limit (calls=100)" -status "FAIL" -details "Expected renewal-period='60' (text)."
    } elseif ($hasRateLimit100 -and $hasRenew60) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "rate-limit (calls=100)" -status "PASS" -details "OK (text)."
    }

    if ($hasRateByKeyAny) {
        $issues = @()
        if (-not $hasRateByKeyRenew)   { $issues += "renewal-period" }
        if (-not $hasRateByKeyCounter) { $issues += "counter-key '@(...)'" }
        if ($issues.Count -gt 0) {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "rate-limit-by-key" -status "FAIL" -details ("Missing/invalid: " + ($issues -join ", ") + " (text).")
        } else {
            Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
                -rule "rate-limit-by-key" -status "PASS" -details "OK (text)."
        }
    }

    # Validation 3 (text)
    if ($cacheTooHigh) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "cache-store" -status "FAIL" -details ("duration must be <= 60 (text). Found " + $cacheTooHigh.Groups['d'].Value)
    } elseif ($hasCacheStore) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "cache-store" -status "PASS" -details "OK or <= 60 (text)."
    }

    # Validation 4/5 (text)
    if ($hasRetry) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "retry" -status "FAIL" -details "<retry> not allowed (text)."
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "retry" -status "PASS" -details "Not present (text)."
    }

    if ($hasTrace) {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "trace" -status "FAIL" -details "<trace> not allowed (text)."
    } else {
        Add-Result -bag $results -journey $journey -env $env -api $api -file $file `
            -rule "trace" -status "PASS" -details "Not present (text)."
    }
}

# ---------- main ----------
$journeys = if ($Journey -eq 'both') { @('external','internal') } else { @($Journey) }

$envs = @()
foreach ($e in $Environments) {
    $envs += ($e -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
$envs = $envs | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique

$policyFiles = Get-PolicyFiles -root $RootPath -journeys $journeys -envs $envs -apiFilter $ApiName
$results = @()

foreach ($pf in $policyFiles) {
    try {
        # Read text
        $rawText = Read-TextUtf8 -path $pf.Path

        # Optional lint (can be suppressed)
        if (-not $SuppressQuoteLint) {
            Lint-UnescapedQuotesInExpressionAttributes -text $rawText -file $pf.Path -journey $pf.Journey -env $pf.Env -api $pf.Api -results ([ref]$results)
        }

        # Produce an XML-parse-friendly version (only for parsing; leaves file content untouched)
        $parseText = Make-XmlParseFriendly -text $rawText

        # Try XML parse using the in-memory, parse-friendly text
        $xml = $null
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.PreserveWhitespace = $true
            $xml.LoadXml($parseText)
        } catch {
            $ex = $_.Exception
            $line = if ($ex -is [System.Xml.XmlException]) { $ex.LineNumber } else { 0 }
            $pos  = if ($ex -is [System.Xml.XmlException]) { $ex.LinePosition } else { 0 }
            Add-Result -bag ([ref]$results) -journey $pf.Journey -env $pf.Env -api $pf.Api -file $pf.Path `
                -rule "XML Parse" -status "WARN" `
                -details ("Parser could not load; continuing with text-based checks. Line {0}, Pos {1}: {2}" -f $line,$pos,$ex.Message)
            Show-XmlErrorContext -path $pf.Path -line $line -pos $pos -radius $ContextRadius
        }

        if ($xml) {
            Check-Rules-Dom   -xml $xml -journey $pf.Journey -env $pf.Env -api $pf.Api -file $pf.Path -results ([ref]$results)
        } else {
            Check-Rules-Regex -text $rawText -journey $pf.Journey -env $pf.Env -api $pf.Api -file $pf.Path -results ([ref]$results)
        }
    } catch {
        Add-Result -bag ([ref]$results) -journey $pf.Journey -env $pf.Env -api $pf.Api -file $pf.Path `
            -rule "Validator runtime" -status "FAIL" -details $_.Exception.Message
    }
}


# ---------- summary ----------
$EOL = "`r`n"
$header = "## APIM Policy Validation Summary${EOL}Journey | Env | API | Rule | Status | Details${EOL}--- | --- | --- | --- | --- | ---"
$lines = foreach ($r in $results) {
    "{0} | {1} | {2} | {3} | {4} | {5}" -f $r.Journey,$r.Env,$r.Api,$r.Rule,$r.Status,$r.Details
}

$failCount     = (@($results | Where-Object { $_.Status -eq 'FAIL' })).Count
$warnCount     = (@($results | Where-Object { $_.Status -eq 'WARN' })).Count
$passInfoCount = (@($results | Where-Object { $_.Status -in @('PASS','INFO') })).Count

Write-Host "`n--- Policy Summary ---"
Write-Host ($header + $EOL + (@($lines) -join $EOL))

if (@($policyFiles).Count -eq 0) {
    Write-Warning ("No policy files found for Journey='{0}', Environments='{1}', ApiName='{2}'." -f ($journeys -join ','), ($envs -join ','), $ApiName)
}

if ($FailOnError -and $failCount -gt 0) {
    # QUIET FAIL: only counts, no verbose error record
    Write-Host ("FAIL={0}, WARN={1}, PASS/INFO={2}" -f $failCount, $warnCount, $passInfoCount)
    exit 1
} else {
    Write-Host ""
    # Final line via here-string to avoid any paste/quote issues
    $final = @"
Validation completed. FAIL=$failCount, WARN=$warnCount, PASS/INFO=$passInfoCount
"@
    Write-Host $final
}

