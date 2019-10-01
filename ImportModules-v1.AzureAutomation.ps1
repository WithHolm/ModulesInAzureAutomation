<#
.SYNOPSIS
Function for updating AZ modules in the Azure automation account.

.DESCRIPTION
Function which is downloading all Az modules from the Powershell gallery, creating temporary blob on Azure, hosting them and uploading
them to Azure automation account. After this is done for all of the modules, storage account is being destroyed.

.PARAMETER AutomationAccount
Name of the automation account where you want to update/import AZ set of modules.

.EXAMPLE
Update-AzAutomationModule -AutomationAccount nemanjajovicautomation
#>
<#
.SYNOPSIS
Function for importing and updating modules in the Azure automation account.

.DESCRIPTION
Function which is downloading modules from the Powershell gallery, creating temporary blob on Azure, hosting them and uploading
them to Azure automation account. 
After this is done for the defined modules, dispose storage account and local storage folder.
This is 

.PARAMETER AutomationAccountName
Parameter description

.PARAMETER ModuleName
Parameter description

.PARAMETER MaximumVersion
Parameter description

.PARAMETER ForceVersion
Parameter description

.PARAMETER SkipImportTest
Parameter description

.PARAMETER WaitForCompletion
Parameter description

.PARAMETER MaxJobs
Parameter description

.EXAMPLE
An example

.NOTES
General notes
#>

