#!/bin/bash
set -eo pipefail

# Find project root
find_root() {
    local dir="$(cd "$(dirname "$0")/../.." && pwd)"
    while [ ! -f "$dir/.env" ] && [ "$dir" != "/" ]; do
        dir="$(dirname "$dir")"
    done
    echo "$dir"
}

ROOT_DIR="$(find_root)"
ENV_FILE="$ROOT_DIR/.env"
COMPOSE_FILE="$(dirname "$0")/docker-compose.yml"
ES_CONTAINER="wolfx0-elasticsearch"
MAX_WAIT=600  # Increased timeout to 10 minutes
PORT_RANGE_START=9200
PORT_RANGE_END=9300

# Load environment with defaults
load_env() {
    [ -f "$ENV_FILE" ] || cp "$ROOT_DIR/.env_sample" "$ENV_FILE"
    source "$ENV_FILE"
    
    : ${ELASTICSEARCH_HOST:=127.0.0.1}
    : ${ELASTICSEARCH_HTTP_PORT:=9200}
    : ${ELASTICSEARCH_TRANSPORT_PORT:=9300}
    : ${INSTALLED_ELASTICSEARCH:=false}
}

# Find next available port
find_available_port() {
    local base_port=$1
    while [ $base_port -le $PORT_RANGE_END ]; do
        if ! lsof -i :$base_port >/dev/null && ! docker ps --format "{{.Ports}}" | grep -q ":$base_port->"; then
            echo "$base_port"
            return
        fi
        ((base_port++))
    done
    echo "ERROR: No ports available in $PORT_RANGE_START-$PORT_RANGE_END" >&2
    exit 1
}

# Update configurations
update_configs() {
    local new_http_port=$1
    local new_transport_port=$2

    # Update .env (host ports)
    sed -i.bak \
        -e "s/^ELASTICSEARCH_HTTP_PORT=.*/ELASTICSEARCH_HTTP_PORT=$new_http_port/" \
        -e "s/^ELASTICSEARCH_TRANSPORT_PORT=.*/ELASTICSEARCH_TRANSPORT_PORT=$new_transport_port/" \
        -e "s|^ELASTICSEARCH_URL=.*|ELASTICSEARCH_URL=http://${ELASTICSEARCH_HOST}:${new_http_port}|" \
        "$ENV_FILE"

    # Update docker-compose.yml (map host ports to container 9200/9300)
    sed -i.bak \
        -e "s/- \"[0-9]\+:9200\"/- \"${new_http_port}:9200\"/" \
        -e "s/- \"[0-9]\+:9300\"/- \"${new_transport_port}:9300\"/" \
        "$COMPOSE_FILE"

    rm -f "${ENV_FILE}.bak" "${COMPOSE_FILE}.bak"
}

# Container management
manage_container() {
    echo "Removing old containers..."
    docker rm -f "$ES_CONTAINER" 2>/dev/null || true
    docker volume rm -f wolfx0_es_data 2>/dev/null || true

    echo "Starting Elasticsearch on port $ELASTICSEARCH_HTTP_PORT..."
    docker-compose -f "$COMPOSE_FILE" up -d
}

# Enhanced health check with backoff
wait_for_elasticsearch() {
    echo "Waiting for Elasticsearch (http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_HTTP_PORT})..."
    local counter=0
    local max_attempts=30
    local delay=5

    while true; do
        echo "Attempt $((counter + 1))/$max_attempts:"
        docker logs --tail 50 "$ES_CONTAINER"
        
        # Check if Elasticsearch is reachable
	if curl -sS -m 5 "http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_HTTP_PORT}" | grep -q "You Know, for Search"; then
	  # Then confirm cluster status is acceptable
	  STATUS=$(curl -sS -m 10 "http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_HTTP_PORT}/_cluster/health" | grep -o '"status":"[^"]\+"' || true)
	  if echo "$STATUS" | grep -qE '"status":"(yellow|green)"'; then
	    echo "Elasticsearch ready with status: $STATUS"
	    return
	  fi
	fi

        sleep $delay
        counter=$((counter + 1))
        
        if [ $counter -ge $max_attempts ]; then
            echo "❌ Health check failed after $max_attempts attempts"
            docker logs "$ES_CONTAINER"
            exit 1
        fi

        # Increase delay exponentially (5s, 10s, 20s, 40s, etc.), capped at 60s
        delay=$((delay * 2))
        [ $delay -gt 60 ] && delay=60
    done
}


# Main execution
main() {
    load_env

    if [ "$INSTALLED_ELASTICSEARCH" = "true" ]; then
        echo "✅ Elasticsearch already installed on port $ELASTICSEARCH_HTTP_PORT"
        exit 0
    fi

    # Find available ports
    if lsof -i :$ELASTICSEARCH_HTTP_PORT || docker ps --format "{{.Ports}}" | grep -q ":$ELASTICSEARCH_HTTP_PORT"; then
        echo "Port conflict detected, finding alternatives..."
        NEW_HTTP_PORT=$(find_available_port $PORT_RANGE_START)
        NEW_TRANSPORT_PORT=$(find_available_port $((NEW_HTTP_PORT + 1)))
        update_configs "$NEW_HTTP_PORT" "$NEW_TRANSPORT_PORT"
        source "$ENV_FILE"
    fi

    manage_container
    wait_for_elasticsearch

    # Mark installation complete
    sed -i.bak "s/^INSTALLED_ELASTICSEARCH=.*/INSTALLED_ELASTICSEARCH=true/" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"

    echo "✅ Success! Elasticsearch running on:"
    echo "   HTTP: http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_HTTP_PORT}"
    echo "   Transport: ${ELASTICSEARCH_TRANSPORT_PORT}"
}

main

