import sys
import re
import logging


def check_aws_arn(file_path):
    pattern = re.compile(r"arn:aws:")  # 匹配AWS ARN标识
    with open(file_path, "r") as f:

        errors = []
        for i, line in enumerate(f, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue  # 忽略空行和注释行

            # 忽略行内注释内容
            code_part = line.split("#")[0]
            if pattern.search(code_part):
                errors.append(f"please avoid hard coded ARN strings here : {file_path} line {i}")

    return errors


if __name__ == "__main__":
    files_to_check = sys.argv[1:]  # 接收pre-commit传递的文件列表
    has_error = False
    for file in files_to_check:
        errors = check_aws_arn(file)
        if errors:
            has_error = True
            for error in errors:
                logging.error(error)

    if has_error:
        print("Changes in modules folder contain hardcoded ARN.")
        sys.exit(1)  # 存在敏感内容时退出码为1（阻止提交）
    else:
        print("No hardcoded ARN found.")
        sys.exit(0)  # 无敏感内容时退出码为0
