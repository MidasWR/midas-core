#!/usr/bin/env bash

# ===== client bundle =====
issue_client_bundle

IP="${MIDAS_RESOLVED_EXTERNAL_IP:-}"
if [[ -z "${IP}" ]]; then
  IP="$(resolve_midas_node_ip)"
fi

echo ""
echo -e "\e[38;5;214m"
echo "███╗   ███╗██╗██████╗  █████╗ ███████╗ ██████╗ ██████╗ ██████╗ ███████╗"
echo "████╗ ████║██║██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗██╔════╝"
echo "██╔████╔██║██║██║  ██║███████║███████╗██║     ██║  ██║██████╔╝█████╗  "
echo "██║╚██╔╝██║██║██║  ██║██╔══██║╚════██║██║     ██║  ██║██╔══██╗██╔══╝  "
echo "██║ ╚═╝ ██║██║██████╔╝██║  ██║███████║╚██████╗╚██████╔╝██║  ██║███████╗"
echo "╚═╝     ╚═╝╚═╝╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝"
echo "                               M I D A S C O R E"
echo -e "\e[0m"
echo -e "\e[32m[INFO] ✔ Installation finished.\e[0m"
echo ""
# echo -e "\e[36m[INFO] Grafana:\e[0m     http://$IP:32000   (admin / prom-operator)"
echo -e "\e[36m[INFO] Frontend:\e[0m    http://$IP:30070"
echo ""

# shellcheck disable=SC2034
OUTPUT_FILE="admin_info.json"

echo -e "\e[33m[INFO] First admin user:\e[0m"

echo "Open the Frontend at http://$IP:30070 to initialize the system and generate the admin user."
# curl -s "http://$IP:8060/api/users/generate" | jq | tee "$OUTPUT_FILE"

echo ""
# echo -e "\e[32m[SUCCESS] Result saved into file: $OUTPUT_FILE\e[0m"
echo -e "\e[32mMidasCore is ready. Time to bend the logs to your will.\e[0m"
echo ""

