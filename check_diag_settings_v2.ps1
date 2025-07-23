#Requires -Modules Az.Accounts, Az.Resources, Az.Monitor

<#
.SYNOPSIS
    Audits Azure resources for diagnostic settings configuration across multiple subscriptions.

.DESCRIPTION
    This script connects to Azure using Service Principal credentials and iterates through
    all accessible subscriptions to check diagnostic settings on resources. It provides
    detailed reporting on configuration status and supports filtering options.

.PARAMETER TenantId
    Azure AD Tenant ID (optional - will prompt if not provided)

.PARAMETER ApplicationId
    Service Principal Application/Client ID (optional - will prompt if not provided)

.PARAMETER OutputPath
    Path to export results to CSV file (optional)

.PARAMETER FilterResourceTypes
    Array of resource types to filter (optional - processes all if not specified)

.PARAMETER ExcludeResourceTypes
    Array of resource types to exclude from processing

.EXAMPLE
    .\Get-DiagnosticSettingsAudit.ps1
    
.EXAMPLE
    .\Get-DiagnosticSettingsAudit.ps1 -OutputPath "C:\Reports\DiagnosticAudit.csv"
    
.EXAMPLE
    .\Get-DiagnosticSettingsAudit.ps1 -FilterResourceTypes @("Microsoft.Compute/virtualMachines", "Microsoft.Storage/storageAccounts")
#>

param(
    [string]$TenantId,
    [string]$ApplicationId,
    [string]$OutputPath,
    [string[]]$FilterResourceTypes,
    [string[]]$ExcludeResourceTypes = @(
        "Microsoft.Resources/deployments",
        "Microsoft.Resources/resourceGroups",
        "Microsoft.Authorization/roleAssignments",
        "Microsoft.Authorization/policyAssignments"
    )
)

# Function to test if a resource supports diagnostic settings using PowerShell cmdlet
function Test-DiagnosticSettingsSupport {
    param([string]$ResourceId)
    
    try {
        $categories = Get-AzDiagnosticSettingCategory -ResourceId $ResourceId -ErrorAction Stop
        
        # If we get categories back, the resource supports diagnostic settings
        return @{
            Supported = $true
            Categories = $categories
            Error = $null
        }
    }
    catch {
        # Check if the error indicates the resource doesn't support diagnostic settings
        if ($_.Exception.Message -like "*does not support diagnostic settings*" -or
            $_.Exception.Message -like "*ResourceTypeNotSupported*" -or
            $_.Exception.Message -like "*BadRequest*" -or
            ($_.Exception.Response.StatusCode -eq 400)) {
            return @{
                Supported = $false
                Categories = $null
                Error = $null
            }
        }
        else {
            # Other errors might be transient or permission-related
            return @{
                Supported = $null  # Unknown due to error
                Categories = $null
                Error = $_.Exception.Message
            }
        }
    }
}

# Function to get supported resource types from cache or build cache
$script:DiagnosticsSupportCache = @{}
function Get-DiagnosticsSupportCached {
    param([string]$ResourceId, [string]$ResourceType)
    
    # Check if we already know about this resource type
    if ($script:DiagnosticsSupportCache.ContainsKey($ResourceType)) {
        return @{
            Supported = $script:DiagnosticsSupportCache[$ResourceType]
            Categories = $null
            Error = $null
        }
    }
    
    # Query using PowerShell cmdlet for this specific resource
    $result = Test-DiagnosticSettingsSupport -ResourceId $ResourceId
    
    # Cache the result for this resource type (if we got a definitive answer)
    if ($result.Supported -ne $null) {
        $script:DiagnosticsSupportCache[$ResourceType] = $result.Supported
    }
    
    return $result
}

# Function to safely get diagnostic settings
function Get-SafeDiagnosticSettings {
    param([string]$ResourceId)
    
    try {
        $settings = Get-AzDiagnosticSetting -ResourceId $ResourceId -ErrorAction Stop -WarningAction SilentlyContinue
        return @{
            Success = $true
            Settings = $settings
            Error = $null
        }
    }
    catch {
        return @{
            Success = $false
            Settings = $null
            Error = $_.Exception.Message
        }
    }
}

