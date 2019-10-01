
# Checks the PowerShell Gallery for the latest available version for the module
function Get-ModuleDependencyAndLatestVersion{
    param(
        [parameter(Mandatory=$true)]
        [string] $ModuleName,
        [string] $PsGalleryApiUrl='https://www.powershellgallery.com/api/v2',
        [String] $Maximumversion
    )

    $ModuleUrlFormat = "$PsGalleryApiUrl/Search()?`$filter={1}&searchTerm=%27{0}%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"
   
    $ModuleVersionOverridesHashTable = ConvertJsonDictTo-HashTable $ModuleVersionOverrides
    $ForcedModuleVersion = $ModuleVersionOverridesHashTable[$ModuleName]
    $CurrentModuleUrl =
        if ($ForcedModuleVersion) {
            $ModuleUrlFormat -f $ModuleName, "Version%20eq%20'$ForcedModuleVersion'"
        } else {
            $ModuleUrlFormat -f $ModuleName, 'IsLatestVersion'
        }

    $SearchResult = Invoke-RestMethod -Method Get -Uri $CurrentModuleUrl -UseBasicParsing

    if (!$SearchResult) {
        Write-Verbose "Could not find module $ModuleName on '$PsGalleryApiUrl'. This may be a module you imported from a different location. Ignoring this module"
    } else {
        if ($SearchResult.Length -and $SearchResult.Length -gt 1) {
            $SearchResult = $SearchResult | Where-Object { $_.title.InnerText -eq $ModuleName }
        }

        if (!$SearchResult) {
            Write-Verbose "Could not find module $ModuleName on PowerShell Gallery. This may be a module you imported from a different location. Ignoring this module"
        } else {
            $PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id
            $ModuleVersion = $PackageDetails.entry.properties.version
            $DependencyString = $PackageDetails.entry.properties.dependencies
            $Dependencies = [ordered]@{}

            #dependencystring ="Az.Accounts:[1.6.2, ):|Az.Advisor:[1.0.1, 1.0.1]:|Az.Aks:[1.0.2, 1.0.2]:" etc....
            $DependencyString.split("|")|%{
                #"Az.Accounts:[1.6.2, ):" --split--> "Az.Accounts","[1.6.2, )",""
                $Dep = $_.split(":")

                #"[1.6.2, )" --Replace--> "1.6.2, " --split--> "1.6.2"," " --trim--> "1.6.2"," " --Where not null or empty--> "1.6.2"
                $Dependencies.$($dep[0]) = @(($Dep[1] -replace "\[|\]|\)|\(","").split(",")|%{$_.trim()}|?{$_})
            }
            [pscustomobject]@{
                Name = ""
                Version = $ModuleVersion
                Dependencies = @()
                Dependencycount = 0
            }
            @($ModuleVersion, $Dependencies)
        }
    }
}

function ConvertJsonDictTo-HashTable($JsonString) {
    try{
        $JsonObj = ConvertFrom-Json $JsonString -ErrorAction Stop
    } catch [System.ArgumentException] {
        throw "Unable to deserialize the JSON string for parameter ModuleVersionOverrides: ", $_
    }

    $Result = @{}
    foreach ($Property in $JsonObj.PSObject.Properties) {
        $Result[$Property.Name] = $Property.Value
    }

    $Result
}

Get-ModuleDependencyAndLatestVersion -ModuleName az -Verbose