#!/bin/bash

# =======================================================
# End-to-end Tomcat Setup Script for LabWare LIMS
# Version: Draft
# Author: Supawee Sitthiparkkun
#
# This script automates the following:
#   - Installs dependencies (OpenJDK 21, ACL).
#   - Fetches and installs a selected version of Tomcat.
#   - Downloads MS SQL Server and PostgreSQL JDBC drivers.
#   - Creates a 'tomcat' user and group.
#   - Configures Tomcat as a systemd service.
#   - Creates the required directory structure for LabWare LIMS.
#   - Adds the current user to the 'tomcat' group.
#   - Provides an uninstall option to remove the Tomcat installation.
# =======================================================

# Exit immediately if a command exits with a non-zero status.
set -e
set -o pipefail

# --- Configuration ---
# The version of OpenJDK to install.
JAVA_VERSION="21"

# --- Script Internal Variables ---
# Get the current user to add them to the tomcat group.
CURRENT_USER="$USER"
TOMCAT_VERSION=""
MINOR_VERSION=""
INSTALL_DIR=""
UNINSTALL_FLAG=false
TMP_FILES=() # Array to hold temporary files for cleanup

trap 'rm -f "${TMP_FILES[@]}"' EXIT

# --- Functions ---
# Fetches available major versions of Tomcat from the Apache download server.
get_available_major_versions() {
  local download_url="https://dlcdn.apache.org/tomcat/"
  curl -s "$download_url" | grep -oP 'href="tomcat-([0-9]+)/"' | cut -d'-' -f2 | cut -d'/' -f1
}

# Fetches the latest minor version of Tomcat for a given major version.
get_latest_minor_version() {
  local major_version="$1"
  local download_url="https://dlcdn.apache.org/tomcat/tomcat-$major_version/"
  
  # Fetches the latest version by looking for the highest version number in the directory listing.
  # This regex is more flexible to handle different versioning schemes, including milestone releases (e.g., -M1).
  local latest_version=$(curl -s "$download_url" | grep -oP "v$major_version(\.[0-9]+)+(-[a-zA-Z0-9]+)?" | sort -V | tail -n 1 | sed 's/v//')

  if [ -z "$latest_version" ]; then
    echo "Error: Could not determine the latest minor version for Tomcat $major_version." >&2
    return 1
  fi

  echo "$latest_version"
  return 0
}

# Checks if an installed Tomcat with the same version already exists.
check_for_existing_install() {
  local major_version="$1"
  local install_dir="/opt/tomcat$major_version"

  # Check if the installation directory exists.
  if [ -d "$install_dir" ]; then
    echo "An existing Tomcat installation was found at '$install_dir'."

    if [ "$DEBUG_MODE" = true ]; then
      uninstall_tomcat "$major_version"
      return # In debug mode, we continue to test the install
    fi

    read -p "Do you want to uninstall the existing version or just stop any running service and exit? (uninstall/stop) " action
    echo ""
	if [[ "$action" == "uninstall" ]]; then
      # Uninstall the old version and then EXIT the script.
      uninstall_tomcat "$major_version"
      echo "Existing version has been uninstalled. Exiting script."
      exit 0
    elif [[ "$action" == "stop" ]]; then
      # If the user chooses 'stop', check if the service is running before trying to stop it.
      local service_name="tomcat$major_version.service"
      if systemctl is-active --quiet "$service_name"; then
          echo "Stopping the existing Tomcat service..."
          sudo systemctl stop "$service_name"
      else
          echo "Installation directory exists, but the service is not active."
      fi
      echo "Exiting script."
      exit 1
	else
      echo "Invalid option. Exiting script."
      exit 1
    fi
  fi
}

