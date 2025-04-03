import sys
import re
 
def check_aws_arn(file_path):
    pattern = re.compile(r'arn:aws:')  # 匹配AWS ARN标识
    with open(file_path, 'r') as f:
        result = True
        for i, line in enumerate(f, 1):
            if pattern.search(line):
                print(f"please avoid hard coded ARN strings：{file_path} line {i}")
                result = False               
    return result
    
if __name__ == "__main__":
    files_to_check = sys.argv[1:]  # 接收pre-commit传递的文件列表
    has_error = False
    for file in files_to_check:
        if not check_aws_arn(file):
            has_error = True
    print(f"是否含有hard_coding:{has_error}")
    sys.exit(1 if has_error else 0)  # 存在敏感内容时退出码为1（阻止提交）