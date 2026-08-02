<#
.SYNOPSIS
    Recursively scans a directory and removes unwanted files/folders
    (currently: *.bak files and __pycache__ folders).

.PARAMETER RootPath
    The top-level directory to scan.

.PARAMETER WhatIf
    If specified, only shows what WOULD be deleted, without deleting anything.

.EXAMPLE
    .\Clean-Directory.ps1 -RootPath "C:\Projects" -WhatIf
    .\Clean-Directory.ps1 -RootPath "C:\Projects"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [switch]$WhatIf
)

# --- Config: add more patterns here as you find new junk ---
$FilePatterns   = @("*.bak")
$FolderPatterns = @("__pycache__")
# -------------------------------------------------------------

if (-not (Test-Path -LiteralPath $RootPath)) {
    Write-Error "Path not found: $RootPath"
    exit 1
}

Write-Host "Scanning: $RootPath" -ForegroundColor Cyan
Write-Host "File patterns:   $($FilePatterns -join ', ')"
Write-Host "Folder patterns: $($FolderPatterns -join ', ')"
Write-Host ""

# --- Find matching files ---
$filesToDelete = foreach ($pattern in $FilePatterns) {
    Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
}

# --- Find matching folders ---
$foldersToDelete = foreach ($pattern in $FolderPatterns) {
    Get-ChildItem -LiteralPath $RootPath -Recurse -Directory -Filter $pattern -ErrorAction SilentlyContinue
}

$totalItems = $filesToDelete.Count + $foldersToDelete.Count

if ($totalItems -eq 0) {
    Write-Host "Nothing found to delete. You're clean!" -ForegroundColor Green
    exit 0
}

Write-Host "Found $($filesToDelete.Count) file(s) and $($foldersToDelete.Count) folder(s) to remove:" -ForegroundColor Yellow
Write-Host ""

foreach ($f in $filesToDelete)   { Write-Host "  [FILE]   $($f.FullName)" }
foreach ($d in $foldersToDelete) { Write-Host "  [FOLDER] $($d.FullName)" }

Write-Host ""

if ($WhatIf) {
    Write-Host "-WhatIf specified: no changes made. Re-run without -WhatIf to actually delete." -ForegroundColor Magenta
    exit 0
}

# --- Confirm before actually deleting ---
$confirmation = Read-Host "Type YES to permanently delete the above $totalItems item(s)"
if ($confirmation -ne "YES") {
    Write-Host "Aborted. Nothing was deleted." -ForegroundColor Yellow
    exit 0
}

$errors = @()

foreach ($f in $filesToDelete) {
    try {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        Write-Host "Deleted file:   $($f.FullName)" -ForegroundColor DarkGray
    } catch {
        $errors += "Failed to delete file $($f.FullName): $_"
    }
}

foreach ($d in $foldersToDelete) {
    try {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
        Write-Host "Deleted folder: $($d.FullName)" -ForegroundColor DarkGray
    } catch {
        $errors += "Failed to delete folder $($d.FullName): $_"
    }
}

Write-Host ""
if ($errors.Count -gt 0) {
    Write-Host "Completed with $($errors.Count) error(s):" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
} else {
    Write-Host "Cleanup complete. Removed $totalItems item(s)." -ForegroundColor Green
}