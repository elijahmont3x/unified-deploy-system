#!/bin/bash
#
# uds-docker.sh - Docker integration for Unified Deployment System
#
# This module provides functions for Docker container and compose management

# Avoid loading multiple times
if [ -n "$UDS_DOCKER_LOADED" ]; then
  return 0
fi
UDS_DOCKER_LOADED=1

# Check if port is available
uds_is_port_available() {
  local port="$1"
  local host="${2:-localhost}"
  
  # Try netstat if available
  if command -v netstat &>/dev/null; then
    if netstat -tuln | grep -q ":$port "; then
      return 1
    fi
  # Try ss if available
  elif command -v ss &>/dev/null; then
    if ss -tuln | grep -q ":$port "; then
      return 1
    fi
  # Fallback to direct check
  else
    if ! (echo >/dev/tcp/$host/$port) 2>/dev/null; then
      return 0
    else
      return 1
    fi
  fi
  
  return 0
}

# Find an available port starting from a base port
uds_find_available_port() {
  local base_port="$1"
  local max_port="${2:-65535}"
  local increment="${3:-1}"
  local host="${4:-localhost}"
  
  local current_port="$base_port"
  
  while [ "$current_port" -le "$max_port" ]; do
    if uds_is_port_available "$current_port" "$host"; then
      echo "$current_port"
      return 0
    fi
    
    current_port=$((current_port + increment))
  done
  
  return 1
}

# Resolve port conflicts automatically
uds_resolve_port_conflicts() {
  local port="$1"
  local app_name="$2"
  
  if uds_is_port_available "$port"; then
    echo "$port"
    return 0
  fi
  
  if [ "${PORT_AUTO_ASSIGN:-true}" = "true" ]; then
    uds_log "Port $port is already in use, finding an alternative" "warning"
    
    local available_port=$(uds_find_available_port "$port")
    
    if [ -n "$available_port" ]; then
      uds_log "Using alternative port: $available_port" "warning"
      echo "$available_port"
      return 0
    else
      uds_log "Failed to find an available port in range $port-65535" "error"
      return 1
    fi
  else
    uds_log "Port $port is already in use and auto-assign is disabled" "error"
    # Show processes using this port for debugging
    if command -v lsof &>/dev/null; then
      uds_log "Process using port $port:" "info"
      lsof -i ":$port" || true
    elif command -v netstat &>/dev/null; then
      uds_log "Process using port $port:" "info"
      netstat -tulpn | grep ":$port " || true
    elif command -v ss &>/dev/null; then
      uds_log "Process using port $port:" "info"
      ss -tulpn | grep ":$port " || true
    fi
    return 1
  fi
}

# Generate a docker-compose.yml file
uds_generate_compose_file() {
  local app_name="$1"
  local image="$2"
  local tag="$3"
  local port="$4"
  local output_file="$5"
  local env_vars="${6:-{}}"
  local volumes="${7:-}"
  local use_profiles="${8:-true}"
  local extra_hosts="${9:-}"
  local compose_version="${10:-3.8}"

  uds_log "Generating docker-compose.yml for $app_name" "debug"

  # Apply secure permissions to the output file directory
  mkdir -p "$(dirname "$output_file")"
  uds_secure_permissions "$(dirname "$output_file")" 700

  # Create compose file header
  uds_generate_compose_header "$output_file" "$compose_version"
  
  # Determine if we have multiple images or a single image
  if [[ "$image" == *","* ]]; then
    uds_generate_multi_services "$app_name" "$image" "$tag" "$port" "$output_file" "$env_vars" "$volumes" "$use_profiles" "$extra_hosts"
  else
    uds_generate_single_service "$app_name" "$image" "$tag" "$port" "$output_file" "$env_vars" "$volumes" "$use_profiles" "$extra_hosts"
  fi

  # Add network configuration
  uds_generate_network_config "$output_file" "$app_name"

  # Add volumes section if defined in volumes input
  if [ -n "$volumes" ] && [[ "$volumes" == *":"* ]]; then
    uds_generate_named_volumes "$output_file" "$app_name" "$volumes"
  fi

  # Secure the compose file
  uds_secure_permissions "$output_file" 600
  
  uds_log "Generated docker-compose.yml at $output_file" "debug"
}

