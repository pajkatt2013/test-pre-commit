#!/bin/bash

read -p "Specify cleanup criteria (possible use cases: workflows_keyword, workflows_xdays, workflows_xoldest, workflows_tagbased, get_workflows_running_longer_xdays, delete_workflows_in_csv_file):" command_input
read -p "Enter env (dev/int/prod):" env_argument

# Check which environment the user is currently logged into and assign the API endpoint
current_context=$(kubectl config current-context)
echo "[INFO] Current context: $current_context"

if [[ "$current_context" != *"$env_argument"* ]]; then
    echo "[ERROR] You are not in the correct kubectl context. Switch to $env_argument context and rerun the script."
    exit 1
fi

case "$env_argument" in
    dev) api_endpoint='https://raas-dev.api.aws.orionadp.com/v1/jobs' ;;
    int) api_endpoint='https://raas-int.api.aws.orionadp.com/v1/jobs' ;;
    prod) api_endpoint='https://raas.api.aws.orionadp.com/v1/jobs' ;;
    *) echo "Error: Invalid environment argument"; exit 1 ;;
esac

# Tranform the age string with time unit days (hours)
function transform_line() {
  awk '
  {
    days=0
    hours=0
    if ($4 ~ /d/) {
      split($4, parts, "d")
      days = parts[1]
      if (parts[2] ~ /h/) {
        split(parts[2], subparts, "h")
        hours = subparts[1]
      }
    } else if ($4 ~ /h/) {
      split($4, subparts, "h")
      hours = subparts[1]
    }
    total_hours = days * 24 + hours
    total_days = total_hours / 24
    printf "%s\t%s\t%s\t%s\t%d\t%d\n", $1, $2, $3, $4, total_hours, total_days
  }
  '
}

# Transform data into csv format with field delimiter ","
function convert_format_csv() {
  awk '
    BEGIN { print "NAMESPACE,NAME,STATUS,AGE,HOURS,DAYS"}
    {
      printf "%s,%s,%s,%s,%d,%d\n", $1, $2, $3, $4, $5, $6
    }
  '
}

function delete_workflow() {
    workflow=$1

    workflow_details=$(kubectl -n raas-pipeline get wf $workflow -o json)
    job_id=$(echo "$workflow_details" | jq -r '.metadata.labels.job_id')

    if [[ -z "$job_id" || "$job_id" == "null" ]]; then
        echo "[WARNING] No job_id found for workflow: $workflow. Deleting from Argo only."
        argo delete -n raas-pipeline "$workflow"
        return
    fi

    echo "[INFO] Deleting Workflow from JMS: $workflow job_id: $job_id"
    tmp_response_body_file=$(mktemp)
    jms_response_code=$(curl -s -o "$tmp_response_body_file" -w "%{http_code}" -X 'DELETE' "$api_endpoint/$job_id" -H 'accept: application/json')
    jms_response_body=$(cat "$tmp_response_body_file")

    echo "[INFO] JMS Response: $jms_response_code for $workflow job_id: $job_id"

    if [[ "$jms_response_code" == "202" ]]; then
        echo "[INFO] Successfully deleted from JMS. Now deleting from Argo."
        argo delete -n raas-pipeline "$workflow"
    elif [[ "$jms_response_code" == "404" ]]; then
        echo "[WARNING] Job ID $job_id not found in JMS. Deleting from Argo only."
        argo delete -n raas-pipeline "$workflow"
    else
        echo "[ERROR] Failed to delete from JMS. Response: $jms_response_code. Still deleting from Argo."
        echo "$workflow $job_id $jms_response_code $jms_response_body" >> "./$jms_error_log"
        argo delete -n raas-pipeline "$workflow"
    fi

    rm "$tmp_response_body_file"
}

function create_timestamped_error_log() {
    # Get the current date and time in the format YYYY-MM-DD_HH-MM-SS
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

    # Create a filename with the timestamp
    jms_error_log="jms_error_log_$timestamp.out"

    # Create the file and export the variable
    touch $jms_error_log
    export jms_error_log
}

export -f delete_workflow
export api_endpoint

case "$command_input" in
    workflows_keyword)
        echo "To delete workflow with specific keyword(s) in workflow name"
        read -p "Workflow status (Failed/Error/Succeeded/Running):" workflow_status
        read -p "Enter keywords (comma-separated and no whitespace, e.g., keyword1,keyword2):" keywords

        # Replace commas with the pipe character (|) to create a regex pattern
        regex=$(echo "$keywords" | sed 's/,/|/g')
        echo "Using regex: \"$regex\""

        kubectl get workflow --all-namespaces |
            awk -v wf_status="$workflow_status" '$3==wf_status {print $2}' |
            awk -v keywords_regex="$regex" '$1 ~ keywords_regex {print $1}' > ./workflows_keywords.out

        create_timestamped_error_log
        cat workflows_keywords.out | awk '{print $1}' | xargs -n 1 -P 10 bash -c 'delete_workflow "$@"' _
        ;;

    workflows_xdays)
        echo "To delete workflow with specific status for last X days"
        read -p "Enter workflow status (Failed/Error/Succeeded/Running):" workflow_status
        read -p "Enter number of days:" min_days
        min_hours=$(($min_days * 24))

        kubectl get workflow --all-namespaces |
            awk -v wf_status="$workflow_status" '$3==wf_status {print $1,$2,$3,$4}' |
            transform_line |
            awk -v mindays=$min_days '$6 >= mindays {print $1,$2,$3,$4,$5,$6}' > ./workflows_xdays.out

        create_timestamped_error_log
        cat workflows_xdays.out | awk '{print $2}' | xargs -n 1 -P 10 bash -c 'delete_workflow "$@"' _
        ;;

    workflows_xoldest)
        echo "To delete X oldest jobs"
        read -p "Enter workflow status (Failed/Error/Succeeded/Running):" workflow_status
        read -p "Enter number of top oldest workflows:" workflows_num

        kubectl get workflow --all-namespaces |
            awk -v wf_status="$workflow_status" '$3==wf_status {print $1,$2,$3,$4}' |
            transform_line |
            awk '{print $2,$3,$4,$5,$6}' | sort -k5,5nr | head -n "$workflows_num" > ./workflows_oldest.out

        create_timestamped_error_log
        cat workflows_oldest.out | awk '{print $1}' | xargs -n 1 -P 10 bash -c 'delete_workflow "$@"' _
        ;;

    *)
        echo "Invalid cleanup criteria: $command_input"
        echo "Valid cleanup criteria are: workflows_xdays, workflows_xoldest, workflows_tagbased, workflows_keyword"
        exit 1
        ;;
esac

