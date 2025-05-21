#!/bin/bash

# Update Cloudflare's proxy IP list and block https traffic from other IPs.
# Suggested location: /usr/local/bin/update_cloudflare_ips.sh
# Suggested cron frequency: daily, weekly, or monthly (the IP ranges don't change often!)

# Define paths for the generated Nginx configuration files
CLOUDFLARE_REAL_IPS_PATH="/etc/nginx/conf.d/cloudflare_real_ips.conf"
CLOUDFLARE_ALLOWLIST_PATH="/etc/nginx/conf.d/cloudflare_allowlist.conf"

# Cloudflare IP list URLs
IPV4_URL="https://www.cloudflare.com/ips-v4"
IPV6_URL="https://www.cloudflare.com/ips-v6"

# Set to true to block traffic at firewall. Set to false to allow but respond with 403.
UFW_RULES=true

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Determine UFW IPv6 status ---
# Read the IPV6 setting from /etc/default/ufw
UFW_IPV6_ENABLED=false
if grep -qE '^IPV6=yes' /etc/default/ufw; then
    UFW_IPV6_ENABLED=true
fi
echo "UFW IPv6 enabled: ${UFW_IPV6_ENABLED}"

# --- Initialize configuration files with headers ---
# Create temporary files to build the content safely before moving them.
TEMP_REAL_IPS_FILE=$(mktemp)
TEMP_ALLOWLIST_FILE=$(mktemp)

echo "# https://www.cloudflare.com/ips" > "${TEMP_REAL_IPS_FILE}"
echo "# Generated at $(LC_ALL=C date)" >> "${TEMP_REAL_IPS_FILE}"
echo "" >> "${TEMP_REAL_IPS_FILE}"

echo "# https://www.cloudflare.com/ips" > "${TEMP_ALLOWLIST_FILE}"
echo "# Generated at $(LC_ALL=C date)" >> "${TEMP_ALLOWLIST_FILE}"
echo "" >> "${TEMP_ALLOWLIST_FILE}"

echo "geo \$realip_remote_addr \$cloudflare_ip {
    default 0;" >> "${TEMP_ALLOWLIST_FILE}"

# --- Remove existing Cloudflare UFW rules (if UFW_RULES is true) ---
if [ "${UFW_RULES}" = true ] ; then
    echo "Removing existing Cloudflare UFW rules..."
    # Get rule numbers for all 'cloudflare_proxy_ip' comments and delete them in reverse order.
    # Using -E for extended regex and '$' to ensure exact match at the end of the comment string.
    ufw status numbered | grep -E 'comment "cloudflare_proxy_ip"$' | awk '{print $1}' | sort -nr | while read rule_num; do
        echo "Deleting UFW rule ${rule_num} (cloudflare_proxy_ip)..."
        # Use --force to avoid confirmation prompts in a script
        ufw --force delete "${rule_num}"
    done
    echo "Existing Cloudflare UFW rules removed."
fi

# --- Process IPv4 addresses ---
echo "Processing Cloudflare IPv4 ranges..."
if IPV4_RAW_CONTENT=$(curl -s "${IPV4_URL}"); then
    # Format for set_real_ip_from and append to the real IPs file
    printf "%s\n" "${IPV4_RAW_CONTENT}" | sed -E '/^[[:space:]]*$/d; s/^/set_real_ip_from /; s/$/;/' >> "${TEMP_REAL_IPS_FILE}"

    # Format for geo block and append to the allowlist file
    printf "%s\n" "${IPV4_RAW_CONTENT}" | sed -E '/^[[:space:]]*$/d; s/^/    /; s/$/ 1;/' >> "${TEMP_ALLOWLIST_FILE}"

    # Conditionally add UFW rules for IPv4 only
    if [ "${UFW_RULES}" = true ] ; then
        printf "%s\n" "${IPV4_RAW_CONTENT}" | while IFS= read -r ip; do
            if [[ -n "$ip" ]]; then # Ensure IP is not empty
                echo "Adding UFW rule for IPv4: $ip (Nginx HTTPS)"
                # Using 'Nginx HTTPS' app profile and 'cloudflare_proxy_ip' comment.
                ufw allow from "${ip}" to any app 'Nginx HTTPS' comment "cloudflare_proxy_ip"
            fi
        done
    fi