# Generate compose file header
uds_generate_compose_header() {
  local output_file="$1"
  local compose_version="$2"
  
  cat > "$output_file" << EOL
# Generated by Unified Deployment System
version: '${compose_version}'

services:
EOL
}

# Generate service configurations for multiple images
uds_generate_multi_services() {
  local app_name="$1"
  local image="$2"
  local tag="$3"
  local port="$4"
  local output_file="$5"
  local env_vars="${6:-{}}"
  local volumes="${7:-}"
  local use_profiles="${8:-true}"
  local extra_hosts="${9:-}"
  
  # Split comma-separated list
  IFS=',' read -ra IMAGES <<< "$image"
  IFS=',' read -ra PORTS <<< "$port"
  
  for i in "${!IMAGES[@]}"; do
    local img_clean=$(echo "${IMAGES[$i]}" | tr -d ' ')
    # Extract service name from image, handling complex image paths
    local service_name=$(echo "$img_clean" | sed -E 's|.*/||' | sed -E 's|:.*||' | tr '[:upper:]' '[:lower:]')
    
    # If service name is empty or invalid, generate a default one
    if [ -z "$service_name" ] || [[ "$service_name" =~ [^a-zA-Z0-9_-] ]]; then
      service_name="service-$((i+1))"
    fi
    
    local service_port=${PORTS[$i]:-3000}
    
    # Write service base configuration
    uds_generate_service_base "$output_file" "$service_name" "$img_clean" "$tag" "$app_name" "$use_profiles"
    
    # Add ports
    uds_generate_service_ports "$output_file" "$service_port"
    
    # Add other service components
    uds_add_service_components "$output_file" "$env_vars" "$volumes" "$extra_hosts" "$service_name" "$app_name"
  done
}

# Generate single service configuration
uds_generate_single_service() {
  local app_name="$1"
  local image="$2"
  local tag="$3"
  local port="$4"
  local output_file="$5"
  local env_vars="${6:-{}}"
  local volumes="${7:-}"
  local use_profiles="${8:-true}"
  local extra_hosts="${9:-}"
  
  # Write service base configuration
  uds_generate_service_base "$output_file" "app" "$image" "$tag" "$app_name" "$use_profiles"
  
  # Add ports
  uds_generate_service_ports "$output_file" "$port"
  
  # Add other service components
  uds_add_service_components "$output_file" "$env_vars" "$volumes" "$extra_hosts" "app" "$app_name"
}

# Add common service components (env vars, volumes, health check, extra hosts, networks)
uds_add_service_components() {
  local output_file="$1"
  local env_vars="$2"
  local volumes="$3"
  local extra_hosts="$4"
  local service_name="$5"
  local app_name="$6"
  
  # Add environment variables
  uds_add_environment_variables "$env_vars" "$output_file" "$service_name"
  
  # Add volumes
  uds_add_volumes "$volumes" "$output_file" "$service_name"
  
  # Add extra hosts
  uds_add_extra_hosts "$extra_hosts" "$output_file"
  
  # Add healthcheck
  uds_add_health_check "$output_file" "$service_name"
  
  # Add networks
  echo "    networks:" >> "$output_file"
  echo "      - ${app_name}-network" >> "$output_file"
}

# Generate service base configuration 
uds_generate_service_base() {
  local output_file="$1"
  local service_name="$2"
  local image="$3"
  local tag="$4"
  local app_name="$5"
  local use_profiles="$6"
  
  cat >> "$output_file" << EOL
  ${service_name}:
    image: ${image}:${tag}
    container_name: ${app_name}-${service_name}
EOL
  
  if [ "$use_profiles" = "true" ]; then
    cat >> "$output_file" << EOL
    profiles:
      - app
EOL
  fi
  
  cat >> "$output_file" << EOL
    restart: unless-stopped
EOL
}

