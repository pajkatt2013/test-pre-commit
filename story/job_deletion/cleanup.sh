#!/bin/bash
 
read -p "Specify cleanup criteria (possible use cases: workflows_keyword, workflows_xdays, workflows_xoldest, workflows_tagbased, get_workflows_running_longer_xdays, delete_workflows_in_csv_file):" command_input
read -p "Enter env (dev/int/prod):" env_argument
  
# Check which environment the user is currently logged into
current_context=$(kubectl config current-context)
echo "currently context: $current_context"
 
# Validate the current environment before proceeding with deletions
if [[ "$env_argument" = "prod" && "$current_context" != *"prod"* ]]; then
    echo "Error: You are not logged into the prod environment"
    exit 1
elif [[ "$env_argument" = "int" && "$current_context" != *"int"* ]]; then
    echo "Error: You are not logged into the int environment"
    exit 1
elif [[ "$env_argument" = "dev" && "$current_context" != *"dev"* ]]; then
    echo "Error: You are not logged into the dev environment"
    exit 1
fi
 
# assign the JMS API endpoint of different env
if [[ "$env_argument" = "dev" ]];
then
    api_endpoint='https://raas-dev.api.aws.orionadp.cn/v1/jobs'
elif [[ "$env_argument" = "int" ]];
then
    api_endpoint='https://raas-int.api.aws.orionadp.cn/v1/jobs'
elif [[ "$env_argument" = "prod" ]];
then
    api_endpoint='https://raas.api.aws.orionadp.cn/v1/jobs'
fi
 
 
 
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
 
