#  OneDrive Setup Script for Linux - Deployment from Management System

This script automates the setup of the **OneDrive** client on Linux machines. It installs required packages, cleans up old configurations, handles Microsoft authentication, performs an initial sync, fixes symlinks, and configures the system for automatic syncing via **systemd**.

---

![OneDrive Logo](https://upload.wikimedia.org/wikipedia/commons/6/60/Microsoft_Office_OneDrive_%282014-2019%29.svg)
![Landscape Logo]([[https://git.ib-ci.com/projects/LANDSCAPE/avatar.png?s=96&v=1700652166802](https://beehiiv-images-production.s3.amazonaws.com/uploads/asset/file/815bc1a2-4a00-45e4-98da-b0547c892a55/Canonical_Landscape_Logo..jpg)](https://beehiiv-images-production.s3.amazonaws.com/uploads/asset/file/815bc1a2-4a00-45e4-98da-b0547c892a55/Canonical_Landscape_Logo..jpg))

##  Script Overview

### 1. **Install Required Packages**
   - Installs **OneDrive**, **zenity**, and **curl** if they are not already installed.

### 2. **Clean Up Old Configurations**
   - Removes any existing OneDrive configuration to start fresh.

### 3. **Microsoft Authentication**
   - Launches the authentication process via **yad** to prompt the user for the authentication URL and complete the login.

### 4. **First Sync (Upload-Only)**
   - Performs an initial sync to upload the user's Desktop folder to OneDrive.

### 5. **Fix Symlink**
   - Checks if the Desktop folder is properly linked and fixes the symlink if needed.

### 6. **Create systemd Service**
   - Sets up a **systemd** service to sync the Desktop folder to OneDrive on startup.

### 7. **Enable Lingering Option**
   - Ensures the systemd service stays active even after the user logs out.

### 8. **Start the Service**
   - Starts the systemd service to automatically sync files to OneDrive on boot.

---

##  Conclusion

This script automates the entire **OneDrive** setup process on Linux. Once deployed, it ensures seamless syncing of the Desktop folder with OneDrive and sets up everything needed for ongoing automatic synchronization.

Created by:Belmin DUran 21.04.2025
