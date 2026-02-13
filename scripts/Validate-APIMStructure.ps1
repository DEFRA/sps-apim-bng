
param(
    [string]$RootPath = ".",
    [ValidateSet('external', 'internal', 'both')] [string]$Journey = 'both',
    [ValidateSet('base', 'dev', 'pre', 'tst', 'all')] [string]$Environment = 'all',
    [string]$ApiName = 'bngicc',
    [string]$ProductName = 'bngicc-product',
    [string]$VersionSetName = 'bngicc',
    [string[]]$NamedValueName = @('bngicc-backend-scopeid', 'CONSUMING-frontend-clientid'),
    [switch]$FailOnError,
    [switch]$EnforceUpperSnakeCaseDisplayName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-File {
    param([string]$Dir, [string[]]$Candidates)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    $entries = Get-ChildItem -LiteralPath $Dir -File -Force
    foreach ($cand in $Candidates) {
        $hit = $entries | Where-Object { $_.Name -ieq $cand } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# apiInformation.json strict validator
function Test-ApiInformationFields {
    param($filePath)
    try {
        $json = Get-Content $filePath -Raw | ConvertFrom-Json
        $props = $json.properties
        if (-not $props) { return "Missing 'properties' object in ${filePath}" }

        $mandatoryFields = @('path','apiVersion','apiVersionSetId','isCurrent','displayName','protocols','serviceUrl','subscriptionRequired')
        foreach ($field in $mandatoryFields) {
            if (-not ($props.PSObject.Properties.Name -icontains $field)) {
                return "Missing mandatory field '$field' in ${filePath}"
            }
            $val = $props.$field
            switch ($field) {
                'protocols' {
                    if (-not $val -or $val.Count -eq 0) {
                        return "Mandatory field '$field' is empty or missing in ${filePath}"
                    }
                }
                { $_ -in @('isCurrent','subscriptionRequired') } {
                    if ($null -eq $val) {
                        return "Mandatory field '$field' is missing in ${filePath}"
                    }
                }
                default {
                    if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                        return "Mandatory field '$field' is empty in ${filePath}"
                    }
                }
            }
        }
    }
    catch { return "Invalid JSON format in ${filePath}" }
    return $null
}

# productInformation.json strict validator
function Test-ProductInformationFields {
    param($filePath)
    try {
        $json = Get-Content $filePath -Raw | ConvertFrom-Json
        $props = $json.properties
        if (-not $props) { return "Missing 'properties' object in ${filePath}" }

        $mandatoryFields = @('displayName','state')
        foreach ($field in $mandatoryFields) {
            if (-not ($props.PSObject.Properties.Name -icontains $field)) {
                return "Missing mandatory field '$field' in ${filePath}"
            }
            $val = $props.$field
            if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                return "Mandatory field '$field' is empty in ${filePath}"
            }
        }
    }
    catch { return "Invalid JSON format in ${filePath}" }
    return $null
}

# versionSetInformation.json strict validator
function Test-VersionSetInformationFields {
    param($filePath)
    try {
        $json = Get-Content $filePath -Raw | ConvertFrom-Json
        $props = $json.properties
        if (-not $props) { return "Missing 'properties' object in ${filePath}" }

        $mandatoryFields = @('displayName','versioningScheme')
        foreach ($field in $mandatoryFields) {
            if (-not ($props.PSObject.Properties.Name -icontains $field)) {
                return "Missing mandatory field '$field' in ${filePath}"
            }
            $val = $props.$field
            if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                return "Mandatory field '$field' is empty in ${filePath}"
            }
        }
    }
    catch { return "Invalid JSON format in ${filePath}" }
    return $null
}

