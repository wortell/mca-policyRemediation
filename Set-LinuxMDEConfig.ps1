Disable-AzContextAutosave -Scope Process | Out-Null

# Login to Azure platform
try {
    Write-Output "Logging into Azure with System-assigned Identity"
    Connect-AzAccount -Identity -ErrorAction 'Stop' | Out-Null

    Write-Output "Successfully logged into the Azure Platform."
}
catch {
    Write-Error "Login error: Logging into azure Failed...`n$($_.Exception.Message)"
    throw
}

# External URL
$mdatpConfigFileUrl = "https://raw.githubusercontent.com/wortell/mca-policyRemediation/refs/heads/main/mdatp-managed.json"

# Define the script to run on each VM
$script = @"
curl -o /etc/opt/microsoft/mdatp/managed/mdatp_managed.json "$mdatpConfigFileUrl"
"@

# Define the default parameters for the Set-AzVMRunCommand cmdlet
$params = @{
    RunCommandName = "ConfigureMDATP"
    SourceScript   = $script
}

$subscriptions = Get-AzSubscription

$subscriptions | ForEach-Object {
    $subscription = $PSItem
    Set-AzContext -Subscription $subscription | Out-Null
    Write-Output "Subscription: $($subscription.Name) on tenant: $($subscription.TenantId)"

    # Get all Linux VMs in the subscription including status
    Write-Output "Getting all Linux VMs in the subscription including status..."
    $linuxVMs = Get-AzVM -Status | Where-Object { $_.StorageProfile.OSDisk.OSType -eq 'Linux' }

    # Execute the script on each running Linux VM
    foreach ($vm in $linuxVMs) {
        # Check if the VM is running
        if ($vm.PowerState -eq 'VM running') {
            Write-Output "Running the script on $($vm.Name)..."
            $result = Set-AzVMRunCommand @params -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -Location $vm.Location

            # Check the status of the run command
            if ($result.ProvisioningState -eq 'Succeeded') {
                # Get the output of the run command
                $output = Get-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -RunCommandName $params.RunCommandName -Expand InstanceView

                Write-Output "Successfully ran the script on $($vm.Name)."

                # Create a custom object with VM name and selected properties
                $selectedProperties = [PSCustomObject]@{
                    VMName         = $vm.Name
                    ExecutionState = $output.InstanceView.ExecutionState
                    ExitCode       = $output.InstanceView.ExitCode
                }
                # Output the custom object as JSON
                Write-Output $selectedProperties | Out-String
            }
            else {
                Write-Error "Failed to run the script on $($vm.Name)."
            }
        }
        else {
            Write-Output "Skipping $($vm.Name) as it is not running."
        }
    }
}
