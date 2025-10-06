# Agent Instructions for tomcat_setup.sh

This document provides guidance for agents working on the `tomcat_setup.sh` script.

## Project Overview

The `tomcat_setup.sh` script is a comprehensive utility designed to automate the installation and configuration of Apache Tomcat on WSL (Windows Subsystem for Linux), specifically for LabWare LIMS development environments.

## Key Conventions and Dependencies

When modifying the script, please adhere to the following conventions:

1.  **`jq` for JSON Parsing:** The script uses `jq` to parse JSON responses from APIs, such as the GitHub API for fetching driver information. `jq` is a required dependency and is installed by the script. Do not use less reliable methods like `grep` or `sed` for parsing JSON.

2.  **Microsoft SQL Server JDBC Driver:** When downloading the MS SQL Server JDBC driver, the script must search for the `.jre11.jar` file specifically. According to official Microsoft documentation, this single JAR is compatible with Java 11 and all newer versions. Do not add logic to search for other JRE-specific versions (e.g., `.jre17.jar`, `.jre21.jar`), as this is unnecessary and goes against the documented distribution method.

3.  **End-to-End Testing:** Before submitting any changes, perform a full end-to-end test by running the installation and uninstallation processes to ensure no regressions have been introduced. The `--debug` flag can be used to bypass interactive prompts during testing.