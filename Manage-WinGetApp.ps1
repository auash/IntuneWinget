<#
.DESCRIPTION
   A wrapper for Winget designed for use with Intune.
.EXAMPLE
   powershell.exe -ep bypass -file Manage-WinGetApps.ps1 -AppId Microsoft.VisualStudioCode
.EXAMPLE
   powershell.exe -ep bypass -file Manage-WinGetApps.ps1 -AppName "Microsoft Visual Studio Code"
.EXAMPLE
   powershell.exe -ep bypass -file Manage-WinGetApps.ps1 -AppName "Microsoft Visual Studio Code" -Action Uninstall
.EXAMPLE 
   powershell.exe -ep bypass -file Manage-WinGetApps.ps1 -AppId Microsoft.VisualStudioCode -LogFolder "C:\Temp\" -Version 1.62.3 -proxy "webproxy.organisation.internal:8080" -TimeoutMinutes 15
.NOTES
#>

param
(
    [parameter(Position = 0)]
    [string]$AppId,

    [parameter()]
    [string]$AppName,


    [parameter()]
    [ValidateNotNullOrEmpty()]
    [validateSet("Install", "Uninstall")]
    [string]$Action = "Install",

    [parameter(HelpMessage="Provide the full path to a folder for logs to be stored in. eg: 'C:\Windows\Logs\'")]
    [string]$LogFolder = "$($env:ALLUSERSPROFILE)\Intune Winget Logs\",

    [parameter(HelpMessage="Force a specific version of an application to install.")]
    [string]$Version,


    [parameter(HelpMessage="Value to be in the format of 'address:port'. eg: 'proxy.organisation.com:8080'. Only used if the Intune Application is configured to run as SYSTEM.")]
    [string]$Proxy,

    [parameter(HelpMessage="The maximum amount of time this script will wait for winget to exit. Default is 30 minutes.")]
    [int]$TimeoutMinutes = 30,

    [parameter(HelpMessage="Specify any additional winget arguments not already provided by this script. The string you provide here will be appended as is. Ensure you do not specify any arguments already controlled by this script.")]
    [string]$CustomArgs

)
Process
{

    # c# class that calls winget and handles the output of winget
    $CommandExecutionHandler = @"
        using System;
        using System.Diagnostics;
        using System.IO;

        namespace WingetWrapper
        {
            public static class Execute
            {
                private static string _LogFilePath;

                public static int Command(string ExecutablePath, string Args, string LogFilePath, int TimeoutMinutes = 60) 
                {
                    if (String.IsNullOrEmpty(LogFilePath))
                    {
                        throw new Exception("No log file path provided");
                    }

                    _LogFilePath = LogFilePath;

                    //* Create your Process
                    Process process = new Process();
                    process.StartInfo.FileName = ExecutablePath;
                    process.StartInfo.UseShellExecute = false;
                    process.StartInfo.CreateNoWindow = true;
                    process.StartInfo.RedirectStandardOutput = true;
                    process.StartInfo.RedirectStandardError = true;

                    //* Optional process configuration
                    if (!String.IsNullOrEmpty(Args)) { process.StartInfo.Arguments = Args; }

                    //* Set your output and error (asynchronous) handlers
                    process.OutputDataReceived += new DataReceivedEventHandler(OutputHandler);
                    process.ErrorDataReceived += new DataReceivedEventHandler(OutputHandler);

                    //* Start process and handlers
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    process.WaitForExit(TimeoutMinutes * 60 * 1000);

                    //* Return the commands exit code
                    return process.ExitCode;
                }
                public static void OutputHandler(object sendingProcess, DataReceivedEventArgs outLine) 
                {
                    //* Do your stuff with the output (write to console/log/StringBuilder)
                    lock (_LogFilePath)
                    {
                        File.AppendAllLines(_LogFilePath, new string[] {outLine.Data});
                    }
                }
            }
        }
"@

    # load the c# code above if it hasn't been loaded already
    if (-not ([System.Management.Automation.PSTypeName]'WingetWrapper.Execute').Type)
    {
        Add-Type -TypeDefinition $CommandExecutionHandler -Language CSharp -ErrorAction Stop
    }
     

    Function Capture-SystemProxySettings()
    {
        $RawNetshOutput = netsh winhttp show proxy

        if ($RawNetshOutput.Count -eq 5 -and $RawNetshOutput[3] -like "*no proxy server*")
        {
            $ProxySettings.ProxyWasSet = $false
        }
        elseif ($RawNetshOutput.Count -eq 6 -and $RawNetshOutput[3] -like "*Proxy Server(s)*" -and $RawNetshOutput[4] -like "*Bypass List*")
        {
            try
            {
                $ProxyServer = $RawNetshOutput[3].Split(":")[1].Trim()
                $BypassList = $RawNetshOutput[4].Split(":")[1].Trim()
                if ($BypassList -like "*(none)*")
                {
                    $BypassList = [string]::Empty
                }
            }
            catch
            {
                throw "Failed to capture proxy settings"
            }

            $ProxySettings.ProxyWasSet = $true
            $ProxySettings.ProxyServer = $ProxyServer
            $ProxySettings.BypassList = $BypassList
        }
        else
        {
            Write-Log "An unexpected value was returned from 'netsh winhttp show proxy'."
            Write-Log "Line count of output: $($RawNetshOutput.Count)"
            Write-Log "The output received:"
            $RawNetshOutput
            throw "Failed to capture proxy settings"
        }
    }

    Function Write-Log($String)
    {
        # Simple log function
        Add-Content -Path $WrapperLogFile -Value ("$( (Get-Date).ToString("yyyy/MM/dd hh:mm:ss:fff")) - $String")
    }



    # Specify the default wrapper log file path. If an AppId or AppName are not specified, then this path is used. When proper parameters are supplied, this variable will be changed later on to an app-specific path.
    $WrapperLogFile = (Join-Path -Path $LogFolder -ChildPath "$($Action) - UNKNOWN - Wrapper.log")


    # In the user context, 'winget.exe' can be called from anywhere. In the SYSTEM context, it cannot. For SYSTEM installs additional work is required to find the winget.exe file. By default we specify the user-context executable.
    $winget = "winget.exe" 


    # Object used to store pre-script proxy settings (if required)
    $ProxySettings = [PSCustomObject]@{
        ProxyWasSet  = $false
        ProxyServer = [string]::Empty
        BypassList  = [string]::Empty
    }


    # Create the log folder if it doesnt already exist
    if (-not (Test-Path $LogFolder))
    {
        New-Item -Path $LogFolder -ItemType Directory -ErrorAction Stop | Out-Null
    }


    # Confirm an AppId or AppName has been provided
    if ([string]::IsNullOrWhiteSpace($AppId) -and [string]::IsNullOrWhiteSpace($AppName))
    {
        Write-Log "ERROR: You have not provided an AppId or AppName. You must specify one of these."
        Exit 4
    }


    # Confirm only ONE OF AppId or AppName has been specified. Not both.
    if ((-not [string]::IsNullOrWhiteSpace($AppId)) -and (-not [string]::IsNullOrWhiteSpace($AppName)))
    {
        Write-Log "ERROR: You have provided both an AppId and AppName. You must specify ONLY one of these."
        Exit 5
    }


    #Work out if the script is running in the user or SYSTEM context
    $Scope = ""
    $LogUsername = ""
    if ($env:USERPROFILE -like "*systemprofile")
    {
        $Scope = "machine"
        $LogUsername = "SYSTEM"
    }
    else
    {
        $Scope = "user"
        $LogUsername = $env:USERNAME.ToUpper()
    }

    # Determine the wrapper log name
    if (-not [string]::IsNullOrWhiteSpace($AppId))
    {
        $WrapperLogFile = (Join-Path -Path $LogFolder -ChildPath "$($Action) - $($AppId) - $($LogUsername) - Wrapper.log")
    }
    else
    {
        $WrapperLogFile = (Join-Path -Path $LogFolder -ChildPath "$($Action) - $($AppName) - $($LogUsername) - Installation.log")
    }



    # If the scope is 'machine' then do some additional work
    if ($Scope -eq "machine")
    {
        Write-Log "Script running under the SYSTEM context. Searching for the best winget.exe file to use..."
        $winget = gci "$env:ProgramFiles\WindowsApps" -Recurse -File | where { $_.name -like "Winget.exe" } | select -ExpandProperty fullname
        
        # Check if there was no results, multiple, or one result.
        if ($null -eq $winget)
        {
            Write-Log "ERROR: Failed to find 'winget.exe' in any folder under '$env:ProgramFiles\WindowsApps'. If this is a 64-bit system, did you ensure your Intune Application is launching the 64-bit version of PowerShell?"
            Write-Log "Script cannot continue."
            Exit 2;
        }
        elseif ($winget.count -gt 1) 
        { 
            Write-Log "Found more than 1 winget.exe. Picking the newest to use..."
            $winget = $winget[-1] 
        }

        Write-Log "winget.exe to be used: '$winget'"

        # If a proxy has been specified, then change the SYSTEM context proxy
        if (-not ([string]::IsNullOrWhiteSpace($Proxy)))
        {
            Write-Log "Proxy information has been provided as a parameter: '$Proxy'"

            #First capture the current SYSTEM proxy configuration (so we can change the configuration back afterwards)
            Write-Log "Capturing the current proxy settings (if any)"
            Capture-SystemProxySettings

            Write-Log "Setting the SYSTEM context proxy to '$Proxy'"
            netsh winhttp set proxy proxy-server="$($Proxy)"
        }
    }
    else
    {
        Write-Log "Script running under the User context"
    }



    # Begin building the standard arguments that are used for both installing and uninstalling
    $Arguments = @("--exact", "--silent", "--accept-source-agreements", "--source", "winget")


    # If AppId is provided, use that
    if (-not [string]::IsNullOrWhiteSpace($AppId))
    {
        $WingetLogFile = "$(Join-Path -Path $LogFolder -ChildPath "$($Action) - $($AppId) - $($LogUsername) - Winget.log")"
        $Arguments = $Arguments + @("--id", "`"$AppId`"", "--log", "`"$WingetLogFile`"")
    }


    # If AppName is provided, use that
    if (-not [string]::IsNullOrWhiteSpace($AppName))
    {
        $WingetLogFile = "$(Join-Path -Path $LogFolder -ChildPath "$($Action) - $($AppName) - $($LogUsername) - Winget.log")"
        $Arguments = $Arguments + @("--name", "`"$AppName`"", "--log", "`"$WingetLogFile`"")
    }


    # If a specific version parameter was provided, append that
    if (-not [string]::IsNullOrWhiteSpace($Version))
    {
        $Arguments = $Arguments + @("--version", "`"$Version`"")
    }


    # If any custom arguments were provided, append that
    if (-not [string]::IsNullOrWhiteSpace($CustomArgs))
    {
        $Arguments = $Arguments + @($CustomArgs)
    }
    

    # Install vs uninstall arguments differ slightly
    switch ($Action)
    {
        "Install"
        {
            $Arguments = @("install", "--scope", $Scope, "--accept-package-agreements") + $Arguments
        }
        "Uninstall"
        {
            $Arguments = @("uninstall") + $Arguments
        }
    }


    # Perform the install or uninstall  
    Write-Log "winget will be called with the following parameters: $Arguments"
    $ExecutionResult = [WingetWrapper.Execute]::Command("`"$winget`"", $Arguments, $WrapperLogFile, $TimeoutMinutes)


    if ($ExecutionResult -ne 0) {
        Write-Log "winget failed with exit code $($ExecutionResult.ExitCode)"
        Exit $ExecutionResult
    }
    else
    {
        Write-Log "$Action successfully completed."
    }
    

    if ($ProxySettings.ProxyWasSet)
    {
        Write-Log "Proxy was modified as part of this script running."
        Write-Log "Resetting the SYSTEM proxy to: $($ProxySettings.ProxyServer) Bypass list: $($ProxySettings.BypassList)"
        netsh winhttp set proxy proxy-server="$($ProxySettings.ProxyServer)" bypass-list="$($ProxySettings.BypassList)"
    }

}


