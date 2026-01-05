# Technitium DHCP Pool Monitor

This repository contains two Bash scripts to assist in monitoring **Technitium DHCP lease pool utilization**.

As of **Technitium DNS Server 14.3**, there is no built-in or easy way to determine when DHCP scopes are running low on available leases.

Note: These scripts evaluate dynamic DHCP leases only. Reserved leases and excluded address ranges are intentionally excluded from usage and availability calculations to accurately reflect the dynamic lease pool.

Both scripts are written entirely in **Bash** and have minimal dependencies.

## Example Output

```text
Querying Technitium DHCP server at https://10.10.10.5...

======================================================================
SCOPE: LAN
======================================================================
Subnet: 10.10.10.0/255.255.255.0
Range: 10.10.10.1 - 10.10.10.254

--- Pool Calculation ---
Total addresses in range: 254
Excluded addresses: 129
  • 10.10.10.1-10.10.10.25 (25 addresses)
  • 10.10.10.151-10.10.10.254 (104 addresses)

Reserved addresses: 23
  • In excluded ranges: 23
  • Outside excluded ranges: 0
Active pool size: 125

--- Usage Statistics ---
Active dynamic leases: 90
Available addresses: 35
Pool utilization: 72.00%

⚠️  NOTICE: Pool usage is elevated (≥70%)
```

### Output Notes

* One section is displayed per DHCP scope
* Excluded ranges are broken down individually
* Pool utilization is calculated as:

```
(active dynamic leases / active pool size) * 100
```

* When `--json` is used, the same data is returned in structured JSON format
* Elevated status is anything over 75%. Critical is usage over 90%.




## Requirements

* `bash`
* `curl`
* `jq`

---

## Scripts Included

* **`DHCPPoolMonitor.sh`**
  General-purpose CLI tool for querying DHCP pool usage and statistics.

* **`DHCPPoolMonitorZabbixWrapper.sh`**
  Wrapper script designed to return a *single numeric value* suitable for Zabbix monitoring.

---

## DHCPPoolMonitor.sh

### Basic Usage

```bash
./DHCPPoolMonitor.sh --server <URL> --token <TOKEN> [OPTIONS]
```

### Required Arguments

| Argument          | Description                                                                   |
| ----------------- | ----------------------------------------------------------------------------- |
| `--server <URL>`  | Technitium server URL (e.g. `http://192.168.1.1:5380`, `https://192.168.1.1`) |
| `--token <TOKEN>` | API authentication token                                                      |

### Optional Arguments

| Argument         | Description                                                 |
| ---------------- | ----------------------------------------------------------- |
| `--scope <name>` | Query a specific DHCP scope (queries all scopes if omitted) |
| `--json`         | Output results in JSON format                               |
| `--verbose`      | Enable verbose/debug output                                 |
| `--insecure`     | Allow insecure SSL connections (self-signed certificates)   |
| `--warning <num>` | Warning threshold percentage (default: 75)                  |
| `--critical <num>` | Critical threshold percentage (default: 90)                |
| `-h`, `--help`   | Show help message                                           |

### Examples

```bash
./DHCPPoolMonitor.sh --server http://192.168.1.1:5380 --token mytoken123
```

```bash
./DHCPPoolMonitor.sh --server http://192.168.1.1:5380 --token mytoken123 --scope "Main Network"
```

```bash
./DHCPPoolMonitor.sh --server https://10.10.10.5 --token mytoken --insecure
```

```bash
./DHCPPoolMonitor.sh --server http://10.10.10.5:5380 --token mytoken --verbose
```

### Notes

* Default Technitium port is **5380**
* Use:

  * `http://` for non-SSL
  * `https://` for SSL
  * `https://` + `--insecure` for self-signed certificates
* API tokens can be created in:
  **Technitium DNS Server Administration → Sessions → Create Token**

---

## Zabbix Wrapper

The Zabbix wrapper is intended to be used as an **external check** or **user parameter**, returning a single numeric value.

### Usage

```bash
./DHCPPoolMonitorZabbixWrapper.sh <server> <token> <scope> <metric> [insecure]
```

### Parameters

| Parameter  | Description                                          |
| ---------- | ---------------------------------------------------- |
| `server`   | Technitium server URL (e.g. `https://10.10.10.5`)    |
| `token`    | API authentication token                             |
| `scope`    | DHCP scope name (e.g. `LAN`, `Guest`, `Chromebooks`) |
| `metric`   | Metric to retrieve (see below)                       |
| `insecure` | Optional: use for self-signed SSL certificates       |

### Available Metrics

| Metric                | Description                         |
| --------------------- | ----------------------------------- |
| `usage_percent`       | Pool utilization percentage (0–100) |
| `active_leases`       | Number of active dynamic leases     |
| `available_addresses` | Available addresses in the pool     |
| `active_pool_size`    | Total usable pool size              |
| `total_range`         | Total addresses in the scope range  |
| `excluded_addresses`  | Number of excluded addresses        |
| `reserved_addresses`  | Number of reserved addresses        |

### Examples

```bash
# Get pool usage percentage
./DHCPPoolMonitorZabbixWrapper.sh https://10.10.10.5 mytoken123 mylan usage_percent insecure
```

```bash
# Get active lease count
./DHCPPoolMonitorZabbixWrapper.sh https://10.10.10.5 mytoken123 mylan active_leases insecure
```

```bash
# Get available addresses (HTTP, no SSL)
./DHCPPoolMonitorZabbixWrapper.sh http://10.10.10.5:5380 mytoken123 mylan available_addresses
```

### Zabbix Item Key Format

```text
DHCPPoolMonitorZabbixWrapper.sh[https://10.10.10.5,{},LAN,usage_percent,insecure]
```

### Zabbix Notes

* Returns a **single numeric value** suitable for Zabbix
* Returns **0** on error or if no data is available
* Requires `jq`
* **`DHCPPoolMonitor.sh` must be in the same directory**