# Generic function to download the latest JDBC driver from GitHub.
download_latest_jdbc_from_github() {
  local repo_owner="$1"
  local repo_name="$2"
  # Accepts a space-separated string of patterns, e.g., ".jre21.jar .jre17.jar"
  local file_patterns="$3"
  local friendly_name="$4"
  local download_url=""

  echo "Downloading latest $friendly_name JDBC Driver"
  
  # Use GitHub API for reliability.
  local api_url="https://api.github.com/repos/$repo_owner/$repo_name/releases/latest"
  
  # Fetch the release info once.
  local release_info
  if ! release_info=$(curl -s "$api_url"); then
      echo "Error: Failed to fetch release info from GitHub API." >&2
      return 1
  fi

  # Loop through the provided patterns to find a suitable download URL.
  for pattern in $file_patterns; do
      download_url=$(echo "$release_info" | jq -r --arg p "$pattern" '.assets[] | .browser_download_url | select(test($p))')
      if [ -n "$download_url" ]; then
          echo "Found a matching driver with pattern: $pattern"
          break # Exit the loop once a match is found
      fi
  done
  
  if [ -z "$download_url" ]; then
    echo "Error: Could not find a suitable $friendly_name driver download URL with the provided patterns." >&2
    return 1
  fi
  
  # Get the original filename from the URL.
  local filename
  filename=$(basename "$download_url")
  local download_path
  download_path=$(mktemp)
  TMP_FILES+=("$download_path")
  
  echo "Downloading from: $download_url"
  if wget --quiet -O "$download_path" "$download_url"; then
    echo "Download successful."
    
    # 1. Copy the file to the destination.
    sudo cp "$download_path" "$INSTALL_DIR/lib/$filename"
    # 2. Set the correct owner so Tomcat can use it.
    sudo chown tomcat:tomcat "$INSTALL_DIR/lib/$filename"
    # 3. Set read permissions for group and others.
    sudo chmod 644 "$INSTALL_DIR/lib/$filename"
    
    echo "$friendly_name JDBC driver installed to $INSTALL_DIR/lib/$filename"
  else
    echo "Error: Failed to download the $friendly_name JDBC driver." >&2
    # The cleanup of the temp file is handled by the trap.
    return 1
  fi
  echo ""
}

# Uninstalls a Tomcat installation.
uninstall_tomcat() {
  local major_version="$1"
  local service_name="tomcat$major_version.service"
  local install_dir="/opt/tomcat$major_version"

  echo "--- Uninstalling Tomcat $major_version ---"
  if [ "$DEBUG_MODE" = false ]; then
    echo "This will permanently delete the Tomcat installation, user, and service."
    read -p "Are you sure you want to continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Uninstall cancelled."
      exit 1
    fi
  fi

  # Stop and disable the service
  if systemctl is-active --quiet "$service_name"; then
    echo "Stopping $service_name..."
    sudo systemctl stop "$service_name"
  fi
  if systemctl is-enabled --quiet "$service_name"; then
    echo "Disabling $service_name..."
    sudo systemctl disable "$service_name"
  fi
  
  if [ -f "/etc/systemd/system/$service_name" ]; then
      sudo rm -f "/etc/systemd/system/$service_name"
      sudo systemctl daemon-reload
  else
      echo "Service file not found."
  fi

  # Remove the current user from the 'tomcat' group FIRST.
  # This ensures the group is empty before we try to delete it.
  if groups "$CURRENT_USER" | grep -q '\btomcat\b'; then
    echo "Removing user $CURRENT_USER from tomcat group..."
    sudo gpasswd -d "$CURRENT_USER" tomcat
  fi

  # Now, it is safe to delete the 'tomcat' user and its primary group.
  if id "tomcat" &>/dev/null; then
    echo "Deleting tomcat user and group..."
    sudo userdel tomcat
    # As a fallback, try to delete the group if it still exists
    if getent group tomcat > /dev/null; then
        sudo groupdel tomcat
    fi
  else
    echo "User tomcat not found."
  fi

  # Remove the installation directory
  if [ -d "$install_dir" ]; then
    echo "Deleting installation directory $install_dir..."
    sudo rm -rf "$install_dir"
  else
    echo "Installation directory $install_dir not found."
  fi

  # Remove the webtemp directory
  if [ -d "/opt/webtemp" ]; then
    echo "Deleting webtemp directory..."
    sudo rm -rf "/opt/webtemp"
  fi

  echo "Tomcat $major_version has been uninstalled."
}

