

<#
APIM Self‑Serve token mapping tool — IN‑PLACE
Updated for current template structure shown in screenshot:
- named values folders remain legacy: API_NAME-backend-scopeid / API_NAME-frontend-clientid
- backends exist under dev/tst/pre with mixed casing and mixed backendInformation filename casing
- supports Tokens: <<TOKEN>> + {{token}} (case-insensitive)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $InputJson,
  [Parameter(Mandatory=$true)] [string] $Schema,
  [Parameter(Mandatory=$true)] [string] $Mapping,
  [Parameter(Mandatory=$true)] [string] $TemplatesRoot,

  [switch] $MaterializeTemplateFolders,
  [switch] $CopyInsteadOfRename,
  [switch] $BackupBeforeWrite,
  [switch] $AllowMissing,

  # Diagnostics
  [switch] $Diagnostics,
  [int]    $DiagDumpChars = 160,
  [switch] $DiagSaveSamples
)

$ErrorActionPreference = 'Stop'
$CorrelationId = [guid]::NewGuid().ToString()
$Timestamp = (Get-Date).ToString('o')

function Resolve-PathSafe([string]$p){
  if(Test-Path -LiteralPath $p){ return (Resolve-Path -LiteralPath $p).Path }
  $alt = Join-Path $PSScriptRoot $p
  if(Test-Path -LiteralPath $alt){ return (Resolve-Path -LiteralPath $alt).Path }
  throw "Path not found: $p"
}

$TemplatesRoot = Resolve-PathSafe $TemplatesRoot
$reportsRoot = $null
$diagLog = $null

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
    $line = "[DIAG] $m"
    Write-Host $line -ForegroundColor DarkGray
    Add-Content -LiteralPath $diagLog -Value ("{0:o} {1}" -f (Get-Date), $line)
  }
}

function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Warning "[WARN] $m" }
function Write-Err ($m){ Write-Error   "[ERROR] $m" }

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
  if(-not (Test-Path -LiteralPath $destDir)){ New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  return $dest
}
function Backup-IfExists([string]$p){
  if(-not $BackupBeforeWrite.IsPresent){ return }
  if(Test-Path -LiteralPath $p){
    $bak = Make-BackupPath $p
    Copy-Item -LiteralPath $p -Destination $bak -Force
    Write-Diag "Backed up '$p' -> '$bak'"
  }
}

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

  # canonicalize <<token>> to uppercase token names
  $Text = [regex]::Replace($Text, '<<\s*([A-Za-z0-9_]+)\s*>>', { param($m) '<<' + $m.Groups[1].Value.ToUpper() + '>>' })

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

  foreach($NAME in $presentAngle){
    $val = Resolve-AngleValue $NAME $InputObj $MappingObj
    if(-not [string]::IsNullOrWhiteSpace($val)){
      $Text = $Text.Replace("<<$NAME>>", $val)
      Write-Diag ("ANGLE: {0} -> '{1}'" -f $NAME, $val)
    }
  }

  foreach($k in $BraceTokens.Keys){
    $pattern = '(?i)\{\{\s*' + [regex]::Escape($k) + '\s*\}\}'
    $Text = [regex]::Replace($Text, $pattern, [string]$BraceTokens[$k])
    Write-Diag ("BRACE: {0} -> '{1}'" -f $k, $BraceTokens[$k])
  }

  if(-not $AllowMissing){
    $unresolved = @()
    $unresolved += ([regex]::Matches($Text, $reAngle) | ForEach-Object { $_.Value })
    $unresolved += ([regex]::Matches($Text, $reBrace) | ForEach-Object { $_.Value })
    $unresolved = $unresolved | Select-Object -Unique
    if($unresolved.Count -gt 0){
      throw ("Unresolved placeholders remain: " + ($unresolved -join ', '))
    }
  }

  return $Text
}

function Find-CaseInsensitiveFile([string]$root, [string]$regex){
  $ciRegex = [regex]"(?i)$regex"
  foreach($item in Get-ChildItem -LiteralPath $root -Recurse -File){
    if($ciRegex.IsMatch($item.FullName)){ return $item.FullName }
  }
  return $null
}

