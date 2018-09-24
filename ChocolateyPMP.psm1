# Filepath for presisting Sources for this provider
$script:PackageSourceFile = "$env:ProgramData\ChocolateyPMP\PackageSources.xml"

Function Get-PackageProviderName
{
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    # Returns the name of the provider
    Return "ChocolateyPMP"
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Initialize-Provider
{
    # Initialize provider before any actions are done 
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Find-Package 
{
    param(
        [string]
        $Name,
        [Version]
        $RequiredVersion,
        [Version]
        $MinimumVersion,
        [Version]
        $MaximumVersion
    )
    
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    
    # If -AllowPrereleaseVersions is supplied, create string for choco.exe 
    If($request.options.ContainsKey('AllowPrereleaseVersions'))
    {        
        $AllowPrereleaseVersionsString = "--prerelease"
    }    
    
    # If -Credentials is supplied, create username/password string for choco.exe 
    If ($request.Credential)
    {
        $CredentialString = "-u $($request.Credential.GetNetworkCredential().UserName) -p $($request.Credential.GetNetworkCredential().Password)"
    }

    # Get all Sources registred for this Provider
    $Sources = Resolve-PackageSource

    $Sources | 
        ForEach-Object {
            # Create Source string for choco.exe
            $Source = $_
            $SourceString = "-s $($Source.Location)"

            # If name of package to search for contains wildcards,
            # choco.exe search does not support that, so we need to change 
            # the string to search for and filter later.
            $NameContainsWildcards = Test-ContainsWildcard -String $Name 
            If ($NameContainsWildcards)
            {
                Write-Verbose "Name coantians wildcards"
                # Store the orogonal searrch name for later filtering
                $NameFilter = $Name
                # Grab the first non-empty part of the name to use as seach criteria
                $Name = ConvertFrom-WildcardPattern -WildcardPattern $Name |
                    Where-Object {$_} |
                    Select-Object -First 1
                Write-Verbose "Name = $Name"
                Write-Verbose "NameFilter = $NameFilter"
            }
            # Else we need to search for the exact name.
            Else
            {
                $ExactNameFilter = "--exact"
            }

            # Asking for spesific version IS supported by choco.exe search
            If ( $RequiredVersion )
            {
                $VersionFilter = "--version $RequiredVersion"
            }
            # Asking a minimum or maximum version IS NOT supported, so we need to ask for all versions and filter later
            ElseIf ( $MinimumVersion -or $MaximumVersion )
            {
                $VersionFilter = "--allversions"
            }

            # Seaching default for only name ("--by-id-only"), returning only a simple parsable list("-r"), and answering any prompts with yes ("-y")
            $Arguments = "search", 
                         $Name, 
                         "--by-id-only", # Searching default only by ID (unique name) of package
                         $VersionFilter, 
                         $ExactNameFilter, 
                         "--limitoutput", # Returning data from choco.exe in "|" delimited short form
                         "--yes", # Answering any prompt with yes
                         $CredentialString, 
                         $SourceString,
                         $AllowPrereleaseVersionsString
            Write-Verbose "Running choco.exe with arguments: $($Arguments -join " ")"
            &choco $Arguments |
                ConvertFrom-Csv -Delimiter "|" -Header "Name","Version" |
                # Post-search filtering for MaximumVersion
                Where-Object {
                    If ($MaximumVersion)
                    {
                        [version]$_.Version -le [version]$MaximumVersion
                    }
                    Else 
                    {
                        $True
                    }
                } |
                # Post-search filtering for MinimumVersion
                Where-Object {
                    If ($MinimumVersion)
                    {
                        [version]$_.Version -ge [version]$MinimumVersion
                    }
                    Else 
                    {
                        $True
                    }
                } |
                # Post-search filtering for Package name (id) containing wildcards
                Where-Object { 
                    If ($NameContainsWildcards)
                    {
                        Test-ContainsWildcardPattern -String $_.Name -WildcardPattern $NameFilter 
                    }
                    Else
                    {
                        $True
                    }
                } |
                # Go trough result of filters above and return results
                ForEach-Object {
                    If ($Request.IsCanceled)
                    {
                        break
                    }  
                    # If -DoNotReturnSummary is supplied, do not query again to retrive summary.
                    If($request.options.ContainsKey('DoNotReturnSummary'))
                    {        
                        $Summary = "-DoNotReturnSummary supplied, no summary is retrieved from source for package."
                    }
                    Else
                    {
                        # Create new search for more detailes
                        $SummaryArguments = $Arguments |
                            ForEach-Object {
                                If ($_ -eq "--limitoutput")
                                {
                                    "--verbose"
                                }
                                Else
                                {
                                    $_
                                }
                            }
                        Write-Verbose "Running choco.exe to get summary for package with argumets: $SummaryArguments"
                        $Summary = &choco $SummaryArguments | 
                            Select-String "^ Summary\: (.*)" |  
                            Select-Object -ExpandProperty Matches | 
                            Select-Object -ExpandProperty Groups | 
                            Select-Object -Last 1 | 
                            Select-Object -ExpandProperty Value                    
                    }    
                    $SWIDObject = @{
                        FastPackageReference = "$($_.Name)|#|$($_.Version)|#|$($Source.Name)|#|$($Source.Location)|#|$($Source.IsTrusted)"
                        Name = $_.Name
                        Version = [version]$_.Version
                        versionScheme  = "MultiPartNumeric"
                        summary = $Summary
                        Source = $Source.Name
                        FromTrustedSource = $Source.IsTrusted
                    }
                    New-SoftwareIdentity @swidObject              
                }
            }
    Write-Verbose -Message "Running $ModuleFunctionString"
}

function Install-Package
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FastPackageReference
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    $FastPackageReferenceObj = ConvertFrom-FastPackageReference -FastPackageReference $FastPackageReference
    # If -Credentials is supplied, create username/password string for choco.exe 
    If ($request.Credential)
    {
        $CredentialString = "-u $($request.Credential.GetNetworkCredential().UserName) -p $($request.Credential.GetNetworkCredential().Password)"
    }

    # Create Source string for choco.exe
    $SourceString = "-s $($FastPackageReferenceObj.SourceLocation)"
    $VersionFilter = "--version=$($FastPackageReferenceObj.Version)"

    # Install
    $Arguments = "install", 
                    $FastPackageReferenceObj.Name, 
                    $VersionFilter, 
                    "--limitoutput", # Returning data from choco.exe in "|" delimited short form
                    "--yes", # Answering any prompt with yes
                    "--no-progress", # Do not show the download progressstatus.
                    $CredentialString, 
                    $SourceString
    Write-Verbose "Running choco.exe with arguments: $($Arguments -join " ")"
    $Sucess = $False
    &choco $Arguments |
        ForEach-Object {
            If ($_) { Write-Verbose $_ }
            If ($_ -like "*already installed*")
            {
                $AlreadyInstalled = $_
            }
            ElseIf ($_ -like "*The install of $($FastPackageReferenceObj.Name) was successful*")
            {
                $Sucess = $True
            }
            If ($_ -like "*See the log for details*")
            {
                $LogInfo = $_
            }
        }
    Write-Verbose "choco.exe exitcode = $LASTEXITCODE"
    If ( $Sucess )
    {
        $SWIDObject = @{
            FastPackageReference = $FastPackageReference
            Name = $FastPackageReferenceObj.Name
            Version = [version]$FastPackageReferenceObj.Version
            versionScheme  = "MultiPartNumeric"
            Summary = $Summary
            Source = $FastPackageReferenceObj.SourceName
        }
        New-SoftwareIdentity @swidObject  
    }
    Else
    {
        ThrowError -ExceptionName "System.Exception" `
                    -ExceptionMessage "Package could not be installed. $AlreadyInstalled $LogInfo" `
                    -ErrorId OperationStopped `
                    -CallerPSCmdlet $PSCmdlet `
                    -ErrorCategory OperationStopped `
                    -ExceptionObject $FastPackageReferenceObj.Name        
         
         
    }

    Write-Verbose -Message "Ending $ModuleFunctionString"
}

function Uninstall-Package
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FastPackageReference
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    $FastPackageReferenceObj = ConvertFrom-FastPackageReference -FastPackageReference $FastPackageReference

    # UnInstall
    $Arguments = "uninstall", 
                    $FastPackageReferenceObj.Name, 
                    $VersionFilter, 
                    "--limitoutput", # Returning data from choco.exe in "|" delimited short form
                    "--yes", # Answering any prompt with yes
                    "--no-progress" # Do not show the download progressstatus.
    Write-Verbose "Running choco.exe with arguments: $($Arguments -join " ")"
    $Sucess = $False
    &choco $Arguments |
        ForEach-Object {
            If ($_) { Write-Verbose $_ }
            If ($_ -like "*is not installed*")
            {
                $AlreadyInstalled = $_
            }
            ElseIf ($_ -like "*$($FastPackageReferenceObj.Name) has been successfully uninstalled*")
            {
                $Sucess = $True
            }
            If ($_ -like "*See the log for details*")
            {
                $LogInfo = $_
            }
        }
    Write-Verbose "choco.exe exitcode = $LASTEXITCODE"
    If ( $Sucess )
    {
        $SWIDObject = @{
            FastPackageReference = $FastPackageReference
            Name = $FastPackageReferenceObj.Name
            Version = [version]$FastPackageReferenceObj.Version
            versionScheme  = "MultiPartNumeric"
            Summary = $Summary
            Source = $FastPackageReferenceObj.SourceName
        }
        New-SoftwareIdentity @swidObject  
    }
    Else
    {
        ThrowError -ExceptionName "System.Exception" `
                    -ExceptionMessage "Package could not be installed. $AlreadyInstalled $LogInfo" `
                    -ErrorId OperationStopped `
                    -CallerPSCmdlet $PSCmdlet `
                    -ErrorCategory OperationStopped `
                    -ExceptionObject $FastPackageReferenceObj.Name        
         
         
    }

    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Get-DynamicOptions
{
    param
    (
        [Microsoft.PackageManagement.MetaProvider.PowerShell.OptionCategory]
        $Category
    )

    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    switch($Category)
    {
        #Install
        #{
            #Write-Output -InputObject (
                #New-DynamicOption -Category $category -Name "Destination" -ExpectedType String -IsRequired $true
            #)
        #}
        Package
        {
            New-DynamicOption -Category $Category -Name "AllowPrereleaseVersions" -ExpectedType Switch -IsRequired $False
            New-DynamicOption -Category $Category -Name "DoNotReturnSummary" -ExpectedType Switch -IsRequired $False
        }
    }
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Resolve-PackageSource
{
    param(
        [string]
        $PackageSourceFile = "$env:ProgramData\ChocolateyPMP\PackageSources.xml"        
    )
    
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    If ($request.PackageSources)
    {
        $SourceName = $request.PackageSources
    }
    Else
    {
        $SourceName = "*"
    }

    # get Sources from the registered config file
    $PackageSources = Import-PackageSourceFromFile -PackageSourceFile $PackageSourceFile
    $PackageSources.GetEnumerator() |
        Where-Object {$_.Key -like $SourceName} |
        ForEach-Object {
            Write-Verbose "$($_.value.Name) -location $($_.value.location) -trusted $($_.value.Trusted) -registered $($_.value.Registered)"
            New-PackageSource -name $_.value.Name -location $_.value.location -trusted $_.value.Trusted -registered $_.value.Registered
        }

    Write-Verbose -Message "Ending $ModuleFunctionString"

}

function Add-PackageSource
{
    [CmdletBinding()]
    param
    (
        [string]
        $Name,
        [string]
        $Location,
        [bool]
        $Trusted
    )     

    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    # Get existing Package Sources from file
    $PackageSources = Import-PackageSourceFromFile -PackageSourceFile $PackageSourceFile

    # Convert Source info to custom object for storage. 
    # Needed as OneGet does not allow for rehydrated Microsoft.PackageManagement.Packaging.PackageSource
    $SourceProps = $PSBoundParameters
    $SourceProps["registered"] = $True
    $PackageSources[$Name] = New-PackageSourcePresistantObject @SourceProps

    # Presist the total sources to file
    $PackageSources | 
        Export-PackageSourceToFile

    # Output the package source to the pipeline
    New-PackageSource -name $Name -location $Location -trusted $Trusted -registered $True

    Write-Verbose -Message "Ending $ModuleFunctionString"
}

function Get-InstalledPackage
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $Name,
        [Parameter()]
        [string]
        $RequiredVersion,
        [Parameter()]
        [string]
        $MinimumVersion,
        [Parameter()]
        [string]
        $MaximumVersion
    )

    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    # If -AllowPrereleaseVersions is supplied, create string for choco.exe 
    If($request.options.ContainsKey('AllowPrereleaseVersions'))
    {        
        $AllowPrereleaseVersionsString = "--prerelease"
    }    
    
    # If -Credentials is supplied, create username/password string for choco.exe 
    If ($request.Credential)
    {
        $CredentialString = "-u $($request.Credential.GetNetworkCredential().UserName) -p $($request.Credential.GetNetworkCredential().Password)"
    }

    # Seaching default for only name ("--by-id-only"), returning only a simple parsable list("-r"), and answering any prompts with yes ("-y")
    $Arguments = "search", 
                    $Name, 
                    "--by-id-only", # Searching default only by ID (unique name) of package
                    "--localonly", # local search
                    $VersionFilter, 
                    $ExactNameFilter, 
                    "--limitoutput", # Returning data from choco.exe in "|" delimited short form
                    "--yes", # Answering any prompt with yes
                    $CredentialString, 
                    $AllowPrereleaseVersionsString
    Write-Verbose "Running choco.exe with arguments: $($Arguments -join " ")"
    &choco $Arguments |
        ConvertFrom-Csv -Delimiter "|" -Header "Name","Version" |
        # Post-search filtering for MaximumVersion
        Where-Object {
            If ($MaximumVersion)
            {
                [version]$_.Version -le [version]$MaximumVersion
            }
            Else 
            {
                $True
            }
        } |
        # Post-search filtering for MinimumVersion
        Where-Object {
            If ($MinimumVersion)
            {
                [version]$_.Version -ge [version]$MinimumVersion
            }
            Else 
            {
                $True
            }
        } |
        # Post-search filtering for Package name (id) containing wildcards
        Where-Object { 
            If ($NameContainsWildcards)
            {
                Test-ContainsWildcardPattern -String $_.Name -WildcardPattern $NameFilter 
            }
            Else
            {
                $True
            }
        } |
        # Go trough result of filters above and return results
        ForEach-Object {
            If ($Request.IsCanceled)
            {
                break
            }  
            # If -DoNotReturnSummary is supplied, do not query again to retrive summary.
            If($request.options.ContainsKey('DoNotReturnSummary'))
            {        
                $Summary = "-DoNotReturnSummary supplied, no summary is retrieved from source for package."
            }
            Else
            {
                # Create new search for more detailes
                $SummaryArguments = $Arguments |
                    ForEach-Object {
                        If ($_ -eq "--limitoutput")
                        {
                            "--verbose"
                        }
                        Else
                        {
                            $_
                        }
                    }
                Write-Verbose "Running choco.exe to get summary for package with argumets: $SummaryArguments"
                $Summary = &choco $SummaryArguments | 
                    Select-String "^ Summary\: (.*)" |  
                    Select-Object -ExpandProperty Matches | 
                    Select-Object -ExpandProperty Groups | 
                    Select-Object -Last 1 | 
                    Select-Object -ExpandProperty Value                    
            }    
            $SWIDObject = @{
                FastPackageReference = "$($_.Name)|#|$($_.Version)|#|Local Chocolatey install|#|Local Chocolatey install|#|True"
                Name = $_.Name
                Version = [version]$_.Version
                versionScheme  = "MultiPartNumeric"
                summary = $Summary
                Source = "Local Chocolatey install"
                FromTrustedSource = $true
            }
            New-SoftwareIdentity @swidObject              
        }

    Write-Verbose -Message "Ending $ModuleFunctionString"

}

Function Remove-PackageSource
{
    param
    (
        [string]
        $Name
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    # Get existing Package Sources from file
    $PackageSources = Import-PackageSourceFromFile -PackageSourceFile $PackageSourceFile

    # Remove Source by name
    $PackageSources.Remove($Name)

    # Presist the total sources to file
    $PackageSources | 
        Export-PackageSourceToFile

    Write-Verbose -Message "Ending $ModuleFunctionString"
}

# HELPER FUNCTIONS
Function Install-ChocolateyClient
{
    [cmdletbinding()]
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    $null = Invoke-WebRequest 'https://chocolatey.org/install.ps1' -UseBasicParsing | 
        Invoke-Expression
    Get-ChocolateyClient
    Write-Verbose -Message "Ending $ModuleFunctionString"

}

Function Get-ChocolateyClient
{
    [Cmdletbinding()]
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    $ChocoTestResult = @{
            IsInstalled = $null
            VersionInstalled = $null
    }    
    try
    {
        $ChocoTestResult.VersionInstalled = [version](&choco -v)
        $ChocoTestResult.IsInstalled = $true
    }
    catch
    {
        $ChocoTestResult.IsInstalled = $false
    }
    New-Object -TypeName PSobject -Property $ChocoTestResult
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Test-ContainsWildcard
{
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $String
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    return [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($String)    
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Test-ContainsWildcardPattern
{
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $String,
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [String]
        $WildcardPattern
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    
    $Pattern = [System.Management.Automation.WildcardPattern]::new($WildcardPattern,[System.Management.Automation.WildcardOptions]::IgnoreCase)
    return $Pattern.IsMatch($String)
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function ConvertFrom-WildcardPattern
{
    [CmdletBinding()]
    param(
        [String]
        $WildcardPattern
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    # Remove Wildcards *, ? and [] and convert rest to an array
    ($WildcardPattern -replace "\*|\?|(\[.*\])","|#|") -split "\|\#\|"
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Import-PackageSourceFromFile
{
    param(
        [string]
        $PackageSourceFile = "$env:ProgramData\ChocolateyPMP\PackageSources.xml"
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"
    try
    {
        $PackageSources = Import-Clixml -Path $PackageSourceFile 
    }
    catch
    {
    }
    If ($PackageSources -is [System.Collections.Specialized.OrderedDictionary] -or 
        $PackageSources -is [Hashtable])
    {
        $PackageSources
    }
    Else
    {
        [ordered]@{}
    }
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function Export-PackageSourceToFile
{
    [cmdletbinding()]
    param(
        # Expect Deserialized.System.Collections.Specialized.OrderedDictionary or
        #        System.Collections.Specialized.OrderedDictionary
        [parameter(Mandatory=$true,ValueFromPipeline=$true)]
        $PackageSource,
        [string]
        $PackageSourceFile = "$env:ProgramData\ChocolateyPMP\PackageSources.xml"
    )
    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    If ( -not (Test-Path -Path (Split-Path -Path $PackageSourceFile -Parent) -PathType Container ))
    {
        $null = New-Item -Path (Split-Path -Path $PackageSourceFile -Parent) -ItemType Directory
    }
    If ($PackageSources -is [System.Collections.Specialized.OrderedDictionary] -or 
        $PackageSources -is [Hashtable])
    {
        $PackageSource | 
            Export-Clixml -Path $PackageSourceFile -Force
    }
    Else
    {
        [ordered]@{} | 
            Export-Clixml -Path $PackageSourceFile -Force
    }    

    Write-Verbose -Message "Ending $ModuleFunctionString"

}

Function ConvertFrom-FastPackageReference
{
    [cmdletbinding()]
    param(
        [string]
        $FastPackageReference
    )

    $ModuleFunctionString = "$($MyInvocation.MyCommand.ModuleName)\$($MyInvocation.MyCommand.Name)"
    Write-Verbose -Message "Running $ModuleFunctionString"

    $FastPackageReferenceArr =  $FastPackageReference -split "\|\#\|"
    New-Object -TypeName PSobject -Property ([ordered]@{
        Name = $FastPackageReferenceArr[0]
        Version = $FastPackageReferenceArr[1]
        SourceName = $FastPackageReferenceArr[2]
        SourceLocation = $FastPackageReferenceArr[3]
        FromTrustedSource = ($FastPackageReferenceArr[4] -eq "true")
    })
    Write-Verbose -Message "Ending $ModuleFunctionString"
}

Function New-PackageSourcePresistantObject
{
    [Cmdletbinding()]
    param(
        [Parameter(Mandatory=$true)]
        [String]
        $Name,
        [Parameter(Mandatory=$true)]
        [String]
        $Location,
        [Parameter(Mandatory=$true)]
        [bool]
        $Trusted,
        [Parameter(Mandatory=$true)]
        [bool]
        $Registered
    )
    New-Object -TypeName PSCustomObject -Property $PSBoundParameters
}

function ThrowError
{
    param
    (        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCmdlet]
        $CallerPSCmdlet,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]        
        $ExceptionName,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ExceptionMessage,

        [System.Object]
        $ExceptionObject,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ErrorId,

        [parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.ErrorCategory]
        $ErrorCategory
    )

    $exception = New-Object $ExceptionName $ExceptionMessage;
    $errorRecord = New-Object System.Management.Automation.ErrorRecord $exception, $ErrorId, $ErrorCategory, $ExceptionObject    
    $CallerPSCmdlet.ThrowTerminatingError($errorRecord)
}