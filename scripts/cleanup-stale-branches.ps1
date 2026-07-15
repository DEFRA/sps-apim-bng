# --- Configuration Flags ---
$DryRun = $true            # Set to $false to execute changes live.
$IgnoreOpenPrs = $true     # Set to $true to protect branches with open PRs.
$StaleDays = 60

$CutoffDate = (Get-Date).AddDays(-$StaleDays)
$CutoffTimestamp = ([DateTimeOffset]$CutoffDate).ToUnixTimeSeconds()

Write-Host "Looking for branches with no activity since: $($CutoffDate.ToString('yyyy-MM-dd'))"
Write-Host "Dry Run mode is: $DryRun"
Write-Host "Ignore branches with open PRs is: $IgnoreOpenPrs"

# Sync remote references
git fetch --prune --all

$staleBranchesFound = @()
$processedCount = 0

$remoteBranches = git branch -r | Where-Object { $_ -notmatch '->' }
foreach ($rb in $remoteBranches) {
    $branchName = $rb.Replace("origin/", "").Trim()

    if ($branchName -eq "master" -or $branchName -eq "develop" -or $branchName -like "stale/*") {
        continue
    }

    if ($IgnoreOpenPrs -eq $true) {
        $prCheck = gh pr list --head $branchName --state open --json number -q '.[].number'
        if (-not [string]::IsNullOrEmpty($prCheck)) {
            Write-Host "Skipping branch '$branchName' because it has an active open PR (#$prCheck)."
            continue
        }
    }

    $lastCommitTimestampStr = git log -1 --format="%at" "origin/$branchName"
    $lastCommitTimestamp = [long]$lastCommitTimestampStr
    $lastCommitDate = [DateTimeOffset]::FromUnixTimeSeconds($lastCommitTimestamp).DateTime.ToString("yyyy-MM-dd")

    if ($lastCommitTimestamp -lt $CutoffTimestamp) {
        $newBranchName = "stale/$branchName"
        $processedCount++
        
        $staleBranchesFound += [PSCustomObject]@{
            OriginalBranch = $branchName
            NewLocation    = $newBranchName
            LastActivity   = $lastCommitDate
        }

        if ($DryRun -eq $true) {
            Write-Host "[DRY RUN]: Would archive stale branch '$branchName' to '$newBranchName'."
        } else {
            Write-Host "Archiving stale branch: $branchName"
            git checkout -b $branchName "origin/$branchName" *>&1
            git push origin "${branchName}:refs/heads/${newBranchName}" *>&1
            git push origin --delete $branchName *>&1
            git checkout --detach *>&1
            git branch -D $branchName *>&1
        }
    }
}

# --- Build Job Summaries and Email Forms ---
$tableRows = ""
if ($processedCount -gt 0) {
    foreach ($b in $staleBranchesFound) {
        $tableRows += "<tr><td style='padding:10px; border:1px solid #ddd;'>$($b.OriginalBranch)</td><td style='padding:10px; border:1px solid #ddd; font-family:monospace;'>$($b.NewLocation)</td><td style='padding:10px; border:1px solid #ddd; text-align:center;'>$($b.LastActivity)</td></tr>"
    }
} else {
    $tableRows = "<tr><td colspan='3' style='padding:15px; border:1px solid #ddd; text-align:center; color:#666;'>No stale branches found meeting criteria this week.</td></tr>"
}

# Write GitHub Actions Steps Board UI
$summaryHeader = @"
# 🧹 Branch Lifecycle Execution Report
* **Total Actioned Branches:** $processedCount
* **Mode:** $(if ($DryRun -eq $true) { 'DRY RUN (Simulated)' } else { 'LIVE (Executed)' })

| Original Branch Name | Archived Space Destination | Last Commit Activity |
| :--- | :--- | :--- |
"@
$summaryHeader | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

if ($processedCount -gt 0) {
    foreach ($b in $staleBranchesFound) {
        "| $($b.OriginalBranch) | $($b.NewLocation) | $($b.LastActivity) |" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
} else {
    "| N/A | No stale branches found | N/A |" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

$headerColor = if ($DryRun -eq $true) { "#007acc" } else { "#5c2d91" }
$badgeText = if ($DryRun -eq $true) { "SIMULATED REPORT (DRY RUN)" } else { "LIVE AUTOMATED CLEANUP" }

$htmlEmail = @"
<div style="font-family: Arial, sans-serif; color: #333; max-width: 700px; margin: 0 auto; border: 1px solid #e0e0e0; padding: 25px; border-radius: 6px; box-shadow: 0 2px 4px rgba(0,0,0,0.05);">
  <h2 style="color: $headerColor; border-bottom: 2px solid $headerColor; padding-bottom: 10px; margin-top: 0;">🧹 Repository Hygiene Report</h2>
  <p style="font-size: 14px; line-height: 1.5;">An automated branch optimization cleanup has completed execution tracking against your repository.</p>
  
  <h3 style="color: #333; margin-bottom: 10px;">📋 Lifecycle Settings Summary</h3>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 25px; font-size: 14px;">
    <tbody>
      <tr>
        <td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; background-color:#f8f9fa; width:40%;">Execution Profile:</td>
        <td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; color: $headerColor;">$badgeText</td>
      </tr>
      <tr>
        <td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; background-color:#f8f9fa;">Inactivity Threshold:</td>
        <td style="padding: 10px; border: 1px solid #ddd;">60 Days Without Commit Events</td>
      </tr>
      <tr>
        <td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; background-color:#f8f9fa;">Protected Branches (SOT):</td>
        <td style="padding: 10px; border: 1px solid #ddd; font-family:monospace; color:#cc241d;">master, develop, stale/*</td>
      </tr>
      <tr>
        <td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; background-color:#f8f9fa;">Total Branches Target:</td>
        <td style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">$processedCount Branch(es)</td>
      </tr>
    </tbody>
  </table>

  <h3 style="color: #333; margin-bottom: 10px;">📦 Branch Relocations</h3>
  <div style="max-height: 400px; overflow-y: auto; border: 1px solid #ddd; margin-bottom: 25px;">
    <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
      <thead>
        <tr style="background-color: #f8f9fa; position: sticky; top: 0; border-bottom: 2px solid #ddd; z-index: 1;">
          <th style="padding: 10px; text-align: left; border: 1px solid #ddd;">Original Source Branch</th>
          <th style="padding: 10px; text-align: left; border: 1px solid #ddd;">Archived Mirror Point</th>
          <th style="padding: 10px; text-align: center; border: 1px solid #ddd; width:25%;">Last Activity Date</th>
        </tr>
      </thead>
      <tbody>
        $tableRows
      </tbody>
    </table>
  </div>

  <div style="background-color: #f9f9f9; padding: 15px; border-left: 4px solid $headerColor; margin: 20px 0; font-size:14px; line-height:1.5;">
    <strong>💡 Code Preservation Policy:</strong><br>
    Zero files or histories have been purged. If you or your team need to restore or continue developing on an archived workspace branch, please reference our step-by-step restoration instructions hosted in the <strong>ADo Wiki Space Documentation</strong>.
  </div>
</div>
"@

$htmlEmail | Out-File -FilePath "$env:RUNNER_TEMP\email_payload.html" -Encoding utf8