# Generate port mapping section
uds_generate_service_ports() {
  local output_file="$1"
  local port="$2"
  
  # Add ports section if port is specified
  if [ -n "$port" ]; then
    cat >> "$output_file" << EOL
    ports:
EOL
    # Handle port mapping format (host:container)
    if [[ "$port" == *":"* ]]; then
      local host_port=$(echo "$port" | cut -d: -f1)
      local container_port=$(echo "$port" | cut -d: -f2)
      echo "      - \"${host_port}:${container_port}\"" >> "$output_file"
    else
      echo "      - \"${port}:${port}\"" >> "$output_file"
    fi
  fi
}

# Generate network configuration
uds_generate_network_config() {
  local output_file="$1"
  local app_name="$2"
  
  cat >> "$output_file" << EOL

networks:
  ${app_name}-network:
    name: ${app_name}-network
EOL
}

# Add named volumes section for persistent storage
uds_generate_named_volumes() {
  local output_file="$1"
  local app_name="$2"
  local volumes="$3"
  
  # Extract volume names from the volume mappings
  local named_volumes=()
  
  # Handle both comma-separated string and JSON array formats
  if [[ "$volumes" == "["* ]]; then
    # JSON array format
    local volume_list=$(echo "$volumes" | jq -r '.[]')
    IFS=$'\n' read -rd '' -a volume_array <<< "$volume_list"
    for volume in "${volume_array[@]}"; do
      if [[ "$volume" == *":"* ]] && [[ ! "$volume" == "./"* ]] && [[ ! "$volume" == "/"* ]] && [[ ! "$volume" == ".:"* ]]; then
        local vol_name=$(echo "$volume" | cut -d: -f1)
        # Skip if it's a relative path
        if [[ ! "$vol_name" =~ ^[./] ]]; then
          named_volumes+=("$vol_name")
        fi
      fi
    done
  else
    # Comma-separated string format
    IFS=',' read -ra VOLUME_MAPPINGS <<< "$volumes"
    for volume in "${VOLUME_MAPPINGS[@]}"; do
      local vol_clean=$(echo "$volume" | tr -d ' ')
      if [[ "$vol_clean" == *":"* ]] && [[ ! "$vol_clean" == "./"* ]] && [[ ! "$vol_clean" == "/"* ]] && [[ ! "$vol_clean" == ".:"* ]]; then
        local vol_name=$(echo "$vol_clean" | cut -d: -f1)
        # Skip if it's a relative path
        if [[ ! "$vol_name" =~ ^[./] ]]; then
          named_volumes+=("$vol_name")
        fi
      fi
    done
  fi
  
  # Add volumes section if we have named volumes
  if [ ${#named_volumes[@]} -gt 0 ]; then
    echo "" >> "$output_file"
    echo "volumes:" >> "$output_file"
    
    # Add each named volume
    for vol_name in "${named_volumes[@]}"; do
      echo "  ${vol_name}:" >> "$output_file"
      echo "    name: ${vol_name}" >> "$output_file"
      echo "    external: false" >> "$output_file"
    done
  fi
}

# Helper function to add health check configuration
uds_add_health_check() {
  local output_file="$1"
  local service_name="$2"
  
  # Check if we have health check info from environment
  if [ -n "${HEALTH_CHECK:-}" ] && [ "${HEALTH_CHECK}" != "none" ] && [ "${HEALTH_CHECK}" != "disabled" ]; then
    local health_check_type="${HEALTH_CHECK_TYPE:-http}"
    local health_check_timeout="${HEALTH_CHECK_TIMEOUT:-60}"
    
    # Only add health check for HTTP or TCP types (internal Docker health checks)
    if [ "$health_check_type" = "http" ] || [ "$health_check_type" = "tcp" ]; then
      echo "    healthcheck:" >> "$output_file"
      
      if [ "$health_check_type" = "http" ]; then
        local health_path="${HEALTH_CHECK}"
        if [ "$health_path" = "auto" ]; then
          health_path="/health"
        fi
        
        # Handle port mapping if specified
        local port="${PORT:-3000}"
        if [[ "$port" == *":"* ]]; then
          port=$(echo "$port" | cut -d: -f2)
        fi
        
        # HTTP health check
        echo "      test: [\"CMD\", \"wget\", \"--no-verbose\", \"--tries=1\", \"--spider\", \"http://localhost:${port}${health_path}\"]" >> "$output_file"
      else
        # TCP health check
        local port="${PORT:-3000}"
        if [[ "$port" == *":"* ]]; then
          port=$(echo "$port" | cut -d: -f2)
        fi
        
        echo "      test: [\"CMD\", \"nc\", \"-z\", \"localhost\", \"${port}\"]" >> "$output_file"
      fi
      
      # Add common healthcheck settings
      echo "      interval: 30s" >> "$output_file"
      echo "      timeout: 10s" >> "$output_file"
      echo "      retries: 3" >> "$output_file"
      echo "      start_period: 60s" >> "$output_file"
    fi
  fi
}

# Helper function to add environment variables to compose file
uds_add_environment_variables() {
  local env_vars="$1"
  local output_file="$2"
  local service_name="$3"
  
  # Add environment variables if provided
  if [ "$env_vars" != "{}" ]; then
    echo "    environment:" >> "$output_file"
    
    # Parse env_vars JSON safely to handle different formats
    if echo "$env_vars" | jq -e 'type == "object"' > /dev/null 2>&1; then
      # Extract service-specific env vars if available
      if echo "$env_vars" | jq -e "has(\"$service_name\")" > /dev/null 2>&1; then
        # Service-specific environment variables
        echo "$env_vars" | jq -r ".[\"$service_name\"] | to_entries[] | \"      - \" + .key + \"=\" + (.value | tostring)" >> "$output_file"
      else
        # Global environment variables for all services
        echo "$env_vars" | jq -r 'to_entries[] | "      - " + .key + "=" + (.value | tostring)' >> "$output_file"
      fi
    else
      uds_log "Warning: env_vars is not a valid JSON object, using empty environment" "warning"
    fi
  fi
}

# Helper function to add volumes to compose file
uds_add_volumes() {
  local volumes="$1"
  local output_file="$2"
  local service_name="$3"
  
  # Add volumes if provided
  if [ -n "$volumes" ]; then
    echo "    volumes:" >> "$output_file"
    
    # Handle both comma-separated string and JSON array formats
    if [[ "$volumes" == "["* ]]; then
      # JSON array format
      echo "$volumes" | jq -r '.[] | "      - " + .' >> "$output_file"
    else
      # Comma-separated string format
      IFS=',' read -ra VOLUME_MAPPINGS <<< "$volumes"
      for volume in "${VOLUME_MAPPINGS[@]}"; do
        local vol_clean=$(echo "$volume" | tr -d ' ')
        echo "      - $vol_clean" >> "$output_file"
      done
    fi
  fi
}

# Helper function to add extra hosts to compose file
uds_add_extra_hosts() {
  local extra_hosts="$1"
  local output_file="$2"
  
  # Add extra hosts if provided
  if [ -n "$extra_hosts" ]; then
    echo "    extra_hosts:" >> "$output_file"
    
    # Handle both comma-separated string and JSON array formats
    if [[ "$extra_hosts" == "["* ]]; then
      # JSON array format
      echo "$extra_hosts" | jq -r '.[] | "      - " + .' >> "$output_file"
    else
      # Comma-separated string format
      IFS=',' read -ra HOST_ENTRIES <<< "$extra_hosts"
      for host in "${HOST_ENTRIES[@]}"; do
        local host_clean=$(echo "$host" | tr -d ' ')
        echo "      - $host_clean" >> "$output_file"
      done
    fi
  fi
}

# Pull Docker images with improved error handling
uds_pull_docker_images() {
  local images="$1"
  local tag="$2"
  local skip_pull="${3:-false}"
  
  if [ "$skip_pull" = "true" ]; then
    uds_log "Skipping Docker image pull as requested" "info"
    return 0
  fi
  
  uds_log "Pulling Docker images..." "info"
  
  # Handle multiple images if specified
  if [[ "$images" == *","* ]]; then
    uds_pull_multiple_images "$images" "$tag"
  else
    uds_pull_single_image "$images" "$tag"
  fi
}

# Pull multiple Docker images
uds_pull_multiple_images() {
  local images="$1"
  local tag="$2"
  
  IFS=',' read -ra IMAGES_ARRAY <<< "$images"
  
  local success_count=0
  local total_images=${#IMAGES_ARRAY[@]}
  
  for img in "${IMAGES_ARRAY[@]}"; do
    local img_clean=$(echo "$img" | tr -d ' ')
    
    uds_log "Pulling image: $img_clean:$tag" "info"
    
    if uds_pull_image_with_retry "$img_clean" "$tag"; then
      success_count=$((success_count + 1))
    fi
  done
  
  # Check if we pulled at least one image successfully
  if [ $success_count -eq 0 ]; then
    uds_log "Failed to pull any images" "error"
    return 1
  elif [ $success_count -lt $total_images ]; then
    uds_log "Warning: Only pulled $success_count of $total_images images" "warning"
    return 0
  fi
  
  uds_log "All images pulled successfully" "success"
  return 0
}

# Pull a single Docker image
uds_pull_single_image() {
  local image="$1"
  local tag="$2"
  
  # Skip if no image specified
  if [ -z "$image" ]; then
    uds_log "No image specified, skipping pull" "warning"
    return 0
  fi
  
  uds_log "Pulling image: $image:$tag" "info"
  
  if uds_pull_image_with_retry "$image" "$tag"; then
    uds_log "Image pull completed successfully" "success"
    return 0
  else
    return 1
  fi
}

# Pull a Docker image with retry logic
uds_pull_image_with_retry() {
  local image="$1"
  local tag="$2"
  local max_attempts=3
  
  # Pull with retry logic
  local attempts=0
  local pull_success=false
  local error_message=""
  
  while [ $attempts -lt $max_attempts ] && [ "$pull_success" = "false" ]; do
    local pull_output=""
    if pull_output=$(docker pull "$image:$tag" 2>&1); then
      pull_success=true
    else
      attempts=$((attempts + 1))
      error_message=$(echo "$pull_output" | grep -i "error" | head -n 1)
      
      if [ $attempts -lt $max_attempts ]; then
        if echo "$pull_output" | grep -q "connection refused"; then
          uds_log "Docker daemon connection refused, retrying in 5s..." "warning"
          sleep 5
        elif echo "$pull_output" | grep -q "not found"; then
          uds_log "Image '$image:$tag' not found in registry" "error"
          break
        else
          uds_log "Pull failed ($error_message), retrying ($attempts/$max_attempts)..." "warning"
          sleep 3
        fi
      fi
    fi
  done
  
  if [ "$pull_success" = "false" ]; then
    uds_log "Failed to pull image $image:$tag after $max_attempts attempts: $error_message" "error"
    return 1
  fi
  
  return 0
}

# Get container logs with proper formatting
uds_get_container_logs() {
  local container_name="$1"
  local lines="${2:-50}"
  local tail_option="${3:--n}"
  
  # Check if container exists
  if ! docker ps -a -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container $container_name not found" "warning"
    return 1
  fi
  
  # Get logs with specified options
  docker logs "$container_name" $tail_option $lines 2>&1
}

# Check container health status
uds_get_container_health() {
  local container_name="$1"
  
  # Check if container exists
  if ! docker ps -a -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container $container_name not found" "warning"
    return 1
  fi
  
  # Get container status first
  local container_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
  
  # If container is not running, return stopped status
  if [ "$container_status" != "running" ]; then
    echo "stopped"
    return 0
  fi
  
  # Get health status if container is running
  local health_status
  health_status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null)
  
  # If health check is not configured, check if container is running
  if [ "$health_status" = "none" ]; then
    echo "running"
  else
    echo "$health_status"
  fi
  
  return 0
}

# Get detailed container information
uds_get_container_info() {
  local container_name="$1"
  
  # Check if container exists
  if ! docker ps -a -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container $container_name not found" "warning"
    return 1
  fi
  
  # Get container information in JSON format
  docker inspect "$container_name" 2>/dev/null
  return $?
}

# Execute command in container with error handling
uds_exec_container() {
  local container_name="$1"
  local command="$2"
  local capture_output="${3:-true}"
  
  # Check if container is running
  if ! docker ps -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container $container_name is not running" "error"
    return 1
  fi
  
  # Execute command
  if [ "$capture_output" = "true" ]; then
    docker exec "$container_name" sh -c "$command"
  else
    docker exec "$container_name" sh -c "$command" &>/dev/null
  fi
  
  local exit_code=$?
  
  if [ $exit_code -ne 0 ]; then
    uds_log "Command failed in container $container_name: $command" "error"
    return $exit_code
  fi
  
  return 0
}

# Start a stopped container with retry logic
uds_start_container() {
  local container_name="$1"
  local max_attempts="${2:-3}"
  
  # Check if container exists
  if ! docker ps -a -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container $container_name not found" "error"
    return 1
  fi
  
  # Check if container is already running
  if docker ps -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container $container_name is already running" "info"
    return 0
  fi
  
  uds_log "Starting container $container_name" "info"
  
  local attempts=0
  local start_success=false
  
  while [ $attempts -lt $max_attempts ] && [ "$start_success" = "false" ]; do
    local start_output=""
    if start_output=$(docker start "$container_name" 2>&1); then
      start_success=true
    else
      attempts=$((attempts + 1))
      local error_message=$(echo "$start_output" | grep -i "error" | head -n 1)
      
      if [ $attempts -lt $max_attempts ]; then
        uds_log "Start failed ($error_message), retrying ($attempts/$max_attempts)..." "warning"
        sleep 3
      fi
    fi
  done
  
  if [ "$start_success" = "false" ]; then
    uds_log "Failed to start container $container_name after $max_attempts attempts" "error"
    return 1
  fi
  
  uds_log "Container $container_name started successfully" "success"
  return 0
}

# Stop a running container with timeout
uds_stop_container() {
  local container_name="$1"
  local timeout="${2:-30}"
  
  # Check if container exists and is running
  if ! docker ps -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container $container_name is not running" "info"
    return 0
  fi
  
  uds_log "Stopping container $container_name (timeout: ${timeout}s)" "info"
  
  if ! docker stop --time="$timeout" "$container_name" &>/dev/null; then
    uds_log "Failed to stop container $container_name gracefully, forcing" "warning"
    
    # Force kill if graceful stop fails
    if ! docker kill "$container_name" &>/dev/null; then
      uds_log "Failed to kill container $container_name" "error"
      return 1
    fi
  fi
  
  uds_log "Container $container_name stopped" "success"
  return 0
}

# Export functions
export -f uds_is_port_available uds_find_available_port uds_resolve_port_conflicts
export -f uds_generate_compose_file uds_pull_docker_images
export -f uds_get_container_logs uds_get_container_health uds_get_container_info
export -f uds_exec_container uds_start_container uds_stop_container
export -f uds_generate_compose_header uds_generate_service_base
export -f uds_generate_service_ports uds_generate_network_config 
export -f uds_generate_named_volumes uds_add_health_check
export -f uds_add_environment_variables uds_add_volumes uds_add_extra_hosts
export -f uds_generate_multi_services uds_generate_single_service
export -f uds_add_service_components uds_pull_multiple_images
export -f uds_pull_single_image uds_pull_image_with_retry