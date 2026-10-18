Performance Tuning Utility {Version}
Beta tester guide

Thanks for testing! This is a beta. Please read this once before you start.


1. Installing and opening the app
---------------------------------
- Run RooIndustries-OptimizationSuite-{Version}-setup.exe and follow the steps.
- You don't need to install anything else. .NET and the Windows App SDK are
  already inside the app.
- Open it from the Start menu: Performance Tuning Utility.
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
Only do this for a setup file you got directly from the person who gave you
the beta. You can
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
- If this PC has more than one operating system, check your boot order after
  you change BIOS settings. Some boards move another system to the front when
  BIOS settings are saved. The app's "Restart now" button always starts this
  Windows, but later restarts follow the BIOS boot order.


5. Games, background apps and memory
------------------------------------
- Games & processes > Processes changes a running app's priorities and CPU
  cores. Games with anti-cheat (for example Call of Duty) don't let other apps
  change them while they run. The app tells you which settings are blocked.
  For those games use the Games tab: set it up while the game is closed, press
  Start, then start the game from its launcher (Steam, Battle.net and so on).
- Background apps has a preset that keeps background apps at normal priority
  and moves them to your E-cores (Intel) or your second CCD (AMD Ryzen with two
  CCDs). Your game can still use every core; the preset only limits the
  background apps. Game launchers such as Steam and Battle.net are left alone,
  because games started from them would inherit the same limits. The other preset lowers their CPU priority
  and memory priority instead, so Windows keeps your game's memory first
  when RAM runs low.
- The Memory page has short guides for getting the most out of your RAM.


6. The FPS preset
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


7. Undo
-------
- The app saves the original value of every setting before it changes it.
- To go back, open the Windows tweaks page and click "Undo all my tweaks",
  check the list, tick "2. Yes, these changes look right", then press
  "Restore settings". Some settings come back only after a restart.
- Uninstalling the app does NOT undo your tweaks, and it keeps your undo
  information. If you want your old settings back, press "Undo all my tweaks"
  before you uninstall. If you already uninstalled, install the app again and
  the undo button still works.


8. Where your data is
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


9. Reporting problems
---------------------
Use "Report a bug" in the app menu (next to Settings). It fills in your PC
specs for you. Add your Discord or email if you want a reply, describe what
happened, then press "Attach logs" and send.

What gets sent to the developers: the specs shown in the form, your
description, your contact if you gave one, the app's logs and a short list of
which tweaks are applied. Your Windows username, PC name and user folder paths
are removed first, and no serial numbers are collected.

If this beta can't send reports online, or sending fails, press "Save report
to a file" instead, then "Open folder", and send that zip file to the
person who gave you the beta.


10. Updating and uninstalling
-----------------------------
From this version on, the app updates itself. It checks for a new beta when
it opens and every few hours after that, downloads it in the background and
checks that it really comes from the developers. When it's ready, you see
"Version ... is ready to install". Press Install now: the app closes, updates
and opens again by itself, usually within a minute. You don't need to
download or run a setup file again. You can also check by hand, or turn off
automatic downloads, in Settings > Updates. The app never installs an update
while a game session or the timer setting is running; stop them first.

The installer takes care of the Governor (the part that keeps
your saved process rules on). When you install a new beta, it pauses the
governor, gives your apps their old settings back, updates the files and then
starts the governor again. When you uninstall, it stops the governor, gives
your apps their old settings back and removes it. Your saved rules stay on
your PC, so they come back if you install the app again. Only install a newer
beta over the one you have. Going back to an older beta is not supported.

The first time you open a newer beta, the app locks its data folder so only
administrators can change it. A small window says "Preparing your saved
settings" while it does this. It can take a few minutes. Please keep it open.
After that, what carries over and what does not:
- Your saved rules, settings and undo information carry over. When you use an
  undo or restore that an older beta saved, the app tells you so and asks you
  to confirm first.
- Cleanup backups made by an older beta cannot be restored by the newer one.
  The files stay on your PC, in the data folder. The app tells you this where
  the restore button was.
- Programs and BIOS tool packages that an older beta unpacked are not reused.
  The app unpacks them again when you open them, and the Firmware page asks you
  to set up the BIOS tool again. Import your custom Windows settings file again
  if you had one.
- A removal that an older beta left half done cannot be resumed. Choose the
  apps again to start a new removal.
- Anything the app did not carry over is kept in a folder next to the data
  folder, named RooIndustriesOptimizationSuite.untrusted-followed by letters
  and numbers. You can look inside it, or delete it once you are happy.

Before you install a new beta or uninstall, still stop a running game session
and turn off the timer setting. Otherwise Windows may keep some files in use.

To uninstall, open Settings > Apps > Installed apps > Performance Tuning
Utility > Uninstall, or use "Uninstall Performance Tuning Utility" in the
Start menu. Remember to undo your tweaks first if you want them
gone.

Programs the app opens for you (tool installers, web pages, folders) also run
with administrator rights, because the app itself does.
