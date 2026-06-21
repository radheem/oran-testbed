#!/bin/bash

_print_container_info() {
    # 'local' is fine here because we are inside a function
    local container_search="$1"
    local container_name container_id container_ip container_ports 
    local container_ext_ports container_network container_working_dir 
    local container_depends_on_raw container_depends_on

    container_name="$(docker container inspect --format "{{.Name}}" "$container_search" | sed 's/\///')"
    container_id="$(docker container inspect --format "{{.ID}}" "$container_search")"
    container_ip="$(docker container inspect --format "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}" "$container_search")"
    container_ports="$(docker container inspect "$container_search" | jq '.[].NetworkSettings.Ports | keys[]')"
    container_ext_ports="$(docker container inspect "$container_search" | jq -r '.[].NetworkSettings.Ports | to_entries[] | select(.value != null) | .value[0].HostPort' | paste -sd ' ' -)"
    
    # Note: Parentheses for arrays are a Bash feature
    container_network=($(docker container inspect --format "{{range \$k, \$v := .NetworkSettings.Networks}}{{printf \"%s\\n\" \$k}}{{end}}" "$container_search"))
    
    container_working_dir=$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_search")
    container_depends_on_raw=$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.depends_on"}}' "$container_search")
    container_depends_on=$(echo "$container_depends_on_raw" | tr ',' '\n' | cut -d: -f1 | paste -sd ' ' -)

    echo "${container_name},${container_ip},${container_ports[*]},${container_ext_ports},${container_network[*]},${container_working_dir},${container_depends_on}" >> ~/tmp/docker-container.txt
}

# Ensure the directory exists
mkdir -p ~/tmp

# Header for the file
echo 'CONTAINER,IP,PORT,EXT_PORT,NETWORKS,WORKDIR,DEPENDS_ON' > ~/tmp/docker-container.txt

# Do NOT use 'local' here
container_search="$1"

if [ -z "$container_search" ]; then
    docker ps --format "{{.ID}}" | while read -r id; do
        _print_container_info "$id"
    done
else
    docker container ls --format "{{.ID}} {{.Names}}" | grep -q "\b$container_search\b" && _print_container_info "$container_search"
fi

echo '------------------------------------------------------'
column -s "," --output-separator " ┊ " -t ~/tmp/docker-container.txt
echo '------------------------------------------------------'

rm ~/tmp/docker-container.txt