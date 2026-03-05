
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

 UPDATED:
 - Supports TemplatesRoot = 'internal' or 'external' and mapping paths base/dev/tst/pre
 - NamedValues: supports BOTH layouts:
     (A) base/namedValues/<KEYNAME>/namedValueInformation.json
     (B) base/namedValues/API_NAME-backend-scopeid/namedValueInformation.json (legacy template folder)
     (C) base/namedValues/API_NAME-frontend-clientid/namedValueInformation.json (legacy template folder)
 - Materialize step can convert legacy NamedValues folders into keyname folders
 - Processes backendInformation per env: dev/tst/pre

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
  [Parameter(Mandatory=$false)] [switch] $InPlace,
  [Parameter(Mandatory=$false)] [switch] $BackupBeforeWrite,
  [Parameter(Mandatory=$false)] [switch] $AllowMissing,
  [Parameter(Mandatory=$false)] [string] $Environment,   # no longer required; kept for compat
  [Parameter(Mandatory=$false)] [string] $SpecPath,

  # --- Diagnostics (opt-in) ---
  [Parameter(Mandatory=$false)] [switch] $Diagnostics,
  [Parameter(Mandatory=$false)] [int]    $DiagDumpChars = 160,
  [Parameter(Mandatory=$false)] [switch] $DiagSaveSamples
)

# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$CorrelationId = [guid]::NewGuid().ToString()
$Timestamp = (Get-Date).ToString('o')
$ExitCodeFS = $null
$script:SubError = $false
$reportsRoot = $null
$diagLog = $null

function Resolve-PathSafe([string]$p){
  if(Test-Path -LiteralPath $p){ return (Resolve-Path -LiteralPath $p).Path }
  $alt = Join-Path $PSScriptRoot $p
  if(Test-Path -LiteralPath $alt){ return (Resolve-Path -LiteralPath $alt).Path }
  throw "Path not found: $p"
}

$TemplatesRoot = Resolve-PathSafe $TemplatesRoot

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

# -----------------------------------------------------------------------------
# IO helpers
# -----------------------------------------------------------------------------
function Get-Json([string]$p){ (Get-Content -LiteralPath $p -Raw) | ConvertFrom-Json }
function Save-Json([object]$obj, [string]$p){
  $json = $obj | ConvertTo-Json -Depth 50
  Set-Content -LiteralPath $p -Value $json -NoNewline
}
function Save-Text([string]$text, [string]$p){ Set-Content -LiteralPath $p -Value $text -NoNewline }

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
# Minimal schema validator (required presence + non-empty)
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
# JSONPath setter
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
# Normalization + token helpers
# -----------------------------------------------------------------------------
function Normalize-EncodedText([string]$text){
  $t = [System.Net.WebUtility]::HtmlDecode($text)
  $t = $t -replace '\\u003c','<' -replace '\\u003e','>' -replace '\\u0026','&'
  $t = $t -replace '\\u007B','{' -replace '\\u007D','}'
  return $t
}

