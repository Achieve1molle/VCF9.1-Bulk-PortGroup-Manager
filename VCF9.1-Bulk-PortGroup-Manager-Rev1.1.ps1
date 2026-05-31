<#
.SYNOPSIS
Achieve One - vDS Distributed Port Group Manager UI
.DESCRIPTION
WinForms UI for managing VMware Distributed Port Groups from a CSV.
CSV columns: name,vlan,state
state 1 = create if missing; state 0 = delete if present, skip if missing.
.Author
Michael Molle
Version 1.0.6:
- Port group naming dropdown: No Prefix, Append Cluster Name, Custom.
- Discover vDS button is placed in Cluster / vDS Selection.
- Newly-created port groups are forced to Static binding, Elastic auto-expand, and 8 initial ports.
- Final report includes AutoExpand.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.6-vds-pg-ui'
$script:ReportsBase = (Get-Location).Path
$script:RunDir = $null
$script:LogFile = $null
$script:VIServer = $null
$script:CsvRules = @()
$script:Results = New-Object System.Collections.Generic.List[object]

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Colors = [ordered]@{
    Form    = [System.Drawing.Color]::FromArgb(14,14,14)
    Panel   = [System.Drawing.Color]::FromArgb(20,20,20)
    Control = [System.Drawing.Color]::FromArgb(31,31,31)
    Header  = [System.Drawing.Color]::FromArgb(45,45,45)
    Text    = [System.Drawing.Color]::FromArgb(238,238,238)
    Border  = [System.Drawing.Color]::FromArgb(88,88,88)
    Select  = [System.Drawing.Color]::FromArgb(0,120,215)
    Pass    = [System.Drawing.Color]::FromArgb(86,196,86)
    Gold    = [System.Drawing.Color]::FromArgb(255,210,64)
    Fail    = [System.Drawing.Color]::FromArgb(220,70,70)
}