# --- Pre-computation ---
# Determine the latest available Tomcat version for use in prompts.
# This ensures the examples shown to the user are always up-to-date.
LATEST_TOMCAT_VERSION=$(get_available_major_versions | sort -nr | head -n 1)

# --- Script Start ---
echo "Starting the end-to-end Tomcat setup for LabWare LIMS."
echo ""

# --- Step 1: Argument Parsing ---
echo "--- Step 1: Argument Parsing ---"
DEBUG_MODE=false
UNINSTALL_FLAG=false
TOMCAT_VERSION=""
ARGUMENTS_FOUND=false

# Keep track of the original arguments to check if any were passed
if [ $# -gt 0 ]; then
  ARGUMENTS_FOUND=true
fi

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --version)
      # Check if a value exists for the --version flag
      if [ -z "$2" ] || [[ "$2" == -* ]]; then
        echo "Error: The --version argument requires a value (e.g., --version $LATEST_TOMCAT_VERSION)." >&2
        exit 1
      fi
      TOMCAT_VERSION="$2"
      shift 2
      ;;
    --uninstall)
      UNINSTALL_FLAG=true
      shift
      ;;
    --debug)
      DEBUG_MODE=true
      shift
      ;;
    *)
      # Silently ignore unknown options
      shift
      ;;
  esac
done

if [ "$ARGUMENTS_FOUND" = true ]; then
  echo "Command-line arguments detected."
  if [ -n "$TOMCAT_VERSION" ]; then
    echo "  - Target Version: $TOMCAT_VERSION"
  fi
  if [ "$UNINSTALL_FLAG" = true ]; then
    echo "  - Action: Uninstall"
  fi
  if [ "$DEBUG_MODE" = true ]; then
    echo "  - Mode: Debug enabled"
  fi
else
  echo "No command-line arguments detected. Proceeding with interactive setup."
fi
echo ""

# --- Step 2: Determine Target Version ---
echo "--- Step 2: Determine Target Version ---"

# If an install is happening without a version argument, ask the user.
if [ "$UNINSTALL_FLAG" = false ] && [ -z "$TOMCAT_VERSION" ]; then
  mapfile -t AVAILABLE_VERSIONS < <(get_available_major_versions | sort -n | uniq)

  echo "Available Tomcat major versions:"
  for version in "${AVAILABLE_VERSIONS[@]}"; do
    echo "  - Tomcat $version"
  done
  echo ""

  while [[ ! " ${AVAILABLE_VERSIONS[@]} " =~ " ${TOMCAT_VERSION} " ]]; do
    read -p "Please enter the major version to install (e.g., $LATEST_TOMCAT_VERSION): " TOMCAT_VERSION
    if [[ ! " ${AVAILABLE_VERSIONS[*]} " =~ " ${TOMCAT_VERSION} " ]]; then
      echo "Invalid version. Please select from the list."
    fi
  done
fi

if [ -n "$TOMCAT_VERSION" ]; then
    echo "Tomcat major version set to: $TOMCAT_VERSION"
else
    echo "No Tomcat version specified (required for uninstall)."
fi
echo ""

# --- Step 3: Select Action (Install/Uninstall) ---
echo "--- Step 3: Select Action (Install/Uninstall) ---"

if [ "$UNINSTALL_FLAG" = true ]; then
    echo "Uninstall action selected."
    # Final validation for uninstall
    if [ -z "$TOMCAT_VERSION" ]; then
        echo "Error: The --version argument is required for uninstalling." >&2
        exit 1
    fi
    
    # This block now ONLY calls the uninstaller and exits.
    echo ""
    uninstall_tomcat "$TOMCAT_VERSION"
    echo "Uninstall complete."
	echo ""
    exit 0
