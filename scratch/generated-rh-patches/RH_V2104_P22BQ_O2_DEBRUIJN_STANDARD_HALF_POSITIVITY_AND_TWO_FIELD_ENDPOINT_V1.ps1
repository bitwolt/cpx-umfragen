# RH_V2104_P22BQ_O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_AND_TWO_FIELD_ENDPOINT_V1.ps1
#
# Exact predecessor: successful P22BP FIX2, v2.103 / 1752.
#
# P22BQ proves strict positivity of the standard source, constructs an explicit
# strictly positive second-difference integral for F_standard(1/2), and thereby
# proves that the standard-half entire function is globally nonconstant.  By
# analytic continuation, it is then nonconstant on every nonempty open set and
# in particular satisfies the exact P22AZ local off-axis nonconstancy predicate.
#
# Consequently the P22BP reduced endpoint package loses its final independent
# nonconstancy field: only a certified atom sequence and the locally uniform
# shifted-polynomial tail limit remain.  This patch does not yet construct that
# exhausting sequence or prove the tail limit, so it does not close the
# reference endpoint and does not move the O2 counter from 3 to 2.
#
# Execution architecture: exactly two large Isabelle traversals.
#   1. Isolated RHBQ01 child-session probe before any persistent change.
#   2. One combined updated-workbench build plus transitive-oracle and
#      final-meta-premise audit in a single child-session dependency graph.
#
# Fail-closed: exact v2.103 status/hash checks, post-probe revalidation,
# rollback on every integration/build/audit failure, broad trust scan, and
# quick_and_dirty=false throughout.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function To-CygwinPath {
    param([Parameter(Mandatory=$true)][string]$WindowsPath)
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        return "/cygdrive/" + $Matches[1].ToLowerInvariant() + "/" + ($Matches[2] -replace '\\','/')
    }
    throw "Cannot convert path: $WindowsPath"
}

function Bash-SingleQuote {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    return "'" + ($Text -replace "'", "'\''") + "'"
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path,$Text,$encoding)
}

function Read-SharedUtf8Text {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,$share)
    $reader = [System.IO.StreamReader]::new($stream,[System.Text.Encoding]::UTF8,$true)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Stop-ExactProcessTree {
    param([Parameter(Mandatory=$true)][int]$ProcessId)
    $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
    if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
        try {
            $null = & $taskkill /PID $ProcessId /T /F 2>&1
            if ($LASTEXITCODE -eq 0) { return }
        }
        catch {}
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

function Get-ExactIsabelleWorkers {
    param([Parameter(Mandatory=$true)][string]$IsabelleRoot,[int[]]$ExcludeProcessIds=@())
    $root = [System.IO.Path]::GetFullPath($IsabelleRoot).TrimEnd([char]'\')
    $excluded = @{}
    foreach ($id in @($ExcludeProcessIds)) { $excluded[[int]$id] = $true }
    return @(
        Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
            if ($excluded.ContainsKey([int]$_.ProcessId)) { $false }
            else {
                $name = [string]$_.Name
                $cmd = [string]$_.CommandLine
                $exe = [string]$_.ExecutablePath
                $underRoot = -not [string]::IsNullOrWhiteSpace($exe) -and $exe.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase)
                ($name -match '^java(?:\.exe)?$' -and $cmd -match 'isabelle\.Isabelle_Tool\s+build') -or
                ($name -match '^poly(?:\.exe)?$' -and ($underRoot -or $cmd -match 'Isabelle2025-2')) -or
                ($name -match '^bash(?:\.exe)?$' -and ($underRoot -or $cmd -match 'Isabelle2025-2\\contrib\\cygwin\\bin\\bash\.exe'))
            }
        }
    )
}

function Stop-ExactIsabelleWorkers {
    param([Parameter(Mandatory=$true)][string]$IsabelleRoot,[int[]]$ExcludeProcessIds=@(),[switch]$Quiet)
    $stopped = [System.Collections.Generic.List[int]]::new()
    for ($round=1; $round -le 4; $round++) {
        $workers = @(Get-ExactIsabelleWorkers -IsabelleRoot $IsabelleRoot -ExcludeProcessIds $ExcludeProcessIds)
        if ($workers.Count -eq 0) { break }
        foreach ($worker in @($workers | Sort-Object ProcessId -Descending)) {
            if (-not $Quiet) { Write-Host ("stopping_isabelle_worker=" + $worker.ProcessId + ";round=" + $round) }
            Stop-ExactProcessTree -ProcessId ([int]$worker.ProcessId)
            [void]$stopped.Add([int]$worker.ProcessId)
        }
        Start-Sleep -Milliseconds 750
    }
    return [pscustomobject]@{
        StoppedProcessIds = @($stopped | Select-Object -Unique)
        Remaining = @(Get-ExactIsabelleWorkers -IsabelleRoot $IsabelleRoot -ExcludeProcessIds $ExcludeProcessIds)
    }
}

