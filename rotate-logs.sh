#!/bin/bash

rotate_log() {
  local log_file="$1"

  if [[ -z "$log_file" ]]; then
    echo "Usage: rotate_log log_file"
    exit 1
  fi

  local log_dir
  log_dir=$(dirname "$log_file")
  local base_name
  base_name=$(basename "$log_file")
  local max_logs=10

  for (( i=max_logs-1; i>=1; i-- )); do
    if [[ -e "$log_dir/$base_name.$i" ]]; then
      mv "$log_dir/$base_name.$i" "$log_dir/$base_name.$((i+1))"
    fi
  done

  if [[ -e "$log_file" ]]; then
    mv "$log_file" "$log_dir/$base_name.1"
  fi

  : > "$log_file"
}

rotate_logs_all() {
  local pattern="${1:-"./logs/*.log"}"
  local max_file_size="${2:-20}"

  for log_file in $pattern; do
    if [[ $(du -m "$log_file" | awk '{print $1}') -gt $max_file_size ]]; then
      rotate_log "$log_file"
    fi
  done
}

truncate_log() {
  local log_file="$1"
  local max_file_size="${2:-20}"

  if [[ -z "$log_file" ]]; then
    echo "Usage: truncate_log log_file"
    exit 1
  fi

  if [[ -e "$log_file" ]]; then
    if [[ $(du -m "$log_file" | awk '{print $1}') -gt $max_file_size ]]; then
      : > "$log_file"
      echo "Truncated $log_file."
    else
      echo "Log file $log_file does not exceed maximum size of $max_file_size MB."
    fi
  else
    echo "Log file $log_file does not exist."
  fi
}

truncate_all_logs() {
  local pattern="${1:-"./logs/*.log"}"
  local max_file_size="${2:-20}"

  for log_file in $pattern; do
    if [[ -e "$log_file" ]]; then
      if [[ $(du -m "$log_file" | awk '{print $1}') -gt $max_file_size ]]; then
        : > "$log_file"
        echo "Truncated $log_file."
      else
        echo "Log file $log_file does not exceed maximum size of $max_file_size MB."
      fi
    else
      echo "Log file $log_file does not exist."
    fi
  done
}

MAX_FILE_SIZE=500
rotate_logs_all "/grafana/logs/*.log" $MAX_FILE_SIZE