Function Import-AzAutomationModule {
    [CmdletBinding()]
    param (
        # Name of the automation account that you want to target.
        [Parameter(Mandatory = $true,
            Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$AutomationAccountName,
        [string]$ModuleName,
        [version]$MaximumVersion,
        [switch]$ForceVersion,
        [switch]$SkipImportTest,
        [switch]$WaitForCompletion,
        [int]$MaxJobs = 20
    )
    process {
        Write-verbose "Testing the avaliability of Automation Account '$AutomationAccount'"
        $FindAccount = Get-AzAutomationAccount | Where-Object { $_.AutomationAccountName -eq "$AutomationAccount" }
        if ([string]::IsNullOrWhiteSpace($FindAccount)) {
            Write-Error "Cannot find instance of the Automation Account '$AutomationAccount'. Terminating!"
            Break
        }
        try {
            $ErrorActionPreference = 'Stop'

            Write-verbose "Getting Modules present in Automation Account '$AutomationAccount'"
            $AutomationModules = $findaccount|Get-AzAutomationModule
            Write-verbose "Getting '$ModuleName' modules from psgallery"
            if($MaxVersion)
            {
                $TempModuleList = @(Find-Module $ModuleName -IncludeDependencies -MaximumVersion $MaximumVersion.ToString())
            }
            else {
                
                $TempModuleList = @(Find-Module $ModuleName -IncludeDependencies)
            }

            Write-Verbose "Filtering list"
            $AzModuleList = $TempModuleList|sort-object name -Unique|%{
                $process = $true
                $Module = $_
                
                #Test if Moduleversion should be installed?
                #$module.AdditionalMetadata.PowerShellVersion 
                $Automationmodule = $AutomationModules|?{$_.name -like $module.name -and $_.ProvisioningState -ne "Failed"}
                if($AutomationModule)
                {
                    if($automationmodule.version -eq $module.version -and !$forceversion)
                    {
                        Write-verbose "Skipping module: '$($module.name)'. Version '$($module.version)' is already installed."
                        $process = $false
                    }
                    elseif($automationmodule.version -gt $module.version -and !$forceversion)
                    {
                        Write-verbose "Skipping module: '$($module.name)' at newer version. Automation Version:$($automationmodule.version), Importing Version:'$($module.version)'"
                        $process = $false
                    }
                }

                #If module would be processed
                if($process)
                {
                    [pscustomobject]@{
                        Name = $module.name
                        Value = $module
                        DependCount = @($_.Dependencies).count
                    }
                }
            }|sort-object name -Unique |Sort-Object DependCount

            Write-verbose "$(@($azmodulelist).count) modules to be processed"
            if($(@($azmodulelist).count) -eq 0)
            {
                return
            }

            #Creating TempFolder
            $TempFolder = (join-path $pwd.path (get-random -Minimum 1000 -Maximum 9999))
            Write-verbose "Creating tempfolder to store modules:'$tempfolder'"
            new-item $TempFolder -ItemType Directory -Force|Out-Null

            #Creating BlobStorage
            <#
                This should really be a static blobstorage so you wouldnt have to define this each time.. but... mabye in the future.. right?
            #>
            $StorageAccountSplat = @{
                Name = $(Get-Random)
                ResourceGroupName = $FindAccount.ResourceGroupName
                Location = $FindAccount.Location
                SkuName = 'Standard_LRS'
            }
            Write-Verbose "Creating Storageaccount: '$($StorageAccountSplat.name)' at RG $($StorageAccountSplat.ResourceGroupName)"
            $StorageAccount = New-AzStorageAccount @StorageAccountSplat
            $StorageKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageAccount.ResourceGroupName -StorageAccountName $StorageAccount.StorageAccountName)[0].Value
            $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -StorageAccountKey $StorageKey
            Write-Verbose "Creating storageconatiner"
            $StorageContainer = New-AzStorageContainer -Name $(Get-Random) -Context $StorageContext -Permission Blob
            
            #Saving Modules to disk
            $SB={
                $Module = $args[0]
                $SavePath = (join-path $args[1] $module.name)
                new-item -Path $SavePath -Force -ItemType Directory|Out-Null
                Write-output "JOB: saving '$($module.name)' to local machine"
                $Module|save-module -Path $SavePath -force -AcceptLicense
                
                start-sleep -Seconds 3

                $CompressSplat = @{
                    Path = "$SavePath\$($Module.Name)\"
                    DestinationPath = "$($args[1])\$($Module.Name).zip"
                    ErrorAction = 'Stop'
                    Update = $true
                }
                Write-Output "JOB: Compressing archive for $($module.name)"
                Compress-Archive @CompressSplat
            }
            get-job|Remove-Job -Force
            $count = 0
            $AzModuleList|%{
                $count++
                $Module = $_.value
                write-verbose "[$count/$(@($AzModuleList).count)] Starting download,compress,upload,import job for $($module.name)"
                while(@($(get-job|?{$_.state -ne "completed"})).count -ge $MaxJobs)
                {
                    write-verbose "waiting 10 sec...Max jobs:$MaxJobs" 
                    start-sleep -Seconds 10
                }
                Start-Job -ScriptBlock $SB -name $module.name -ArgumentList @($module,$tempfolder)|Out-Null #,$StorageContainer,$StorageKey,$StorageAccount.StorageAccountName,$FindAccount) -name $module.name|out-null
            }
            get-job|Receive-Job -Wait|%{
                write-verbose $_
            }



            $count = 0
            foreach($mod in $AzModuleList)
            {
                $item = get-item "$(join-path $TempFolder $mod.name).zip"
                $count++
                $UploadSplat = @{
                    Container = $StorageContainer.Name
                    Context = $StorageContext
                    File = $item.FullName
                    Confirm = $false
                }
                Write-verbose "[$count/$(@($AzModuleList).count)] Uploading $($Item.name) to blob"
                $FileUpload = Set-AzStorageBlobContent @UploadSplat -verbose:$false
                $ImportSplat = @{
                    Name = $($Item.BaseName)
                    ResourceGroupName = $FindAccount.ResourceGroupName
                    AutomationAccountName = $FindAccount.AutomationAccountName
                    ContentLinkUri = $FileUpload.ICloudBlob.Uri.OriginalString # "$($FileUpload.Context.BlobEndPoint)$($StorageContainer.Name)/$($FileUpload.Name)"
                }
                Write-verbose "[$count/$(@($AzModuleList).count)] Importing module to Automation Account '$automationaccount', contentlink = $($ImportSplat.ContentLinkUri)"
                [void](Import-AzAutomationModule @ImportSplat)
            }

            if($WaitForCompletion)
            {
                # Write-Verbose "Waiting for completion"
                $Wait = $true
                while($wait)
                {
                    $waitseconds = 20
                    Start-Sleep -Seconds $waitseconds
                    $CreatingCount = @($findaccount|Get-AzAutomationModule|?{$_.name -in @($AzModuleList).name -and $_.ProvisioningState -ne "Creating"}).count
                    $wait = [bool](@($AzModuleList).count-$CreatingCount)
                    if($wait)
                    {
                        Write-Verbose "$([datetime]::now.Tostring('hh:mm:ss').replace(".",":")) Waiting for completion of $CreatingCount/$(@($AzModuleList).count) modules. Checking in $waitseconds seconds"
                    }
                }
                $StrLength = @($AzModuleList).name|%{$_.length}|sort-object -Descending|select -first 1
                $findaccount|Get-AzAutomationModule|?{$_.name -in @($AzModuleList).name}|%{
                    Write-Verbose "$($_.name.padright($strlength)) = $($_.ProvisioningState)"
                }
            }
        }
        catch {
            Write-Warning $_
            # Write-Error "$_" -ErrorAction Stop
        }
        finally{
            if($StorageAccount)
            {
                Write-Verbose "Removing temp blobstorage '$($StorageAccount.Id)'"
                $StorageAccount|Remove-AzStorageAccount -Force
            }
            # Remove-AzStorageAccount $StorageAccount.StorageAccountName -ResourceGroupName $StorageAccount.ResourceGroupName -Confirm:$false -Force
            Write-Verbose "Removing local temp path '$tempfolder'"
            get-item $TempFolder|remove-item -Recurse -Force
        }
    }
}

Update-AzAutomationModule -AutomationAccount "Philautomation" -Verbose -ModuleName az  -WaitForCompletion