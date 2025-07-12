# Prompt for SPN credentials
$tenantId = Read-Host "Enter Tenant ID"
$appId = Read-Host "Enter Application (Client) ID"
$appSecret = Read-Host "Enter Application Secret" -AsSecureString

$spnCredential = New-Object System.Management.Automation.PSCredential($appId, $appSecret)

Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $spnCredential

# Get all virtual networks in the subscription
$vNets = Get-AzVirtualNetwork

foreach ($vNet in $vNets) {
    $updated = $false
    foreach ($subnet in $vNet.Subnets) {
        # Check if DefaultOutboundAccess property exists
        if ($subnet.PSObject.Properties.Name -contains "DefaultOutboundAccess") {
            if ($subnet.DefaultOutboundAccess -ne $false) {
                $subnet.DefaultOutboundAccess = $false
                $updated = $true
                Write-Host "Updated DefaultOutboundAccess for subnet $($subnet.Name) in vNet $($vNet.Name)"
            } else {
                Write-Host "DefaultOutboundAccess already set to false for subnet $($subnet.Name) in vNet $($vNet.Name)"
            }
        } else {
            # Add the property if it doesn't exist
            $subnet | Add-Member -NotePropertyName "DefaultOutboundAccess" -NotePropertyValue $false
            $updated = $true
            Write-Host "Set DefaultOutboundAccess for subnet $($subnet.Name) in vNet $($vNet.Name)"
        }
    }
    # Only update the vNet if any subnet was changed
    if ($updated) {
        Set-AzVirtualNetwork -VirtualNetwork $vNet
    }
}