else
    # This block now ONLY prepares for the installation.
    echo "Install action selected."
    MINOR_VERSION=$(get_latest_minor_version "$TOMCAT_VERSION")
    echo "Full version for installation: $MINOR_VERSION"
    echo ""
fi

# --- Step 4: Pre-installation Checks ---
echo "--- Step 4: Pre-installation Checks ---"

# This check for an existing install now ONLY runs when installing.
check_for_existing_install "$TOMCAT_VERSION"

# Privilege Check
echo "Checking for administrative privileges..."
# Silently check if a password is required.
if sudo -n true 2>/dev/null; then
    echo "Administrative privileges are active."
else
    # If a password is required, prompt the user now.
    echo "This script requires administrative privileges. Please enter your password if prompted."
    if ! sudo -v; then
        echo "Error: Could not obtain administrative privileges." >&2
        exit 1
    fi
fi
# Keep the sudo session alive in the background
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
echo ""

# --- Step 5: Install Dependencies ---
echo "--- Step 5: Updating packages and installing OpenJDK $JAVA_VERSION and ACL ---"
sudo apt-get update
sudo apt-get upgrade -y
# Install acl to manage file permissions with setfacl
sudo apt-get install -y "openjdk-$JAVA_VERSION-jdk" acl curl wget lsb-release jq
echo ""

# --- Step 6: Download and Install Tomcat ---
echo "--- Step 6: Downloading and installing Tomcat ---"
INSTALL_DIR="/opt/tomcat$TOMCAT_VERSION"
DOWNLOAD_URL="https://dlcdn.apache.org/tomcat/tomcat-$TOMCAT_VERSION/v$MINOR_VERSION/bin/apache-tomcat-$MINOR_VERSION.tar.gz"
DOWNLOAD_FILE=$(mktemp)

echo "Download URL: $DOWNLOAD_URL"
wget --progress=bar:force -O "$DOWNLOAD_FILE" "$DOWNLOAD_URL"

sudo mkdir -p "$INSTALL_DIR"
sudo tar xzf "$DOWNLOAD_FILE" -C "$INSTALL_DIR" --strip-components=1
echo "Extraction successful. Tomcat installed in $INSTALL_DIR."

rm "$DOWNLOAD_FILE"
echo "Cleaned up installation files."
echo ""

# --- Step 7: Create User, Group, and Directories ---
echo "--- Step 7: Creating dedicated user and directories ---"
sudo groupadd --system --force tomcat
if ! id "tomcat" >/dev/null 2>&1; then
    sudo useradd -d "$INSTALL_DIR" --system -g tomcat -s /bin/false tomcat
fi
sudo chown -R tomcat:tomcat "$INSTALL_DIR"

# Set permissions for the entire conf directory
echo "Setting permissions for the conf directory."
sudo chown -R tomcat:tomcat "$INSTALL_DIR/conf"
sudo chmod -R g+w "$INSTALL_DIR/conf"
sudo setfacl -R -m g:tomcat:rwx "$INSTALL_DIR/conf"
sudo setfacl -Rdm g:tomcat:rwx "$INSTALL_DIR/conf"

# Set permissions for the lib directory for easy library management
echo "Setting permissions for the lib directory."
sudo chmod -R g+w "$INSTALL_DIR/lib"
sudo setfacl -R -m g:tomcat:rwx "$INSTALL_DIR/lib"
sudo setfacl -Rdm g:tomcat:rwx "$INSTALL_DIR/lib"

# Set permissions for the webapps directory for easy deployment
echo "Setting permissions for the webapps directory."
sudo chmod -R g+w "$INSTALL_DIR/webapps"
sudo setfacl -R -m g:tomcat:rwx "$INSTALL_DIR/webapps"
sudo setfacl -Rdm g:tomcat:rwx "$INSTALL_DIR/webapps"

