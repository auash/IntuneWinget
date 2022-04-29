# IntuneWinget

A PowerShell wrapper that provides an easy way to utilise winget via Intune

## Background

winget has several limitations which mean it cannot be utilised via Intune easily. This script resolves many of these limitations and provides an easy way to use winget as the deployment tool for Intune Applications.

Further information: https://asherjebbink.medium.com/winget-for-intune-and-sccm-361b88ca0eb

## Usage

1. Package the `Manage-WinGetApp.ps1` file into an .intunewin file using the Microsoft Win32 Content Prep Tool
2. If your users are *not* local administrators, you need to confirm the installation options available to you for the application you want to install:
   - Using the [Manifests](https://github.com/microsoft/winget-pkgs/tree/master/manifests) list, find the `xxxxx.installer.yaml` file for your app.
   - Take note of the "Scope" line(s):

     ![image](https://user-images.githubusercontent.com/70518732/165887253-9622d028-009e-4292-8b78-82733187f3de.png)
     
   - If the application *only* has `machine` listed, then you will have to install this application under the SYSTEM context (as your users do not have rights to install system-wide applications).
   - If the application has *both* `user` and `machine`, then you can choose which context the installation should be done in.
3. Create a new Intune Application and use the following format for the install and uninstall commands:
```
Install:
%windir%\sysnative\WindowsPowershell\v1.0\powershell.exe -file Manage-WingetApp.ps1 -AppId “TimKosse.FileZilla.Client"

Uninstall:
%windir%\sysnative\WindowsPowershell\v1.0\powershell.exe -file Manage-WingetApp.ps1 -AppId “TimKosse.FileZilla.Client" -Action Uninstall
``` 
4. Specify whether the installation should be done under the SYSTEM or User context (check step 2 above) using the toggles
5. Specify the rest of the Application configuration like normal.


## Logs
The script creates 2 log files for every application install/uninstall that runs:
  - One log file for the wrapper script and the output of the winget.exe (file name ends in `- wrapper.log`)
  - One log file for the application installation executable itself (file name ends in `- installation.log`)

By default these logs are created in `C:\ProgramData\Intune Winget Logs\`. You can change the location the log files are created in by specifying the `-LogFolder` parameter


## Parameters
| Parameter | Type | Description | Default | Example |
| --- | --- | --- | --- | --- |
| AppId | string | The 'id' of the Application to install/uninstall. This is the value provided to the winget parameter `--id`. You must specify **either** the `AppId` or `AppName`, but **not** both. | <null> | Microsoft.VisualStudioCode  |
| AppName | string | The 'name' of the Application to install/uninstall. This is the value provided to the winget parameter `--name`. You must specify **either** the `AppId` or `AppName`, but **not** both. | <null> | "Microsoft Visual Studio Code" |
| Action | string | Allowed values are `Install` or `Uninstall`. | Install | Install |
| LogFolder | string | The full path to a folder for log files to be stored. If the folder doesn't exist, then this script will try and create it. | C:\ProgramData\Intune Winget Logs | "C:\Windows\Logs\" |
| Version | string | Allows you to force a specific version of the application to tbe installed/uninstalled. This is the value provided to the winget parameter `--version` | <null> | 1.57.3 |
| Proxy | string | This parameter is only utilised if the script is running under the SYSTEM context. When specified, the SYSTEM context proxy is changed to the value provided. The script reverts the SYSTEM proxy back to the pre-script value once completed. | <null> | "webproxy.organisation.internal:8080" |
| TimeoutMinutes | int | The maximum number of minutes this script will wait for the winget process to complete the install/uninstall before treating it as a failure and killing the process. | 30 | 120 |
| CustomArgs | string | You can provide values for winget parameters that are not already controlled by this script (or if any new parameters are added in future) through this parameter. Anything you specify here will be appended onto the end of the parameters that are provided to winget. **Warning**: ensure you do not specify any of the parameters that are already controlled by this script. | <null> | "--header somevalue" |
  
  
  
## Notes
  - winget is called with the `--exact` parameter, so the AppId or AppName you provide must be the exact string for the application you want installed/uninstalled
  - The output of the winget.exe process is written to the `- wrapper.log` in real time.
  - Output from winget.exe versus that from this script can be differentiated by the start of the log line. Lines that contain the date/time at the beginning are from this script. Lines without the date/time are the raw output from the winget.exe process:
  ![image](https://user-images.githubusercontent.com/70518732/165889309-66e4bd30-8a38-41f3-8055-1dc3d7d7c8ee.png)