# namedValueInformation.json strict validator
function Test-NamedValueFields {
    param($filePath)
    try {
        $json = Get-Content $filePath -Raw | ConvertFrom-Json
        $props = $json.properties
        if (-not $props) { return "Missing 'properties' object in ${filePath}" }

        $mandatoryFields = @('displayName','secret','tags','value')
        foreach ($field in $mandatoryFields) {
            if (-not ($props.PSObject.Properties.Name -icontains $field)) {
                return "Missing mandatory field '$field' in ${filePath}"
            }
            $val = $props.$field
            if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                return "Mandatory field '$field' is empty in ${filePath}"
            }
        }

        if ($EnforceUpperSnakeCaseDisplayName) {
            if (-not ($props.displayName -cmatch '^[A-Z0-9_]+$')) {
                return "Invalid displayName '${props.displayName}' in ${filePath}: Must match UPPER_SNAKE_CASE"
            }
        }
    }
    catch { return "Invalid JSON format in ${filePath}" }
    return $null
}

# YAML validator
function Test-YamlOpenAPI {
    param($filePath)
    try {
        $content = Get-Content $filePath -Raw
        if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
        if (-not [regex]::IsMatch($content,'(?im)^\s*(openapi|swagger)\s*:\s*["'']?\d')) {
            return "Missing OpenAPI/Swagger version in ${filePath}"
        }
        if (-not [regex]::IsMatch($content,'(?im)^\s*info\s*:')) { return "Missing 'info' section in ${filePath}" }
        if (-not [regex]::IsMatch($content,'(?im)^\s*paths\s*:')) { return "Missing 'paths' section in ${filePath}" }
    }
    catch { return "Invalid YAML format in ${filePath}" }
    return $null
}

function Test-EmptyJsonFile {
    param($filePath)
    try {
        $raw = (Get-Content $filePath -Raw).Trim()
        if ($raw -eq '{}') { return $null }
        $obj = $raw | ConvertFrom-Json
        if ($obj -is [hashtable] -and $obj.Keys.Count -eq 0) { return $null }
        return "File '$filePath' must be an empty JSON object ({})."
    }
    catch { return "Invalid JSON in '$filePath': $_" }
}

# --------------------------------------------------------------------------
# EXPECTATIONS
# --------------------------------------------------------------------------

$JourneyList = if ($Journey -eq 'both') { @('external','internal') } else { @($Journey) }
$EnvList = if ($Environment -eq 'all') { @('base','dev','pre','tst') } else { @($Environment) }

$Expectations = @(
    @{ Name = "apis/*"
       RelDir = { param($j,$e,$n) Join-Path (Join-Path (Join-Path $j $e) "apis") $n }
       Required = @( @('apiInformation.json','apinformation.json'),
                     @('Specification.yaml','specification.yaml','specification.yml'),
                     @('Policy.xml','policy.xml') )
       Validators = @{
         'apiInformation.json
apinformation.json' = { param($p) Test-ApiInformationFields $p }
         'Specification.yaml
specification.yaml
specification.yml' = { param($p) Test-YamlOpenAPI $p }
         'Policy.xml
policy.xml' = {
             param($p)
             $content = Get-Content $p -Raw

             if ($content -notmatch '<policies>') { 
                 return "Missing <policies> root element in ${p}" 
             }
             if ($content -notmatch '<inbound>')  { 
                 return "Missing <inbound> section in ${p}" 
             }
             return $null
         }
       }
    },

    @{ Name = "products/*"
       RelDir = { param($j,$e,$n) Join-Path (Join-Path (Join-Path $j $e) "products") $n }
       Required = @( @('productInformation.json') )
       Validators = @{ 'productInformation.json' = { param($p) Test-ProductInformationFields $p } }
    },

    @{ Name = "products/*/apis/$ApiName"
       RelDir = { param($j,$e,$n)
           Join-Path (Join-Path (Join-Path (Join-Path $j $e) "products") $n) (Join-Path 'apis' $ApiName)
       }
       Required = @( @('productApiInformation.json') )
       Validators = @{ 'productApiInformation.json' = { param($p) Test-EmptyJsonFile $p } }
    },

    @{ Name = "version sets/*"
       RelDir = { param($j,$e,$n) Join-Path (Join-Path (Join-Path $j $e) "version sets") $n }
       Required = @( @('versionSetInformation.json') )
       Validators = @{ 'versionSetInformation.json' = { param($p) Test-VersionSetInformationFields $p } }
    },

    @{ Name = "namedValues/*"
       RelDir = { param($j,$e,$n) Join-Path (Join-Path (Join-Path $j $e) "namedValues") $n }
       Required = @( @('namedValueInformation.json') )
       Validators = @{ 'namedValueInformation.json' = { param($p) Test-NamedValueFields $p } }
    }
)