# Main script execution
try {
    Write-Host "=== Azure Diagnostic Settings Audit ===" -ForegroundColor Cyan
    Write-Host "Starting at: $(Get-Date)" -ForegroundColor Green
    
    # Prompt for credentials if not provided
    if (-not $TenantId) {
        $TenantId = Read-Host "Enter Tenant ID"
    }
    
    if (-not $ApplicationId) {
        $ApplicationId = Read-Host "Enter Application (Client) ID"
    }
    
    $AppSecret = Read-Host "Enter Application Secret" -AsSecureString
    $SpnCredential = New-Object System.Management.Automation.PSCredential($ApplicationId, $AppSecret)
    
    # Connect to Azure
    Write-Host "`nConnecting to Azure..." -ForegroundColor Yellow
    $connectionResult = Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $SpnCredential -ErrorAction Stop
    Write-Host "Successfully connected as: $($connectionResult.Context.Account.Id)" -ForegroundColor Green
    
    # Get all accessible subscriptions
    Write-Host "`nRetrieving accessible subscriptions..." -ForegroundColor Yellow
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
    
    if ($subscriptions.Count -eq 0) {
        throw "No enabled subscriptions found for this Service Principal."
    }
    
    Write-Host "Found $($subscriptions.Count) enabled subscription(s):" -ForegroundColor Green
    foreach ($sub in $subscriptions) {
        Write-Host "  • $($sub.Name) ($($sub.Id))" -ForegroundColor White
    }
    
    # Initialize results collection
    $results = @()
    $totalResources = 0
    $processedResources = 0
    
    # Process each subscription
    foreach ($subscription in $subscriptions) {
        Write-Host "`n" + "="*80 -ForegroundColor Cyan
        Write-Host "Processing Subscription: $($subscription.Name)" -ForegroundColor Cyan
        Write-Host "="*80 -ForegroundColor Cyan
        
        try {
            Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
            
            # Get resources with filtering
            Write-Host "Retrieving resources..." -ForegroundColor Yellow
            $resources = Get-AzResource
            
            # Apply filters
            if ($FilterResourceTypes) {
                $resources = $resources | Where-Object { $_.Type -in $FilterResourceTypes }
                Write-Host "Applied resource type filter. Resources to process: $($resources.Count)" -ForegroundColor Yellow
            }
            
            if ($ExcludeResourceTypes) {
                $resources = $resources | Where-Object { $_.Type -notin $ExcludeResourceTypes }
            }
            
            $totalResources += $resources.Count
            Write-Host "Processing $($resources.Count) resources..." -ForegroundColor Yellow
            
            $counter = 0
            foreach ($resource in $resources) {
                $counter++
                $processedResources++
                
                # Progress indicator
                if ($counter % 50 -eq 0 -or $counter -eq $resources.Count) {
                    Write-Progress -Activity "Processing Resources" -Status "Subscription: $($subscription.Name)" -PercentComplete (($counter / $resources.Count) * 100)
                }
                
                $result = [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    SubscriptionId = $subscription.Id
                    ResourceName = $resource.Name
                    ResourceType = $resource.Type
                    ResourceGroup = $resource.ResourceGroupName
                    Location = $resource.Location
                    ResourceId = $resource.ResourceId
                    DiagnosticSettingsStatus = ""
                    DiagnosticSettingsCount = 0
                    SettingsDetails = ""
                    SupportsdiagnosticSettings = ""
                    Error = ""
                    ProcessedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }
                
                # Check if resource supports diagnostic settings using Azure API
                $supportResult = Get-DiagnosticsSupportCached -ResourceId $resource.ResourceId -ResourceType $resource.Type
                
                if ($supportResult.Supported -eq $true) {
                    $result.SupportsdiagnosticSettings = $true
                    
                    # Attempt to get diagnostic settings
                    $diagResult = Get-SafeDiagnosticSettings -ResourceId $resource.ResourceId
                    
                    if ($diagResult.Success) {
                        if ($diagResult.Settings -and $diagResult.Settings.Count -gt 0) {
                            $result.DiagnosticSettingsStatus = "Configured"
                            $result.DiagnosticSettingsCount = $diagResult.Settings.Count
                            
                            # Create detailed settings summary
                            $settingsDetails = @()
                            foreach ($setting in $diagResult.Settings) {
                                $details = "Name: $($setting.Name)"
                                if ($setting.WorkspaceId) { $details += " | Workspace: Yes" }
                                if ($setting.StorageAccountId) { $details += " | Storage: Yes" }
                                if ($setting.EventHubName) { $details += " | EventHub: Yes" }
                                $settingsDetails += $details
                            }
                            $result.SettingsDetails = $settingsDetails -join "; "
                            
                            Write-Host "  ✓ $($resource.Name) - Configured ($($diagResult.Settings.Count) setting(s))" -ForegroundColor Green
                        } else {
                            $result.DiagnosticSettingsStatus = "Not Configured"
                            Write-Host "  ⚠ $($resource.Name) - No diagnostic settings configured" -ForegroundColor Yellow
                        }
                    } else {
                        $result.DiagnosticSettingsStatus = "Error"
                        $result.Error = $diagResult.Error
                        Write-Host "  ✗ $($resource.Name) - Error checking settings: $($diagResult.Error)" -ForegroundColor Red
                    }
                } elseif ($supportResult.Supported -eq $false) {
                    $result.SupportsdiagnosticSettings = $false
                    $result.DiagnosticSettingsStatus = "Not Supported"
                    Write-Host "  ○ $($resource.Name) - Diagnostic settings not supported" -ForegroundColor Gray
                } else {
                    # Unknown support status due to error
                    $result.SupportsdiagnosticSettings = "Unknown"
                    $result.DiagnosticSettingsStatus = "Unknown"
                    $result.Error = $supportResult.Error
                    Write-Host "  ? $($resource.Name) - Unable to determine support: $($supportResult.Error)" -ForegroundColor Magenta
                }
                
                $results += $result
            }
        }
        catch {
            Write-Error "Error processing subscription $($subscription.Name): $($_.Exception.Message)"
            continue
        }
    }
    
    Write-Progress -Activity "Processing Resources" -Completed
    
    # Generate summary report
    Write-Host "`n" + "="*80 -ForegroundColor Cyan
    Write-Host "AUDIT SUMMARY" -ForegroundColor Cyan
    Write-Host "="*80 -ForegroundColor Cyan
    
    $summary = $results | Group-Object DiagnosticSettingsStatus | Select-Object Name, Count
    $summary | Format-Table -AutoSize
    
    $supportedResources = $results | Where-Object { $_.SupportsdiagnosticSettings -eq $true }
    $configuredResources = $results | Where-Object { $_.DiagnosticSettingsStatus -eq "Configured" }
    
    Write-Host "Total Resources Processed: $processedResources" -ForegroundColor White
    Write-Host "Resources Supporting Diagnostic Settings: $($supportedResources.Count)" -ForegroundColor White
    Write-Host "Resources with Diagnostic Settings Configured: $($configuredResources.Count)" -ForegroundColor Green
    
    # Display cache statistics
    $cacheStats = $script:DiagnosticsSupportCache.GetEnumerator() | Group-Object Value
    Write-Host "`nResource Type Support Cache:" -ForegroundColor Cyan
    foreach ($stat in $cacheStats) {
        $status = if ($stat.Name -eq "True") { "Supported" } else { "Not Supported" }
        Write-Host "  $status: $($stat.Count) resource types" -ForegroundColor White
    }
    
    if ($supportedResources.Count -gt 0) {
        $compliancePercentage = [math]::Round(($configuredResources.Count / $supportedResources.Count) * 100, 2)
        Write-Host "Compliance Percentage: $compliancePercentage%" -ForegroundColor $(if ($compliancePercentage -ge 80) { "Green" } elseif ($compliancePercentage -ge 60) { "Yellow" } else { "Red" })
    }
    
    # Export results if path specified
    if ($OutputPath) {
        Write-Host "`nExporting results to: $OutputPath" -ForegroundColor Yellow
        $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Export completed successfully!" -ForegroundColor Green
    }
    
    # Display resources that need attention
    $needsAttention = $results | Where-Object { 
        $_.SupportsdiagnosticSettings -eq $true -and $_.DiagnosticSettingsStatus -ne "Configured" 
    }
    
    if ($needsAttention.Count -gt 0) {
        Write-Host "`n" + "="*80 -ForegroundColor Yellow
        Write-Host "RESOURCES NEEDING ATTENTION ($($needsAttention.Count))" -ForegroundColor Yellow
        Write-Host "="*80 -ForegroundColor Yellow
        
        $needsAttention | Select-Object SubscriptionName, ResourceName, ResourceType, DiagnosticSettingsStatus | 
            Format-Table -AutoSize
    }
    
    Write-Host "`nAudit completed at: $(Get-Date)" -ForegroundColor Green
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
}
finally {
    # Clean up
    Write-Host "`nCleaning up..." -ForegroundColor Yellow
}