# Replace placeholders in mapping paths
function Apply-TemplatePlaceholders([string]$rel){
  $r = $rel
  $r = [regex]::Replace($r, 'API_NAME', [string]$script:apiName, 'IgnoreCase')
  return $r
}

function Tpl([string]$logical){
  $m = $script:mappingObj

  # 1) primary: mapping path (API_NAME replaced)
  if($m.templates.PSObject.Properties.Name -contains $logical){
    $rel = [string]$m.templates.$logical
    $full = Join-Path $TemplatesRoot (Apply-TemplatePlaceholders $rel)
    if(Test-Path -LiteralPath $full){ return $full }
  }

  # 2) fallbacks for casing mismatches on Linux
  switch($logical){
    'namedValueBackendInformation.json' {
      $scan = Find-CaseInsensitiveFile $TemplatesRoot 'base[\\/]named values[\\/].*backend\-scopeid[\\/].*namedValueInformation\.json$'
      if($scan){ return $scan }
    }
    'namedValueFrontendInformation.json' {
      $scan = Find-CaseInsensitiveFile $TemplatesRoot 'base[\\/]named values[\\/].*frontend\-clientid[\\/].*namedValueInformation\.json$'
      if($scan){ return $scan }
    }
    'backendInformation.base.json' {
      $scan = Find-CaseInsensitiveFile $TemplatesRoot 'base[\\/]backends[\\/].*\-backend[\\/].*backendinformation\.json$'
      if($scan){ return $scan }
    }
    'backendInformation.dev.json' {
      $scan = Find-CaseInsensitiveFile $TemplatesRoot 'dev[\\/]backends[\\/].*\-backend[\\/].*backendinformation\.json$'
      if($scan){ return $scan }
    }
    'backendInformation.tst.json' {
      $scan = Find-CaseInsensitiveFile $TemplatesRoot 'tst[\\/]backends[\\/].*\-backend[\\/].*backendinformation\.json$'
      if($scan){ return $scan }
    }
    'backendInformation.pre.json' {
      $scan = Find-CaseInsensitiveFile $TemplatesRoot 'pre[\\/]backends[\\/].*\-backend[\\/].*backendinformation\.json$'
      if($scan){ return $scan }
    }
  }

  throw "Template '$logical' not found (mapping + CI fallbacks)."
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

  $script:inputObj   = Get-Json $InputJson
  $script:schemaObj  = Get-Json $Schema
  $script:mappingObj = Get-Json $Mapping
} catch {
  Write-Err "Failed to resolve/load paths: $($_.Exception.Message)"
  exit 3
}

$valErrors = Validate-AgainstSchema $script:inputObj $script:schemaObj
if($valErrors.Count -gt 0){
  foreach($e in $valErrors){ Write-Err $e }
  exit 1
}

$script:apiName = [string]$script:inputObj.API_NAME

# -----------------------------------------------------------------------------
# Brace token bag (policy + yaml/xml)
# -----------------------------------------------------------------------------
$tokens = @{}
if($script:inputObj.PSObject.Properties.Name -contains 'TENANT_ID'){ $tokens['tenant_id'] = [string]$script:inputObj.TENANT_ID }
if($script:inputObj.PSObject.Properties.Name -contains 'BACKEND_SCOPEID_KEYNAME'){ $tokens['backend_scopeid'] = [string]$script:inputObj.BACKEND_SCOPEID_KEYNAME }
if($script:inputObj.PSObject.Properties.Name -contains 'FRONTEND_CLIENTID_KEYNAME'){ $tokens['frontend_clientid'] = [string]$script:inputObj.FRONTEND_CLIENTID_KEYNAME }
if($script:inputObj.PSObject.Properties.Name -contains 'RATE_LIMIT_CALLS'){ $tokens['rate_limit_calls'] = [string]$script:inputObj.RATE_LIMIT_CALLS }
if($script:inputObj.PSObject.Properties.Name -contains 'RATE_LIMIT_PERIOD'){ $tokens['rate_limit_period'] = [string]$script:inputObj.RATE_LIMIT_PERIOD }

