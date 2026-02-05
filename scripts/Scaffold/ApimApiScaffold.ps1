
<#
.SYNOPSIS
 APIM Self‑Serve token mapping tool (PS 5.1/7 compatible) — IN‑PLACE mode

.DESCRIPTION
 - Step 1: Materialize template folders by renaming 'API_NAME' → <actual api> (optional switch)
 - Step 2: Apply per‑environment overrides; replace tokens directly in source files:
     * ONLY double‑angle tokens: <<TOKEN>>
     * Brace tokens: {{token}} (case‑insensitive) for convenience in JSON/YAML
 - JSON templates are tokenized as text → parsed → patched via mapping JSONPaths (in-place)
 - Diagnostics and Reports are OPT-IN:
     * Diagnostics only when -Diagnostics is passed (lazy report dir/log creation)
     * Reports (JSON/MD/HTML, optional DOCX/PDF) only when -GenerateReports is passed
 - Optional backups under TemplatesRoot/.bak/<timestamp>

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
  [Parameter(Mandatory=$false)] [switch] $MaterializeTemplateFolders, # FIRST: rename 'API_NAME' → '<api>'
  [Parameter(Mandatory=$false)] [switch] $CopyInsteadOfRename,        # copy instead of rename (default = rename)
  [Parameter(Mandatory=$false)] [switch] $InPlace,                    # apply mapping directly to source files
  [Parameter(Mandatory=$false)] [switch] $BackupBeforeWrite,          # backups under TemplatesRoot/.bak/<timestamp>
  [Parameter(Mandatory=$false)] [switch] $AllowMissing,               # allow unresolved tokens without failing
  [Parameter(Mandatory=$false)] [string] $Environment,                # base|dev|tst|pre|prod
  [Parameter(Mandatory=$false)] [string] $SpecPath,                   # optional external OpenAPI spec (in-place)

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
$SubError = $false

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
function Save-Text([string]$text, [string]$p){ Set-Content -LiteralPath $p -Value $text }

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
  if(-not (Test-Path -LiteralPath $destDir)){ New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
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
# Diagnostics helpers
# -----------------------------------------------------------------------------
function Normalize-EncodedText([string]$text){
  $t = [System.Net.WebUtility]::HtmlDecode($text)
  $t = $t -replace '\\u003c','<' -replace '\\u003e','>' -replace '\\u0026','&'
  $t = $t -replace '&lt;','<' -replace '&gt;','>' -replace '&amp;','&'
  return $t
}
function Detect-Tokens([string]$text){
  $reDouble = '<<\s*([A-Za-z0-9_]+)\s*>>'
  $reBrace  = '\{\{\s*([A-Za-z0-9_\-]+)\s*\}\}'
  $d = [ordered]@{}
  $d.double = ([regex]::Matches($text, $reDouble) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique
  $d.brace  = ([regex]::Matches($text, $reBrace)  | ForEach-Object { $_.Groups[1].Value.ToLower() }) | Select-Object -Unique
  return [pscustomobject]$d
}
function Dump-Sample([string]$label, [string]$text, [int]$n){
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
  if(-not (Test-Path -LiteralPath $samplesDir)){ New-Item -ItemType Directory -Path $samplesDir -Force | Out-Null }
  $file = Join-Path $samplesDir ("{0}-{1}-{2}.txt" -f ($label -replace '[^\w\-]','_'), $stage, $CorrelationId)
  $snippet = $text.Substring(0, [Math]::Min($n, $text.Length))
  Set-Content -LiteralPath $file -Value $snippet
  Write-Diag "Saved sample: $file"
}

# -----------------------------------------------------------------------------
# Token replacement (DOUBLE + BRACE) — reusable for ALL templates
# -----------------------------------------------------------------------------
function Replace-Tokens(
  [string] $Text,
  [pscustomobject] $InputObj,
  [hashtable] $BraceTokens,
  [pscustomobject] $Mapping,
  [bool] $AllowMissing
){
  # Normalize, canonicalize encoded <<TOKEN>>
  $Text = Normalize-EncodedText $Text
  $Text = [regex]::Replace($Text, '<<\s*([A-Za-z0-9_]+)\s*>>', { '<<' + $args[0].Groups[1].Value.ToUpper() + '>>' })
  $Text = [regex]::Replace($Text, '\\u003c\\u003c\s*([A-Za-z0-9_]+)\s*\\u003e\\u003e', { '<<' + $args[0].Groups[1].Value.ToUpper() + '>>' })

  # Discover DOUBLE + BRACE
  $reDouble = '<<\s*([A-Za-z0-9_]+)\s*>>'
  $reBrace  = '\{\{\s*([A-Za-z0-9_\-]+)\s*\}\}'
  $presentDouble = ([regex]::Matches($Text, $reDouble) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique

  if($Diagnostics.IsPresent){
    Write-Diag ("Replace-Tokens: present double-angle = " + ($presentDouble -join ', '))
    $presentBrace = ([regex]::Matches($Text, $reBrace) | ForEach-Object { $_.Groups[1].Value.ToLower() }) | Select-Object -Unique
    Write-Diag ("Replace-Tokens: present brace       = " + ($presentBrace -join ', '))
  }

  # Resolve & replace DOUBLE deterministically
  function Resolve-AngleValue([string]$NAME, [pscustomobject]$InputObj, [pscustomobject]$Mapping){
    if($InputObj.PSObject.Properties.Name -contains $NAME){ return [string]$InputObj.$NAME }
    if($Mapping -and ($Mapping.PSObject.Properties.Name -contains 'angleAliases')){
      if($Mapping.angleAliases.PSObject.Properties.Name -contains $NAME){
        $key = [string]$Mapping.angleAliases.$NAME
        if($InputObj.PSObject.Properties.Name -contains $key){ return [string]$InputObj.$key }
      }
    }
    return $null
  }

  $missingDouble = @()
  foreach($NAME in $presentDouble){
    $val = Resolve-AngleValue $NAME $InputObj $Mapping
    if([string]::IsNullOrWhiteSpace($val)){
      $missingDouble += $NAME
      continue
    }
    $Text = $Text.Replace("<<$NAME>>", $val)
    $Text = [regex]::Replace($Text, ("<<\s*{0}\s*>>" -f [regex]::Escape($NAME)), [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $val })
    if($Diagnostics.IsPresent){ Write-Diag ("ANGLE: {0} -> '{1}'" -f $NAME, $val) }
  }

  # Brace tokens
  foreach($k in $BraceTokens.Keys){
    $pattern = '(?i)\{\{\s*' + [regex]::Escape($k) + '\s*\}\}'
    $Text = [regex]::Replace($Text, $pattern, [string]$BraceTokens[$k])
    if($Diagnostics.IsPresent){ Write-Diag ("BRACE: {0} -> '{1}'" -f $k, $BraceTokens[$k]) }
  }

  # Final unresolved check (DOUBLE + BRACE only)
  $unresolved = @()
  $unresolved += ([regex]::Matches($Text, $reDouble) | ForEach-Object { $_.Value })
  $unresolved += ([regex]::Matches($Text, $reBrace)  | ForEach-Object { $_.Value })
  $unresolved = $unresolved | Select-Object -Unique

  if( ($unresolved.Count -gt 0) -and (-not $AllowMissing) ){
    if($Diagnostics.IsPresent -and $missingDouble.Count -gt 0){
      Write-Diag ("Unresolved DOUBLE-ANGLE tokens (no value found): " + ($missingDouble -join ', '))
    }
    throw ("Unresolved placeholders remain in template content: " + ($unresolved -join ', '))
  }
  return $Text
}

# -----------------------------------------------------------------------------
# Template resolution (mapping + robust fallbacks incl. case-insensitive scan)
# -----------------------------------------------------------------------------
function Find-CaseInsensitiveFile([string]$root, [string]$regex){
  # Returns first match by regex (case-insensitive) or $null
  $ciRegex = [regex]"(?i)$regex"
  foreach($item in Get-ChildItem -LiteralPath $root -Recurse -File){
    if($ciRegex.IsMatch($item.FullName)){ return $item.FullName }
  }
  return $null
}

function Tpl([string]$logical){
  $mappingObj = $script:mappingObj

  # 1) If mapping has a path, use it (try API_NAME replaced, then literal)
  if($mappingObj.templates.PSObject.Properties.Name -contains $logical){
    $rel = [string]$mappingObj.templates.$logical
    $relReplaced = $rel -replace 'API_NAME',$script:apiName
    $fullReplaced= Join-Path $TemplatesRoot $relReplaced
    $fullLiteral = Join-Path $TemplatesRoot $rel
    if(Test-Path -LiteralPath $fullReplaced){ return $fullReplaced }
    elseif(Test-Path -LiteralPath $fullLiteral){ return $fullLiteral }
  }

  # 2) Fallbacks for named values with both casing styles and a CI scan
  switch ($logical) {

    'namedValueBackendInformation.json' {
      # Common/expected path
      $p1 = Join-Path $TemplatesRoot ("namedValues/{0}-backend-scopeid/namedValueInformation.json" -f $script:apiName)
      if(Test-Path $p1){ return $p1 }

      # Case-insensitive scan: any .../namedValues/*backend-scopeid*/namedValueInformation.json
      $scan = Find-CaseInsensitiveFile -root $TemplatesRoot -regex 'namedValues[\\/].*backend\-scopeid[\\/].*namedValueInformation\.json$'
      if($scan){ return $scan }
    }

    'namedValueFrontendInformation.json' {
      # Two common folder casings:
      $p2a = Join-Path $TemplatesRoot "namedValues/consuming-frontend-clientid/namedValueInformation.json"
      $p2b = Join-Path $TemplatesRoot "namedValues/CONSUMING-frontend-clientid/namedValueInformation.json"
      if(Test-Path $p2a){ return $p2a }
      if(Test-Path $p2b){ return $p2b }

      # Case-insensitive scan: any .../namedValues/*frontend-clientid*/namedValueInformation.json
      $scan = Find-CaseInsensitiveFile -root $TemplatesRoot -regex 'namedValues[\\/].*frontend\-clientid[\\/].*namedValueInformation\.json$'
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
  Write-Err "Failed to resolve/load paths: $($_.Exception.Message)"; exit 3
}
$valErrors = Validate-AgainstSchema $inputObj $schemaObj
if($valErrors.Count -gt 0){
  foreach($e in $valErrors){ Write-Err $e }
  Write-Err "JSON validation errors encountered."; exit 1
}

# -----------------------------------------------------------------------------
# Resolve environment overlay
# -----------------------------------------------------------------------------
$effective = @{}
foreach($p in $inputObj.PSObject.Properties){ if($p.Name -ne 'environments'){ $effective[$p.Name] = $p.Value } }
if($Environment -and $inputObj.PSObject.Properties.Name -contains 'environments'){
  $envKey = $Environment.ToLower()
  $envObj = $inputObj.environments.$envKey
  if($envObj){ foreach($p in $envObj.PSObject.Properties){ $effective[$p.Name] = $p.Value } }
  else { Write-Warn "Environment '$Environment' not found; using base values." }
}
$effectiveObj = [pscustomobject]$effective
if(-not ($effectiveObj.PSObject.Properties.Name -contains 'API_NAME')){ Write-Err "API_NAME missing"; exit 1 }
$script:apiName = [string]$effectiveObj.API_NAME
Write-Diag "Effective keys: $([string]::Join(', ', ( $effectiveObj.PSObject.Properties.Name | Sort-Object )))"

# -----------------------------------------------------------------------------
# Brace token bag (policy + JSON/YAML templates)
# -----------------------------------------------------------------------------
$tokens = @{}
if($effectiveObj.PSObject.Properties.Name -contains 'TENANT_ID')                         { $tokens['tenant_id']          = [string]$effectiveObj.TENANT_ID }
if($effectiveObj.PSObject.Properties.Name -contains 'API_BACKEND_SCOPEID_VALUE')         { $tokens['backend_scopeid']    = [string]$effectiveObj.API_BACKEND_SCOPEID_VALUE }
if($effectiveObj.PSObject.Properties.Name -contains 'CONSUMING_FRONTEND_CLIENTID_VALUE') { $tokens['frontend_clientid']  = [string]$effectiveObj.CONSUMING_FRONTEND_CLIENTID_VALUE }
if($effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_CALLS')                  { $tokens['rate_limit_calls']   = [string]$effectiveObj.RATE_LIMIT_CALLS }
if($effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_PERIOD')                 { $tokens['rate_limit_period']  = [string]$effectiveObj.RATE_LIMIT_PERIOD }
foreach($k in @('API_NAME','API_VERSION','API_DISPLAY_NAME','API_DESCRIPTION','API_BACKEND_URL')){
  if($effectiveObj.PSObject.Properties.Name -contains $k){ $tokens[$k.ToLower()] = [string]$effectiveObj.$k }
}
Write-Diag ("Brace token keys available: {0}" -f ([string]::Join(', ', ( $tokens.Keys | Sort-Object ))))

# -----------------------------------------------------------------------------
# Step 1 — Materialize template folders (rename API_NAME → <api>) incl. nested dirs
# -----------------------------------------------------------------------------
if($MaterializeTemplateFolders.IsPresent){
  Write-Info "Materializing template folders (API_NAME -> '$script:apiName') under $TemplatesRoot"

  # 1) Known top-level segments from mapping
  foreach ($tplProp in $mappingObj.templates.PSObject.Properties) {
    $rel = [string]$tplProp.Value
    if ($rel -match 'API_NAME') {
      $src = Join-Path $TemplatesRoot (Split-Path $rel -Parent) # e.g., products/API_NAME_product
      $dst = Join-Path $TemplatesRoot (Split-Path ($rel -replace 'API_NAME', $script:apiName) -Parent)
      if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
        if ($CopyInsteadOfRename.IsPresent) {
          Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
          Write-Info "Copied '$src' -> '$dst'"
        } else {
          Move-Item -LiteralPath $src -Destination $dst -Force
          Write-Info "Renamed '$src' -> '$dst'"
        }
      } else {
        Write-Diag "Materialize (mapping) skip: src? $(Test-Path $src) ; dst? $(Test-Path $dst)"
      }
    }
  }

  # 2) Deep scan: rename ANY directory that contains 'API_NAME' (nested)
  $dirs = Get-ChildItem -LiteralPath $TemplatesRoot -Directory -Recurse `
          | Where-Object { $_.Name -like '*API_NAME*' } `
          | Sort-Object FullName -Descending  # deeper nodes first
  foreach($d in $dirs){
    $newName = $d.Name -replace 'API_NAME', $script:apiName
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
  Write-Diag "$label tokens (pre): << >> = $($pre.double.Count), {{ }} = $($pre.brace.Count)"
  if($pre.double.Count -gt 0){ Write-Diag "$label tokens (pre, double): $([string]::Join(', ', ($pre.double)))" }

  $text = Replace-Tokens -Text $norm -InputObj $effectiveObj -BraceTokens $tokens -Mapping $mappingObj -AllowMissing ([bool]$AllowMissing)

  # Parse and patch via mapping JSONPaths (authoritative)
  try{
    $obj = $text | ConvertFrom-Json
  } catch {
    throw "Template '$tpl' could not be parsed as JSON after token replacement. Error: $($_.Exception.Message)"
  }

  foreach($f in $mappingObj.fields){
    foreach($u in $f.usage){
      if(($u.target -eq 'file') -and ($u.file -eq $logical) -and $u.jsonPath){
        $key  = $f.inputKey; $path = $u.jsonPath
        if($effectiveObj.PSObject.Properties.Name -contains $key){
          Set-JsonPathValue -obj $obj -jsonPath $path -value $effectiveObj.$key
        } elseif($f.mandatory -and (-not $AllowMissing.IsPresent)){
          Write-Warn ("{0}: missing mandatory '{1}' for {2}" -f $label, $key, $path)
          $script:SubError = $true
        }
      }
    }
  }

  Backup-IfExists $tpl | Out-Null
  Save-Json $obj $tpl

  $postText = (Get-Content -LiteralPath $tpl -Raw)
  $post = Detect-Tokens $postText
  Write-Diag "$label tokens (post): << >> = $($post.double.Count), {{ }} = $($post.brace.Count)"
  if(($post.double.Count + $post.brace.Count) -gt 0){ Write-Diag "$label unresolved (post): $([string]::Join(', ', ($post.double + $post.brace)))" }
}

function Process-TextTemplate([string]$logical, [string]$label){
  $tpl = Tpl $logical
  Write-Diag "$label path: $tpl"

  $raw = Get-Content -LiteralPath $tpl -Raw
  Dump-Sample "$label raw" $raw $DiagDumpChars; Save-SampleFile $label "raw" $raw $DiagDumpChars

  $norm = Normalize-EncodedText $raw
  Dump-Sample "$label normalized" $norm $DiagDumpChars; Save-SampleFile $label "normalized" $norm $DiagDumpChars

  $pre = Detect-Tokens $norm
  Write-Diag "$label tokens (pre): << >> = $($pre.double.Count), {{ }} = $($pre.brace.Count)"

  $text = Replace-Tokens -Text $norm -InputObj $effectiveObj -BraceTokens $tokens -Mapping $mappingObj -AllowMissing ([bool]$AllowMissing)

  Dump-Sample "$label replaced" $text $DiagDumpChars; Save-SampleFile $label "replaced" $text $DiagDumpChars

  Backup-IfExists $tpl | Out-Null
  Save-Text $text $tpl

  $post = Detect-Tokens $text
  Write-Diag "$label tokens (post): << >> = $($post.double.Count), {{ }} = $($post.brace.Count)"
  if(($post.double.Count + $post.brace.Count) -gt 0){ Write-Diag "$label unresolved (post): $([string]::Join(', ', ($post.double + $post.brace)))" }
}

# -----------------------------------------------------------------------------
# Step 2 — Process files IN‑PLACE
# -----------------------------------------------------------------------------
try{
  # JSON templates
  Process-JsonTemplate -logical 'apiInformation.json'         -label 'apiInformation.json'
  Process-JsonTemplate -logical 'productInformation.json'     -label 'productInformation.json'
  Process-JsonTemplate -logical 'versionSetInformation.json'  -label 'versionSetInformation.json'

  # named values (backend & frontend)
  Process-JsonTemplate -logical 'namedValueBackendInformation.json'  -label 'namedValues.backend.namedValueInformation.json'
  Process-JsonTemplate -logical 'namedValueFrontendInformation.json' -label 'namedValues.frontend.namedValueInformation.json'

  # policy.xml (DOUBLE + BRACE)
  Process-TextTemplate -logical 'policy.xml' -label 'policy.xml'

  # specification.yaml
  if($SpecPath){
    $SpecPath = Resolve-PathSafe $SpecPath
    $tplSpec = Tpl 'specification.yaml'
    $specText = Get-Content -LiteralPath $SpecPath -Raw
    $normSpec = Normalize-EncodedText $specText
    $repSpec  = Replace-Tokens -Text $normSpec -InputObj $effectiveObj -BraceTokens $tokens -Mapping $mappingObj -AllowMissing ([bool]$AllowMissing)
    Backup-IfExists $tplSpec | Out-Null
    Save-Text $repSpec $tplSpec
    Write-Info "specification.yaml updated in-place from external spec"
  } else {
    Process-TextTemplate -logical 'specification.yaml' -label 'specification.yaml'
  }
} catch {
  Write-Err "Processing failure: $($_.Exception.Message)"; $ExitCodeFS = 3
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
  ($audit | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $reportJson

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
  Set-Content -LiteralPath $reportMd -Value $md

  $html = "<!DOCTYPE html><html lang=""en""><head><meta charset=""utf-8"" /><title>APIM Self-Serve In-Place Mapping</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;line-height:1.5}pre{white-space:pre-wrap}</style></head><body><h1>APIM Self-Serve In-Place Mapping</h1><pre>$md</pre></body></html>"
  Set-Content -LiteralPath $reportHtml -Value $html

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
if($SubError){ Write-Err "Substitution errors encountered. Exit code = 2"; exit 2 }

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
