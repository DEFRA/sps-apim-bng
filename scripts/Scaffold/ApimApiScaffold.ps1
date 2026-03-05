
<#
.SYNOPSIS
 APIM Self‑Serve token mapping tool (PS 5.1/7 compatible) — IN‑PLACE mode

.DESCRIPTION
 - Step 1: Materialize template folders by renaming placeholder folder segments (optional switch)
 - Step 2: Replace tokens directly in source files:
     * Double‑angle tokens: <<TOKEN>> (case-insensitive; also supports HTML-encoded &lt;&lt;TOKEN&gt;&gt;)
     * Brace tokens: {{token}} (case-insensitive) for convenience in JSON/YAML
 - JSON templates are tokenized as text → parsed → patched via mapping JSONPaths (in-place)
 - Diagnostics and Reports are OPT-IN
 - Optional backups under TemplatesRoot/.bak/<timestamp>

 UPDATED FOR YOUR STRUCTURE + INPUT:
 - Supports TemplatesRoot = 'internal' and mapping paths like base/dev/tst
 - Supports namedValues folders materialized to BACKEND_SCOPEID_KEYNAME / FRONTEND_CLIENTID_KEYNAME
 - Supports backendInformation.dev.json + backendInformation.tst.json
 - Supports both <<DEV_BACKEND_URL>> and <<TST_BACKEND_URL>> tokens in templates
 - Keeps unknown brace tokens (e.g. {{ apiOpsKeyVaultName }}) unresolved when -AllowMissing is passed

 Exit codes:
  0 = success
  1 = validation errors
  2 = substitution errors
  3 = filesystem/path errors
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $InputJson,
  [Parameter(Mandatory=$true)] [string] $Schema,
  [Parameter(Mandatory=$true)] [string] $Mapping,
  [Parameter(Mandatory=$true)] [string] $TemplatesRoot,

  # --- Behavior ---
  [Parameter(Mandatory=$false)] [switch] $MaterializeTemplateFolders,
  [Parameter(Mandatory=$false)] [switch] $CopyInsteadOfRename,
  [Parameter(Mandatory=$false)] [switch] $InPlace,              # kept for backward compat
  [Parameter(Mandatory=$false)] [switch] $BackupBeforeWrite,
  [Parameter(Mandatory=$false)] [switch] $AllowMissing,
  [Parameter(Mandatory=$false)] [string] $Environment,          # base|dev|tst|pre|prod (optional)
  [Parameter(Mandatory=$false)] [string] $SpecPath,

  # --- Diagnostics (opt-in) ---
  [Parameter(Mandatory=$false)] [switch] $Diagnostics,
  [Parameter(Mandatory=$false)] [int]    $DiagDumpChars = 160,
  [Parameter(Mandatory=$false)] [switch] $DiagSaveSamples,

  # --- Reports (opt-in) ---
  [Parameter(Mandatory=$false)] [switch] $GenerateReports,
  [Parameter(Mandatory=$false)] [switch] $ExportDocx,
  [Parameter(Mandatory=$false)] [switch] $ExportPdf
)

# -----------------------------------------------------------------------------
# Runtime and audit
# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$CorrelationId = [guid]::NewGuid().ToString()
$Timestamp = (Get-Date).ToString('o')
$ExitCodeFS = $null
$script:SubError = $false

function Resolve-PathSafe([string]$p){
  if(Test-Path -LiteralPath $p){ return (Resolve-Path -LiteralPath $p).Path }
  $alt = Join-Path $PSScriptRoot $p
  if(Test-Path -LiteralPath $alt){ return (Resolve-Path -LiteralPath $alt).Path }
  throw "Path not found: $p"
}
function Try-Pandoc(){ try { return (Get-Command pandoc -ErrorAction SilentlyContinue) } catch { return $null } }

$TemplatesRoot = Resolve-PathSafe $TemplatesRoot

# Lazy init for reports/diag artifacts (only if Diagnostics or GenerateReports are used)
$reportsRoot = $null
$diagLog     = $null

function Write-Diag([string]$m){
  if($Diagnostics.IsPresent){
    if(-not $reportsRoot){
      $reportsRoot = Join-Path $TemplatesRoot "reports"
      if(-not (Test-Path -LiteralPath $reportsRoot)){
        New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
      }
    }
    if(-not $diagLog){
      $diagLog = Join-Path $reportsRoot ("diag-" + $CorrelationId + ".log")
      "" | Set-Content -LiteralPath $diagLog
    }
    $line = "[DIAG] " + $m
    Write-Host $line -ForegroundColor DarkGray
    Add-Content -LiteralPath $diagLog -Value ("{0:o} {1}" -f (Get-Date), $line)
  }
}

function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Warning "[WARN] $m" }
function Write-Err ($m){ Write-Error   "[ERROR] $m" }