# Create Catalina and webtemp directories with correct permissions
echo "Creating and setting permissions for the Catalina and webtemp directories."
sudo mkdir -p "$INSTALL_DIR/conf/Catalina/localhost"
sudo mkdir -p "/opt/webtemp"
sudo chown -R tomcat:tomcat "$INSTALL_DIR/conf/Catalina"
sudo chown -R tomcat:tomcat "/opt/webtemp"
sudo setfacl -R -m g:tomcat:rwx "$INSTALL_DIR/conf/Catalina/localhost"
sudo setfacl -Rdm g:tomcat:rwx "$INSTALL_DIR/conf/Catalina/localhost"
sudo setfacl -R -m g:tomcat:rwx "/opt/webtemp"
sudo setfacl -Rdm g:tomcat:rwx "/opt/webtemp"

# Add current user to the tomcat group
echo "Adding user '$CURRENT_USER' to the 'tomcat' group."
sudo usermod -aG tomcat "$CURRENT_USER"
echo ""

# --- Step 8: Download and Install JDBC Drivers ---
echo "--- Step 8: Download and Install JDBC Drivers ---"
# For MS SQL, the .jre11.jar is compatible with Java 11 and newer.
download_latest_jdbc_from_github "microsoft" "mssql-jdbc" ".jre11.jar" "MS SQL Server"
# For PostgreSQL, we use a more specific regex to ensure we get the main JAR.
download_latest_jdbc_from_github "pgjdbc" "pgjdbc" "postgresql-[0-9.]+\.jar$" "PostgreSQL"

# --- Step 9: Create setenv.sh and configure memory ---
echo "--- Step 9: Configuring Tomcat memory settings ---"
SETENV_FILE="$INSTALL_DIR/bin/setenv.sh"
# Use a 'here document' for clarity.
sudo bash -c "cat > '$SETENV_FILE'" <<EOF
export JAVA_OPTS="-Djava.awt.headless=true -Xms512m -Xmx1024m"
EOF
sudo chown tomcat:tomcat "$SETENV_FILE"
sudo chmod +x "$SETENV_FILE"
echo "Memory settings configured in $SETENV_FILE."
echo ""

# --- Step 10: Create systemd service ---
echo "--- Step 10: Creating and enabling Tomcat systemd service ---"
SERVICE_FILE="/etc/systemd/system/tomcat$TOMCAT_VERSION.service"
JAVA_HOME_PATH=$(update-java-alternatives -l | grep "^java-1.$JAVA_VERSION" | awk '{print $3}')

if [ -z "$JAVA_HOME_PATH" ]; then
    echo "Error: Could not determine JAVA_HOME for OpenJDK $JAVA_VERSION."
    exit 1
fi

sudo bash -c "cat > '$SERVICE_FILE'" <<EOF
[Unit]
Description=Apache Tomcat $TOMCAT_VERSION Web Application Server
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=$JAVA_HOME_PATH"
Environment="CATALINA_HOME=$INSTALL_DIR"
Environment="CATALINA_BASE=$INSTALL_DIR"
Environment="CATALINA_PID=$INSTALL_DIR/temp/tomcat.pid"
ExecStart=$INSTALL_DIR/bin/startup.sh
ExecStop=$INSTALL_DIR/bin/shutdown.sh
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "tomcat$TOMCAT_VERSION.service"
sudo systemctl start "tomcat$TOMCAT_VERSION.service"

# Check status to confirm it started correctly.
sudo systemctl status --no-pager "tomcat$TOMCAT_VERSION.service"
echo ""
echo "Tomcat service is created, enabled, and started."
echo ""

# --- Script End ---
echo "--- Setup Complete ---"
echo ""
echo "A new terminal session is required for the group changes to take effect."

# Check if running in WSL and provide the Windows Explorer path if it is.
if [[ -n "$WSL_DISTRO_NAME" ]] || grep -q -i "microsoft" /proc/version; then
    echo "You can now access the Tomcat directories from Windows File Explorer."
    echo "Path: \\\\wsl.localhost\\$(lsb_release -is)\\opt\\tomcat$TOMCAT_VERSION\\"
    echo "You can deploy your WebLIMS WAR file to the webapps directory at this location."
fi
echo ""