# Transform data into csv format with field delimiter ";"
function convert_format_csv() {
  awk '
    BEGIN { print "NAMESPACE;NAME;STATUS;AGE;HOURS;DAYS"}
    {
      printf "%s;%s;%s;%s;%d;%d\n", $1, $2, $3, $4, $5, $6
    }
  '
}
 
 
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
         
        for w in $(cat workflows_keywords.out | awk '{print $1}');
            do echo "$w";
                # echo "Fetching details for workflow: $workflow"
                workflow_details=$(kubectl -n raas-pipeline get wf $w -o json)
                # Extracting job_id from metadata
              job_id=$(echo "$workflow_details" | jq -r '.metadata.labels.job_id')
 
                # Invoking the JMS API to delete the JMS job with job id
                job_status=$(curl -X 'DELETE' $api_endpoint/$job_id -H 'accept: application/json')
                jms_status_code=$(echo $job_status | jq -r '.status')
                jms_status_error=$(echo $job_status | jq -r '.error')
 
                if [[ "$jms_status_code" = "200" ]]; then
                        # Invoking the Argo workflow delete for the given workflow
                        argo delete -n raas-pipeline "$w";
                else
                        echo $w $job_id $jms_status_code $jms_status_error  > ./jms_error.out
                fi
        done
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
 
        for w in $(cat workflows_xdays.out | awk '{print $2}');
            do echo "$w";
                # echo "Fetching details for workflow: $workflow"
                workflow_details=$(kubectl -n raas-pipeline get wf $w -o json)
                # Extracting job_id from metadata
              job_id=$(echo "$workflow_details" | jq -r '.metadata.labels.job_id')
 
                # Invoking the JMS API to delete the JMS job with job id
                job_status=$(curl -X 'DELETE' $api_endpoint/$job_id -H 'accept: application/json')
                jms_status_code=$(echo $job_status | jq -r '.status')
                jms_status_error=$(echo $job_status | jq -r '.error')
 
                if [[ "$jms_status_code" = "200" ]]; then
                        # Invoking the Argo workflow delete for the given workflow
                        argo delete -n raas-pipeline "$w";
                else
                        echo $w $job_id $jms_status_code $jms_status_error  > ./jms_error.out
                fi
        ;;
  
    workflows_tagbased)
        echo "To delete job types with specific tag"
        read -p "Enter tag:" tag_argument
  
        # select environment for workflows
        if [ "$env_argument" = "prod" ]; then
            echo "prod selected for finding jobs with specific keyword/tag"
            for ctx in $(curl -s -X "GET" \
            "https://raas-job-management.100100021.prod.aws.orionadp.com/v1/jobs?tags=${tag_argument}%3A&page=0&size=2000" \
            -H "accept: application/json" | jq -r '.content[] | .contextId'); do echo "##########################################"; echo ""; echo "Context id: ${ctx}" ; echo ""; argo delete -n raas-pipeline -l context_id=${ctx} --status Running,Failed,Error ; done
        elif [ "$env_argument" = "int" ]; then
            echo "int selected for finding jobs with specific keyword/tag"
            for ctx in $(curl -s -X "GET" \
            "https://raas-job-management.100100020.int.aws.orionadp.com/v1/jobs?tags=${tag_argument}%3A&page=0&size=2000" \
            -H "accept: application/json" | jq -r '.content[] | .contextId'); do echo "##########################################"; echo ""; echo "Context id: ${ctx}" ; echo ""; argo delete -n raas-pipeline -l context_id=${ctx} --status Running,Failed,Error ; done
        elif [ "$env_argument" = "dev" ]; then
            echo "dev selected for finding jobs with specific keyword/tag"
            for ctx in $(curl -s -X "GET" \
            "https://raas-job-management.100100019.dev.aws.orionadp.com/v1/jobs?tags=${tag_argument}%3A&page=0&size=2000" \
            -H "accept: application/json" | jq -r '.content[] | .contextId'); do echo "##########################################"; echo ""; echo "Context id: ${ctx}" ; echo ""; argo delete -n raas-pipeline -l context_id=${ctx} --status Running,Failed,Error ; done
        else
            echo "invalid input for env argument"
        fi
        ;;
  
    workflows_xoldest)
        echo "To delete X oldest jobs"
        read -p "Enter workflow status (Failed/Error/Succeeded/Running):" workflow_status
        read -p "Enter number of top oldest workflows:" workflows_num
 
        kubectl get workflow --all-namespaces |
            awk -v wf_status="$workflow_status" '$3==wf_status {print $1,$2,$3,$4}' |
            transform_line |
            awk '{print $2,$3,$4,$5,$6}' | sort -k5,5nr | head -n "$workflows_num" > ./workflows_oldest.out
         
        for w in $(cat workflows_oldest.out | awk '{print $1}');
            do echo "$w";
                # echo "Fetching details for workflow: $workflow"
                workflow_details=$(kubectl -n raas-pipeline get wf $w -o json)
                # Extracting job_id from metadata
              job_id=$(echo "$workflow_details" | jq -r '.metadata.labels.job_id')
 
                # Invoking the JMS API to delete the JMS job with job id
                job_status=$(curl -X 'DELETE' $api_endpoint/$job_id -H 'accept: application/json')
                jms_status_code=$(echo $job_status | jq -r '.status')
                jms_status_error=$(echo $job_status | jq -r '.error')
 
                if [[ "$jms_status_code" = "200" ]]; then
                        # Invoking the Argo workflow delete for the given workflow
                        argo delete -n raas-pipeline "$w";
                else 
                        echo $w $job_id $jms_status_code $jms_status_error  > ./jms_error.out
                fi
        ;;
  
    get_workflows_running_longer_xdays)
        echo "To get running workflows longer than x days (output in csv format)"
        workflow_status="Running"
        read -p "Enter output file name(without extension name .csv):" output_csv_filename
        read -p "Enter number of days(minimun duration of running workflow):" min_days
        min_hours=$(($min_days * 24))
 
 
        kubectl get workflow --all-namespaces |
            awk -v wf_status=$workflow_status '$3==wf_status {print $1,$2,$3,$4}' |
            transform_line |
            awk -v mindays=$min_days '$6 >= mindays {print $1,$2,$3,$4,$5,$6}' |
            convert_format_csv > $output_csv_filename.csv
        ;;
 
    delete_workflows_in_csv_file)
        echo "To delete the workflows (documented in the pre-defined input csv file"
        read -p "Enter the input file name(without extension name .csv):" input_csv_filename
        read -p "Confirmation for the deletion with 'YES', otherwise the task will be aborted:" deletion_confirmatiion
 
        if [ "$deletion_confirmatiion" = "YES" ]; then
            echo "[INFO] Start to delete workflows ..."
            for wf in $(cat $input_csv_filename.csv | tail -n +2 | awk -F ";" '{print $2}'); do
              # echo "Fetching details for workflow: $workflow"
              workflow_details=$(kubectl -n raas-pipeline get wf $wf -o json)
              # Extracting job_id from metadata
              job_id=$(echo "$workflow_details" | jq -r '.metadata.labels.job_id')
              # Invoking the JMS API to delete the JMS job with job id
              job_status=$(curl -X 'DELETE' $api_endpoint/$job_id -H 'accept: application/json')
              jms_status_code=$(echo $job_status | jq -r '.status')
                jms_status_error=$(echo $job_status | jq -r '.error')
 
              if [[ "$jms_status_code" = "200" ]]; then
                        # Invoking the Argo workflow delete for the given workflow
                        echo "[INFO] Deleting running workflow <$wf>";
                        argo delete -n raas-pipeline "$wf";
                        echo "Done";
              else 
                        echo $w $job_id $jms_status_code $jms_status_error  > ./jms_error.out
              fi
 
               
               
               
            done
        else
            echo "[INFO] Deletion task is aborted"
        fi
        ;;
    *)
        echo "Invalid cleanup criteria: $command_input"
        echo "Valid cleanup criteria are: workflows_xdays, workflows_xoldest, workflows_tagbased, workflows_keyword"
        exit 1
        ;;
esac