else
    echo "Error fetching IPv4 ranges. Aborting."
    rm "${TEMP_REAL_IPS_FILE}" "${TEMP_ALLOWLIST_FILE}"
    exit 1
fi

# Add blank lines for readability between IPv4 and IPv6 blocks in the generated files
printf "\n" >> "${TEMP_REAL_IPS_FILE}"
printf "\n" >> "${TEMP_ALLOWLIST_FILE}"

# --- Process IPv6 addresses ---
echo "Processing Cloudflare IPv6 ranges..."
if IPV6_RAW_CONTENT=$(curl -s "${IPV6_URL}"); then
    # Format for set_real_ip_from and append to the real IPs file
    printf "%s\n" "${IPV6_RAW_CONTENT}" | sed -E '/^[[:space:]]*$/d; s/^/set_real_ip_from /; s/$/;/' >> "${TEMP_REAL_IPS_FILE}"

    # Format for geo block and append to the allowlist file
    printf "%s\n" "${IPV6_RAW_CONTENT}" | sed -E '/^[[:space:]]*$/d; s/^/    /; s/$/ 1;/' >> "${TEMP_ALLOWLIST_FILE}"

    # Conditionally add UFW rules for IPv6 if UFW_RULES is true AND IPv6 is enabled in UFW config
    if [ "${UFW_RULES}" = true ] && [ "${UFW_IPV6_ENABLED}" = true ] ; then
        printf "%s\n" "${IPV6_RAW_CONTENT}" | while IFS= read -r ip; do
            if [[ -n "$ip" ]]; then # Ensure IP is not empty
                echo "Adding UFW rule for IPv6: $ip (Nginx HTTPS)"
                ufw allow from "${ip}" to any app 'Nginx HTTPS' comment "cloudflare_proxy_ip"
            fi
        done
    fi
else
    echo "Error fetching IPv6 ranges. Aborting."
    rm "${TEMP_REAL_IPS_FILE}" "${TEMP_ALLOWLIST_FILE}"
    exit 1
fi

# --- Finalize configuration files ---
echo "}
# if you wish to only allow cloudflare IP's add this to your site block for each host:
#if (\$cloudflare_ip != 1) {
#    return 403;
#}" >> "${TEMP_ALLOWLIST_FILE}"

echo "real_ip_header CF-Connecting-IP;" >> "${TEMP_REAL_IPS_FILE}"
echo "real_ip_recursive on;" >> "${TEMP_REAL_IPS_FILE}"

# --- Validate and apply Nginx configuration ---
echo "Testing Nginx configuration..."
if nginx -t; then
    mv "${TEMP_REAL_IPS_FILE}" "${CLOUDFLARE_REAL_IPS_PATH}"
    mv "${TEMP_ALLOWLIST_FILE}" "${CLOUDFLARE_ALLOWLIST_PATH}"
    echo "Nginx configuration files updated."
    echo "Reloading Nginx..."
    if systemctl reload nginx; then
        echo "Nginx reloaded successfully."
    else
        echo "Error reloading Nginx. Check Nginx logs."
        exit 1
    fi
else
    echo "Nginx configuration test failed. Not applying changes."
    rm "${TEMP_REAL_IPS_FILE}" "${TEMP_ALLOWLIST_FILE}" # Clean up temp files on failure
    exit 1
fi

# Clean up temporary files (should already be moved, but as a safeguard)
rm -f "${TEMP_REAL_IPS_FILE}" "${TEMP_ALLOWLIST_FILE}"
