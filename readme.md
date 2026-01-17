
# Software Installer via WinGet, MS Store and Local


![License](https://img.shields.io/github/license/osmanonurkoc/WinGet_Installer)
![Release](https://img.shields.io/github/v/release/osmanonurkoc/WinGet_Installer)
![Downloads](https://img.shields.io/github/downloads/osmanonurkoc/WinGet_Installer/total)
![Language](https://img.shields.io/badge/language-PowerShell-blue)

A modern, dark-mode compatible GUI wrapper for the Windows Package Manager (Winget). This tool allows you to bulk install applications, search online repositories, and perform full system software backups/restorations.

---
### 📥 Download Latest

[![Download Release](https://img.shields.io/badge/Download-Latest%20Release-success?style=for-the-badge&logo=windows)](https://github.com/osmanonurkoc/WinGet_Installer/releases/latest)

## 📸 Screenshots

<p align="center">
  <img src="images/screenshot1.png" width="85%" alt="Category View" />
  <br/>
  <img src="images/screenshot2.png" width="85%" alt="Backup and Restore" />
  <br/>
  <img src="images/screenshot3.png" width="85%" alt="Search Repository" />
  <br/>
  <img src="images/screenshot4.png" width="85%" alt="Updates" />
</p>

---

## 🔥 Features

* **Bulk Installation:** Install dozens of apps defined in `config.xml` with a single click.
* **Repository Search (New):** * **Live Filter:** Instantly filter through the cached Winget repository as you type.
  * **Online Search:** Press `ENTER` to perform a deep search across Winget and MSStore sources to find any application.
* **Backup & Restore (New):** * **Export:** Create a snapshot of your installed software (JSON format).
  * **Restore:** Restore your software suite on a fresh Windows installation using the backup file.
* **Smart Source Repair:** Automatically detects and fixes Winget 404 errors and Source Certification errors (0x8a15005e).
* **Modern UI:** A clean WPF interface with a built-in Dark/Light theme toggle.
* **Local App Support:** Can trigger local `.exe` or `.msi` installers from a `Programs` folder.
* **Silent Operation:** Hides the background PowerShell console window automatically.
* **App Upgrades:** Unified view for Upgrades and Pinned applications with visual separator.

## 🚀 How to Run

1.  Download the latest release zip.
2.  Extract the archive.
3.  Right-click `WinGet_Installer.ps1`.
4.  Select **Run with PowerShell**.

> **Note:** If you run into execution policy errors, open PowerShell as Admin and run: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

## ⚙️ Configuration (config.xml)

The application list is fully customizable via `config.xml`.

```xml
<InstallerConfig>
  <WingetApps>
    <Category Name="Browsers">
      <App Name="Google Chrome" Id="Google.Chrome" />
      <App Name="Firefox" Id="Mozilla.Firefox" />
    </Category>
    <Category Name="Communication">
      <App Name="Discord" Id="Discord.Discord" />
    </Category>
  </WingetApps>

  <LocalApps>
    <App Name="My Custom App" Path="Programs\setup.exe" />
    <App Name="My Custom App (with arguments)"
    Path="Programs\setup.exe"
    Args="-R -c -install -autostart -filter:&quot;LAN,WLAN&quot;" />
  </LocalApps>
</InstallerConfig>
```
## 🛠️ Auto-Repair Logic

This tool is designed to be resilient. If Winget fails during installation:

1.  **Certificate Errors:** It will automatically download the latest Winget release from Microsoft servers via BITS and update the package manager.
    
2.  **Source Errors:** It will reset the Winget sources to factory defaults and force an update.
    
3.  **Fallback Strategy:** It intelligently switches between `winget` and `msstore` sources based on the App ID format.
    


## 📄 License
This project is licensed under the [MIT License](LICENSE).

---
*Created by [@osmanonurkoc](https://www.osmanonurkoc.com)*