# --------------------------------------------------------------------------
# RUN VALIDATION
# --------------------------------------------------------------------------

$Errors = @()
$SummaryLines = @()

foreach ($journey in $JourneyList) {
    foreach ($env in $EnvList) {

        $envPath = Join-Path $RootPath (Join-Path $journey $env)
        if (-not (Test-Path $envPath)) {
            $Errors += "Missing environment folder: ${envPath}"
            $SummaryLines += "$journey | $env | (folder) | FAIL Missing environment folder"
            continue
        }

        foreach ($exp in $Expectations) {

            $targetNames = if ($exp.Name -like 'apis/*') {
                @($ApiName)
            }
            elseif ($exp.Name -like 'products/*/apis/*') {
                @($ProductName)
            }
            elseif ($exp.Name -like 'products/*') {
                @($ProductName)
            }
            elseif ($exp.Name -like 'version sets/*') {
                @($VersionSetName)
            }
            elseif ($exp.Name -like 'namedValues/*') {
                $NamedValueName
            }
            else {
                @($NamedValueName)
            }

            foreach ($target in $targetNames) {

                $dir = & $exp.RelDir $journey $env $target

                if (-not (Test-Path $dir)) {
                    $Errors += "Missing folder: ${dir}"
                    $SummaryLines += "$journey | $env | $($exp.Name) | FAIL Missing folder ($target)"
                    continue
                }

                foreach ($group in $exp.Required) {
                    $resolved = Resolve-File -Dir $dir -Candidates $group

                    if (-not $resolved) {
                        $Errors += "Missing file in '${dir}': one of [$($group -join ', ')]"
                        $SummaryLines += "$journey | $env | $($exp.Name) | FAIL Missing $($group -join ' / ') ($target)"
                    }
                    else {
                        $leaf = Split-Path $resolved -Leaf
                        $SummaryLines += "$journey | $env | $($exp.Name) | PASS $leaf ($target)"

                        foreach ($key in $exp.Validators.Keys) {
                            $alts = $key -split '\n'
                            foreach ($alt in $alts) {
                                if ($alt.Trim().ToLower() -eq $leaf.ToLower()) {
                                    $r = & $exp.Validators[$key] $resolved
                                    if ($r) {
                                        $Errors += $r
                                        $SummaryLines += "$journey | $env | $($exp.Name) | FAIL $r ($target)"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

# --------------------------------------------------------------------------
# OUTPUT SUMMARY
# --------------------------------------------------------------------------

$EOL = "`r`n"
$header = "## APIM Validation Summary${EOL}Journey | Env | Item | Status${EOL}--- | --- | --- | ---"
$body   = ($SummaryLines -join $EOL)

if ($Errors.Count -gt 0) {
    $status = "FAIL Validation FAILED. $($Errors.Count) issue(s) found."
    $footer = "### Issues:${EOL}" + ($Errors -join $EOL)
    $exit   = 1
}
else {
    $status = "PASS Validation PASSED. All checks successful."
    $footer = ""
    $exit   = 0
}

$full = $header + $EOL + $body + $EOL + $EOL + $status + $EOL + $footer + $EOL
Write-Host "`n--- Summary ---`n$full"

if ($FailOnError -and $exit -ne 0) { exit $exit }
