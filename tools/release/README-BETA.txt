Roo Industries Optimization Suite {Version}
Beta tester guide

Thanks for testing! This is a beta. Please read this once before you start.


1. Installing and opening the app
---------------------------------
- Run RooIndustries-OptimizationSuite-{Version}-setup.exe and follow the steps.
- You don't need to install anything else. .NET and the Windows App SDK are
  already inside the app.
- Open it from the Start menu: Roo Industries Optimization Suite.
- Windows asks "Do you want to allow this app to make changes?" every time you
  open it. Click Yes. The app needs administrator rights to change Windows
  settings and to save your undo information.
- Use a Windows account that is an administrator on this PC. If you type in a
  different admin account's password, the app changes that account's settings
  instead of yours.


2. "Windows protected your PC" (SmartScreen)
--------------------------------------------
The beta isn't signed yet, so Windows doesn't recognize it. When you run the
setup file:
- Click "More info".
- Click "Run anyway".
Only do this for a setup file you got directly from Roo Industries. You can
check the file with the SHA256 value we sent you: open PowerShell and run
  Get-FileHash .\RooIndustries-OptimizationSuite-{Version}-setup.exe
and compare the result.


3. Smart App Control
--------------------
If Smart App Control is on, Windows blocks unsigned apps completely and there's
no "Run anyway" button. The beta can't run while it's on.
- Check it in Windows Security > App & browser control > Smart App Control.
- If it's set to On, you have to turn it Off to test the beta.
- Heads up: on many Windows versions, once Smart App Control is off you can't
  turn it back on without resetting or reinstalling Windows. If you don't want
  that, don't test the beta on this PC.


4. Before you change anything
-----------------------------
- Make a Windows restore point first. The Windows tweaks page has a Restore
  points button that does it for you.
- Close your games before you apply tweaks.
- Some tweaks need a restart. The app tells you when.


5. The FPS preset
-----------------
The FPS preset button picks up to 15 Windows security settings (settings your
PC doesn't have are skipped). Turned off together, they raised average FPS by
about 7 to 10% in our Counter-Strike 2 tests on two PCs. Your results depend on
your PC, so compare your FPS before and after.

Nothing changes until you do all three steps: press "1. Check", tick "2. Yes,
these changes look right", then press "3. Apply". The changes take effect after
a restart.

The security trade-off: the preset turns off Memory Integrity, VBS,
Credential Guard, Secure Launch, the Windows hypervisor, Spectre and Meltdown
protections and Control Flow Guard. With those off, your PC is easier to
attack if you ever run something malicious. Hyper-V, WSL 2, Windows Sandbox and
Docker also stop working. Some anti-cheat systems check Windows security
settings, so if a game refuses to start afterwards, undo the preset. Don't use
the FPS preset on a PC you use for banking, work or school.
"Undo all my tweaks" puts everything back after a restart.


6. Undo
-------
- The app saves the original value of every setting before it changes it.
- To go back, open the Windows tweaks page and click "Undo all my tweaks",
  check the list, tick "2. Yes, these changes look right", then press
  "Restore settings". Some settings come back only after a restart.
- Uninstalling the app does NOT undo your tweaks, and it keeps your undo
  information. If you want your old settings back, press "Undo all my tweaks"
  before you uninstall. If you already uninstalled, install the app again and
  the undo button still works.


7. Where your data is
---------------------
- The app itself: C:\Program Files\Roo Industries\Optimization Suite
- Your undo information, saved choices and review files:
    %LOCALAPPDATA%\RooIndustriesOptimizationSuite
  (paste that into the File Explorer address bar to open it)
- The saved Windows tweak state is also kept in the registry at
  HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustriesOptimizationSuite
- Backups for process and game session changes are kept in
  C:\Program Files\Roo Industries\Optimization Suite\backend\state
- The app's log is in the logs folder inside the data folder above
  (Settings > Open logs folder).
Please don't delete these while you're testing, or undo can't work.


8. Reporting problems
---------------------
Use "Report a bug" in the app menu (next to Settings). It fills in your PC
specs for you. Add your Discord or email if you want a reply, describe what
happened, then press "Attach logs" and send.

What gets sent to Roo Industries: the specs shown in the form, your
description, your contact if you gave one, the app's logs and a short list of
which tweaks are applied. Your Windows username, PC name and user folder paths
are removed first, and no serial numbers are collected.

If sending fails, the form lets you save the report to a file so you can send
it by hand.


9. Updating and uninstalling
----------------------------
Before you install a new beta or uninstall, stop anything the app is running
in the background: saved process rules, a running game session and the timer
setting. Otherwise Windows may keep some files in use.

To uninstall, open Settings > Apps > Installed apps > Roo Industries
Optimization Suite > Uninstall, or use "Uninstall Roo Industries Optimization
Suite" in the Start menu. Remember to undo your tweaks first if you want them
gone.

Programs the app opens for you (tool installers, web pages, folders) also run
with administrator rights, because the app itself does.
