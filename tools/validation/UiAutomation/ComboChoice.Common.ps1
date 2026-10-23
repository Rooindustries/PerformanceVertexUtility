Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function Get-ComboBox($Root, [string]$Id) {
    $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ComboBox)))
}

function Get-ComboChoice($Box) {
    try { @($Box.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection() | ForEach-Object { $_.Current.Name }) | Select-Object -First 1 } catch { $null }
}

function Find-ComboChoice($Box, [string]$Like) {
    $container = $null
    if ($Box.TryGetCurrentPattern([Windows.Automation.ItemContainerPattern]::Pattern, [ref]$container)) {
        try {
            $item = $null
            for ($n = 0; $n -lt 5000; $n++) {
                $item = $container.FindItemByProperty($item, $null, $null)
                if (-not $item) { break }
                if ($item.Current.Name -like $Like) { return $item }
            }
        } catch {}
    }
    $listItem = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)
    $last = $null
    for ($page = 0; $page -lt 60; $page++) {
        $items = @($Box.FindAll([Windows.Automation.TreeScope]::Descendants, $listItem))
        $item = @($items | Where-Object { $_.Current.Name -like $Like }) | Select-Object -First 1
        if ($item -or -not $items.Count -or $items[-1].Current.Name -ceq $last) { return $item }
        $last = $items[-1].Current.Name
        $scroll = @($Box.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | Where-Object { try { $_.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable } catch { $false } }) | Select-Object -First 1
        try {
            if ($scroll) { $scroll.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Scroll([Windows.Automation.ScrollAmount]::NoAmount, [Windows.Automation.ScrollAmount]::LargeIncrement) }
            else { $items[-1].GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView() }
        } catch { return $null }
        Start-Sleep -Milliseconds 150
    }
}

function Select-ComboChoice($Root, [string]$Id, [string]$Like, [double]$Seconds = 90) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds); $found = $false; $failure = $null
    do {
        $box = Get-ComboBox $Root $Id
        if ($box -and $box.Current.IsEnabled) {
            $picked = Get-ComboChoice $box
            if ($picked -like $Like) { return $picked }
            try { $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch { $failure = $_.Exception.Message }
            Start-Sleep -Milliseconds 300
            $item = Find-ComboChoice $box $Like
            if ($item) {
                $found = $true
                try { $item.GetCurrentPattern([Windows.Automation.VirtualizedItemPattern]::Pattern).Realize() } catch {}
                try { $item.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView() } catch {}
                try { $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { $failure = $_.Exception.Message }
                Start-Sleep -Milliseconds 500
            }
            $box = Get-ComboBox $Root $Id
            if ($box) {
                try { $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
                $picked = Get-ComboChoice $box
                if ($picked -like $Like) { return $picked }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $found) { throw ('Choice missing: ' + $Like) }
    throw ('Choice not taken: ' + $Like + $(if ($failure) { ' (' + $failure + ')' }))
}