foreach($k in @('API_NAME','API_VERSION','API_DISPLAY_NAME','API_DESCRIPTION','BASE_BACKEND_URL',
               'BACKEND_SCOPEID_KEYNAME','FRONTEND_CLIENTID_KEYNAME',
               'DEV_BACKEND_URL','TST_BACKEND_URL','PRE_BACKEND_URL')){
  if($script:inputObj.PSObject.Properties.Name -contains $k){
    $tokens[$k.ToLower()] = [string]$script:inputObj.$k
  }
}

# -----------------------------------------------------------------------------
# Step 1 — Materialize folders: rename any directory containing API_NAME (any casing)
# This fixes API_NAME vs API_Name folders on Linux.
# -----------------------------------------------------------------------------
if($MaterializeTemplateFolders.IsPresent){
  Write-Info "Materializing template folders under $TemplatesRoot"

  $dirs = Get-ChildItem -LiteralPath $TemplatesRoot -Directory -Recurse |
          Where-Object { $_.Name -match '(?i)API_NAME' } |
          Sort-Object FullName -Descending

  foreach($d in $dirs){
    $newName = [regex]::Replace($d.Name, 'API_NAME', $script:apiName, 'IgnoreCase')
    if($newName -eq $d.Name){ continue }
    $target = Join-Path $d.Parent.FullName $newName
    if(Test-Path -LiteralPath $target){ continue }

    if($CopyInsteadOfRename.IsPresent){
      Copy-Item -LiteralPath $d.FullName -Destination $target -Recurse -Force
      Write-Info "Copied '$($d.FullName)' -> '$target'"
    } else {
      Rename-Item -LiteralPath $d.FullName -NewName $newName -Force
      Write-Info "Renamed '$($d.FullName)' -> '$target'"
    }
  }
}

# -----------------------------------------------------------------------------
# In-place processors
# -----------------------------------------------------------------------------
function Process-JsonTemplate([string]$logical){
  $tpl = Tpl $logical
  $raw = Get-Content -LiteralPath $tpl -Raw
  $text = Replace-Tokens -Text $raw -InputObj $script:inputObj -BraceTokens $tokens -MappingObj $script:mappingObj -AllowMissing ([bool]$AllowMissing)
  $obj = $text | ConvertFrom-Json

  foreach($f in $script:mappingObj.fields){
    foreach($u in $f.usage){
      if(($u.target -eq 'file') -and ($u.file -eq $logical) -and $u.jsonPath){
        $key = $f.inputKey
        if($script:inputObj.PSObject.Properties.Name -contains $key){
          Set-JsonPathValue -obj $obj -jsonPath $u.jsonPath -value $script:inputObj.$key
        }
      }
    }
  }

  Backup-IfExists $tpl
  Save-Json $obj $tpl
}

function Process-TextTemplate([string]$logical){
  $tpl = Tpl $logical
  $raw = Get-Content -LiteralPath $tpl -Raw
  $text = Replace-Tokens -Text $raw -InputObj $script:inputObj -BraceTokens $tokens -MappingObj $script:mappingObj -AllowMissing ([bool]$AllowMissing)
  Backup-IfExists $tpl
  Save-Text $text $tpl
}

# -----------------------------------------------------------------------------
# Execute
# -----------------------------------------------------------------------------
try{
  Process-JsonTemplate 'apiInformation.json'
  Process-JsonTemplate 'productInformation.json'
  Process-JsonTemplate 'versionSetInformation.json'

  Process-JsonTemplate 'namedValueBackendInformation.json'
  Process-JsonTemplate 'namedValueFrontendInformation.json'

  Process-TextTemplate 'policy.xml'
  Process-TextTemplate 'specification.yaml'

  Process-JsonTemplate 'backendInformation.base.json'
  Process-JsonTemplate 'backendInformation.dev.json'
  Process-JsonTemplate 'backendInformation.tst.json'
  Process-JsonTemplate 'backendInformation.pre.json'

  Write-Host "✅ Completed IN-PLACE." -ForegroundColor Green
  exit 0
} catch {
  Write-Err "Processing failure: $($_.Exception.Message)"
  exit 3
}