function Replace-Tokens(
  [string] $Text,
  [pscustomobject] $InputObj,
  [hashtable] $BraceTokens,
  [pscustomobject] $MappingObj,
  [bool] $AllowMissing
){
  $Text = Normalize-EncodedText $Text

  # canonicalize <<token>> to uppercase names
  $Text = [regex]::Replace($Text, '<<\s*([A-Za-z0-9_]+)\s*>>', {
    param($m) '<<' + $m.Groups[1].Value.ToUpper() + '>>'
  })

  $reAngle = '<<\s*([A-Za-z0-9_]+)\s*>>'
  $reBrace = '\{\{\s*([A-Za-z0-9_\-]+)\s*\}\}'

  $presentAngle = ([regex]::Matches($Text, $reAngle) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique

  function Resolve-AngleValue([string]$NAME, [pscustomobject]$InputObj, [pscustomobject]$MappingObj){
    if($InputObj.PSObject.Properties.Name -contains $NAME){ return [string]$InputObj.$NAME }
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
    Write-Diag ("ANGLE: {0} -> '{1}'" -f $NAME, $val)
  }

  # replace only known brace keys, leave unknown ones (e.g. {{ apiOpsKeyVaultName }})
  foreach($k in $BraceTokens.Keys){
    $pattern = '(?i)\{\{\s*' + [regex]::Escape($k) + '\s*\}\}'
    $Text = [regex]::Replace($Text, $pattern, [string]$BraceTokens[$k])
    Write-Diag ("BRACE: {0} -> '{1}'" -f $k, $BraceTokens[$k])
  }

  # strict unresolved check unless AllowMissing
  $unresolved = @()
  $unresolved += ([regex]::Matches($Text, $reAngle) | ForEach-Object { $_.Value })
  $unresolved += ([regex]::Matches($Text, $reBrace) | ForEach-Object { $_.Value })
  $unresolved = $unresolved | Select-Object -Unique

  if(($unresolved.Count -gt 0) -and (-not $AllowMissing)){
    throw ("Unresolved placeholders remain: " + ($unresolved -join ', '))
  }

  return $Text
}

# -----------------------------------------------------------------------------
# Template resolution (mapping + fallbacks)
# -----------------------------------------------------------------------------
function Find-CaseInsensitiveFile([string]$root, [string]$regex){
  $ciRegex = [regex]"(?i)$regex"
  foreach($item in Get-ChildItem -LiteralPath $root -Recurse -File){
    if($ciRegex.IsMatch($item.FullName)){ return $item.FullName }
  }
  return $null
}

function Apply-TemplatePlaceholders([string]$rel){
  $r = $rel
  if($script:effectiveObj.PSObject.Properties.Name -contains 'API_NAME'){
    $r = [regex]::Replace($r, 'API_NAME', [string]$script:effectiveObj.API_NAME, 'IgnoreCase')
  }
  if($script:effectiveObj.PSObject.Properties.Name -contains 'BACKEND_SCOPEID_KEYNAME'){
    $r = [regex]::Replace($r, 'BACKEND_SCOPEID_KEYNAME', [string]$script:effectiveObj.BACKEND_SCOPEID_KEYNAME, 'IgnoreCase')
  }
  if($script:effectiveObj.PSObject.Properties.Name -contains 'FRONTEND_CLIENTID_KEYNAME'){
    $r = [regex]::Replace($r, 'FRONTEND_CLIENTID_KEYNAME', [string]$script:effectiveObj.FRONTEND_CLIENTID_KEYNAME, 'IgnoreCase')
  }
  return $r
}

function Tpl([string]$logical){
  $mappingObj = $script:mappingObj

  # 1) Try mapping path with placeholder replacement
  if($mappingObj.templates.PSObject.Properties.Name -contains $logical){
    $rel = [string]$mappingObj.templates.$logical
    $relReplaced = Apply-TemplatePlaceholders $rel
    $fullReplaced = Join-Path $TemplatesRoot $relReplaced
    $fullLiteral  = Join-Path $TemplatesRoot $rel

    if(Test-Path -LiteralPath $fullReplaced){ return $fullReplaced }
    if(Test-Path -LiteralPath $fullLiteral){ return $fullLiteral }
  }

  # 2) NamedValues fallbacks (this is the missing piece in your current script)
  switch($logical){
    'namedValueBackendInformation.json' {
      # legacy folder name based on API_NAME
      $legacy = Join-Path $TemplatesRoot ("base/namedValues/{0}-backend-scopeid/namedValueInformation.json" -f $script:apiName)
      if(Test-Path -LiteralPath $legacy){ return $legacy }

      $scan = Find-CaseInsensitiveFile -root $TemplatesRoot -regex 'base[\\/]namedValues[\\/].*backend\-scopeid[\\/].*namedValueInformation\.json$'
      if($scan){ return $scan }
    }
    'namedValueFrontendInformation.json' {
      $legacy = Join-Path $TemplatesRoot ("base/namedValues/{0}-frontend-clientid/namedValueInformation.json" -f $script:apiName)
      if(Test-Path -LiteralPath $legacy){ return $legacy }

      $scan = Find-CaseInsensitiveFile -root $TemplatesRoot -regex 'base[\\/]namedValues[\\/].*frontend\-clientid[\\/].*namedValueInformation\.json$'
      if($scan){ return $scan }
    }
  }

  throw "Template '$logical' not found (tried mapping paths + fallbacks)."
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

  $script:effectiveObj = Get-Json $InputJson
  $schemaObj = Get-Json $Schema
  $script:mappingObj = Get-Json $Mapping
} catch {
  Write-Err "Failed to resolve/load paths: $($_.Exception.Message)"
  exit 3
}

$valErrors = Validate-AgainstSchema $script:effectiveObj $schemaObj
if($valErrors.Count -gt 0){
  foreach($e in $valErrors){ Write-Err $e }
  Write-Err "JSON validation errors encountered."
  exit 1
}

$script:apiName = [string]$script:effectiveObj.API_NAME

# -----------------------------------------------------------------------------
# Brace token bag
# -----------------------------------------------------------------------------
$tokens = @{}

if($script:effectiveObj.PSObject.Properties.Name -contains 'TENANT_ID'){ $tokens['tenant_id'] = [string]$script:effectiveObj.TENANT_ID }
if($script:effectiveObj.PSObject.Properties.Name -contains 'BACKEND_SCOPEID_KEYNAME'){ $tokens['backend_scopeid'] = [string]$script:effectiveObj.BACKEND_SCOPEID_KEYNAME }
if($script:effectiveObj.PSObject.Properties.Name -contains 'FRONTEND_CLIENTID_KEYNAME'){ $tokens['frontend_clientid'] = [string]$script:effectiveObj.FRONTEND_CLIENTID_KEYNAME }
if($script:effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_CALLS'){ $tokens['rate_limit_calls'] = [string]$script:effectiveObj.RATE_LIMIT_CALLS }
if($script:effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_PERIOD'){ $tokens['rate_limit_period'] = [string]$script:effectiveObj.RATE_LIMIT_PERIOD }

foreach($k in @('API_NAME','API_VERSION','API_DISPLAY_NAME','API_DESCRIPTION','API_BACKEND_URL',
               'BACKEND_SCOPEID_KEYNAME','FRONTEND_CLIENTID_KEYNAME','DEV_BACKEND_URL','TST_BACKEND_URL','PRE_BACKEND_URL')){
  if($script:effectiveObj.PSObject.Properties.Name -contains $k){
    $tokens[$k.ToLower()] = [string]$script:effectiveObj.$k
  }
}

# -----------------------------------------------------------------------------
# Step 1 — Materialize template folders (including legacy namedValues → keyname namedValues)
# -----------------------------------------------------------------------------
if($MaterializeTemplateFolders.IsPresent){
  Write-Info "Materializing template folders under $TemplatesRoot"

  # Generic materialize using mapping templates (parent folders)
  foreach ($tplProp in $script:mappingObj.templates.PSObject.Properties) {
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
    }
  }

  # Explicit: legacy namedValues folder conversion to keyname folder
  if($script:effectiveObj.PSObject.Properties.Name -contains 'BACKEND_SCOPEID_KEYNAME'){
    $legacyFolder = Join-Path $TemplatesRoot ("base/namedValues/{0}-backend-scopeid" -f $script:apiName)
    $keyFolder    = Join-Path $TemplatesRoot ("base/namedValues/{0}" -f [string]$script:effectiveObj.BACKEND_SCOPEID_KEYNAME)

    if((Test-Path -LiteralPath $legacyFolder) -and -not (Test-Path -LiteralPath $keyFolder)){
      if($CopyInsteadOfRename.IsPresent){
        Copy-Item -LiteralPath $legacyFolder -Destination $keyFolder -Recurse -Force
        Write-Info "Copied legacy backend namedValue folder '$legacyFolder' -> '$keyFolder'"
      } else {
        Move-Item -LiteralPath $legacyFolder -Destination $keyFolder -Force
        Write-Info "Renamed legacy backend namedValue folder '$legacyFolder' -> '$keyFolder'"
      }
    }
  }

  if($script:effectiveObj.PSObject.Properties.Name -contains 'FRONTEND_CLIENTID_KEYNAME'){
    $legacyFolder = Join-Path $TemplatesRoot ("base/namedValues/{0}-frontend-clientid" -f $script:apiName)
    $keyFolder    = Join-Path $TemplatesRoot ("base/namedValues/{0}" -f [string]$script:effectiveObj.FRONTEND_CLIENTID_KEYNAME)

    if((Test-Path -LiteralPath $legacyFolder) -and -not (Test-Path -LiteralPath $keyFolder)){
      if($CopyInsteadOfRename.IsPresent){
        Copy-Item -LiteralPath $legacyFolder -Destination $keyFolder -Recurse -Force
        Write-Info "Copied legacy frontend namedValue folder '$legacyFolder' -> '$keyFolder'"
      } else {
        Move-Item -LiteralPath $legacyFolder -Destination $keyFolder -Force
        Write-Info "Renamed legacy frontend namedValue folder '$legacyFolder' -> '$keyFolder'"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Processing helpers
# -----------------------------------------------------------------------------
function Process-JsonTemplate([string]$logical, [string]$label){
  $tpl = Tpl $logical
  Write-Diag "$label path: $tpl"

  $raw = Get-Content -LiteralPath $tpl -Raw
  $norm = Normalize-EncodedText $raw

  $text = Replace-Tokens -Text $norm -InputObj $script:effectiveObj -BraceTokens $tokens -MappingObj $script:mappingObj -AllowMissing ([bool]$AllowMissing)
  $obj = $text | ConvertFrom-Json

  foreach($f in $script:mappingObj.fields){
    foreach($u in $f.usage){
      if(($u.target -eq 'file') -and ($u.file -eq $logical) -and $u.jsonPath){
        $key  = $f.inputKey
        $path = $u.jsonPath
        if($script:effectiveObj.PSObject.Properties.Name -contains $key){
          Set-JsonPathValue -obj $obj -jsonPath $path -value $script:effectiveObj.$key
        }
      }
    }
  }

  Backup-IfExists $tpl | Out-Null
  Save-Json $obj $tpl
}

function Process-TextTemplate([string]$logical, [string]$label){
  $tpl = Tpl $logical
  $raw = Get-Content -LiteralPath $tpl -Raw
  $norm = Normalize-EncodedText $raw
  $text = Replace-Tokens -Text $norm -InputObj $script:effectiveObj -BraceTokens $tokens -MappingObj $script:mappingObj -AllowMissing ([bool]$AllowMissing)

  Backup-IfExists $tpl | Out-Null
  Save-Text $text $tpl
}

# -----------------------------------------------------------------------------
# Step 2 — Process templates
# -----------------------------------------------------------------------------
try{
  Process-JsonTemplate -logical 'apiInformation.json' -label 'apiInformation'
  Process-JsonTemplate -logical 'productInformation.json' -label 'productInformation'
  Process-JsonTemplate -logical 'versionSetInformation.json' -label 'versionSetInformation'

  Process-JsonTemplate -logical 'namedValueBackendInformation.json' -label 'namedValue backend'
  Process-JsonTemplate -logical 'namedValueFrontendInformation.json' -label 'namedValue frontend'

  Process-TextTemplate -logical 'policy.xml' -label 'policy.xml'
  Process-TextTemplate -logical 'specification.yaml' -label 'specification.yaml'

  Process-JsonTemplate -logical 'backendInformation.dev.json' -label 'backend dev'
  Process-JsonTemplate -logical 'backendInformation.tst.json' -label 'backend tst'
  Process-JsonTemplate -logical 'backendInformation.pre.json' -label 'backend pre'

} catch {
  Write-Err "Processing failure: $($_.Exception.Message)"
  exit 3
}

Write-Host "✅ Completed IN-PLACE." -ForegroundColor Green
exit 0
