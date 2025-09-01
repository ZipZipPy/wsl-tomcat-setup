# WSL Tomcat Setup Script for LabWare LIMS

A comprehensive Bash script to automate the installation and configuration of Apache Tomcat on WSL for LabWare LIMS development and consulting environments.

## Features

- Installs a specific major version of Tomcat (9, 10, or 11).
- Automatically downloads the latest minor version.
- Installs OpenJDK, MS SQL, and PostgreSQL JDBC drivers.
- Creates a dedicated `tomcat` user and group.
- Sets up a `systemd` service for easy management.
- Configures permissions (`setfacl`) for seamless access from Windows File Explorer.
- Includes a robust uninstaller.

## Prerequisites

- Windows Subsystem for Linux (WSL) with an Ubuntu/Debian-based distribution.
- `sudo` privileges.

## Usage

1.  Make the script executable:
    ```bash
    chmod +x tomcat_setup.sh
    ```

2.  Run an interactive installation:
    ```bash
    ./tomcat_setup.sh
    ```

3.  Run a scripted installation:
    ```bash
    # Install Tomcat 11
    ./tomcat_setup.sh --version 11
    ```

4.  Uninstall an existing version:
    ```bash
    # Uninstall Tomcat 11
    ./tomcat_setup.sh --uninstall --version 11
    ```
