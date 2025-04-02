#!/bin/bash

read -p "Specify cleanup criteria (workflows_keyword, workflows_xdays, workflows_xoldest, workflows_tagbased, get_workflows_running_longer_xdays, delete_workflows_in_csv_file): " command_input
read -p "Enter env (dev/int/prod): " env_argument

# Check the current kubectl context
current_context=$(kubectl config current-context)
echo "[INFO] Current context: $current_context"

if [[ "$current_context" != *"$env_argument"* ]]; then
    echo "[ERROR] You are not in the correct kubectl context. Switch to $env_argument context and rerun the script."
    exit 1
fi

# Function to delete workflow from Argo (without JMS dependency)
function delete_workflow() {
    workflow=$1
    echo "[INFO] Attempting to delete workflow: $workflow"

    # Try to get workflow details
    workflow_details=$(kubectl -n raas-pipeline get wf "$workflow" -o json 2>/dev/null)
    
    if [[ -z "$workflow_details" || "$workflow_details" == "null" ]]; then
        echo "[WARNING] Workflow $workflow not found in Kubernetes. Skipping..."
        return
    fi

    # Delete workflow from Argo
    echo "[INFO] Deleting workflow from Argo: $workflow"
    argo delete -n raas-pipeline "$workflow"
}

export -f delete_workflow

case "$command_input" in
    workflows_keyword)
        echo "Deleting workflows with specific keywords in their name"
        read -p "Workflow status (Failed/Error/Succeeded/Running): " workflow_status
        read -p "Enter keywords (comma-separated, no spaces, e.g., keyword1,keyword2): " keywords

        regex=$(echo "$keywords" | sed 's/,/|/g')  # Convert to regex pattern
        echo "Using regex: \"$regex\""

        kubectl get workflow --all-namespaces |
            awk -v wf_status="$workflow_status" '$3==wf_status {print $2}' |
            awk -v keywords_regex="$regex" '$1 ~ keywords_regex {print $1}' > workflows_keywords.out

        cat workflows_keywords.out | awk '{print $1}' | xargs -n 1 -P 10 bash -c 'delete_workflow "$@"' _
        ;;

    workflows_xdays)
        echo "Deleting workflows older than X days"
        read -p "Workflow status (Failed/Error/Succeeded/Running): " workflow_status
        read -p "Enter number of days: " min_days
        min_hours=$((min_days * 24))

        kubectl get workflow --all-namespaces |
            awk -v wf_status="$workflow_status" '$3==wf_status {print $1,$2,$3,$4}' |
            awk '{print $2}' > workflows_xdays.out

        cat workflows_xdays.out | xargs -n 1 -P 10 bash -c 'delete_workflow "$@"' _
        ;;

    workflows_xoldest)
        echo "Deleting X oldest workflows"
        read -p "Workflow status (Failed/Error/Succeeded/Running): " workflow_status
        read -p "Enter number of top oldest workflows: " workflows_num

        kubectl get workflow --all-namespaces |
            awk -v wf_status="$workflow_status" '$3==wf_status {print $2}' |
            sort | head -n "$workflows_num" > workflows_oldest.out

        cat workflows_oldest.out | xargs -n 1 -P 10 bash -c 'delete_workflow "$@"' _
        ;;

    get_workflows_running_longer_xdays)
        echo "Getting workflows running longer than X days (output in CSV format)"
        workflow_status="Running"
        read -p "Enter output file name (without extension .csv): " output_csv_filename
        read -p "Enter number of days (minimum duration of running workflow): " min_days
        
        kubectl get workflow --all-namespaces |
            awk -v wf_status=$workflow_status '$3==wf_status {print $1,$2,$3,$4}' |
            awk '{print $2}' > "$output_csv_filename.csv"

        echo "[INFO] Output saved to $output_csv_filename.csv"
        ;;

    delete_workflows_in_csv_file)
        echo "Deleting workflows from a predefined CSV file"
        read -p "Enter the input file name: " input_csv_filename
        read -p "Confirmation for the deletion with 'YES', otherwise task will be aborted: " deletion_confirmation

        if [[ "$deletion_confirmation" == "YES" ]]; then
            echo "[INFO] Starting workflow deletion..."
            cat "$input_csv_filename" | tail -n +2 | awk -F "," '{print $2}' | xargs -n 1 -P 10 bash -c 'delete_workflow "$@"' _
        else
            echo "[INFO] Deletion task aborted."
        fi
        ;;

    *)
        echo "[ERROR] Invalid cleanup criteria: $command_input"
        echo "Valid options: workflows_xdays, workflows_xoldest, workflows_tagbased, workflows_keyword"
        exit 1
        ;;
esac
