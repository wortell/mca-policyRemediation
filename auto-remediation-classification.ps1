[cmdletbinding()]
param(
    [Parameter(Mandatory = $true)]
    $rootManagementGroup
)

$policies = @('McaClassificationTagGold', 'McaClassificationTagSilver', 'McaClassificationTagBronze', 'McaClassificationTagInformational')

#region connect to Azure
try {
    Connect-AzAccount -Identity
} catch {
    Write-Error "Unable to connect to Azure.`n$_"
    exit 1
}
#endregion

#region create a variable to make sure no errors have occurred during the run.
$problemsOccurred = $false
#endregion

$params = @{
    managementGroupId = $rootManagementGroup
}

#region loading functions
function Start-PolicyRemediationMgSubscription {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, HelpMessage = 'Name of the management group to get subscriptions from.')]
        [string]$managementGroupId,

        [Parameter(Mandatory = $true, Position = 1, HelpMessage = 'Name of the policy to assign.')]
        [string]$policyName
    )
    begin {
        # Function to get all subscriptions in a management group
        function Get-AllMgSubscriptions {
            [cmdletbinding()]
            param (
                [Parameter(Mandatory = $true, HelpMessage = 'Management Group Name to query for subscriptions.')]
                [string]$ManagementGroupId
            )
    
            try {
                $rootManagementGroup = Get-AzManagementGroup -GroupName $ManagementGroupId -Expand -Recurse -ErrorAction Stop
            } catch {
                Write-Error "Failed to get management group info for '$ManagementGroupId'.`n$($_.Exception.Message)"
                throw
            }
    
            # Create a collection to store all information in 
            $subscriptionInfo = [System.Collections.Generic.List[pscustomobject]]::new()
    
            # Create a variable to store the level of the subscription in the management group hierarchy
            $level = 0
    
            # Get the home tenant id
            $homeTenantId = $rootManagementGroup.TenantId
    
            # Loop through the subscriptions in the root management group
            foreach ($subscription in $rootManagementGroup.Children.where({$_.Type -match 'subscriptions'})) {
                $info = [pscustomobject]@{
                    SubscriptionName  = $subscription.DisplayName
                    SubscriptionId    = $subscription.Name
                    ParentMg          = $rootManagementGroup.DisplayName
                    TenantId          = $homeTenantId
                    SubscriptionLevel = $level
                }
                $subscriptionInfo.Add($info)
            }
    
            # Loop through the management groups in the root management group, untill there are no more management groups
            while ($rootManagementGroup.Children.where({$_.Type -match 'managementGroups'}).Count -gt 0) {
                $level++
                foreach ($managementGroup in $rootManagementGroup.Children.where({$_.Type -match 'managementGroups'})) {
                    foreach ($subscription in $managementGroup.Children.where({$_.Type -match 'subscriptions'})) {
                        $info = [pscustomobject]@{
                            SubscriptionName  = $subscription.DisplayName
                            SubscriptionId    = $subscription.Name
                            ParentMg          = $managementGroup.DisplayName
                            TenantId          = $homeTenantId
                            SubscriptionLevel = $level
                        }
                        $subscriptionInfo.Add($info)
                    }
                }
                $rootManagementGroup = $rootManagementGroup.Children.where({$_.Type -match 'managementGroups'})
            }
    
            # Output the information
            $subscriptionInfo
        }

        Write-Verbose "Management Group set - Getting subscriptions in management group '$managementGroupId'"
        # Getting all subscriptions in a management group
        try {
            $subscriptions = Get-AllMgSubscriptions -ManagementGroupId $managementGroupId -ErrorAction Stop
        } catch {
            Write-Error "Failed to get subscriptions in management group '$managementGroupId': $_"
            exit 1
        }
    }
    process {
        # Assigning the policy to all subscriptions
        foreach ($subscription in $subscriptions) {
            Write-Output "Remediating policy '$policyName' for subscription '$($subscription.SubscriptionName)'"

            $assignmentName = "{0}-{1}" -f $policyName, $subscription.SubscriptionName
            if ($assignmentName.Length -gt 64) {
                $assignmentName = $assignmentName.Substring(0, 64)
            }
            $assignmentParams = @{
                Name  = $assignmentName
                Scope = "/subscriptions/$($subscription.SubscriptionId)"
            }

            try {
                $policyAssignment = Get-AzPolicyAssignment @assignmentParams
            } catch {
                Write-Error "Failed to get policy assignment '$policyName' for subscription '$($subscription.SubscriptionName)': $_"
                $problemsOccurred = $true
                continue # Continue with the next subscription even if one fails
            }

            if ($policyAssignment) {
                try {
                    Set-AzContext -SubscriptionId $subscription.SubscriptionId -ErrorAction Stop
                    $remediateParams = @{
                        Name               = $policyAssignment.Name
                        policyAssignmentId = $policyAssignment.PolicyAssignmentId
                        # Scope              = $policyAssignment.ResourceId
                        AsJob              = $true
                        ErrorAction        = 'Stop'
                    }
                    try {
                        Start-AzPolicyRemediation @remediateParams
                    } catch {
                        Write-Error "Failed to remediate policy assignment '$($policyAssignment.Name)' in subscription '$($subscription.SubscriptionName)': $_"
                        $problemsOccurred = $true
                        continue # Continue with the next subscription even if one fails
                    }
                } catch {
                    Write-Error "Failed to set context to subscription '$($subscription.SubscriptionName)': $_"
                    $problemsOccurred = $true
                    continue # Continue with the next subscription even if one fails
                }
            }
        }
    } 
    end {
        if ($problemsOccurred) {
            "One or more policies failed to remediate"
            throw
        }
    }
}
#endregion

foreach ($policy in $policies) {
    $params.policyName = $policy
    Start-PolicyRemediationMgSubscription @params
}
