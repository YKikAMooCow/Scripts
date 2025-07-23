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

foreach ($subscription in $subscriptions) {
    Write-Host "`nProcessing subscription: $($subscription.Name) ($($subscription.Id))"
    Set-AzContext -SubscriptionId $subscription.Id

    # Get all resources in the subscription
    $resources = Get-AzResource

    foreach ($resource in $resources) {
        # Check if the resource supports diagnostic settings
        try {
            $diagSettings = Get-AzDiagnosticSetting -ResourceId $resource.ResourceId -ErrorAction SilentlyContinue
            if ($diagSettings) {
                Write-Host "`nResource: $($resource.Name) ($($resource.Type))"
                Write-Host "Diagnostic settings configured:"
                $diagSettings | Format-List
            } else {
                Write-Host "`nResource: $($resource.Name) ($($resource.Type))"
                Write-Host "No diagnostic settings configured."
            }
        } catch {
            # Resource does not support diagnostic settings
            Write-Host "`nResource: $($resource.Name) ($($resource.Type))"
            Write-Host "Diagnostic settings not supported for this resource."
        }
    }
}