Write-Diag "PSVersion: $($PSVersionTable.PSVersion); OS: $([System.Environment]::OSVersion.VersionString)"
Write-Diag "CorrelationId: $CorrelationId"

# -----------------------------------------------------------------------------
# IO helpers
# -----------------------------------------------------------------------------
function Get-Json([string]$p){ (Get-Content -LiteralPath $p -Raw) | ConvertFrom-Json }
function Save-Json([object]$obj, [string]$p){
  $json = $obj | ConvertTo-Json -Depth 50
  Set-Content -LiteralPath $p -Value $json -NoNewline
}
function Save-Text([string]$text, [string]$p){
  Set-Content -LiteralPath $p -Value $text -NoNewline
}

function Make-BackupPath([string]$targetPath){
  $safeTs = $Timestamp.Replace(':','-')
  $bakRoot = Join-Path $TemplatesRoot ".bak/$safeTs"
  $rel = $targetPath
  try {
    $relCandidate = Resolve-Path -LiteralPath $targetPath -Relative
    if($relCandidate){ $rel = $relCandidate }
  } catch {
    if ($targetPath.StartsWith($TemplatesRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $targetPath.Substring($TemplatesRoot.Length).TrimStart('\','/')
    } else {
      $rel = Split-Path -Leaf $targetPath
    }
  }
  $dest = Join-Path $bakRoot $rel
  $destDir = Split-Path -Parent $dest
  if(-not (Test-Path -LiteralPath $destDir)){
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  }
  return $dest
}
function Backup-IfExists([string]$p){
  if(-not $BackupBeforeWrite.IsPresent){ return $null }
  if(Test-Path -LiteralPath $p){
    $bak = Make-BackupPath $p
    Copy-Item -LiteralPath $p -Destination $bak -Force
    Write-Diag "Backed up '$p' -> '$bak'"
    return $bak
  }
  return $null
}

# -----------------------------------------------------------------------------
# Minimal schema validator
# -----------------------------------------------------------------------------
function Validate-AgainstSchema([pscustomobject]$data, [pscustomobject]$schemaObj){
  $errs = @()
  if($schemaObj.required){
    foreach($req in $schemaObj.required){
      if(-not ($data.PSObject.Properties.Name -contains $req)){
        $errs += "Missing required field: $req"
      } elseif ([string]::IsNullOrWhiteSpace([string]$data.$req)){
        $errs += "Empty value for required field: $req"
      }
    }
  }
  return $errs
}

# -----------------------------------------------------------------------------
# JSONPath setter (simple dotted paths)
# -----------------------------------------------------------------------------
function Set-JsonPathValue([object]$obj, [string]$jsonPath, [object]$value){
  if(-not $jsonPath.StartsWith('$.')){ throw "Unsupported JSONPath: $jsonPath" }
  $parts  = $jsonPath.TrimStart('$.').Split('.')
  $cursor = $obj
  for($i=0; $i -lt ($parts.Length-1); $i++){
    $p = $parts[$i]
    if(-not ($cursor.PSObject.Properties.Name -contains $p)){
      $cursor | Add-Member -MemberType NoteProperty -Name $p -Value ([PSCustomObject]@{})
    }
    $cursor = $cursor.$p
  }
  $leaf = $parts[-1]
  if($cursor.PSObject.Properties.Name -contains $leaf){ $cursor.$leaf = $value }
  else { $cursor | Add-Member -MemberType NoteProperty -Name $leaf -Value $value }
}

# -----------------------------------------------------------------------------
# Diagnostics helpers + normalization
# -----------------------------------------------------------------------------
function Normalize-EncodedText([string]$text){
  # Decode HTML entities (&lt; &gt; &amp; etc.)
  $t = [System.Net.WebUtility]::HtmlDecode($text)

  # Decode common unicode escapes if they appear literally
  $t = $t -replace '\\u003c','<' -replace '\\u003e','>' -replace '\\u0026','&'
  $t = $t -replace '\\u007B','{' -replace '\\u007D','}'

  return $t
}

function Detect-Tokens([string]$text){
  $reAngle = '<<\s*([A-Za-z0-9_]+)\s*>>'
  $reBrace = '\{\{\s*([A-Za-z0-9_\-]+)\s*\}\}'
  $d = [ordered]@{}
  $d.double = ([regex]::Matches($text, $reAngle) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique
  $d.brace  = ([regex]::Matches($text, $reBrace) | ForEach-Object { $_.Groups[1].Value.ToLower() }) | Select-Object -Unique
  return [pscustomobject]$d
}

function Dump-Sample([string]$label, [string]$text, [int]$n){
  if(-not $Diagnostics.IsPresent){ return }
  $snippet = $text.Substring(0, [Math]::Min($n, $text.Length)).Replace("`r"," ").Replace("`n"," ")
  Write-Diag "$label sample($n): $snippet"
}

function Save-SampleFile([string]$label, [string]$stage, [string]$text, [int]$n){
  if(-not $DiagSaveSamples.IsPresent -or -not $Diagnostics.IsPresent){ return }
  if(-not $reportsRoot){
    $reportsRoot = Join-Path $TemplatesRoot "reports"
    if(-not (Test-Path -LiteralPath $reportsRoot)){
      New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
    }
  }
  $samplesDir = Join-Path $reportsRoot "samples"
  if(-not (Test-Path -LiteralPath $samplesDir)){
    New-Item -ItemType Directory -Path $samplesDir -Force | Out-Null
  }
  $file = Join-Path $samplesDir ("{0}-{1}-{2}.txt" -f ($label -replace '[^\w\-]','_'), $stage, $CorrelationId)
  $snippet = $text.Substring(0, [Math]::Min($n, $text.Length))
  Set-Content -LiteralPath $file -Value $snippet -NoNewline
  Write-Diag "Saved sample: $file"
}

# -----------------------------------------------------------------------------
# Token replacement (ANGLE + BRACE)
# -----------------------------------------------------------------------------
function Replace-Tokens(
  [string] $Text,
  [pscustomobject] $InputObj,
  [hashtable] $BraceTokens,
  [pscustomobject] $MappingObj,
  [bool] $AllowMissing
){
  $Text = Normalize-EncodedText $Text

  # Canonicalize angle tokens to uppercase inside the text
  $Text = [regex]::Replace($Text, '<<\s*([A-Za-z0-9_]+)\s*>>', {
    param($m) '<<' + $m.Groups[1].Value.ToUpper() + '>>'
  })

  $reAngle = '<<\s*([A-Za-z0-9_]+)\s*>>'
  $reBrace = '\{\{\s*([A-Za-z0-9_\-]+)\s*\}\}'

  $presentAngle = ([regex]::Matches($Text, $reAngle) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique

  if($Diagnostics.IsPresent){
    Write-Diag ("Replace-Tokens: present angle = " + ($presentAngle -join ', '))
    $presentBrace = ([regex]::Matches($Text, $reBrace) | ForEach-Object { $_.Groups[1].Value.ToLower() }) | Select-Object -Unique
    Write-Diag ("Replace-Tokens: present brace = " + ($presentBrace -join ', '))
  }

  function Resolve-AngleValue([string]$NAME, [pscustomobject]$InputObj, [pscustomobject]$MappingObj){
    # direct key match
    if($InputObj.PSObject.Properties.Name -contains $NAME){ return [string]$InputObj.$NAME }

    # mapping angleAliases
    if($MappingObj -and ($MappingObj.PSObject.Properties.Name -contains 'angleAliases')){
      if($MappingObj.angleAliases.PSObject.Properties.Name -contains $NAME){
        $key = [string]$MappingObj.angleAliases.$NAME
        if($InputObj.PSObject.Properties.Name -contains $key){ return [string]$InputObj.$key }
      }
    }
    return $null
  }

  $missingAngle = @()
  foreach($NAME in $presentAngle){
    $val = Resolve-AngleValue $NAME $InputObj $MappingObj
    if([string]::IsNullOrWhiteSpace($val)){
      $missingAngle += $NAME
      continue
    }
    $Text = $Text.Replace("<<$NAME>>", $val)
    if($Diagnostics.IsPresent){ Write-Diag ("ANGLE: {0} -> '{1}'" -f $NAME, $val) }
  }

  # Brace tokens: only replace keys we have; leave others intact (e.g., {{ apiOpsKeyVaultName }})
  foreach($k in $BraceTokens.Keys){
    $pattern = '(?i)\{\{\s*' + [regex]::Escape($k) + '\s*\}\}'
    $Text = [regex]::Replace($Text, $pattern, [string]$BraceTokens[$k])
    if($Diagnostics.IsPresent){ Write-Diag ("BRACE: {0} -> '{1}'" -f $k, $BraceTokens[$k]) }
  }

  # Final unresolved check (ANGLE + BRACE)
  $unresolved = @()
  $unresolved += ([regex]::Matches($Text, $reAngle) | ForEach-Object { $_.Value })
  $unresolved += ([regex]::Matches($Text, $reBrace) | ForEach-Object { $_.Value })
  $unresolved = $unresolved | Select-Object -Unique

  if(($unresolved.Count -gt 0) -and (-not $AllowMissing)){
    if($Diagnostics.IsPresent -and $missingAngle.Count -gt 0){
      Write-Diag ("Unresolved ANGLE tokens (no value found): " + ($missingAngle -join ', '))
    }
    throw ("Unresolved placeholders remain in template content: " + ($unresolved -join ', '))
  }

  return $Text
}

# -----------------------------------------------------------------------------
# Template resolution (mapping + robust fallbacks)
# -----------------------------------------------------------------------------
function Find-CaseInsensitiveFile([string]$root, [string]$regex){
  $ciRegex = [regex]"(?i)$regex"
  foreach($item in Get-ChildItem -LiteralPath $root -Recurse -File){
    if($ciRegex.IsMatch($item.FullName)){ return $item.FullName }
  }
  return $null
}

function Apply-TemplatePlaceholders([string]$rel){
  # Replace placeholders used in mapping templates
  $r = $rel

  if($script:effectiveObj -and $script:effectiveObj.PSObject.Properties.Name -contains 'API_NAME'){
    $r = [regex]::Replace($r, 'API_NAME', [string]$script:effectiveObj.API_NAME, 'IgnoreCase')
  }
  if($script:effectiveObj -and $script:effectiveObj.PSObject.Properties.Name -contains 'BACKEND_SCOPEID_KEYNAME'){
    $r = [regex]::Replace($r, 'BACKEND_SCOPEID_KEYNAME', [string]$script:effectiveObj.BACKEND_SCOPEID_KEYNAME, 'IgnoreCase')
  }
  if($script:effectiveObj -and $script:effectiveObj.PSObject.Properties.Name -contains 'FRONTEND_CLIENTID_KEYNAME'){
    $r = [regex]::Replace($r, 'FRONTEND_CLIENTID_KEYNAME', [string]$script:effectiveObj.FRONTEND_CLIENTID_KEYNAME, 'IgnoreCase')
  }
  return $r
}

function Tpl([string]$logical){
  $mappingObj = $script:mappingObj

  # 1) Mapping path resolution (with placeholder replacement)
  if($mappingObj.templates.PSObject.Properties.Name -contains $logical){
    $rel = [string]$mappingObj.templates.$logical
    $relReplaced = Apply-TemplatePlaceholders $rel

    $fullReplaced = Join-Path $TemplatesRoot $relReplaced
    $fullLiteral  = Join-Path $TemplatesRoot $rel

    if(Test-Path -LiteralPath $fullReplaced){ return $fullReplaced }
    if(Test-Path -LiteralPath $fullLiteral){ return $fullLiteral }
  }

  # 2) Fallbacks for older namedValues layout (API_NAME-backend-scopeid / API_NAME-frontend-clientid)
  switch($logical){

    'namedValueBackendInformation.json' {
      $p1 = Join-Path $TemplatesRoot ("base/namedValues/{0}-backend-scopeid/namedValueInformation.json" -f $script:apiName)
      if(Test-Path -LiteralPath $p1){ return $p1 }

      $scan = Find-CaseInsensitiveFile -root $TemplatesRoot -regex 'base[\\/]namedValues[\\/].*backend\-scopeid[\\/].*namedValueInformation\.json$'
      if($scan){ return $scan }
    }

    'namedValueFrontendInformation.json' {
      $p2 = Join-Path $TemplatesRoot ("base/namedValues/{0}-frontend-clientid/namedValueInformation.json" -f $script:apiName)
      if(Test-Path -LiteralPath $p2){ return $p2 }

      $scan = Find-CaseInsensitiveFile -root $TemplatesRoot -regex 'base[\\/]namedValues[\\/].*frontend\-clientid[\\/].*namedValueInformation\.json$'
      if($scan){ return $scan }
    }
  }

  throw "Template '$logical' not found (tried mapping + fallbacks)."
}

# -----------------------------------------------------------------------------
# Load inputs
# -----------------------------------------------------------------------------
try{
  $InputJson  = Resolve-PathSafe $InputJson
  $Schema     = Resolve-PathSafe $Schema
  $Mapping    = Resolve-PathSafe $Mapping

  Write-Info "[PATH] InputJson     = $InputJson"
  Write-Info "[PATH] Schema        = $Schema"
  Write-Info "[PATH] Mapping       = $Mapping"
  Write-Info "[PATH] TemplatesRoot = $TemplatesRoot"

  $inputObj   = Get-Json $InputJson
  $schemaObj  = Get-Json $Schema
  $mappingObj = Get-Json $Mapping
  $script:mappingObj = $mappingObj
} catch {
  Write-Err "Failed to resolve/load paths: $($_.Exception.Message)"
  exit 3
}

$valErrors = Validate-AgainstSchema $inputObj $schemaObj
if($valErrors.Count -gt 0){
  foreach($e in $valErrors){ Write-Err $e }
  Write-Err "JSON validation errors encountered."
  exit 1
}

# -----------------------------------------------------------------------------
# Resolve environment overlay
# -----------------------------------------------------------------------------
$effective = @{}
foreach($p in $inputObj.PSObject.Properties){
  if($p.Name -ne 'environments'){ $effective[$p.Name] = $p.Value }
}

# legacy overlay support if you still have environments object
if($Environment -and $inputObj.PSObject.Properties.Name -contains 'environments'){
  $envKey = $Environment.ToLower()
  $envObj = $inputObj.environments.$envKey
  if($envObj){
    foreach($p in $envObj.PSObject.Properties){ $effective[$p.Name] = $p.Value }
  } else {
    Write-Warn "Environment '$Environment' not found under input.json.environments; using base values."
  }
}

$script:effectiveObj = [pscustomobject]$effective

if(-not ($script:effectiveObj.PSObject.Properties.Name -contains 'API_NAME')){
  Write-Err "API_NAME missing"
  exit 1
}

$script:apiName = [string]$script:effectiveObj.API_NAME
Write-Diag "Effective keys: $([string]::Join(', ', ( $script:effectiveObj.PSObject.Properties.Name | Sort-Object )))"

# Optional: environment-driven override of API_BACKEND_URL for apiInformation.json (serviceUrl)
# If you run workflow once per env, this makes apiInformation serviceUrl use DEV/TST URL.
if($Environment){
  switch($Environment.ToLower()){
    'dev' {
      if($script:effectiveObj.PSObject.Properties.Name -contains 'DEV_BACKEND_URL'){
        $script:effectiveObj.API_BACKEND_URL = [string]$script:effectiveObj.DEV_BACKEND_URL
        Write-Diag "Environment override: API_BACKEND_URL <- DEV_BACKEND_URL"
      }
    }
    'tst' {
      if($script:effectiveObj.PSObject.Properties.Name -contains 'TST_BACKEND_URL'){
        $script:effectiveObj.API_BACKEND_URL = [string]$script:effectiveObj.TST_BACKEND_URL
        Write-Diag "Environment override: API_BACKEND_URL <- TST_BACKEND_URL"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Brace token bag (policy + JSON/YAML templates)
# -----------------------------------------------------------------------------
$tokens = @{}

# TenantId is used in policy.xml (value may contain helm token e.g. #{{ defraTenantId }})
if($script:effectiveObj.PSObject.Properties.Name -contains 'TENANT_ID'){
  $tokens['tenant_id'] = [string]$script:effectiveObj.TENANT_ID
}

# IMPORTANT: policies usually reference named value *names* now
if($script:effectiveObj.PSObject.Properties.Name -contains 'BACKEND_SCOPEID_KEYNAME'){
  $tokens['backend_scopeid'] = [string]$script:effectiveObj.BACKEND_SCOPEID_KEYNAME
}
if($script:effectiveObj.PSObject.Properties.Name -contains 'FRONTEND_CLIENTID_KEYNAME'){
  $tokens['frontend_clientid'] = [string]$script:effectiveObj.FRONTEND_CLIENTID_KEYNAME
}

if($script:effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_CALLS'){
  $tokens['rate_limit_calls'] = [string]$script:effectiveObj.RATE_LIMIT_CALLS
}
if($script:effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_PERIOD'){
  $tokens['rate_limit_period'] = [string]$script:effectiveObj.RATE_LIMIT_PERIOD
}

# convenience brace keys (lowercase)
foreach($k in @(
  'API_NAME','API_VERSION','API_DISPLAY_NAME','API_DESCRIPTION','API_BACKEND_URL',
  'BACKEND_SCOPEID_KEYNAME','FRONTEND_CLIENTID_KEYNAME',
  'DEV_BACKEND_URL','TST_BACKEND_URL'
)){
  if($script:effectiveObj.PSObject.Properties.Name -contains $k){
    $tokens[$k.ToLower()] = [string]$script:effectiveObj.$k
  }
}

Write-Diag ("Brace token keys available: {0}" -f ([string]::Join(', ', ( $tokens.Keys | Sort-Object ))))

# -----------------------------------------------------------------------------
# Step 1 — Materialize template folders
# -----------------------------------------------------------------------------
if($MaterializeTemplateFolders.IsPresent){
  Write-Info "Materializing template folders under $TemplatesRoot"

  # A) Materialize from mapping templates (parent folders)
  foreach ($tplProp in $mappingObj.templates.PSObject.Properties) {
    $rel = [string]$tplProp.Value
    $srcParentRel = Split-Path $rel -Parent
    $dstParentRel = Split-Path (Apply-TemplatePlaceholders $rel) -Parent

    $src = Join-Path $TemplatesRoot $srcParentRel
    $dst = Join-Path $TemplatesRoot $dstParentRel

    if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
      if ($CopyInsteadOfRename.IsPresent) {
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        Write-Info "Copied '$src' -> '$dst'"
      } else {
        Move-Item -LiteralPath $src -Destination $dst -Force
        Write-Info "Renamed '$src' -> '$dst'"
      }
    } else {
      Write-Diag "Materialize skip: src? $(Test-Path $src) ; dst? $(Test-Path $dst)"
    }
  }

  # B) Deep scan: rename any directory containing API_NAME placeholder (case-insensitive)
  $dirs = Get-ChildItem -LiteralPath $TemplatesRoot -Directory -Recurse `
          | Where-Object { $_.Name -match '(?i)API_NAME' } `
          | Sort-Object FullName -Descending

  foreach($d in $dirs){
    $newName = [regex]::Replace($d.Name, 'API_NAME', $script:apiName, 'IgnoreCase')
    if ($newName -eq $d.Name) { continue }
    $target = Join-Path $d.Parent.FullName $newName
    if (Test-Path -LiteralPath $target) {
      Write-Diag "Skip rename (target exists): $($d.FullName) -> $target"
      continue
    }
    if ($CopyInsteadOfRename.IsPresent) {
      Copy-Item -LiteralPath $d.FullName -Destination $target -Recurse -Force
      Write-Info "Copied folder: '$($d.FullName)' -> '$target'"
    } else {
      Rename-Item -LiteralPath $d.FullName -NewName $newName -Force
      Write-Info "Renamed folder: '$($d.FullName)' -> '$target'"
    }
  }

  # C) Special: materialize namedValues from old layout to keyname layout (if applicable)
  # If your templates still have base/namedValues/API_NAME-backend-scopeid but mapping expects base/namedValues/<keyname>
  if($script:effectiveObj.PSObject.Properties.Name -contains 'BACKEND_SCOPEID_KEYNAME'){
    $old = Join-Path $TemplatesRoot ("base/namedValues/{0}-backend-scopeid" -f $script:apiName)
    $new = Join-Path $TemplatesRoot ("base/namedValues/{0}" -f [string]$script:effectiveObj.BACKEND_SCOPEID_KEYNAME)
    if((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new)){
      if($CopyInsteadOfRename.IsPresent){
        Copy-Item -LiteralPath $old -Destination $new -Recurse -Force
        Write-Info "Copied namedValue backend folder '$old' -> '$new'"
      } else {
        Move-Item -LiteralPath $old -Destination $new -Force
        Write-Info "Renamed namedValue backend folder '$old' -> '$new'"
      }
    }
  }
  if($script:effectiveObj.PSObject.Properties.Name -contains 'FRONTEND_CLIENTID_KEYNAME'){
    $old = Join-Path $TemplatesRoot ("base/namedValues/{0}-frontend-clientid" -f $script:apiName)
    $new = Join-Path $TemplatesRoot ("base/namedValues/{0}" -f [string]$script:effectiveObj.FRONTEND_CLIENTID_KEYNAME)
    if((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new)){
      if($CopyInsteadOfRename.IsPresent){
        Copy-Item -LiteralPath $old -Destination $new -Recurse -Force
        Write-Info "Copied namedValue frontend folder '$old' -> '$new'"
      } else {
        Move-Item -LiteralPath $old -Destination $new -Force
        Write-Info "Renamed namedValue frontend folder '$old' -> '$new'"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# In-place file handlers
# -----------------------------------------------------------------------------
function Process-JsonTemplate([string]$logical, [string]$label){
  $tpl = Tpl $logical
  Write-Diag "$label path: $tpl"

  $raw = Get-Content -LiteralPath $tpl -Raw
  Dump-Sample "$label raw" $raw $DiagDumpChars; Save-SampleFile $label "raw" $raw $DiagDumpChars

  $norm = Normalize-EncodedText $raw
  Dump-Sample "$label normalized" $norm $DiagDumpChars; Save-SampleFile $label "normalized" $norm $DiagDumpChars

  $pre = Detect-Tokens $norm
  Write-Diag "$label tokens (pre): <<>>=$($pre.double.Count), {{}}=$($pre.brace.Count)"
  if($pre.double.Count -gt 0){ Write-Diag "$label tokens (pre, angle): $([string]::Join(', ', ($pre.double)))" }

  $text = Replace-Tokens -Text $norm -InputObj $script:effectiveObj -BraceTokens $tokens -MappingObj $script:mappingObj -AllowMissing ([bool]$AllowMissing)

  try{
    $obj = $text | ConvertFrom-Json
  } catch {
    throw "Template '$tpl' could not be parsed as JSON after token replacement. Error: $($_.Exception.Message)"
  }

  # Apply mapping JSONPath patches (authoritative)
  foreach($f in $script:mappingObj.fields){
    foreach($u in $f.usage){
      if(($u.target -eq 'file') -and ($u.file -eq $logical) -and $u.jsonPath){
        $key  = $f.inputKey
        $path = $u.jsonPath
        if($script:effectiveObj.PSObject.Properties.Name -contains $key){
          Set-JsonPathValue -obj $obj -jsonPath $path -value $script:effectiveObj.$key
        } elseif($f.mandatory -and (-not $AllowMissing.IsPresent)){
          Write-Warn ("{0}: missing mandatory '{1}' for {2}" -f $label, $key, $path)
          $script:SubError = $true
        }
      }
    }
  }

  Backup-IfExists $tpl | Out-Null
  Save-Json $obj $tpl

  $postText = Normalize-EncodedText (Get-Content -LiteralPath $tpl -Raw)
  $post = Detect-Tokens $postText
  Write-Diag "$label tokens (post): <<>>=$($post.double.Count), {{}}=$($post.brace.Count)"
  if(($post.double.Count + $post.brace.Count) -gt 0){
    Write-Diag "$label unresolved (post): $([string]::Join(', ', ($post.double + $post.brace)))"
  }
}

function Process-TextTemplate([string]$logical, [string]$label){
  $tpl = Tpl $logical
  Write-Diag "$label path: $tpl"

  $raw = Get-Content -LiteralPath $tpl -Raw
  Dump-Sample "$label raw" $raw $DiagDumpChars; Save-SampleFile $label "raw" $raw $DiagDumpChars

  $norm = Normalize-EncodedText $raw
  Dump-Sample "$label normalized" $norm $DiagDumpChars; Save-SampleFile $label "normalized" $norm $DiagDumpChars

  $pre = Detect-Tokens $norm
  Write-Diag "$label tokens (pre): <<>>=$($pre.double.Count), {{}}=$($pre.brace.Count)"

  $text = Replace-Tokens -Text $norm -InputObj $script:effectiveObj -BraceTokens $tokens -MappingObj $script:mappingObj -AllowMissing ([bool]$AllowMissing)

  Dump-Sample "$label replaced" $text $DiagDumpChars; Save-SampleFile $label "replaced" $text $DiagDumpChars

  Backup-IfExists $tpl | Out-Null
  Save-Text $text $tpl

  $post = Detect-Tokens $text
  Write-Diag "$label tokens (post): <<>>=$($post.double.Count), {{}}=$($post.brace.Count)"
  if(($post.double.Count + $post.brace.Count) -gt 0){
    Write-Diag "$label unresolved (post): $([string]::Join(', ', ($post.double + $post.brace)))"
  }
}

# -----------------------------------------------------------------------------
# Step 2 — Process files IN‑PLACE
# -----------------------------------------------------------------------------
try{
  # Base JSON templates
  Process-JsonTemplate -logical 'apiInformation.json'         -label 'base/apis/*/apiInformation.json'
  Process-JsonTemplate -logical 'productInformation.json'     -label 'base/products/*/productInformation.json'
  Process-JsonTemplate -logical 'versionSetInformation.json'  -label 'base/version sets/*/versionSetInformation.json'

  # Named values
  Process-JsonTemplate -logical 'namedValueBackendInformation.json'  -label 'base/namedValues/*backend*/namedValueInformation.json'
  Process-JsonTemplate -logical 'namedValueFrontendInformation.json' -label 'base/namedValues/*frontend*/namedValueInformation.json'

  # Policy + Spec (text)
  Process-TextTemplate -logical 'policy.xml'         -label 'base/apis/*/policy.xml'

  if($SpecPath){
    $SpecPath = Resolve-PathSafe $SpecPath
    $tplSpec = Tpl 'specification.yaml'
    $specText = Normalize-EncodedText (Get-Content -LiteralPath $SpecPath -Raw)
    $repSpec  = Replace-Tokens -Text $specText -InputObj $script:effectiveObj -BraceTokens $tokens -MappingObj $script:mappingObj -AllowMissing ([bool]$AllowMissing)
    Backup-IfExists $tplSpec | Out-Null
    Save-Text $repSpec $tplSpec
    Write-Info "specification.yaml updated in-place from external spec"
  } else {
    Process-TextTemplate -logical 'specification.yaml' -label 'base/apis/*/specification.yaml'
  }

  # Backend Information per environment (JSON)
  Process-JsonTemplate -logical 'backendInformation.dev.json' -label 'dev/backends/*/backendInformation.json'
  Process-JsonTemplate -logical 'backendInformation.tst.json' -label 'tst/backends/*/backendInformation.json'

} catch {
  Write-Err "Processing failure: $($_.Exception.Message)"
  $ExitCodeFS = 3
}

# -----------------------------------------------------------------------------
# Reports (only if -GenerateReports is passed)
# -----------------------------------------------------------------------------
if ($GenerateReports.IsPresent) {
  if(-not $reportsRoot){
    $reportsRoot = Join-Path $TemplatesRoot "reports"
    if(-not (Test-Path -LiteralPath $reportsRoot)){
      New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
    }
  }

  $reportJson = Join-Path $reportsRoot "inplace-$($CorrelationId).json"
  $reportMd   = Join-Path $reportsRoot "inplace-$($CorrelationId).md"
  $reportHtml = Join-Path $reportsRoot "inplace-$($CorrelationId).html"

  $audit = [ordered]@{
    correlationId       = $CorrelationId
    timestamp           = $Timestamp
    templatesRoot       = $TemplatesRoot
    mapping             = $Mapping
    inputJson           = $InputJson
    environment         = $Environment
    allowMissing        = [bool]$AllowMissing
    diagnostics         = [bool]$Diagnostics
    diagDumpChars       = $DiagDumpChars
    diagSaveSamples     = [bool]$DiagSaveSamples
    backupBeforeWrite   = [bool]$BackupBeforeWrite
    materializedFolders = [bool]$MaterializeTemplateFolders
    copyInsteadOfRename = [bool]$CopyInsteadOfRename
  }
  ($audit | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $reportJson -NoNewline

  $md = @"
# APIM Self-Serve In-Place Mapping Report
- **Correlation ID**: $CorrelationId
- **Timestamp**: $Timestamp
- **Templates Root**: $TemplatesRoot
- **Mapping**: $Mapping
- **Input JSON**: $InputJson
- **Environment**: $Environment
- **Allow Missing**: $([bool]$AllowMissing)
- **Diagnostics**: $([bool]$Diagnostics)
- **Diag Dump Chars**: $DiagDumpChars
- **Diag Samples**: $([bool]$DiagSaveSamples)
- **Backup Before Write**: $([bool]$BackupBeforeWrite)
- **Materialized Folders**: $([bool]$MaterializeTemplateFolders)
- **Copy Instead Of Rename**: $([bool]$CopyInsteadOfRename)
"@
  Set-Content -LiteralPath $reportMd -Value $md -NoNewline

  $html = "<!DOCTYPE html><html lang=""en""><head><meta charset=""utf-8"" /><title>APIM Self-Serve In-Place Mapping</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;line-height:1.5}pre{white-space:pre-wrap}</style></head><body><h1>APIM Self-Serve In-Place Mapping</h1><pre>$md</pre></body></html>"
  Set-Content -LiteralPath $reportHtml -Value $html -NoNewline

  Write-Diag "Report written: MD=$reportMd ; HTML=$reportHtml"

  $pandoc = Try-Pandoc
  if($pandoc){
    if($ExportDocx.IsPresent){
      $reportDocx = Join-Path $reportsRoot "inplace-$($CorrelationId).docx"
      & $pandoc.Source $reportMd -o $reportDocx
      if(Test-Path -LiteralPath $reportDocx){ Write-Info "DOCX created: $reportDocx" } else { Write-Warn "DOCX conversion failed." }
    }
    if($ExportPdf.IsPresent){
      $reportPdf = Join-Path $reportsRoot "inplace-$($CorrelationId).pdf"
      & $pandoc.Source $reportMd -o $reportPdf
      if(Test-Path -LiteralPath $reportPdf){ Write-Info "PDF created: $reportPdf" } else { Write-Warn "PDF conversion failed." }
    }
  } elseif($ExportDocx.IsPresent -or $ExportPdf.IsPresent){
    Write-Warn "Pandoc not found. DOCX/PDF export skipped."
  }
}

# -----------------------------------------------------------------------------
# Exit semantics
# -----------------------------------------------------------------------------
if($ExitCodeFS -eq 3){ Write-Err "Filesystem errors encountered. Exit code = 3"; exit 3 }
if($script:SubError){ Write-Err "Substitution errors encountered. Exit code = 2"; exit 2 }

if ($GenerateReports.IsPresent -or $Diagnostics.IsPresent) {
  $msg = "✅ Completed IN-PLACE."
  if ($GenerateReports.IsPresent) {
    $msg += "`nReports:"
    $msg += "`n- " + (Join-Path $reportsRoot "inplace-$CorrelationId.json")
    $msg += "`n- " + (Join-Path $reportsRoot "inplace-$CorrelationId.md")
    $msg += "`n- " + (Join-Path $reportsRoot "inplace-$CorrelationId.html")
  }
  if ($Diagnostics.IsPresent -and $diagLog) {
    $msg += "`nDiag log:`n- " + $diagLog
  }
  Write-Host $msg -ForegroundColor Green
} else {
  Write-Host "✅ Completed IN-PLACE." -ForegroundColor Green
}
exit 0
