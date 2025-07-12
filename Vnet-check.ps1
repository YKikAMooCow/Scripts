# Prompt for SPN credentials
$tenantId = Read-Host "Enter Tenant ID"
$appId = Read-Host "Enter Application (Client) ID"
$appSecret = Read-Host "Enter Application Secret" -AsSecureString

$spnCredential = New-Object System.Management.Automation.PSCredential($appId, $appSecret)

Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $spnCredential

# Get all subscriptions the SPN has access to
$subscriptions = Get-AzSubscription

# Display the list of subscriptions to be processed
Write-Host "The following subscriptions will be processed:`n"
foreach ($subscription in $subscriptions) {
    Write-Host " - $($subscription.Name) ($($subscription.Id))"
}

# Ask for user confirmation
$confirmation = Read-Host "`nDo you want to continue? (Y/N) [Default: N]"
if ($confirmation.ToUpper() -ne "Y") {
    Write-Host "Operation cancelled by user."
    exit
}

# Prepare a list of changes to be made
$changes = @()

foreach ($subscription in $subscriptions) {
    Set-AzContext -SubscriptionId $subscription.Id

    $vNets = Get-AzVirtualNetwork

    foreach ($vNet in $vNets) {
        foreach ($subnet in $vNet.Subnets) {
            $needsChange = $false
            if ($subnet.PSObject.Properties.Name -contains "DefaultOutboundAccess") {
                if ($subnet.DefaultOutboundAccess -ne $false) {
                    $needsChange = $true
                }
            } else {
                $needsChange = $true
            }
            if ($needsChange) {
                $changes += [PSCustomObject]@{
                    Subscription = $subscription.Name
                    VNet        = $vNet.Name
                    Subnet      = $subnet.Name
                }
            }
        }
    }
}

if ($changes.Count -eq 0) {
    Write-Host "`nNo subnet changes are required. Exiting."
    exit
}

Write-Host "`nThe following subnet changes will be made:`n"
$changes | ForEach-Object {
    Write-Host "Subscription: $($_.Subscription) | VNet: $($_.VNet) | Subnet: $($_.Subnet)"
}

# Confirm with user before making changes
$changeConfirmation = Read-Host "`nDo you want to apply these changes? (Y/N) [Default: N]"
if ($changeConfirmation.ToUpper() -ne "Y") {
    Write-Host "Operation cancelled by user."
    exit
}

# Now perform the changes
foreach ($subscription in $subscriptions) {
    Set-AzContext -SubscriptionId $subscription.Id

    Write-Host "Processing subscription: $($subscription.Name)"

    $vNets = Get-AzVirtualNetwork

    foreach ($vNet in $vNets) {
        $updated = $false
        foreach ($subnet in $vNet.Subnets) {
            if ($subnet.PSObject.Properties.Name -contains "DefaultOutboundAccess") {
                if ($subnet.DefaultOutboundAccess -ne $false) {
                    $subnet.DefaultOutboundAccess = $false
                    $updated = $true
                    Write-Host "Updated DefaultOutboundAccess for subnet $($subnet.Name) in vNet $($vNet.Name)"
                }
            } else {
                $subnet | Add-Member -NotePropertyName "DefaultOutboundAccess" -NotePropertyValue $false
                $updated = $true
                Write-Host "Set DefaultOutboundAccess for subnet $($subnet.Name) in vNet $($vNet.Name)"
            }
        }
        if ($updated) {
            Set-AzVirtualNetwork -VirtualNetwork $vNet
        }
    }
}
