#!/usr/bin/env bash
# /home/media/scripts/docker/docker-check.sh
echo "=== Docker Daemon Status ==="
if systemctl is-active --quiet docker; then
    echo "Docker Daemon: Running"
else
    echo "Docker Daemon: Stopped/Unavailable"
    exit 0
fi

echo -e "\n=== Running Containers & Port Mappings ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "\n=== Arr Stack Connectivity Checks ==="
declare -A ARR_PORTS=( ["Sonarr"]="8989" ["Radarr"]="7878" ["Prowlarr"]="9696" ["Bazarr"]="6767" ["Jellyfin"]="8096" ["qBittorrent"]="8080" )

for app in "${!ARR_PORTS[@]}"; do
    port="${ARR_PORTS[$app]}"
    if nc -z -w 2 127.0.0.1 "$port" 2>/dev/null; then
        echo -e "  [OK] $app listening on port $port"
    else
        echo -e "  [FAIL] $app NOT responding on port $port"
    fi
done