function Invoke-BashLive {
    param(
        [Parameter(Mandatory=$true)][string]$BashExe,
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$LiveLogPath,
        [Parameter(Mandatory=$true)][string]$Label,
        [ValidateRange(1,86400)][int]$TimeoutSeconds
    )
    $directory = Split-Path -Parent $LiveLogPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Write-Utf8NoBom -Path $LiveLogPath -Text ""
    $runnerPath = [System.IO.Path]::ChangeExtension($LiveLogPath,".runner.sh")
    $runnerCyg = To-CygwinPath $runnerPath
    $logCyg = To-CygwinPath $LiveLogPath
    $runnerText =
        "#!/usr/bin/env bash`n" +
        "set -o pipefail`n" +
        "export PATH=`"/usr/bin:/bin:`$PATH`"`n" +
        "exec > " + (Bash-SingleQuote $logCyg) + " 2>&1 || exit 126`n" +
        "printf '%s\n' '[WRAPPER_STARTED]'`n" +
        $Command + "`n"
    Write-Utf8NoBom -Path $runnerPath -Text $runnerText

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $BashExe
    $psi.Arguments = "--noprofile --norc `"" + $runnerCyg + "`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $started = $false
    $timedOut = $false
    $printed = 0
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("[LIVE_PROCESS_BEGIN] label=" + $Label + " timeout_seconds=" + $TimeoutSeconds)
    Write-Host ("live_log=" + $LiveLogPath)
    try {
        $started = $process.Start()
        if (-not $started) { throw "Process.Start returned false for $Label." }
        while (-not $process.WaitForExit(1000)) {
            $snapshot = Read-SharedUtf8Text -Path $LiveLogPath
            if ($snapshot.Length -lt $printed) { $printed = 0 }
            if ($snapshot.Length -gt $printed) {
                Write-Host -NoNewline $snapshot.Substring($printed)
                $printed = $snapshot.Length
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                Write-Host ("[LIVE_TIMEOUT] label=" + $Label)
                Stop-ExactProcessTree -ProcessId $process.Id
                [void]$process.WaitForExit(10000)
                break
            }
        }
        if (-not $process.HasExited) {
            Stop-ExactProcessTree -ProcessId $process.Id
            [void]$process.WaitForExit(10000)
        }
    }
    finally { $watch.Stop() }
    $text = Read-SharedUtf8Text -Path $LiveLogPath
    if ($text.Length -gt $printed) { Write-Host -NoNewline $text.Substring($printed) }
    $exitCode = if ($timedOut) { 124 } elseif ($process.HasExited) { $process.ExitCode } else { 125 }
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $lines = @($text -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    Write-Host ("[LIVE_PROCESS_END] label=" + $Label + " exit_code=" + $exitCode + " timed_out=" + $timedOut + " elapsed_seconds=" + [int][Math]::Ceiling($watch.Elapsed.TotalSeconds))
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode=$exitCode; Text=$text; Lines=$lines; TimedOut=$timedOut;
        ElapsedSeconds=[int][Math]::Ceiling($watch.Elapsed.TotalSeconds); Log=$LiveLogPath
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TextSha256 {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace("-","") }
    finally { $hasher.Dispose() }
}

function Count-Pattern {
    param([Parameter(Mandatory=$true)][System.IO.FileInfo[]]$Files,[Parameter(Mandatory=$true)][string]$Pattern)
    $count = 0
    foreach ($file in $Files) {
        foreach ($match in @(Select-String -LiteralPath $file.FullName -Pattern $Pattern -AllMatches -CaseSensitive:$false -ErrorAction Stop)) {
            $count += $match.Matches.Count
        }
    }
    return $count
}

function Write-CompactProbeError {
    param([Parameter(Mandatory=$true)][string]$TheoryPath,[string[]]$BuildLines)
    foreach ($line in @($BuildLines | Where-Object { $_ -match 'FAILED|Error|error|Exception|Unfinished|Failed|Undefined|Bad context|Type unification|Outer syntax|At command|goal|subgoal' } | Select-Object -First 40)) {
        Write-Host ("  " + $line)
    }
    $numbers = [System.Collections.Generic.List[int]]::new()
    foreach ($line in $BuildLines) {
        if ($line -match 'line ([0-9]+) of ') {
            $n = [int]$Matches[1]
            if (-not $numbers.Contains($n)) { [void]$numbers.Add($n) }
        }
    }
    if ($numbers.Count -eq 0) { return }
    $source = @(Get-Content -LiteralPath $TheoryPath)
    foreach ($n in $numbers) {
        Write-Host ("--- PROBE_SOURCE line=" + $n + " ---")
        for ($i=[Math]::Max(1,$n-8); $i -le [Math]::Min($source.Count,$n+12); $i++) {
            $marker = if ($i -eq $n) { ">>" } else { "  " }
            Write-Host ("{0} {1,4}: {2}" -f $marker,$i,$source[$i-1])
        }
        Write-Host "--- END_PROBE_SOURCE ---"
    }
}

function Get-P22BQOracleAuditTheoremNames {
    param([Parameter(Mandatory=$true)][string]$TheoryDirectory)
    $files = @(
        Get-ChildItem -LiteralPath $TheoryDirectory -File -Filter "*.thy" |
        Where-Object {
            $_.Name -eq "RH_O4_Unconditional_Analytic_Closure_v2_76.thy" -or
            $_.Name -match '^RH_O2_.*_v2_(7[7-9]|8[0-9]|9[0-9]|10[0-4])\.thy$'
        } |
        Sort-Object Name
    )
    $regex = [regex]'(?m)^\s*(?:lemma|theorem|corollary)\s+(?:\([^\r\n)]*\)\s*)?([A-Za-z][A-Za-z0-9_'']*)(?:\s*\[[^\]\r\n]*\])?\s*:'
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($match in $regex.Matches($text)) {
            $name = [string]$match.Groups[1].Value
            if (-not $names.Contains($name)) { [void]$names.Add($name) }
        }
    }
    foreach ($name in @("O2_remaining_foundation_milestones_v2104_value","status_v2104_never_claims_unconditional_RH")) {
        if (-not $names.Contains($name)) { [void]$names.Add($name) }
    }
    return @($names)
}

$desktop = [Environment]::GetFolderPath("Desktop")
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportOpen = $false
$scriptFailed = $false
$integrationStarted = $false
$committed = $false
$verifiedBase = $false
$mutex = $null
$mutexAcquired = $false
$backupDirectory = $null
$rootPath = $null
$theoryPath = $null
$statusTheoryPath = $null
$statusJsonPath = $null
$script:IsabelleRootForCleanup = $null

try {
    $reportOpen = $true
    Write-Host "===== RH_REPORT_BEGIN ====="
    Write-Host "stage=P22BQ_O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_AND_TWO_FIELD_ENDPOINT"
    Write-Host "patch_revision=STANDARD_HALF_STRICT_POSITIVITY_GLOBAL_NONCONSTANCY_V1"
    Write-Host "runner_repair_only=false"
    Write-Host "mathematical_body_new_for_P22BQ=true"
    Write-Host "required_base_workbench=v2.103"
    Write-Host "required_base_formal_points=1752"
    Write-Host "existing_P22AB_source_nonnegativity_reused=true"
    Write-Host "existing_P22AV_standard_half_entire_reused=true"
    Write-Host "existing_P22BP_unit_shift_endpoint_transfer_reused=true"
    Write-Host "standard_source_strict_positivity_targeted=true"
    Write-Host "standard_half_second_difference_targeted=true"
    Write-Host "standard_half_global_nonconstancy_targeted=true"
    Write-Host "standard_half_local_nonconstancy_targeted=true"
    Write-Host "endpoint_package_reduced_from_three_fields_to_two=true"
    Write-Host "exhausting_atom_sequence_targeted=false"
    Write-Host "tail_limit_targeted=false"
    Write-Host "reference_endpoint_closed_targeted=false"
    Write-Host "probe_before_integration=true"
    Write-Host "combined_full_build_and_oracle_audit=true"
    Write-Host "large_isabelle_traversals_expected=2"
    Write-Host "rollback_on_any_integration_failure=true"
    Write-Host "quick_and_dirty=false"
    Write-Host "expected_main_theory_declarations=23"
    Write-Host "expected_status_theory_declarations=5"
    Write-Host "expected_resulting_formal_points=1780"
    Write-Host "expected_audited_theorem_count=408"
    Write-Host "O2_foundation_milestones_remaining=3"
    Write-Host ("timestamp=" + (Get-Date).ToString("o"))

    $mutex = New-Object System.Threading.Mutex($false,"Global\RH_P22BQ_V2104_WORKBENCH_MUTEX")
    $mutexAcquired = $mutex.WaitOne(0)
    if (-not $mutexAcquired) { throw "Another RH patch/audit process already holds the P22BQ mutex." }

    $workbench = Join-Path $desktop "RH_PROOF_ARCHITECTURE\02_ISABELLE_FORMALIZATION\00_CURRENT_WORKBENCH\RH_UNCONDITIONALIZATION_v1_99_WORKBENCH"
    $isabelleDirectory = Join-Path $desktop "Isabelle2025-2"
    $script:IsabelleRootForCleanup = $isabelleDirectory
    $rootPath = Join-Path $workbench "ROOT"
    $theoryDirectory = Join-Path $workbench "theories"
    $statusDirectory = Join-Path $workbench "status"
    $backupRoot = Join-Path $workbench "patch_backups"
    foreach ($required in @($workbench,$isabelleDirectory,$rootPath,$theoryDirectory,$statusDirectory,$backupRoot)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Required path missing: $required" }
    }

    $preCleanup = Stop-ExactIsabelleWorkers -IsabelleRoot $isabelleDirectory -ExcludeProcessIds @($PID) -Quiet
    Write-Host ""
    Write-Host "[PRESTART_EXACT_ISABELLE_WORKER_CLEANUP]"
    Write-Host ("preexisting_workers_stopped=" + $preCleanup.StoppedProcessIds.Count)
    Write-Host ("remaining_exact_isabelle_workers=" + $preCleanup.Remaining.Count)
    if ($preCleanup.Remaining.Count -ne 0) { throw "Exact Isabelle workers remain before P22BQ." }

    $baseFile = @(
        Get-ChildItem -LiteralPath $statusDirectory -File -Filter "P22BP_O2_DEBRUIJN_EXPLICIT_UNIT_SHIFT_REDUCED_ENDPOINT_PACKAGE_STATUS_*.json" |
        Sort-Object LastWriteTime -Descending
    ) | Select-Object -First 1
    if ($null -eq $baseFile) { throw "No integrated P22BP v2.103 status JSON found." }
    $baseStatusJsonPath = $baseFile.FullName
    $baseStatusJsonRuntimeHash = Get-Sha256 -Path $baseStatusJsonPath
    $baseStatus = Get-Content -LiteralPath $baseStatusJsonPath -Raw | ConvertFrom-Json
    if ([string]$baseStatus.stage -ne "P22BP_O2_DEBRUIJN_EXPLICIT_UNIT_SHIFT_REDUCED_ENDPOINT_PACKAGE") { throw "P22BP status has an unexpected stage." }
    if ([string]$baseStatus.resulting_workbench -ne "v2.103") { throw "P22BP status does not describe v2.103." }
    if ([int]$baseStatus.current_registered_formal_points -ne 1752) { throw "P22BP status does not describe 1752 formal points." }
    if ([int]$baseStatus.main_theory_declarations -ne 14 -or [int]$baseStatus.status_theory_declarations -ne 5) { throw "P22BP declaration counts are unexpected." }
    if ([string]$baseStatus.selected_theory_body_sha256 -ne "8BE40CC30EF2F2930C973BE19A308DA16FBC51290031EC3C77C9E7C2A63CB66E") { throw "P22BP selected body is not the confirmed FIX2 body." }
    foreach ($flag in @(
        "O4_unconditional_bundle_closed",
        "O2_DEBRUIJN_ABSOLUTE_EXPONENTIAL_MOMENT_CLOSED",
        "O2_DEBRUIJN_COMPLEX_ENTIRE_COMPACT_BOUND_CLOSED",
        "O2_DEBRUIJN_MONTEL_SUBSEQUENCE_CLOSED",
        "O2_DEBRUIJN_REAL_AXIS_COMPLEX_POINTWISE_BRIDGE_CLOSED",
        "O2_DEBRUIJN_ALL_MONTEL_LIMITS_IDENTIFIED_CLOSED",
        "O2_DEBRUIJN_LOCALLY_UNIFORM_CONVERGENCE_CLOSED",
        "O2_DEBRUIJN_WEIERSTRASS_STRIP_FACTOR_FOUNDATION_CLOSED",
        "O2_DEBRUIJN_REAL_EVEN_CANONICAL_TRUNCATION_FOUNDATION_CLOSED",
        "O2_DEBRUIJN_EXPLICIT_UNIT_SHIFT_REDUCED_ENDPOINT_PACKAGE_CLOSED",
        "explicit_unit_shift_schedule_constructed",
        "explicit_unit_shift_chain_constructed",
        "unit_shift_contracted_width_zero_proved",
        "zero_width_shifted_standard_zero_polynomial_sequence_constructed",
        "eventual_off_axis_zero_freeness_of_unit_shift_sequence_proved",
        "reduced_package_endpoint_transfer_proved",
        "pnsubstl_oracle_repair_verified"
    )) {
        if (-not [bool]$baseStatus.$flag) { throw "Required P22BP flag is false: $flag" }
    }
    foreach ($flag in @(
        "exhausting_canonical_atom_sequence_constructed",
        "locally_uniform_shifted_polynomial_tail_limit_proved",
        "standard_half_locally_nonconstant_off_axis_proved",
        "reference_endpoint_all_real_closed",
        "reference_endpoint_3_to_2_promotion",
        "O2_reference_endpoint_no_contact_closed",
        "O2_no_escape_compactness_closed",
        "O2_first_contact_closed",
        "unconditional_RH_proved"
    )) {
        if ([bool]$baseStatus.$flag) { throw "P22BP unexpectedly claims closed: $flag" }
    }
    if ([int]$baseStatus.transitive_oracles_after_P22BP -ne 0 -or [int]$baseStatus.audited_theorem_count -ne 390 -or [int]$baseStatus.final_meta_premises -ne 0) { throw "P22BP audit precondition failed." }
    if ([int]$baseStatus.O2_first_contact_foundation_milestones_remaining -ne 3) { throw "P22BP milestone count is not three." }

    $baseTheoryPath = Join-Path $theoryDirectory "RH_O2_DeBruijn_Explicit_Unit_Shift_Reduced_Endpoint_Package_v2_103.thy"
    $baseStatusTheoryPath = Join-Path $theoryDirectory "RH_Unconditional_Status_v2_103.thy"
    $normalizationTheoryPath = Join-Path $theoryDirectory "RH_O2_DeBruijn_Normalization_Foundation_v2_80.thy"
    $expectedRootHash = [string]$baseStatus.hashes.ROOT
    $expectedBaseTheoryHash = [string]$baseStatus.hashes.theory
    $expectedBaseStatusTheoryHash = [string]$baseStatus.hashes.status_theory
    if ((Get-Sha256 -Path $rootPath) -ne $expectedRootHash) { throw "ROOT does not match integrated P22BP status." }
    if ((Get-Sha256 -Path $baseTheoryPath) -ne $expectedBaseTheoryHash) { throw "v2.103 main theory hash mismatch." }
    if ((Get-Sha256 -Path $baseStatusTheoryPath) -ne $expectedBaseStatusTheoryHash) { throw "v2.103 status theory hash mismatch." }

    $oracleFile = @(
        Get-ChildItem -LiteralPath $statusDirectory -File -Filter "PNSUBSTL_ORACLE_FREE_REPAIR_STATUS_*.json" |
        Sort-Object LastWriteTime -Descending
    ) | Select-Object -First 1
    if ($null -eq $oracleFile) { throw "No pnsubstl oracle-repair status found." }
    $oracleRepairStatusPath = $oracleFile.FullName
    $oracleRepairStatusRuntimeHash = Get-Sha256 -Path $oracleRepairStatusPath
    $oracleStatus = Get-Content -LiteralPath $oracleRepairStatusPath -Raw | ConvertFrom-Json
    if ([int]$oracleStatus.transitive_oracles_after_repair -ne 0 -or [int]$oracleStatus.formerly_affected_transitive_oracles_after_repair -ne 0 -or -not [bool]$oracleStatus.broad_source_trust_scan_clean) { throw "Oracle-repair precondition failed." }
    $expectedNormalizationHash = "CE0774D3382EE578BF58D83C938478E5C128D33F67D5A1C4C1B28136247B1188"
    if ((Get-Sha256 -Path $normalizationTheoryPath) -ne $expectedNormalizationHash) { throw "Oracle-free v2.80 normalization hash mismatch." }

    Write-Host ""
    Write-Host "[V2103_ORACLE_FREE_PRECONDITION]"
    Write-Host ("base_status_json=" + $baseStatusJsonPath)
    Write-Host ("base_status_json_runtime_sha256=" + $baseStatusJsonRuntimeHash)
    Write-Host ("oracle_repair_status_json=" + $oracleRepairStatusPath)
    Write-Host "ROOT_match=True"
    Write-Host "v2103_theory_match=True"
    Write-Host "v2103_status_theory_match=True"
    Write-Host "v280_oracle_free_hash_match=True"
    Write-Host "audited_transitive_oracles_before=0"
    $verifiedBase = $true

    $theoryName = "RH_O2_DeBruijn_Standard_Half_Positivity_And_Two_Field_Endpoint_v2_104"
    $statusTheoryName = "RH_Unconditional_Status_v2_104"
    $theoryPath = Join-Path $theoryDirectory ($theoryName + ".thy")
    $statusTheoryPath = Join-Path $theoryDirectory ($statusTheoryName + ".thy")
    if (Test-Path -LiteralPath $theoryPath) { throw "v2.104 main theory already exists." }
    if (Test-Path -LiteralPath $statusTheoryPath) { throw "v2.104 status theory already exists." }

    $theoryBody = @'
text \<open>
  P22BQ closes the nonconstancy field of the P22BP reduced endpoint package.
  The standard source is proved strictly positive, not merely nonnegative.
  A symmetric imaginary-axis second difference of F_standard(1/2) is then the
  complex embedding of a strictly positive real Lebesgue integral.  Hence the
  standard-half entire function is globally nonconstant.  Analytic continuation
  promotes this to nonconstancy on every nonempty open set, yielding exactly the
  P22AZ local off-axis nonconstancy predicate.

  The endpoint interface is therefore reduced to two genuine fields only: a
  certified standard-zero atom sequence and the locally uniform tail limit of
  its explicit unit-shifted polynomials.  This theory does not construct either
  field and does not close the reference endpoint, no escape, first contact, or
  RH.  The O2 administrative counter remains three.
\<close>

definition p22bq_standard_half_density_v2104 :: "real \<Rightarrow> real" where
  "p22bq_standard_half_density_v2104 u =
     exp ((1 / 2::real) * u^2) * p22as_Phi_standard_even_v280 u"

lemma RH_P22BQ_Phi_plus_term_zero_strictly_positive_v2104:
  "0 < Phi_plus_term 0 (abs u)"
proof -
  let ?a = "abs u"
  have a_nonnegative_v2104: "0 \<le> ?a"
    by simp

  have factorization_raw_v2104:
    "Phi_plus_term 0 ?a =
      (pi * (real (Suc 0))^2 * exp (5 * ?a / 2) *
        (2 * pi * (real (Suc 0))^2 * exp (2 * ?a) - 3)) *
      exp (-pi * (real (Suc 0))^2 * exp (2 * ?a))"
    by (rule RH_P22AB_Phi_plus_term_factor_nonnegative_axis_v264[
          OF a_nonnegative_v2104])

  have factorization_v2104:
    "Phi_plus_term 0 ?a =
      (pi * exp (5 * ?a / 2) *
        (2 * pi * exp (2 * ?a) - 3)) *
      exp (-pi * exp (2 * ?a))"
    using factorization_raw_v2104
    by simp

  have exponent_nonnegative_v2104: "0 \<le> 2 * ?a"
    using a_nonnegative_v2104 by linarith

  have exp_two_ge_one_v2104: "1 \<le> exp (2 * ?a)"
  proof -
    have "exp 0 \<le> exp (2 * ?a)"
      by (rule exp_mono[OF exponent_nonnegative_v2104])
    then show ?thesis by simp
  qed

  have pi_nonnegative_v2104: "0 \<le> pi"
    by (rule less_imp_le[OF pi_gt_zero])

  have pi_le_base_v2104: "pi \<le> pi * exp (2 * ?a)"
  proof -
    have "pi * 1 \<le> pi * exp (2 * ?a)"
      by (rule mult_left_mono[
            OF exp_two_ge_one_v2104 pi_nonnegative_v2104])
    then show ?thesis by simp
  qed

  have three_lt_base_v2104: "3 < pi * exp (2 * ?a)"
    by (rule less_le_trans[OF pi_gt3 pi_le_base_v2104])

  have base_positive_v2104: "0 < pi * exp (2 * ?a)"
    by (rule mult_pos[OF pi_gt_zero exp_pos])

  have three_lt_twice_base_v2104:
    "3 < 2 * (pi * exp (2 * ?a))"
    using three_lt_base_v2104 base_positive_v2104
    by linarith

  have bracket_positive_v2104:
    "0 < 2 * pi * exp (2 * ?a) - 3"
    using three_lt_twice_base_v2104
    by (simp add: algebra_simps)

  have leading_positive_v2104:
    "0 < pi * exp (5 * ?a / 2)"
    by (rule mult_pos[OF pi_gt_zero exp_pos])

  have leading_bracket_positive_v2104:
    "0 < pi * exp (5 * ?a / 2) *
      (2 * pi * exp (2 * ?a) - 3)"
    by (rule mult_pos[
          OF leading_positive_v2104 bracket_positive_v2104])

  have full_product_positive_v2104:
    "0 <
      (pi * exp (5 * ?a / 2) *
        (2 * pi * exp (2 * ?a) - 3)) *
      exp (-pi * exp (2 * ?a))"
    by (rule mult_pos[
          OF leading_bracket_positive_v2104 exp_pos])

  show ?thesis
    using factorization_v2104 full_product_positive_v2104
    by simp
qed

theorem RH_P22BQ_Phi_theta_strictly_positive_v2104:
  "0 < Phi_theta u"
proof -
  have summable_v2104:
    "summable (\<lambda>n. Phi_plus_term n (abs u))"
    by (rule RH_P22AB_Phi_plus_term_summable_v264)

  have nonnegative_v2104:
    "\<And>n. 0 \<le> Phi_plus_term n (abs u)"
    by (rule RH_P22AB_Phi_plus_term_nonnegative_v264)
       simp

  have first_positive_v2104:
    "0 < Phi_plus_term 0 (abs u)"
    by (rule RH_P22BQ_Phi_plus_term_zero_strictly_positive_v2104)

  have sum_positive_v2104:
    "0 < suminf (\<lambda>n. Phi_plus_term n (abs u))"
    by (rule suminf_pos2[
          OF summable_v2104 nonnegative_v2104 first_positive_v2104])

  show ?thesis
    unfolding Phi_theta_def Phi_plus_def
    by (rule sum_positive_v2104)
qed

theorem RH_P22BQ_standard_source_strictly_positive_v2104:
  "0 < p22as_Phi_standard_even_v280 u"
proof -
  have source_identity_v2104:
    "p22as_Phi_standard_even_v280 u = Phi_theta (2 * u)"
    by (rule RH_P22AS_standard_source_exact_v280)
  have positive_v2104: "0 < Phi_theta (2 * u)"
    by (rule RH_P22BQ_Phi_theta_strictly_positive_v2104)
  show ?thesis
    using source_identity_v2104 positive_v2104
    by simp
qed

theorem RH_P22BQ_standard_half_density_strictly_positive_v2104:
  "0 < p22bq_standard_half_density_v2104 u"
  unfolding p22bq_standard_half_density_v2104_def
  by (rule mult_pos[
        OF exp_pos RH_P22BQ_standard_source_strictly_positive_v2104])

definition p22bq_symmetric_curvature_factor_v2104 :: "real \<Rightarrow> real" where
  "p22bq_symmetric_curvature_factor_v2104 u =
     exp u + exp (-u) - 2"

lemma RH_P22BQ_symmetric_curvature_factor_square_v2104:
  "p22bq_symmetric_curvature_factor_v2104 u =
    (exp u - 1)^2 / exp u"
  unfolding p22bq_symmetric_curvature_factor_v2104_def
  apply (simp only: exp_minus)
  apply field_simp
  apply algebra
  done

lemma RH_P22BQ_symmetric_curvature_factor_nonnegative_v2104:
  "0 \<le> p22bq_symmetric_curvature_factor_v2104 u"
proof -
  have quotient_nonnegative_v2104:
    "0 \<le> (exp u - 1)^2 / exp u"
    by (rule divide_nonneg[OF sq_nonneg])
       (rule less_imp_le[OF exp_pos])
  show ?thesis
    using RH_P22BQ_symmetric_curvature_factor_square_v2104[
      of u] quotient_nonnegative_v2104
    by simp
qed

lemma RH_P22BQ_symmetric_curvature_factor_positive_v2104:
  assumes u_nonzero_v2104: "u \<noteq> 0"
  shows "0 < p22bq_symmetric_curvature_factor_v2104 u"
proof -
  have exp_ne_one_v2104: "exp u \<noteq> 1"
    using u_nonzero_v2104
    by (simp only: exp_eq_one_iff)

  have difference_nonzero_v2104: "exp u - 1 \<noteq> 0"
    using exp_ne_one_v2104 by simp

  have square_nonzero_v2104: "(exp u - 1)^2 \<noteq> 0"
    using difference_nonzero_v2104 by simp

  have square_positive_v2104: "0 < (exp u - 1)^2"
    using sq_nonneg[of "exp u - 1"] square_nonzero_v2104
    by linarith

  have quotient_positive_v2104:
    "0 < (exp u - 1)^2 / exp u"
    by (rule divide_pos[OF square_positive_v2104 exp_pos])

  show ?thesis
    using RH_P22BQ_symmetric_curvature_factor_square_v2104[
      of u] quotient_positive_v2104
    by simp
qed

definition p22bq_standard_half_curvature_density_v2104 ::
  "real \<Rightarrow> real" where
  "p22bq_standard_half_curvature_density_v2104 u =
     p22bq_standard_half_density_v2104 u *
     p22bq_symmetric_curvature_factor_v2104 u"

theorem RH_P22BQ_standard_half_curvature_density_nonnegative_v2104:
  "0 \<le> p22bq_standard_half_curvature_density_v2104 u"
  unfolding p22bq_standard_half_curvature_density_v2104_def
  by (rule mult_nonneg)
     (rule less_imp_le[
       OF RH_P22BQ_standard_half_density_strictly_positive_v2104])
     (rule RH_P22BQ_symmetric_curvature_factor_nonnegative_v2104)

theorem RH_P22BQ_standard_half_curvature_density_positive_v2104:
  assumes u_nonzero_v2104: "u \<noteq> 0"
  shows "0 < p22bq_standard_half_curvature_density_v2104 u"
  unfolding p22bq_standard_half_curvature_density_v2104_def
  by (rule mult_pos[
        OF RH_P22BQ_standard_half_density_strictly_positive_v2104
           RH_P22BQ_symmetric_curvature_factor_positive_v2104[
             OF u_nonzero_v2104]])

lemma RH_P22BQ_standard_half_integrand_second_difference_v2104:
  "p22as_standard_integrand_v280 (1 / 2) (Complex 0 1) u +
    p22as_standard_integrand_v280 (1 / 2) (-(Complex 0 1)) u -
    p22as_standard_integrand_v280 (1 / 2) 0 u -
    p22as_standard_integrand_v280 (1 / 2) 0 u =
    of_real (p22bq_standard_half_curvature_density_v2104 u)"
proof -
  have positive_exponent_v2104:
    "(Complex 0 1) * (Complex 0 1) * of_real u = of_real (-u)"
    by simp

  have negative_exponent_v2104:
    "(Complex 0 1) * (-(Complex 0 1)) * of_real u = of_real u"
    by simp

  have positive_phase_v2104:
    "exp ((Complex 0 1) * (Complex 0 1) * of_real u) =
      of_real (exp (-u))"
    by (subst positive_exponent_v2104, rule exp_of_real)

  have negative_phase_v2104:
    "exp ((Complex 0 1) * (-(Complex 0 1)) * of_real u) =
      of_real (exp u)"
    by (subst negative_exponent_v2104, rule exp_of_real)

  show ?thesis
    unfolding
      p22as_standard_integrand_v280_def
      p22bq_standard_half_density_v2104_def
      p22bq_standard_half_curvature_density_v2104_def
      p22bq_symmetric_curvature_factor_v2104_def
    using positive_phase_v2104 negative_phase_v2104
    by (simp add: algebra_simps)
qed

theorem RH_P22BQ_standard_half_curvature_density_integrable_v2104:
  "integrable lborel p22bq_standard_half_curvature_density_v2104"
proof -
  let ?fp = "p22as_standard_integrand_v280 (1 / 2) (Complex 0 1)"
  let ?fm = "p22as_standard_integrand_v280 (1 / 2) (-(Complex 0 1))"
  let ?f0 = "p22as_standard_integrand_v280 (1 / 2) 0"

  have fp_integrable_v2104: "set_integrable lborel UNIV ?fp"
    by (rule RH_P22AV_standard_integrand_whole_integrable_v283)
  have fm_integrable_v2104: "set_integrable lborel UNIV ?fm"
    by (rule RH_P22AV_standard_integrand_whole_integrable_v283)
  have f0_integrable_v2104: "set_integrable lborel UNIV ?f0"
    by (rule RH_P22AV_standard_integrand_whole_integrable_v283)

  have sum_integrable_v2104:
    "set_integrable lborel UNIV (\<lambda>u. ?fp u + ?fm u)"
    by (rule set_integral_add(1)[
          OF fp_integrable_v2104 fm_integrable_v2104])

  have first_difference_integrable_v2104:
    "set_integrable lborel UNIV
      (\<lambda>u. ?fp u + ?fm u - ?f0 u)"
    by (rule set_integral_diff(1)[
          OF sum_integrable_v2104 f0_integrable_v2104])

  have second_difference_integrable_v2104:
    "set_integrable lborel UNIV
      (\<lambda>u. ?fp u + ?fm u - ?f0 u - ?f0 u)"
    by (rule set_integral_diff(1)[
          OF first_difference_integrable_v2104 f0_integrable_v2104])

  have embedded_integrable_v2104:
    "set_integrable lborel UNIV
      (\<lambda>u. of_real
        (p22bq_standard_half_curvature_density_v2104 u))"
    using second_difference_integrable_v2104
    by (simp only:
      RH_P22BQ_standard_half_integrand_second_difference_v2104)

  show ?thesis
    using embedded_integrable_v2104
    unfolding set_integrable_def
    by simp
qed

theorem RH_P22BQ_standard_half_curvature_integral_positive_v2104:
  "0 < lebesgue_integral lborel
    p22bq_standard_half_curvature_density_v2104"
proof -
  have integrable_v2104:
    "integrable lborel p22bq_standard_half_curvature_density_v2104"
    by (rule RH_P22BQ_standard_half_curvature_density_integrable_v2104)

  have ae_nonnegative_v2104:
    "AE u in lborel.
      0 \<le> p22bq_standard_half_curvature_density_v2104 u"
    by (rule AE_I2)
       (rule RH_P22BQ_standard_half_curvature_density_nonnegative_v2104)

  have ae_nonzero_argument_v2104:
    "AE u in lborel. u \<noteq> (0::real)"
    by (rule AE_lborel_singleton)

  have ae_positive_v2104:
    "AE u in lborel.
      0 < p22bq_standard_half_curvature_density_v2104 u"
    using ae_nonzero_argument_v2104
  proof eventually_elim
    fix u :: real
    assume u_nonzero_v2104: "u \<noteq> 0"
    show "0 < p22bq_standard_half_curvature_density_v2104 u"
      by (rule RH_P22BQ_standard_half_curvature_density_positive_v2104[
            OF u_nonzero_v2104])
  qed

  have integral_nonnegative_v2104:
    "0 \<le> lebesgue_integral lborel
      p22bq_standard_half_curvature_density_v2104"
    by (rule integral_nonneg_AE[OF ae_nonnegative_v2104])

  have integral_nonzero_v2104:
    "lebesgue_integral lborel
      p22bq_standard_half_curvature_density_v2104 \<noteq> 0"
  proof
    assume integral_zero_v2104:
      "lebesgue_integral lborel
        p22bq_standard_half_curvature_density_v2104 = 0"

    have ae_zero_v2104:
      "AE u in lborel.
        p22bq_standard_half_curvature_density_v2104 u = 0"
      using integral_zero_v2104
        integral_nonneg_eq_0_iff_AE[
          OF integrable_v2104 ae_nonnegative_v2104]
      by blast

    from ae_zero_v2104 ae_positive_v2104
    show False
    proof eventually_elim
      fix u :: real
      assume zero_v2104:
        "p22bq_standard_half_curvature_density_v2104 u = 0"
      assume positive_v2104:
        "0 < p22bq_standard_half_curvature_density_v2104 u"
      show False
        using zero_v2104 positive_v2104 by linarith
    qed
  qed

  show ?thesis
    using integral_nonnegative_v2104 integral_nonzero_v2104
    by linarith
qed

theorem RH_P22BQ_standard_half_second_difference_identity_v2104:
  "p22as_F_standard_v280 (1 / 2) (Complex 0 1) +
    p22as_F_standard_v280 (1 / 2) (-(Complex 0 1)) -
    p22as_F_standard_v280 (1 / 2) 0 -
    p22as_F_standard_v280 (1 / 2) 0 =
    of_real
      (lebesgue_integral lborel
        p22bq_standard_half_curvature_density_v2104)"
proof -
  let ?fp = "p22as_standard_integrand_v280 (1 / 2) (Complex 0 1)"
  let ?fm = "p22as_standard_integrand_v280 (1 / 2) (-(Complex 0 1))"
  let ?f0 = "p22as_standard_integrand_v280 (1 / 2) 0"
  let ?fc = "p22bq_standard_half_curvature_density_v2104"

  have fp_integrable_v2104: "set_integrable lborel UNIV ?fp"
    by (rule RH_P22AV_standard_integrand_whole_integrable_v283)
  have fm_integrable_v2104: "set_integrable lborel UNIV ?fm"
    by (rule RH_P22AV_standard_integrand_whole_integrable_v283)
  have f0_integrable_v2104: "set_integrable lborel UNIV ?f0"
    by (rule RH_P22AV_standard_integrand_whole_integrable_v283)

  have sum_integrable_v2104:
    "set_integrable lborel UNIV (\<lambda>u. ?fp u + ?fm u)"
    by (rule set_integral_add(1)[
          OF fp_integrable_v2104 fm_integrable_v2104])
  have first_integrable_v2104:
    "set_integrable lborel UNIV
      (\<lambda>u. ?fp u + ?fm u - ?f0 u)"
    by (rule set_integral_diff(1)[
          OF sum_integrable_v2104 f0_integrable_v2104])

  have sum_integral_v2104:
    "set_lebesgue_integral lborel UNIV
       (\<lambda>u. ?fp u + ?fm u) =
     set_lebesgue_integral lborel UNIV ?fp +
     set_lebesgue_integral lborel UNIV ?fm"
    by (rule set_integral_add(2)[
          OF fp_integrable_v2104 fm_integrable_v2104])

  have first_integral_v2104:
    "set_lebesgue_integral lborel UNIV
       (\<lambda>u. ?fp u + ?fm u - ?f0 u) =
     (set_lebesgue_integral lborel UNIV ?fp +
      set_lebesgue_integral lborel UNIV ?fm) -
     set_lebesgue_integral lborel UNIV ?f0"
    using set_integral_diff(2)[
      OF sum_integrable_v2104 f0_integrable_v2104]
      sum_integral_v2104
    by simp

  have second_integral_v2104:
    "set_lebesgue_integral lborel UNIV
       (\<lambda>u. ?fp u + ?fm u - ?f0 u - ?f0 u) =
     (set_lebesgue_integral lborel UNIV ?fp +
      set_lebesgue_integral lborel UNIV ?fm) -
     set_lebesgue_integral lborel UNIV ?f0 -
     set_lebesgue_integral lborel UNIV ?f0"
    using set_integral_diff(2)[
      OF first_integrable_v2104 f0_integrable_v2104]
      first_integral_v2104
    by simp

  have standard_expression_v2104:
    "p22as_F_standard_v280 (1 / 2) (Complex 0 1) +
      p22as_F_standard_v280 (1 / 2) (-(Complex 0 1)) -
      p22as_F_standard_v280 (1 / 2) 0 -
      p22as_F_standard_v280 (1 / 2) 0 =
     set_lebesgue_integral lborel UNIV
       (\<lambda>u. ?fp u + ?fm u - ?f0 u - ?f0 u)"
    unfolding p22as_F_standard_v280_def
    using second_integral_v2104
    by (rule sym)

  have pointwise_integral_v2104:
    "set_lebesgue_integral lborel UNIV
       (\<lambda>u. ?fp u + ?fm u - ?f0 u - ?f0 u) =
     set_lebesgue_integral lborel UNIV
       (\<lambda>u. of_real (?fc u))"
  proof (rule set_lebesgue_integral_cong)
    show "UNIV \<in> sets lborel" by simp
    show
      "\<forall>u. u \<in> UNIV \<longrightarrow>
        ?fp u + ?fm u - ?f0 u - ?f0 u = of_real (?fc u)"
      by (intro allI impI)
         (rule RH_P22BQ_standard_half_integrand_second_difference_v2104)
  qed

  have embedded_integral_v2104:
    "set_lebesgue_integral lborel UNIV
       (\<lambda>u. of_real (?fc u)) =
     of_real (set_lebesgue_integral lborel UNIV ?fc)"
    by (rule set_integral_complex_of_real)

  have univ_integral_v2104:
    "set_lebesgue_integral lborel UNIV ?fc =
     lebesgue_integral lborel ?fc"
    unfolding set_lebesgue_integral_def
    by simp

  have embedded_univ_integral_v2104:
    "of_real (set_lebesgue_integral lborel UNIV ?fc) =
     of_real (lebesgue_integral lborel ?fc)"
    by (rule arg_cong[OF univ_integral_v2104])

  show ?thesis
    by (rule trans[OF standard_expression_v2104])
       (rule trans[OF pointwise_integral_v2104])
       (rule trans[OF embedded_integral_v2104])
       (rule embedded_univ_integral_v2104)
qed

theorem RH_P22BQ_standard_half_second_difference_nonzero_v2104:
  "p22as_F_standard_v280 (1 / 2) (Complex 0 1) +
    p22as_F_standard_v280 (1 / 2) (-(Complex 0 1)) -
    p22as_F_standard_v280 (1 / 2) 0 -
    p22as_F_standard_v280 (1 / 2) 0 \<noteq> 0"
proof -
  have integral_positive_v2104:
    "0 < lebesgue_integral lborel
      p22bq_standard_half_curvature_density_v2104"
    by (rule RH_P22BQ_standard_half_curvature_integral_positive_v2104)

  have embedded_nonzero_v2104:
    "of_real
      (lebesgue_integral lborel
        p22bq_standard_half_curvature_density_v2104) \<noteq>
      (0::complex)"
    using integral_positive_v2104 by simp

  show ?thesis
    using RH_P22BQ_standard_half_second_difference_identity_v2104
      embedded_nonzero_v2104
    by simp
qed

theorem RH_P22BQ_standard_half_not_constant_on_UNIV_v2104:
  "\<not> (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)
    constant_on (UNIV :: complex set)"
proof
  assume constant_v2104:
    "(\<lambda>w. p22as_F_standard_v280 (1 / 2) w)
      constant_on (UNIV :: complex set)"

  have positive_i_equals_zero_v2104:
    "p22as_F_standard_v280 (1 / 2) (Complex 0 1) =
     p22as_F_standard_v280 (1 / 2) 0"
    using constant_v2104
    unfolding constant_on_def
    by blast

  have negative_i_equals_zero_v2104:
    "p22as_F_standard_v280 (1 / 2) (-(Complex 0 1)) =
     p22as_F_standard_v280 (1 / 2) 0"
    using constant_v2104
    unfolding constant_on_def
    by blast

  have second_difference_zero_v2104:
    "p22as_F_standard_v280 (1 / 2) (Complex 0 1) +
      p22as_F_standard_v280 (1 / 2) (-(Complex 0 1)) -
      p22as_F_standard_v280 (1 / 2) 0 -
      p22as_F_standard_v280 (1 / 2) 0 = 0"
    using positive_i_equals_zero_v2104 negative_i_equals_zero_v2104
    by simp

  show False
    using second_difference_zero_v2104
      RH_P22BQ_standard_half_second_difference_nonzero_v2104
    by contradiction
qed

theorem RH_P22BQ_standard_half_locally_nonconstant_off_axis_v2104:
  "p22az_locally_nonconstant_off_axis_v287
    (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)"
  unfolding p22az_locally_nonconstant_off_axis_v287_def
proof (intro allI impI)
  fix z0 :: complex
  fix S :: "complex set"
  assume off_axis_v2104: "Im z0 \<noteq> 0"
  assume open_S_v2104: "open S"
  assume connected_S_v2104: "connected S"
  assume z0_in_S_v2104: "z0 \<in> S"

  show
    "\<not> (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)
      constant_on S"
  proof
    assume local_constant_v2104:
      "(\<lambda>w. p22as_F_standard_v280 (1 / 2) w)
        constant_on S"

    have z0_islimpt_S_v2104: "z0 islimpt S"
      using open_S_v2104 z0_in_S_v2104
      by (intro interior_limit_point)
         (auto simp: interior_open)

    have global_constant_v2104:
      "(\<lambda>w. p22as_F_standard_v280 (1 / 2) w)
        constant_on (UNIV :: complex set)"
      by (rule analytic_continuation'[
            OF RH_P22AV_F_standard_half_entire_v283
               open_UNIV connected_UNIV _ _
               z0_islimpt_S_v2104 local_constant_v2104])
         simp_all

    show False
      using global_constant_v2104
        RH_P22BQ_standard_half_not_constant_on_UNIV_v2104
      by contradiction
  qed
qed

definition p22bq_two_field_unit_shift_endpoint_package_v2104 ::
  "(nat \<Rightarrow> p22aw_factor_atom_v284 list) \<Rightarrow> bool" where
  "p22bq_two_field_unit_shift_endpoint_package_v2104 atoms \<longleftrightarrow>
     (\<forall>n atom.
       atom \<in> set (atoms n) \<longrightarrow>
       p22bo_standard_zero_atom_v2102 atom) \<and>
     p22az_locally_uniform_polynomial_tail_limit_v287
       (p22bp_unit_shifted_standard_zero_sequence_v2103 atoms)
       (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)"

theorem RH_P22BQ_two_field_package_imp_P22BP_package_v2104:
  assumes two_field_package_v2104:
    "p22bq_two_field_unit_shift_endpoint_package_v2104 atoms"
  shows
    "p22bp_reduced_unit_shift_endpoint_package_v2103 atoms"
proof -
  have components_v2104:
    "(\<forall>n atom.
       atom \<in> set (atoms n) \<longrightarrow>
       p22bo_standard_zero_atom_v2102 atom) \<and>
     p22az_locally_uniform_polynomial_tail_limit_v287
       (p22bp_unit_shifted_standard_zero_sequence_v2103 atoms)
       (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)"
    using two_field_package_v2104
    unfolding p22bq_two_field_unit_shift_endpoint_package_v2104_def
    by assumption

  have certified_v2104:
    "\<forall>n atom.
      atom \<in> set (atoms n) \<longrightarrow>
      p22bo_standard_zero_atom_v2102 atom"
    by (rule conjunct1[OF components_v2104])

  have tail_limit_v2104:
    "p22az_locally_uniform_polynomial_tail_limit_v287
      (p22bp_unit_shifted_standard_zero_sequence_v2103 atoms)
      (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)"
    by (rule conjunct2[OF components_v2104])

  show ?thesis
    unfolding p22bp_reduced_unit_shift_endpoint_package_v2103_def
  proof (intro conjI)
    show
      "\<forall>n atom.
        atom \<in> set (atoms n) \<longrightarrow>
        p22bo_standard_zero_atom_v2102 atom"
      by (rule certified_v2104)
  next
    show
      "p22az_locally_uniform_polynomial_tail_limit_v287
        (p22bp_unit_shifted_standard_zero_sequence_v2103 atoms)
        (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)"
      by (rule tail_limit_v2104)
  next
    show
      "p22az_locally_nonconstant_off_axis_v287
        (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)"
      by (rule RH_P22BQ_standard_half_locally_nonconstant_off_axis_v2104)
  qed
qed

theorem RH_P22BQ_two_field_package_imp_reference_endpoint_v2104:
  assumes two_field_package_v2104:
    "p22bq_two_field_unit_shift_endpoint_package_v2104 atoms"
  shows
    "reference_no_off_axis_zero_obligation p22av_ref_lambda_v283"
proof -
  have p22bp_package_v2104:
    "p22bp_reduced_unit_shift_endpoint_package_v2103 atoms"
    by (rule RH_P22BQ_two_field_package_imp_P22BP_package_v2104[
          OF two_field_package_v2104])

  show ?thesis
    by (rule RH_P22BP_reduced_package_imp_reference_endpoint_v2103[
          OF p22bp_package_v2104])
qed

definition p22bq_standard_half_positivity_two_field_foundation_v2104 ::
  bool where
  "p22bq_standard_half_positivity_two_field_foundation_v2104 \<longleftrightarrow>
     (\<forall>u::real. 0 < Phi_theta u) \<and>
     0 < lebesgue_integral lborel
       p22bq_standard_half_curvature_density_v2104 \<and>
     \<not> (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)
       constant_on (UNIV :: complex set) \<and>
     p22az_locally_nonconstant_off_axis_v287
       (\<lambda>w. p22as_F_standard_v280 (1 / 2) w) \<and>
     (\<forall>atoms.
       p22bq_two_field_unit_shift_endpoint_package_v2104 atoms
       \<longrightarrow>
       reference_no_off_axis_zero_obligation p22av_ref_lambda_v283)"

theorem RH_P22BQ_standard_half_positivity_two_field_foundation_v2104:
  "p22bq_standard_half_positivity_two_field_foundation_v2104"
  unfolding p22bq_standard_half_positivity_two_field_foundation_v2104_def
proof (intro conjI)
  show "\<forall>u::real. 0 < Phi_theta u"
    by (intro allI)
       (rule RH_P22BQ_Phi_theta_strictly_positive_v2104)
next
  show
    "0 < lebesgue_integral lborel
      p22bq_standard_half_curvature_density_v2104"
    by (rule RH_P22BQ_standard_half_curvature_integral_positive_v2104)
next
  show
    "\<not> (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)
      constant_on (UNIV :: complex set)"
    by (rule RH_P22BQ_standard_half_not_constant_on_UNIV_v2104)
next
  show
    "p22az_locally_nonconstant_off_axis_v287
      (\<lambda>w. p22as_F_standard_v280 (1 / 2) w)"
    by (rule RH_P22BQ_standard_half_locally_nonconstant_off_axis_v2104)
next
  show
    "\<forall>atoms.
      p22bq_two_field_unit_shift_endpoint_package_v2104 atoms
      \<longrightarrow>
      reference_no_off_axis_zero_obligation p22av_ref_lambda_v283"
  proof (intro allI impI)
    fix atoms :: "nat \<Rightarrow> p22aw_factor_atom_v284 list"
    assume package_v2104:
      "p22bq_two_field_unit_shift_endpoint_package_v2104 atoms"
    show "reference_no_off_axis_zero_obligation p22av_ref_lambda_v283"
      by (rule RH_P22BQ_two_field_package_imp_reference_endpoint_v2104[
            OF package_v2104])
  qed
qed
'@

    $declarationPattern = '(?m)^\s*(definition|lemma|theorem|corollary|record|datatype|inductive|fun)\s+'
    $mainDeclarationCount = [regex]::Matches($theoryBody,$declarationPattern).Count
    if ($mainDeclarationCount -ne 23) { throw "Unexpected P22BQ main declaration count: $mainDeclarationCount" }
    foreach ($required in @(
        "definition p22bq_standard_half_density_v2104",
        "lemma RH_P22BQ_Phi_plus_term_zero_strictly_positive_v2104",
        "theorem RH_P22BQ_Phi_theta_strictly_positive_v2104",
        "theorem RH_P22BQ_standard_source_strictly_positive_v2104",
        "theorem RH_P22BQ_standard_half_density_strictly_positive_v2104",
        "definition p22bq_symmetric_curvature_factor_v2104",
        "lemma RH_P22BQ_symmetric_curvature_factor_square_v2104",
        "lemma RH_P22BQ_symmetric_curvature_factor_nonnegative_v2104",
        "lemma RH_P22BQ_symmetric_curvature_factor_positive_v2104",
        "definition p22bq_standard_half_curvature_density_v2104",
        "theorem RH_P22BQ_standard_half_curvature_density_nonnegative_v2104",
        "theorem RH_P22BQ_standard_half_curvature_density_positive_v2104",
        "lemma RH_P22BQ_standard_half_integrand_second_difference_v2104",
        "theorem RH_P22BQ_standard_half_curvature_density_integrable_v2104",
        "theorem RH_P22BQ_standard_half_curvature_integral_positive_v2104",
        "theorem RH_P22BQ_standard_half_second_difference_identity_v2104",
        "theorem RH_P22BQ_standard_half_second_difference_nonzero_v2104",
        "theorem RH_P22BQ_standard_half_not_constant_on_UNIV_v2104",
        "theorem RH_P22BQ_standard_half_locally_nonconstant_off_axis_v2104",
        "definition p22bq_two_field_unit_shift_endpoint_package_v2104",
        "theorem RH_P22BQ_two_field_package_imp_P22BP_package_v2104",
        "theorem RH_P22BQ_two_field_package_imp_reference_endpoint_v2104",
        "definition p22bq_standard_half_positivity_two_field_foundation_v2104",
        "theorem RH_P22BQ_standard_half_positivity_two_field_foundation_v2104"
    )) {
        if (-not $theoryBody.Contains($required)) { throw "P22BQ body missing declaration: $required" }
    }
    foreach ($required in @(
        "RH_P22AB_Phi_plus_term_factor_nonnegative_axis_v264",
        "RH_P22AB_Phi_plus_term_summable_v264",
        "RH_P22AB_Phi_plus_term_nonnegative_v264",
        "RH_P22AS_standard_source_exact_v280",
        "RH_P22AV_standard_integrand_whole_integrable_v283",
        "RH_P22AV_F_standard_half_entire_v283",
        "RH_P22BP_reduced_package_imp_reference_endpoint_v2103",
        "suminf_pos2",
        "integral_nonneg_eq_0_iff_AE",
        "AE_lborel_singleton",
        "analytic_continuation'",
        "set_integral_complex_of_real"
    )) {
        if (-not $theoryBody.Contains($required)) { throw "P22BQ body missing exact reference: $required" }
    }
    if ($theoryBody -match '\bsorry\b|\boops\b|\baxiomatization\b|(?m)^\s*oracle(?:\s|$)|trusted_|\bundefined\b|\bskip_proofs\b|Thm\.add_axiom|Thm\.add_oracle|\bnlinarith\b|\bsos\b|(?m)^\s*by\s+ring\s*$|(?m)^\s*calc\s*$') { throw "P22BQ body contains forbidden trust or unstable proof content." }
    if ($theoryBody.Contains('O2_remaining_foundation_milestones_v2104 = 2')) { throw "P22BQ attempts premature O2 promotion." }
    $selectedBodySha256 = Get-TextSha256 -Text $theoryBody
    $expectedSelectedBodySha256 = "__EXPECTED_BODY_SHA256__"
    if ($selectedBodySha256 -ne $expectedSelectedBodySha256) { throw "P22BQ embedded Isabelle body hash mismatch." }

    $probeOracleAssertion = @'
ML \<open>
  val p22bq_probe_theorems = [
    @{thm RH_P22BQ_Phi_plus_term_zero_strictly_positive_v2104},
    @{thm RH_P22BQ_Phi_theta_strictly_positive_v2104},
    @{thm RH_P22BQ_standard_source_strictly_positive_v2104},
    @{thm RH_P22BQ_standard_half_density_strictly_positive_v2104},
    @{thm RH_P22BQ_symmetric_curvature_factor_square_v2104},
    @{thm RH_P22BQ_symmetric_curvature_factor_nonnegative_v2104},
    @{thm RH_P22BQ_symmetric_curvature_factor_positive_v2104},
    @{thm RH_P22BQ_standard_half_curvature_density_nonnegative_v2104},
    @{thm RH_P22BQ_standard_half_curvature_density_positive_v2104},
    @{thm RH_P22BQ_standard_half_integrand_second_difference_v2104},
    @{thm RH_P22BQ_standard_half_curvature_density_integrable_v2104},
    @{thm RH_P22BQ_standard_half_curvature_integral_positive_v2104},
    @{thm RH_P22BQ_standard_half_second_difference_identity_v2104},
    @{thm RH_P22BQ_standard_half_second_difference_nonzero_v2104},
    @{thm RH_P22BQ_standard_half_not_constant_on_UNIV_v2104},
    @{thm RH_P22BQ_standard_half_locally_nonconstant_off_axis_v2104},
    @{thm RH_P22BQ_two_field_package_imp_P22BP_package_v2104},
    @{thm RH_P22BQ_two_field_package_imp_reference_endpoint_v2104},
    @{thm RH_P22BQ_standard_half_positivity_two_field_foundation_v2104}
  ];
  val _ = if length p22bq_probe_theorems = 19 then () else error "P22BQ_PROBE_THEOREM_COUNT";
  val oracles = Thm_Deps.all_oracles p22bq_probe_theorems;
  val _ = if null oracles then () else error ("P22BQ_PROBE_TRANSITIVE_ORACLES=" ^ Int.toString (length oracles));
\<close>
'@

    $probeTheory = @"
theory RHBQ01
  imports
    "RH_Unconditionalization_v1_99.RH_Unconditional_Status_v2_103"
begin

$theoryBody

$probeOracleAssertion

end
"@

    $isabelleExe = Join-Path $isabelleDirectory "bin\isabelle"
    $bash = Join-Path $isabelleDirectory "contrib\cygwin\bin\bash.exe"
    foreach ($exe in @($isabelleExe,$bash)) { if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Required Isabelle executable missing: $exe" } }
    $isabelleCyg = To-CygwinPath $isabelleExe
    $workbenchCyg = To-CygwinPath $workbench
    $probeRoot = Join-Path $env:TEMP ("RH_V2104_P22BQ_" + $timestamp)
    $probeDirectory = Join-Path $probeRoot "RHBQ01"
    New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
    $probeTheoryPath = Join-Path $probeDirectory "RHBQ01.thy"
    $probeRootText = @"
session RHBQ01 = RH_Unconditionalization_v1_99 +
  options [quick_and_dirty = false]
  sessions
    Elliptic_Functions
    "HOL-Probability"
  theories
    RHBQ01
"@
    Write-Utf8NoBom -Path $probeTheoryPath -Text $probeTheory
    Write-Utf8NoBom -Path (Join-Path $probeDirectory "ROOT") -Text $probeRootText
    $probeCyg = To-CygwinPath $probeDirectory
    $probeLog = Join-Path $probeDirectory "probe.log"
    $probeCommand = (Bash-SingleQuote $isabelleCyg) + " build -o quick_and_dirty=false -d " + (Bash-SingleQuote $workbenchCyg) + " -D " + (Bash-SingleQuote $probeCyg) + " -v"
    Write-Host ""
    Write-Host "[P22BQ_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_PROBE]"
    $probe = Invoke-BashLive -BashExe $bash -Command $probeCommand -LiveLogPath $probeLog -Label "PROBE_RHBQ01" -TimeoutSeconds 1800
    Write-Host ("probe_exit_code=" + $probe.ExitCode)
    Write-Host ("probe_passed=" + ($probe.ExitCode -eq 0 -and -not $probe.TimedOut))
    Write-Host ("probe_elapsed_seconds=" + $probe.ElapsedSeconds)
    Write-Host "probe_hard_oracle_assertion_present=true"
    if ($probe.ExitCode -ne 0 -or $probe.TimedOut) {
        Write-CompactProbeError -TheoryPath $probeTheoryPath -BuildLines $probe.Lines
        Write-Host "[PROBE_LOG_TAIL]"
        foreach ($line in @($probe.Lines | Select-Object -Last 220)) { Write-Host $line }
        throw "P22BQ probe failed; v2.103 retained."
    }
    Write-Host "probe_zero_oracle_assertion_passed=true"

    Write-Host ""
    Write-Host "[PREINTEGRATION_REVALIDATION]"
    if ((Get-Sha256 -Path $rootPath) -ne $expectedRootHash) { throw "ROOT changed during probe." }
    if ((Get-Sha256 -Path $baseTheoryPath) -ne $expectedBaseTheoryHash) { throw "v2.103 main theory changed during probe." }
    if ((Get-Sha256 -Path $baseStatusTheoryPath) -ne $expectedBaseStatusTheoryHash) { throw "v2.103 status theory changed during probe." }
    if ((Get-Sha256 -Path $baseStatusJsonPath) -ne $baseStatusJsonRuntimeHash) { throw "P22BP status JSON changed during probe." }
    if ((Get-Sha256 -Path $oracleRepairStatusPath) -ne $oracleRepairStatusRuntimeHash) { throw "Oracle repair status changed during probe." }
    if ((Get-Sha256 -Path $normalizationTheoryPath) -ne $expectedNormalizationHash) { throw "v2.80 normalization changed during probe." }
    Write-Host "all_predecessor_hashes_still_match=true"

    $finalTheory = @"
theory $theoryName
  imports
    RH_Unconditional_Status_v2_103
begin

$theoryBody

end
"@

    $statusTheory = @'
theory RH_Unconditional_Status_v2_104
  imports
    RH_Unconditional_Status_v2_103
    RH_O2_DeBruijn_Standard_Half_Positivity_And_Two_Field_Endpoint_v2_104
begin

record unconditionalization_status_v2104 =
  O4_unconditional_bundle_closed_v2104 :: bool
  O2_real_even_canonical_truncation_foundation_closed_v2104 :: bool
  O2_explicit_unit_shift_reduced_endpoint_package_closed_v2104 :: bool
  O2_standard_half_positivity_two_field_endpoint_closed_v2104 :: bool
  O2_reference_endpoint_no_contact_closed_v2104 :: bool
  O2_no_escape_compactness_closed_v2104 :: bool
  O2_first_contact_closed_v2104 :: bool
  unconditional_RH_closed_v2104 :: bool

definition status_v2104 :: unconditionalization_status_v2104 where
  "status_v2104 =
   \<lparr>
     O4_unconditional_bundle_closed_v2104 = True,
     O2_real_even_canonical_truncation_foundation_closed_v2104 = True,
     O2_explicit_unit_shift_reduced_endpoint_package_closed_v2104 = True,
     O2_standard_half_positivity_two_field_endpoint_closed_v2104 = True,
     O2_reference_endpoint_no_contact_closed_v2104 = False,
     O2_no_escape_compactness_closed_v2104 = False,
     O2_first_contact_closed_v2104 = False,
     unconditional_RH_closed_v2104 = False
   \<rparr>"

definition O2_remaining_foundation_milestones_v2104 :: nat where
  "O2_remaining_foundation_milestones_v2104 = 3"

theorem O2_remaining_foundation_milestones_v2104_value:
  "O2_remaining_foundation_milestones_v2104 = 3"
  unfolding O2_remaining_foundation_milestones_v2104_def
  by simp

theorem status_v2104_never_claims_unconditional_RH:
  "\<not> unconditional_RH_closed_v2104 status_v2104"
  unfolding status_v2104_def
  by simp

end
'@

    $statusDeclarationCount = [regex]::Matches($statusTheory,$declarationPattern).Count
    if ($statusDeclarationCount -ne 5) { throw "Unexpected P22BQ status declaration count: $statusDeclarationCount" }
    $newFormalPoints = $mainDeclarationCount + $statusDeclarationCount
    $currentFormalPoints = 1752 + $newFormalPoints
    if ($currentFormalPoints -ne 1780) { throw "Unexpected P22BQ formal-point count: $currentFormalPoints" }

    $backupDirectory = Join-Path $backupRoot ("P22BQ_V1_" + $timestamp)
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $rootPath -Destination (Join-Path $backupDirectory "ROOT") -Force
    Copy-Item -LiteralPath $baseStatusJsonPath -Destination (Join-Path $backupDirectory "predecessor_status.json") -Force
    Copy-Item -LiteralPath $oracleRepairStatusPath -Destination (Join-Path $backupDirectory "oracle_repair_status.json") -Force

    Write-Host ""
    Write-Host "[PERSISTENT_INTEGRATION_BEGIN]"
    Write-Host ("backup_directory=" + $backupDirectory)
    Write-Host "workbench_modified_only_after_probe_passes=true"
    $integrationStarted = $true
    Write-Utf8NoBom -Path $theoryPath -Text $finalTheory
    Write-Utf8NoBom -Path $statusTheoryPath -Text $statusTheory

    $rootLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $rootPath)) { [void]$rootLines.Add([string]$line) }
    $indices = @()
    for ($i=0; $i -lt $rootLines.Count; $i++) { if ($rootLines[$i].Trim() -eq "RH_Unconditional_Status_v2_103") { $indices += $i } }
    if ($indices.Count -ne 1) { throw "Expected exactly one v2.103 status anchor in ROOT." }
    $index = [int]$indices[0]
    $anchor = $rootLines[$index]
    $indent = $anchor.Substring(0,$anchor.Length-$anchor.TrimStart().Length)
    $rootLines.Insert($index+1,$indent+$theoryName)
    $rootLines.Insert($index+2,$indent+$statusTheoryName)
    Write-Utf8NoBom -Path $rootPath -Text ([string]::Join([Environment]::NewLine,[string[]]$rootLines.ToArray()))

    $auditNames = @(Get-P22BQOracleAuditTheoremNames -TheoryDirectory $theoryDirectory)
    if ($auditNames.Count -ne 408) { throw "Unexpected P22BQ audit theorem count: $($auditNames.Count)" }
    $auditEntries = [string]::Join(","+[Environment]::NewLine,[string[]]@($auditNames | ForEach-Object { "    @{thm " + $_ + "}" }))
    $auditDirectory = Join-Path $backupDirectory "audit"
    New-Item -ItemType Directory -Path $auditDirectory -Force | Out-Null
    $auditTheoryPath = Join-Path $auditDirectory "RHBQ_POST_INTEGRATION_AUDIT.thy"
    $auditRootPath = Join-Path $auditDirectory "ROOT"
    $combinedLog = Join-Path $backupDirectory "combined_build_audit.log"
    $auditTheory = @"
theory RHBQ_POST_INTEGRATION_AUDIT
  imports
    "RH_Unconditionalization_v1_99.RH_Unconditional_Status_v2_104"
begin

ML \<open>
  val p22bq_audited_theorems = [
$auditEntries
  ];
  val _ = if length p22bq_audited_theorems = 408 then () else error "P22BQ_AUDITED_THEOREM_COUNT";
  val p22bq_oracles = Thm_Deps.all_oracles p22bq_audited_theorems;
  val _ = if null p22bq_oracles then () else error ("P22BQ_TRANSITIVE_ORACLES=" ^ Int.toString (length p22bq_oracles));
  val final_meta_premises =
    length (Logic.strip_imp_prems (Thm.prop_of @{thm RH_P22BQ_standard_half_positivity_two_field_foundation_v2104})) +
    length (Logic.strip_imp_prems (Thm.prop_of @{thm status_v2104_never_claims_unconditional_RH}));
  val _ = if final_meta_premises = 0 then () else error ("P22BQ_FINAL_META_PREMISES=" ^ Int.toString final_meta_premises);
\<close>

end
"@
    $auditRoot = @"
session RHBQ_POST_INTEGRATION_AUDIT = RH_Unconditionalization_v1_99 +
  options [quick_and_dirty = false]
  sessions
    Elliptic_Functions
    "HOL-Probability"
  theories
    RHBQ_POST_INTEGRATION_AUDIT
"@
    Write-Utf8NoBom -Path $auditTheoryPath -Text $auditTheory
    Write-Utf8NoBom -Path $auditRootPath -Text $auditRoot
    $auditCyg = To-CygwinPath $auditDirectory
    $combinedCommand = (Bash-SingleQuote $isabelleCyg) + " build -o quick_and_dirty=false -d " + (Bash-SingleQuote $workbenchCyg) + " -D " + (Bash-SingleQuote $auditCyg) + " -v"
    Write-Host ""
    Write-Host "[COMBINED_FULL_WORKBENCH_BUILD_AND_TRANSITIVE_ORACLE_AUDIT]"
    $combined = Invoke-BashLive -BashExe $bash -Command $combinedCommand -LiveLogPath $combinedLog -Label "COMBINED_FULL_BUILD_AND_ORACLE_AUDIT" -TimeoutSeconds 3600
    Write-Host ("combined_exit_code=" + $combined.ExitCode)
    Write-Host ("combined_timed_out=" + $combined.TimedOut)
    Write-Host ("combined_elapsed_seconds=" + $combined.ElapsedSeconds)
    Write-Host ("combined_line_count=" + $combined.Lines.Count)
    Write-Host ("combined_log=" + $combinedLog)
    Write-Host "quick_and_dirty=false"
    Write-Host ("oracle_audit_theorem_count=" + $auditNames.Count)
    if ($combined.ExitCode -ne 0 -or $combined.TimedOut) { throw "Combined P22BQ build/oracle audit failed." }
    if (-not (Test-Path -LiteralPath $combinedLog -PathType Leaf) -or (Get-Item -LiteralPath $combinedLog).Length -eq 0) { throw "Combined P22BQ run produced no nonempty log." }
    Write-Host "combined_dependency_graph_completed=true"
    Write-Host "combined_ML_audit_assertions_passed=true"
    Write-Host "audited_theorem_count=408"
    Write-Host "transitive_oracles_in_audited_theorems=0"
    Write-Host "final_meta_premises=0"

    $trustPatterns = [ordered]@{
        sorry='\bsorry\b'; oops='\boops\b'; axiomatization='\baxiomatization\b';
        axioms_command='(?m)^\s*axioms(?:\s|$)'; oracle_command='(?m)^\s*oracle(?:\s|$)';
        undefined='\bundefined\b'; skip_proofs='\bskip_proofs\b';
        Thm_add_axiom='Thm\.add_axiom'; Thm_add_oracle='Thm\.add_oracle';
        ML_command='(?m)^\s*ML(?:\s|\\<open>|$)'; ML_file='(?m)^\s*ML_file(?:\s|$)';
        setup='(?m)^\s*setup(?:\s|$)'; local_setup='(?m)^\s*local_setup(?:\s|$)';
        method_setup='(?m)^\s*method_setup(?:\s|$)'; attribute_setup='(?m)^\s*attribute_setup(?:\s|$)';
        simproc_setup='(?m)^\s*simproc_setup(?:\s|$)'; quick_and_dirty_true='quick_and_dirty\s*=\s*true'
    }
    foreach ($key in $trustPatterns.Keys) {
        try { $null = [regex]::new([string]$trustPatterns[$key]) }
        catch { throw ("Invalid trust regex " + $key + ": " + $_.Exception.Message) }
    }
    $theoryFiles = @(Get-ChildItem -LiteralPath $theoryDirectory -Filter "*.thy" -File | Sort-Object Name)
    $trustScan = [ordered]@{}
    Write-Host ""
    Write-Host "[BROAD_SOURCE_TRUST_SCAN]"
    Write-Host ("scanned_files=" + $theoryFiles.Count)
    foreach ($key in $trustPatterns.Keys) {
        $count = Count-Pattern -Files $theoryFiles -Pattern $trustPatterns[$key]
        $trustScan[$key] = $count
        Write-Host ($key + "=" + $count)
        if ([int]$count -ne 0) { throw ("P22BQ broad trust scan failed: " + $key) }
    }
    if ((Get-Sha256 -Path $normalizationTheoryPath) -ne $expectedNormalizationHash) { throw "v2.80 changed during integration/build." }

    $finalRootHash = Get-Sha256 -Path $rootPath
    $finalTheoryHash = Get-Sha256 -Path $theoryPath
    $finalStatusTheoryHash = Get-Sha256 -Path $statusTheoryPath
    $statusJsonPath = Join-Path $statusDirectory ("P22BQ_O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_STATUS_" + $timestamp + ".json")
    $statusObject = [ordered]@{
        stage="P22BQ_O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_AND_TWO_FIELD_ENDPOINT";
        timestamp=(Get-Date).ToString("o"); base_workbench="v2.103"; resulting_workbench="v2.104";
        previous_registered_formal_points=1752; current_registered_formal_points=1780;
        new_registered_formal_points=28; main_theory_declarations=23; status_theory_declarations=5;
        selected_proof_variant="STRICT_SOURCE_POSITIVITY_SYMMETRIC_SECOND_DIFFERENCE_AND_ANALYTIC_CONTINUATION";
        selected_theory_body_sha256=$selectedBodySha256; conditional_claims=$false; all_integrated_claims_unconditional=$true;
        O4_unconditional_bundle_closed=$true;
        O2_DEBRUIJN_REAL_EVEN_CANONICAL_TRUNCATION_FOUNDATION_CLOSED=$true;
        O2_DEBRUIJN_EXPLICIT_UNIT_SHIFT_REDUCED_ENDPOINT_PACKAGE_CLOSED=$true;
        O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_CLOSED=$true;
        standard_source_strictly_positive_proved=$true;
        standard_half_curvature_integral_strictly_positive_proved=$true;
        standard_half_global_nonconstancy_proved=$true;
        standard_half_locally_nonconstant_off_axis_proved=$true;
        endpoint_package_reduced_to_two_fields=$true;
        local_nonconstancy_removed_from_remaining_endpoint_assumptions=$true;
        exhausting_canonical_atom_sequence_constructed=$false;
        locally_uniform_shifted_polynomial_tail_limit_proved=$false;
        concrete_Gaussian_polynomial_approximants_constructed=$false;
        reference_endpoint_all_real_closed=$false; reference_endpoint_3_to_2_promotion=$false;
        O2_reference_endpoint_no_contact_closed=$false; O2_no_escape_compactness_closed=$false;
        O2_first_contact_closed=$false; O2_first_contact_foundation_milestones_remaining=3;
        O2_foundation_milestone_count_is_administrative_bundle=$true; unconditional_RH_proved=$false;
        predecessor_status_json=$baseStatusJsonPath; oracle_repair_status_json=$oracleRepairStatusPath;
        pnsubstl_oracle_repair_verified=$true; audited_theorem_count=408; transitive_oracles_after_P22BQ=0;
        final_meta_premises=0;
        full_build=[ordered]@{exit_code=0;timed_out=$false;elapsed_seconds=$combined.ElapsedSeconds;log=$combinedLog;quick_and_dirty=$false;combined_with_oracle_audit=$true};
        oracle_audit=[ordered]@{exit_code=0;elapsed_seconds=$combined.ElapsedSeconds;log=$combinedLog;transitive_oracles=0;audited_theorem_count=408;final_meta_premises=0;combined_with_full_build=$true};
        hashes=[ordered]@{ROOT=$finalRootHash;theory=$finalTheoryHash;status_theory=$finalStatusTheoryHash;oracle_free_v280=$expectedNormalizationHash};
        trust_scan=$trustScan;
        next_mathematical_step="construct_an_exhausting_certified_standard_zero_atom_sequence_and_prove_locally_uniform_convergence_of_its_explicit_unit_shifted_polynomials_to_F_standard_half_then_apply_the_two_field_endpoint_transfer_and_move_O2_3_to_2"
    }
    Write-Utf8NoBom -Path $statusJsonPath -Text ($statusObject | ConvertTo-Json -Depth 20)
    $written = Get-Content -LiteralPath $statusJsonPath -Raw | ConvertFrom-Json
    if ([string]$written.resulting_workbench -ne "v2.104" -or [int]$written.current_registered_formal_points -ne 1780 -or -not [bool]$written.O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_CLOSED -or -not [bool]$written.standard_source_strictly_positive_proved -or -not [bool]$written.standard_half_global_nonconstancy_proved -or -not [bool]$written.standard_half_locally_nonconstant_off_axis_proved -or -not [bool]$written.endpoint_package_reduced_to_two_fields -or [bool]$written.exhausting_canonical_atom_sequence_constructed -or [bool]$written.locally_uniform_shifted_polynomial_tail_limit_proved -or [bool]$written.reference_endpoint_all_real_closed -or [int]$written.transitive_oracles_after_P22BQ -ne 0 -or [int]$written.audited_theorem_count -ne 408 -or [int]$written.final_meta_premises -ne 0 -or [int]$written.O2_first_contact_foundation_milestones_remaining -ne 3) { throw "Written P22BQ status JSON is inconsistent." }

    $committed = $true
    Write-Host ""
    Write-Host "[CURRENT_CONFIRMED_TRUE_AFTER_P22BQ]"
    Write-Host "CURRENT_WORKBENCH_VERSION=v2.104"
    Write-Host "PREVIOUS_INTEGRATED_REGISTERED_FORMAL_POINTS=1752"
    Write-Host "CURRENT_INTEGRATED_REGISTERED_FORMAL_POINTS=1780"
    Write-Host "NEW_REGISTERED_FORMAL_POINTS_INTEGRATED=28"
    Write-Host "O4_UNCONDITIONAL_BUNDLE_CLOSED=true"
    Write-Host "O2_DEBRUIJN_EXPLICIT_UNIT_SHIFT_REDUCED_ENDPOINT_PACKAGE_CLOSED=true"
    Write-Host "O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_CLOSED=true"
    Write-Host "STANDARD_SOURCE_STRICTLY_POSITIVE_PROVED=true"
    Write-Host "STANDARD_HALF_CURVATURE_INTEGRAL_STRICTLY_POSITIVE_PROVED=true"
    Write-Host "STANDARD_HALF_GLOBAL_NONCONSTANCY_PROVED=true"
    Write-Host "STANDARD_HALF_LOCALLY_NONCONSTANT_OFF_AXIS_PROVED=true"
    Write-Host "ENDPOINT_PACKAGE_REDUCED_TO_TWO_FIELDS=true"
    Write-Host "LOCAL_NONCONSTANCY_REMOVED_FROM_REMAINING_ENDPOINT_ASSUMPTIONS=true"
    Write-Host "EXHAUSTING_CANONICAL_ATOM_SEQUENCE_CONSTRUCTED=false"
    Write-Host "LOCALLY_UNIFORM_SHIFTED_POLYNOMIAL_TAIL_LIMIT_PROVED=false"
    Write-Host "REFERENCE_ENDPOINT_ALL_REAL_CLOSED=false"
    Write-Host "REFERENCE_ENDPOINT_3_TO_2_PROMOTION=false"
    Write-Host "LARGE_ISABELLE_TRAVERSALS_EXECUTED=2"
    Write-Host "TRANSITIVE_ORACLES_IN_AUDITED_THEOREMS=0"
    Write-Host "AUDITED_THEOREM_COUNT=408"
    Write-Host "FINAL_META_PREMISES=0"
    Write-Host "BROAD_SOURCE_TRUST_SCAN_CLEAN=true"
    Write-Host "O2_REFERENCE_ENDPOINT_NO_CONTACT_CLOSED=false"
    Write-Host "O2_NO_ESCAPE_COMPACTNESS_CLOSED=false"
    Write-Host "O2_FIRST_CONTACT_CLOSED=false"
    Write-Host "O2_FOUNDATION_MILESTONES_REMAINING=3"
    Write-Host "GLOBAL_RH_PROVED_UNCONDITIONALLY=false"
    Write-Host ("status_json=" + $statusJsonPath)
    Write-Host "P22BQ_RESULT=O2_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_INTEGRATED"
}
catch {
    $scriptFailed = $true
    Write-Host ""
    Write-Host "[SCRIPT_ERROR]"
    Write-Host ("message=" + $_.Exception.Message)
    Write-Host ("type=" + $_.Exception.GetType().FullName)
}
finally {
    if ($null -ne $script:IsabelleRootForCleanup) {
        try { $null = Stop-ExactIsabelleWorkers -IsabelleRoot $script:IsabelleRootForCleanup -ExcludeProcessIds @($PID) -Quiet } catch {}
    }
    if ($integrationStarted -and -not $committed) {
        Write-Host ""
        Write-Host "[ROLLBACK_BEGIN]"
        try {
            if ($null -ne $backupDirectory -and (Test-Path -LiteralPath (Join-Path $backupDirectory "ROOT") -PathType Leaf)) { Copy-Item -LiteralPath (Join-Path $backupDirectory "ROOT") -Destination $rootPath -Force }
            if ($null -ne $theoryPath -and (Test-Path -LiteralPath $theoryPath)) { Remove-Item -LiteralPath $theoryPath -Force }
            if ($null -ne $statusTheoryPath -and (Test-Path -LiteralPath $statusTheoryPath)) { Remove-Item -LiteralPath $statusTheoryPath -Force }
            if ($null -ne $statusJsonPath -and (Test-Path -LiteralPath $statusJsonPath)) { Remove-Item -LiteralPath $statusJsonPath -Force }
            Write-Host "rollback_completed=true"
            Write-Host "rollback_build_not_forced=true"
        }
        catch { Write-Host ("rollback_failed=" + $_.Exception.Message) }
    }
    if ($scriptFailed) {
        Write-Host "P22BQ_RESULT=O2_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_FAILED"
        if ($verifiedBase) {
            Write-Host "CURRENT_WORKBENCH_VERSION=v2.103"
            Write-Host "CURRENT_INTEGRATED_REGISTERED_FORMAL_POINTS=1752"
            Write-Host "O2_DEBRUIJN_EXPLICIT_UNIT_SHIFT_REDUCED_ENDPOINT_PACKAGE_CLOSED=true"
            Write-Host "O2_DEBRUIJN_STANDARD_HALF_POSITIVITY_TWO_FIELD_ENDPOINT_CLOSED=false"
            Write-Host "STANDARD_HALF_LOCALLY_NONCONSTANT_OFF_AXIS_PROVED=false"
            Write-Host "EXHAUSTING_CANONICAL_ATOM_SEQUENCE_CONSTRUCTED=false"
            Write-Host "LOCALLY_UNIFORM_SHIFTED_POLYNOMIAL_TAIL_LIMIT_PROVED=false"
            Write-Host "O2_FOUNDATION_MILESTONES_REMAINING=3"
            Write-Host "GLOBAL_RH_PROVED_UNCONDITIONALLY=false"
        }
        else { Write-Host "CURRENT_WORKBENCH_VERSION=UNVERIFIED_BY_THIS_RUN" }
    }
    if ($null -ne $mutex -and $mutexAcquired) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
    if ($reportOpen) { Write-Host "===== RH_REPORT_END =====" }
}

if ($scriptFailed) { exit 1 }