function New-RunDir {
    param([string]$BasePath)
    if ([string]::IsNullOrWhiteSpace($BasePath) -or -not (Test-Path $BasePath)) { $BasePath = (Get-Location).Path }
    $script:RunDir = Join-Path $BasePath ('vDSPortGroup-Run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
    $script:LogFile = Join-Path $script:RunDir ('vDSPortGroup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    '' | Set-Content -Path $script:LogFile -Encoding UTF8
}
function Write-Log { param([string]$Message,[string]$Level='INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    try { $script:txtLog.AppendText($line + [Environment]::NewLine); $script:txtLog.SelectionStart = $script:txtLog.Text.Length; $script:txtLog.ScrollToCaret() } catch {}
    Write-Host $line
}
function Ensure-LocalSelfSignedCertificate {
    try {
        if(-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)){ Write-Log 'New-SelfSignedCertificate cmdlet not available; skipping local helper certificate generation.' 'WARN'; return }
        $friendly = 'AchieveOne-vDSPortGroup-Manager-Local'
        $existing = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $friendly } | Select-Object -First 1
        if($existing){ Write-Log "Local helper self-signed certificate already exists: Thumbprint=$($existing.Thumbprint)"; return }
        $cert = New-SelfSignedCertificate -DnsName 'AchieveOne-vDSPortGroup-Manager' -CertStoreLocation 'Cert:\CurrentUser\My' -FriendlyName $friendly -NotAfter (Get-Date).AddYears(5) -KeyLength 2048 -ErrorAction Stop
        Write-Log "Generated local helper self-signed certificate: Thumbprint=$($cert.Thumbprint)" 'PASS'
    } catch { Write-Log "Local helper self-signed certificate generation skipped/failed: $($_.Exception.Message)" 'WARN' }
}
function Add-Result { param([string]$VCenter,[string]$Datacenter,[string]$Cluster,[string]$VDSwitch,[string]$PortGroup,[string]$VLAN,[string]$RequestedState,[string]$Action,[string]$Status,[string]$Message)
    $obj = [pscustomobject]@{ Timestamp=Get-Date; VCenter=$VCenter; Datacenter=$Datacenter; Cluster=$Cluster; VDSwitch=$VDSwitch; PortGroup=$PortGroup; VLAN=$VLAN; RequestedState=$RequestedState; Action=$Action; Status=$Status; Message=$Message }
    $script:Results.Add($obj) | Out-Null
    try { [void]$script:gridResults.Rows.Add($Cluster,$VDSwitch,$PortGroup,$VLAN,$RequestedState,$Action,$Status,$Message) } catch {}
    $lvl = if($Status -eq 'Pass'){'PASS'}elseif($Status -eq 'Fail'){'FAIL'}elseif($Status -eq 'Warn'){'WARN'}else{'INFO'}
    Write-Log "[$Cluster][$VDSwitch][$PortGroup] $Action/$Status - $Message" $lvl
}

function Test-PowerCLICommandSet {
    $required = @('Connect-VIServer','Disconnect-VIServer','Get-Cluster','Get-VMHost','Get-Datacenter','Get-VDSwitch','Get-VDPortgroup','New-VDPortgroup','Remove-VDPortgroup','Get-View')
    foreach($cmd in $required){ if(-not (Get-Command $cmd -ErrorAction SilentlyContinue)){ return $false } }
    return $true
}
function Import-PowerCLI-Safely {
    if(Test-PowerCLICommandSet){ return $true }
    $moduleNames = @('VMware.VimAutomation.Sdk','VMware.VimAutomation.Common','VMware.VimAutomation.Cis.Core','VMware.VimAutomation.Core','VMware.VimAutomation.Vds')
    $importErrors = New-Object System.Collections.Generic.List[string]
    foreach($m in $moduleNames){ if(Get-Module -Name $m){ continue }; if(Get-Module -ListAvailable -Name $m | Select-Object -First 1){ try { Import-Module $m -ErrorAction Stop | Out-Null } catch { $importErrors.Add("$m : $($_.Exception.Message)") | Out-Null } } }
    if(Test-PowerCLICommandSet){ if($importErrors.Count -gt 0){ Write-Log ("PowerCLI loaded with non-blocking import warnings: " + ($importErrors -join ' | ')) 'WARN' }; return $true }
    try { Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null } catch { if(Test-PowerCLICommandSet){ Write-Log "PowerCLI cmdlets are available. Ignoring non-blocking VMware.PowerCLI meta-module import error: $($_.Exception.Message)" 'WARN'; return $true }; throw }
    return (Test-PowerCLICommandSet)
}
function Ensure-PowerCLI { param([switch]$InstallIfMissing)
    if(Import-PowerCLI-Safely){ return $true }
    if(-not (Get-Module -ListAvailable -Name VMware.PowerCLI | Select-Object -First 1)){
        if(-not $InstallIfMissing){ return $false }
        Write-Log 'Installing VMware.PowerCLI...' 'WARN'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
    }
    return (Import-PowerCLI-Safely)
}
function Check-Prereqs {
    try {
        $script:lblPS.Text = "PowerShell: $($PSVersionTable.PSVersion)"; $script:lblPS.ForeColor = $script:Colors.Pass
        if(Get-Module -ListAvailable -Name VMware.PowerCLI | Select-Object -First 1){ $script:lblPCLI.Text='VMware.PowerCLI: Found'; $script:lblPCLI.ForeColor=$script:Colors.Pass } else { $script:lblPCLI.Text='VMware.PowerCLI: Not found'; $script:lblPCLI.ForeColor=$script:Colors.Gold }
    } catch { Write-Log "Prereq check failed: $($_.Exception.Message)" 'WARN' }
}

function Style-Button($b){ $b.FlatStyle='Flat'; $b.FlatAppearance.BorderColor=$script:Colors.Border; $b.BackColor=$script:Colors.Control; $b.ForeColor=$script:Colors.Text; $b.Height=30 }
function New-Button($text,$parent){ $b=New-Object System.Windows.Forms.Button; $b.Text=$text; Style-Button $b; $parent.Controls.Add($b); $b }
function New-Group($text,$parent){ $g=New-Object System.Windows.Forms.GroupBox; $g.Text=$text; $g.ForeColor=$script:Colors.Text; $g.BackColor=$script:Colors.Form; $parent.Controls.Add($g); $g }
function New-Label($text,$parent){ $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.ForeColor=$script:Colors.Text; $l.BackColor=$script:Colors.Form; $parent.Controls.Add($l); $l }
function New-TextBox($parent){ $t=New-Object System.Windows.Forms.TextBox; $t.BackColor=$script:Colors.Control; $t.ForeColor=$script:Colors.Text; $t.BorderStyle='FixedSingle'; $parent.Controls.Add($t); $t }
function Style-Grid($grid){
    $grid.AllowUserToAddRows=$false; $grid.RowHeadersVisible=$false; $grid.BackgroundColor=$script:Colors.Panel; $grid.BorderStyle='FixedSingle'; $grid.AutoSizeColumnsMode='Fill'; $grid.EnableHeadersVisualStyles=$false
    $grid.ColumnHeadersDefaultCellStyle.BackColor=$script:Colors.Header; $grid.ColumnHeadersDefaultCellStyle.ForeColor=$script:Colors.Text
    $grid.DefaultCellStyle.BackColor=$script:Colors.Panel; $grid.DefaultCellStyle.ForeColor=$script:Colors.Text; $grid.DefaultCellStyle.SelectionBackColor=$script:Colors.Select; $grid.DefaultCellStyle.SelectionForeColor=$script:Colors.Text; $grid.GridColor=$script:Colors.Border
}

function Get-CurrentVCenterName { try { if($script:VIServer){ return [string]$script:VIServer.Name } } catch {}; return '' }
function Connect-vCenterFromUi {
    if(-not (Ensure-PowerCLI)){ throw 'VMware.PowerCLI module is required. Use Install PowerCLI first.' }
    $server=$txtVCenter.Text.Trim(); $user=$txtUser.Text.Trim(); $pass=$txtPassword.Text
    if(-not $server){ throw 'vCenter Server is required.' }; if(-not $user){ throw 'Username is required.' }; if(-not $pass){ throw 'Password is required.' }
    $cred=[pscredential]::new($user,(ConvertTo-SecureString $pass -AsPlainText -Force))
    Write-Log "Connecting to vCenter $server ..."
    $script:VIServer = Connect-VIServer -Server $server -Credential $cred -ErrorAction Stop
    $lblConn.Text = "Connected: $($script:VIServer.Name)"; $lblConn.ForeColor=$script:Colors.Pass
    Write-Log "Connected to vCenter $($script:VIServer.Name)." 'PASS'
}
function Disconnect-vCenterFromUi { try { if($script:VIServer){ Disconnect-VIServer -Server $script:VIServer -Confirm:$false | Out-Null } } catch {}; $script:VIServer=$null; $lblConn.Text='Disconnected'; $lblConn.ForeColor=$script:Colors.Gold; Write-Log 'Disconnected from vCenter.' }
function Get-DatacenterNameForCluster { param($Cluster)
    try { return (Get-Datacenter -Cluster $Cluster -ErrorAction Stop | Select-Object -First 1).Name } catch {}
    try { return (Get-Datacenter -RelatedObject $Cluster -ErrorAction Stop | Select-Object -First 1).Name } catch {}
    return ''
}
function Discover-vDSInventory {
    if(-not $script:VIServer){ throw 'Connect to vCenter first.' }
    $gridInventory.Rows.Clear(); Write-Log 'Discovering cluster/vDS mappings...'
    foreach($cluster in (Get-Cluster -Server $script:VIServer | Sort-Object Name)){
        $hosts=@(Get-VMHost -Location $cluster -ErrorAction SilentlyContinue); if($hosts.Count -eq 0){ continue }
        $dcName=Get-DatacenterNameForCluster -Cluster $cluster
        foreach($vds in @(Get-VDSwitch -VMHost $hosts -ErrorAction SilentlyContinue | Sort-Object Name -Unique)){
            $idx=$gridInventory.Rows.Add(); $gridInventory.Rows[$idx].Cells['Selected'].Value=$false; $gridInventory.Rows[$idx].Cells['Datacenter'].Value=$dcName; $gridInventory.Rows[$idx].Cells['Cluster'].Value=[string]$cluster.Name; $gridInventory.Rows[$idx].Cells['VDSwitch'].Value=[string]$vds.Name; $gridInventory.Rows[$idx].Cells['VDSId'].Value=[string]$vds.Id
        }
    }
    Write-Log "Discovery complete. Found $($gridInventory.Rows.Count) cluster/vDS rows." 'PASS'
}
function Get-SelectedInventoryRows {
    $selected=@(); foreach($row in $gridInventory.Rows){ if($row.IsNewRow){ continue }; $checked=$false; try { $checked=[System.Convert]::ToBoolean($row.Cells['Selected'].Value) } catch {}; if($checked){ $selected += [pscustomobject]@{ VCenter=(Get-CurrentVCenterName); Datacenter=[string]$row.Cells['Datacenter'].Value; Cluster=[string]$row.Cells['Cluster'].Value; VDSwitch=[string]$row.Cells['VDSwitch'].Value; VDSId=[string]$row.Cells['VDSId'].Value } } }; return $selected
}
function Get-PortGroupName { param([string]$ClusterName,[string]$RuleName)
    $mode='No Prefix'; try { if($cmbPrefix.SelectedItem){ $mode=[string]$cmbPrefix.SelectedItem } } catch {}
    switch($mode){
        'No Prefix' { return $RuleName }
        'Append Cluster Name' { return ('{0}-{1}' -f $ClusterName,$RuleName) }
        'Custom' { $prefix=''; try { $prefix=$txtCustomPrefix.Text.Trim() } catch {}; if([string]::IsNullOrWhiteSpace($prefix)){ throw 'Custom prefix selected but the custom prefix box is blank.' }; return ('{0}-{1}' -f $prefix,$RuleName) }
        default { return $RuleName }
    }
}
function Import-RulesCsv { param([string]$Path)
    if(-not (Test-Path $Path)){ throw "CSV not found: $Path" }
    $rows=@(Import-Csv -Path $Path)
    foreach($required in @('name','vlan','state')){ if(-not ($rows | Get-Member -Name $required -MemberType NoteProperty)){ throw "CSV missing required column '$required'. Required headers: name,vlan,state" } }
    $validated=@(); foreach($r in $rows){
        $name=([string]$r.name).Trim(); $vlanText=([string]$r.vlan).Trim(); $stateText=([string]$r.state).Trim()
        if(-not $name){ throw 'CSV contains a blank name.' }
        [int]$vlan=0; if(-not [int]::TryParse($vlanText,[ref]$vlan)){ throw "Invalid VLAN '$vlanText' for name '$name'." }; if($vlan -lt 0 -or $vlan -gt 4094){ throw "VLAN '$vlan' for '$name' must be 0-4094." }
        [int]$state=0; if(-not [int]::TryParse($stateText,[ref]$state) -or ($state -notin 0,1)){ throw "State for '$name' must be 0 or 1." }
        $validated += [pscustomobject]@{ name=$name; vlan=$vlan; state=$state }
    }
    $script:CsvRules=$validated; $gridRules.Rows.Clear(); foreach($r in $script:CsvRules){ [void]$gridRules.Rows.Add($r.name,$r.vlan,$r.state) }
    $txtCsv.Text=$Path; Write-Log "Loaded $($script:CsvRules.Count) CSV rule rows from $Path" 'PASS'
}
function Save-ExampleCsv { param([string]$Path)
    @([pscustomobject]@{name='APP_WEB';vlan=120;state=1},[pscustomobject]@{name='APP_DB';vlan=121;state=1},[pscustomobject]@{name='OLD_NETWORK';vlan=999;state=0}) | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Log "Example CSV saved: $Path" 'PASS'
}
function Resolve-VDSwitchByIdOrName { param([string]$VDSId,[string]$VDSName)
    $vds=$null; if($VDSId){ $vds=Get-VDSwitch -Server $script:VIServer -Id $VDSId -ErrorAction SilentlyContinue }; if(-not $vds -and $VDSName){ $vds=Get-VDSwitch -Server $script:VIServer -Name $VDSName -ErrorAction Stop | Select-Object -First 1 }; return $vds
}
function Wait-vSphereTask { param($TaskMoRef,[string]$Description='vSphere task')
    if(-not $TaskMoRef){ return }; $taskView=Get-View -Id $TaskMoRef -ErrorAction Stop
    while($taskView.Info.State -eq 'running' -or $taskView.Info.State -eq 'queued'){ Start-Sleep -Milliseconds 500; $taskView.UpdateViewData('Info.State','Info.Error') }
    if($taskView.Info.State -eq 'error'){ $msg=if($taskView.Info.Error){$taskView.Info.Error.LocalizedMessage}else{'Unknown task error'}; throw "$Description failed: $msg" }
}
function Set-VDPortgroupStaticElastic8 { param([Parameter(Mandatory=$true)]$VDPortgroup)
    try {
        $pgView=$VDPortgroup.ExtensionData; $spec=New-Object VMware.Vim.DVPortgroupConfigSpec
        $spec.ConfigVersion=$pgView.Config.ConfigVersion; $spec.Type='earlyBinding'; $spec.NumPorts=8; $spec.AutoExpand=$true
        $task=$pgView.ReconfigureDVPortgroup_Task($spec); Wait-vSphereTask -TaskMoRef $task -Description "Set static/elastic/8 ports on port group '$($VDPortgroup.Name)'"
        Write-Log "Configured '$($VDPortgroup.Name)' with Static binding, Elastic auto-expand, and 8 initial ports." 'PASS'
    } catch { throw "Port group '$($VDPortgroup.Name)' was created, but setting Static/Elastic/8 ports failed: $($_.Exception.Message)" }
}
function Export-ActionReport {
    $csv=Join-Path $script:RunDir 'PortGroup-Actions.csv'; $html=Join-Path $script:RunDir 'PortGroup-Actions.html'
    $script:Results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    $style='<style>body{font-family:Segoe UI,Arial;background:#111;color:#eee}table{border-collapse:collapse}td,th{border:1px solid #555;padding:4px 8px}th{background:#333}</style>'
    $script:Results | ConvertTo-Html -Head $style -Title 'vDS Port Group Action Report' -PreContent "<h2>vDS Port Group Action Report</h2><p>Run folder: $script:RunDir</p>" | Set-Content -Path $html -Encoding UTF8
    Write-Log "Action reports exported: $csv ; $html"
}
function Get-VlanDescription { param($VDPortgroup)
    try { $cfg=$VDPortgroup.ExtensionData.Config.DefaultPortConfig.Vlan; if($null -eq $cfg){ return '' }; $type=$cfg.GetType().Name; switch -Regex ($type) { 'VlanIdSpec' { return [string]$cfg.VlanId } 'TrunkVlanSpec' { return (($cfg.VlanId | ForEach-Object { if($_.Start -eq $_.End){$_.Start}else{"$($_.Start)-$($_.End)"} }) -join ';') } 'PvlanSpec' { return "PVLAN:$($cfg.PvlanId)" } default { return $type } } } catch { try { return [string]$VDPortgroup.VlanConfiguration } catch { return '' } }
}
function Get-VDPortgroupAutoExpand { param($VDPortgroup) try { return [string]$VDPortgroup.ExtensionData.Config.AutoExpand } catch { return '' } }
function Export-FinalPortGroupReport {
    if(-not $script:VIServer){ throw 'Connect to vCenter first.' }
    $path=Join-Path $script:RunDir ('Final-vDS-PortGroup-Report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    Write-Log 'Building final vDS and distributed port group inventory report...'
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($cluster in (Get-Cluster -Server $script:VIServer | Sort-Object Name)){
        $hosts=@(Get-VMHost -Location $cluster -ErrorAction SilentlyContinue); if($hosts.Count -eq 0){ continue }
        $dcName=Get-DatacenterNameForCluster -Cluster $cluster
        foreach($vds in @(Get-VDSwitch -VMHost $hosts -ErrorAction SilentlyContinue | Sort-Object Name -Unique)){
            $pgs=@(Get-VDPortgroup -VDSwitch $vds -ErrorAction SilentlyContinue | Sort-Object Name)
            if($pgs.Count -eq 0){ $rows.Add([pscustomobject]@{VCenter=$script:VIServer.Name;Datacenter=$dcName;Cluster=$cluster.Name;Switch=$vds.Name;'Port Group'='';VLAN='';NumPorts='';Binding='';AutoExpand='';Type='vDS';Notes='No port groups found'}) | Out-Null }
            else { foreach($pg in $pgs){ $rows.Add([pscustomobject]@{VCenter=$script:VIServer.Name;Datacenter=$dcName;Cluster=$cluster.Name;Switch=$vds.Name;'Port Group'=$pg.Name;VLAN=(Get-VlanDescription $pg);NumPorts=$pg.NumPorts;Binding=$pg.PortBinding;AutoExpand=(Get-VDPortgroupAutoExpand $pg);Type='vDS Port Group';Notes=''}) | Out-Null } }
        }
    }
    $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8; Write-Log "Final inventory report exported: $path" 'PASS'; return $path
}
function Invoke-PortGroupChanges {
    if(-not $script:VIServer){ throw 'Connect to vCenter first.' }; if(-not $script:CsvRules -or $script:CsvRules.Count -eq 0){ throw 'Load a CSV first.' }
    $selected=@(Get-SelectedInventoryRows); if($selected.Count -eq 0){ throw 'Select at least one cluster/vDS row first.' }
    $script:Results.Clear(); $gridResults.Rows.Clear()
    foreach($target in $selected){
        try {
            $vds=Resolve-VDSwitchByIdOrName -VDSId $target.VDSId -VDSName $target.VDSwitch; if(-not $vds){ throw "Could not resolve vDS '$($target.VDSwitch)'" }
            foreach($rule in $script:CsvRules){
                $pgName=Get-PortGroupName -ClusterName $target.Cluster -RuleName $rule.name
                try {
                    $existing=Get-VDPortgroup -VDSwitch $vds -Name $pgName -ErrorAction SilentlyContinue
                    if([int]$rule.state -eq 1){
                        if($existing){ Add-Result $target.VCenter $target.Datacenter $target.Cluster $target.VDSwitch $pgName $rule.vlan '1' 'Create' 'Skip' 'Port group already exists.' }
                        else { $newPg=New-VDPortgroup -VDSwitch $vds -Name $pgName -VLanId ([int]$rule.vlan) -NumPorts 8 -PortBinding Static -ErrorAction Stop; Set-VDPortgroupStaticElastic8 -VDPortgroup $newPg; Add-Result $target.VCenter $target.Datacenter $target.Cluster $target.VDSwitch $pgName $rule.vlan '1' 'Create' 'Pass' 'Port group created with Static binding, Elastic auto-expand, and 8 initial ports.' }
                    } else {
                        if($existing){ $existing | Remove-VDPortgroup -Confirm:$false -ErrorAction Stop; Add-Result $target.VCenter $target.Datacenter $target.Cluster $target.VDSwitch $pgName $rule.vlan '0' 'Delete' 'Pass' 'Port group deleted.' }
                        else { Add-Result $target.VCenter $target.Datacenter $target.Cluster $target.VDSwitch $pgName $rule.vlan '0' 'Delete' 'Skip' 'Port group was not found; no action taken.' }
                    }
                } catch { Add-Result $target.VCenter $target.Datacenter $target.Cluster $target.VDSwitch $pgName $rule.vlan ([string]$rule.state) 'Process' 'Fail' $_.Exception.Message }
            }
        } catch { Add-Result $target.VCenter $target.Datacenter $target.Cluster $target.VDSwitch '' '' '' 'Resolve vDS' 'Fail' $_.Exception.Message }
    }
    Export-ActionReport; Export-FinalPortGroupReport | Out-Null; Write-Log 'Port group changes completed.' 'PASS'
}
function Set-Busy([bool]$Busy){ foreach($b in @($btnConnect,$btnDisconnect,$btnDiscover,$btnLoadCsv,$btnExampleCsv,$btnApply,$btnExportReport,$btnInstallPCLI,$btnRecheck,$btnBrowseReports,$btnSelectAll,$btnSelectNone,$btnClose,$btnOpenRun)){ try { $b.Enabled = -not $Busy } catch {} }; if($Busy){$form.Cursor=[System.Windows.Forms.Cursors]::WaitCursor}else{$form.Cursor=[System.Windows.Forms.Cursors]::Default} }

# ---------------- UI ----------------
New-RunDir -BasePath $script:ReportsBase
$form=New-Object System.Windows.Forms.Form
$form.Text="Achieve One - Port Group Manager"
$form.MinimumSize=New-Object System.Drawing.Size(1120,760)
$form.Size=New-Object System.Drawing.Size(1540,900)
$form.StartPosition='CenterScreen'; $form.BackColor=$script:Colors.Form; $form.ForeColor=$script:Colors.Text; $form.Font=New-Object System.Drawing.Font('Segoe UI',9)

$grpPrereq=New-Group 'Prerequisites' $form; $grpConnect=New-Group 'vCenter Connection' $form; $grpInventory=New-Group 'Cluster / vDS Selection' $form; $grpCsv=New-Group 'CSV Rules: name, vlan, state' $form; $grpResults=New-Group 'Action Results' $form; $grpLog=New-Group 'Log' $form; $grpActions=New-Group 'Reports / Actions' $form
$script:lblPS=New-Label 'PowerShell: checking...' $grpPrereq; $script:lblPCLI=New-Label 'VMware.PowerCLI: checking...' $grpPrereq; $btnRecheck=New-Button 'Recheck' $grpPrereq; $btnInstallPCLI=New-Button 'Install PowerCLI' $grpPrereq
$lblVc=New-Label 'vCenter:' $grpConnect; $txtVCenter=New-TextBox $grpConnect; $lblUser=New-Label 'Username:' $grpConnect; $txtUser=New-TextBox $grpConnect; $lblPwd=New-Label 'Password:' $grpConnect; $txtPassword=New-TextBox $grpConnect; $txtPassword.UseSystemPasswordChar=$true; $btnConnect=New-Button 'Connect' $grpConnect; $btnDisconnect=New-Button 'Disconnect' $grpConnect; $lblConn=New-Label 'Disconnected' $grpConnect; $lblConn.ForeColor=$script:Colors.Gold
$btnSelectAll=New-Button 'Select All' $grpInventory; $btnSelectNone=New-Button 'Select None' $grpInventory; $btnDiscover=New-Button 'Discover vDS' $grpInventory
$gridInventory=New-Object System.Windows.Forms.DataGridView; $script:gridInventory=$gridInventory; Style-Grid $gridInventory; $grpInventory.Controls.Add($gridInventory)
$colSel=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $colSel.Name='Selected'; $colSel.HeaderText='Modify'; $colSel.FillWeight=45; $gridInventory.Columns.Add($colSel) | Out-Null
[void]$gridInventory.Columns.Add('Datacenter','Datacenter'); [void]$gridInventory.Columns.Add('Cluster','Cluster'); [void]$gridInventory.Columns.Add('VDSwitch','vDS'); [void]$gridInventory.Columns.Add('VDSId','vDS Id'); $gridInventory.Columns['VDSId'].Visible=$false; $gridInventory.Columns['Cluster'].FillWeight=150; $gridInventory.Columns['VDSwitch'].FillWeight=150
$txtCsv=New-TextBox $grpCsv; $btnLoadCsv=New-Button 'Load CSV...' $grpCsv; $btnExampleCsv=New-Button 'Download Example CSV' $grpCsv
$lblPrefix=New-Label 'Port Group Naming:' $grpCsv; $cmbPrefix=New-Object System.Windows.Forms.ComboBox; $cmbPrefix.DropDownStyle='DropDownList'; $cmbPrefix.BackColor=$script:Colors.Control; $cmbPrefix.ForeColor=$script:Colors.Text; $cmbPrefix.FlatStyle='Flat'; [void]$cmbPrefix.Items.Add('No Prefix'); [void]$cmbPrefix.Items.Add('Append Cluster Name'); [void]$cmbPrefix.Items.Add('Custom'); $cmbPrefix.SelectedIndex=0; $grpCsv.Controls.Add($cmbPrefix)
$lblCustomPrefix=New-Label 'Custom Prefix:' $grpCsv; $txtCustomPrefix=New-TextBox $grpCsv; $lblCustomPrefix.Enabled=$false; $txtCustomPrefix.Enabled=$false
$gridRules=New-Object System.Windows.Forms.DataGridView; $script:gridRules=$gridRules; Style-Grid $gridRules; $gridRules.ReadOnly=$true; $grpCsv.Controls.Add($gridRules); [void]$gridRules.Columns.Add('name','name'); [void]$gridRules.Columns.Add('vlan','vlan'); [void]$gridRules.Columns.Add('state','state')
$gridResults=New-Object System.Windows.Forms.DataGridView; $script:gridResults=$gridResults; Style-Grid $gridResults; $gridResults.ReadOnly=$true; $grpResults.Controls.Add($gridResults); foreach($c in @('Cluster','vDS','Port Group','VLAN','State','Action','Status','Message')){ [void]$gridResults.Columns.Add(($c -replace ' ',''),$c) }; $gridResults.Columns['Message'].FillWeight=240
$btnOpenLog=New-Button 'Open Log' $grpLog; $txtLog=New-Object System.Windows.Forms.TextBox; $script:txtLog=$txtLog; $txtLog.Multiline=$true; $txtLog.ScrollBars='Vertical'; $txtLog.BackColor=$script:Colors.Control; $txtLog.ForeColor=$script:Colors.Text; $txtLog.BorderStyle='FixedSingle'; $grpLog.Controls.Add($txtLog)
$lblReports=New-Label 'Reports Path:' $grpActions; $txtReports=New-TextBox $grpActions; $txtReports.Text=$script:ReportsBase; $btnBrowseReports=New-Button 'Browse...' $grpActions; $btnApply=New-Button 'Create Port Groups' $grpActions; $btnExportReport=New-Button 'Export  vDS Report' $grpActions; $btnOpenRun=New-Button 'Open Run Folder' $grpActions; $btnClose=New-Button 'Close' $grpActions

function Layout-Ui {
    $m=10; $w=$form.ClientSize.Width; $h=$form.ClientSize.Height; $topH=138; $actionsH=74; $csvH=230
    $leftTopW=[Math]::Min(390,[int](($w-$m*3)*0.31)); if($leftTopW -lt 330){$leftTopW=330}; $grpPrereq.SetBounds($m,$m,$leftTopW,$topH); $grpConnect.SetBounds($grpPrereq.Right+$m,$m,$w-$grpPrereq.Width-$m*3,$topH)
    $rightW=[Math]::Max(455,[int](($w-$m*3)*0.38)); $leftW=$w-$rightW-$m*3; $midY=$m+$topH+$m; $midH=[Math]::Max(300,$h-$topH-$actionsH-$m*4)
    $resultsH=[int](($midH-$csvH-$m*2)*0.56); if($resultsH -lt 145){$resultsH=145}; $logH=$midH-$csvH-$resultsH-$m*2; if($logH -lt 130){$logH=130}
    $grpInventory.SetBounds($m,$midY,$leftW,$midH); $grpCsv.SetBounds($grpInventory.Right+$m,$midY,$rightW,$csvH); $grpResults.SetBounds($grpInventory.Right+$m,$grpCsv.Bottom+$m,$rightW,$resultsH); $grpLog.SetBounds($grpInventory.Right+$m,$grpResults.Bottom+$m,$rightW,$logH); $grpActions.SetBounds($m,$h-$actionsH-$m,$w-$m*2,$actionsH)
    $script:lblPS.SetBounds(15,32,$grpPrereq.Width-175,22); $script:lblPCLI.SetBounds(15,64,$grpPrereq.Width-175,22); $btnRecheck.SetBounds($grpPrereq.Width-150,28,135,28); $btnInstallPCLI.SetBounds($grpPrereq.Width-150,62,135,28)
    $fieldY=30; $buttonY=82; $gap=10; $lblVc.SetBounds(15,$fieldY+3,58,22); $lblUser.SetBounds([Math]::Max(240,[int]($grpConnect.Width*0.42)),$fieldY+3,68,22); $lblPwd.SetBounds([Math]::Max(450,[int]($grpConnect.Width*0.66)),$fieldY+3,68,22); $txtVCenter.SetBounds(75,$fieldY,[Math]::Max(155,$lblUser.Left-85),24); $txtUser.SetBounds($lblUser.Right+8,$fieldY,[Math]::Max(130,$lblPwd.Left-$lblUser.Right-16),24); $txtPassword.SetBounds($lblPwd.Right+8,$fieldY,[Math]::Max(130,$grpConnect.Width-$lblPwd.Right-23),24); $btnConnect.SetBounds(15,$buttonY,105,30); $btnDisconnect.SetBounds($btnConnect.Right+$gap,$buttonY,105,30); $lblConn.SetBounds($btnDisconnect.Right+20,$buttonY+5,[Math]::Max(180,$grpConnect.Width-$btnDisconnect.Right-35),22)
    $btnSelectAll.SetBounds(15,24,95,28); $btnSelectNone.SetBounds(120,24,100,28); $btnDiscover.SetBounds(230,24,125,28); $gridInventory.SetBounds(15,62,$grpInventory.Width-30,$grpInventory.Height-77)
    $txtCsv.SetBounds(15,25,[Math]::Max(160,$grpCsv.Width-315),24); $btnLoadCsv.SetBounds($txtCsv.Right+10,23,95,28); $btnExampleCsv.SetBounds($btnLoadCsv.Right+10,23,175,28); $lblPrefix.SetBounds(15,62,120,22); $cmbPrefix.SetBounds(140,59,170,24); $lblCustomPrefix.SetBounds(325,62,90,22); $txtCustomPrefix.SetBounds(420,59,[Math]::Max(120,$grpCsv.Width-435),24); $gridRules.SetBounds(15,98,$grpCsv.Width-30,$grpCsv.Height-113)
    $gridResults.SetBounds(15,25,$grpResults.Width-30,$grpResults.Height-40); $btnOpenLog.SetBounds(15,23,$grpLog.Width-30,28); $txtLog.SetBounds(15,60,$grpLog.Width-30,$grpLog.Height-75)
    $lblReports.SetBounds(15,32,90,22); $txtReports.SetBounds(105,29,[Math]::Max(260,$grpActions.Width-760),24); $btnBrowseReports.SetBounds($txtReports.Right+10,27,90,28); $x=$grpActions.Width-520; foreach($pair in @(@($btnApply,140),@($btnExportReport,140),@($btnOpenRun,120),@($btnClose,70))){ $pair[0].SetBounds($x,27,$pair[1],28); $x += $pair[1]+10 }
}
$form.Add_Resize({ Layout-Ui })
$cmbPrefix.Add_SelectedIndexChanged({ $isCustom=([string]$cmbPrefix.SelectedItem -eq 'Custom'); $lblCustomPrefix.Enabled=$isCustom; $txtCustomPrefix.Enabled=$isCustom })
$btnRecheck.Add_Click({ Check-Prereqs })
$btnInstallPCLI.Add_Click({ try{ Set-Busy $true; Ensure-PowerCLI -InstallIfMissing | Out-Null; Check-Prereqs } catch { Write-Log $_.Exception.Message 'ERROR'; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Install failed','OK','Error') | Out-Null } finally { Set-Busy $false } })
$btnConnect.Add_Click({ try{ Set-Busy $true; Connect-vCenterFromUi } catch { Write-Log $_.Exception.Message 'ERROR'; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Connect failed','OK','Error') | Out-Null } finally { Set-Busy $false } })
$btnDisconnect.Add_Click({ Disconnect-vCenterFromUi })
$btnDiscover.Add_Click({ try{ Set-Busy $true; Discover-vDSInventory } catch { Write-Log $_.Exception.Message 'ERROR'; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Discovery failed','OK','Error') | Out-Null } finally { Set-Busy $false } })
$btnSelectAll.Add_Click({ foreach($r in $gridInventory.Rows){ if(-not $r.IsNewRow){ $r.Cells['Selected'].Value=$true } } })
$btnSelectNone.Add_Click({ foreach($r in $gridInventory.Rows){ if(-not $r.IsNewRow){ $r.Cells['Selected'].Value=$false } } })
$btnLoadCsv.Add_Click({ try{ $d=New-Object System.Windows.Forms.OpenFileDialog; $d.Filter='CSV files (*.csv)|*.csv|All files (*.*)|*.*'; if($d.ShowDialog() -eq 'OK'){ Import-RulesCsv -Path $d.FileName } } catch { Write-Log $_.Exception.Message 'ERROR'; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'CSV load failed','OK','Error') | Out-Null } })
$btnExampleCsv.Add_Click({ try{ $d=New-Object System.Windows.Forms.SaveFileDialog; $d.Filter='CSV files (*.csv)|*.csv'; $d.FileName='vDS-PortGroup-Rules-Example.csv'; if($d.ShowDialog() -eq 'OK'){ Save-ExampleCsv -Path $d.FileName } } catch { Write-Log $_.Exception.Message 'ERROR' } })
$btnBrowseReports.Add_Click({ $d=New-Object System.Windows.Forms.FolderBrowserDialog; if($d.ShowDialog() -eq 'OK'){ $script:ReportsBase=$d.SelectedPath; $txtReports.Text=$script:ReportsBase; New-RunDir -BasePath $script:ReportsBase; Write-Log "New run folder: $script:RunDir" } })
$btnApply.Add_Click({ try{ $answer=[System.Windows.Forms.MessageBox]::Show('This will create/delete distributed port groups on selected cluster/vDS rows. Continue?','Confirm Changes','YesNo','Warning'); if($answer -ne 'Yes'){ return }; Set-Busy $true; Invoke-PortGroupChanges; [System.Windows.Forms.MessageBox]::Show("Changes complete. Reports are in:`n$script:RunDir",'Complete','OK','Information') | Out-Null } catch { Write-Log $_.Exception.Message 'ERROR'; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Apply failed','OK','Error') | Out-Null } finally { Set-Busy $false } })
$btnExportReport.Add_Click({ try{ Set-Busy $true; $p=Export-FinalPortGroupReport; [System.Windows.Forms.MessageBox]::Show("Report exported:`n$p",'Report exported','OK','Information') | Out-Null } catch { Write-Log $_.Exception.Message 'ERROR'; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Report failed','OK','Error') | Out-Null } finally { Set-Busy $false } })
$btnOpenLog.Add_Click({ if(Test-Path $script:LogFile){ Invoke-Item $script:LogFile } })
$btnOpenRun.Add_Click({ if(Test-Path $script:RunDir){ Invoke-Item $script:RunDir } })
$btnClose.Add_Click({ Disconnect-vCenterFromUi; $form.Close() })

Layout-Ui
Write-Log "==== vDS Port Group Manager UI started v$script:Version ===="
Write-Log "Run folder: $script:RunDir"
Ensure-LocalSelfSignedCertificate
Check-Prereqs
[void]$form.ShowDialog()
