import sys
import re
import os

try:
    from colorama import init, Fore, Style
    init()
    COLOR = True
except ImportError:
    COLOR = False

ARN_PATTERN = re.compile(r"arn:aws:[a-z0-9-]+:[a-z0-9-]*:\d{12}:[\w+=,.@/-]+")

def color_text(text, color):
    if not COLOR:
        return text
    return f"{color}{text}{Style.RESET_ALL}"

def check_aws_arn(file_path):
    if not os.path.exists(file_path):
        print(color_text(f"[ERROR] File not found: {file_path}", Fore.RED))
        return False

    if not os.path.isfile(file_path):
        print(color_text(f"[SKIPPED] Not a regular file: {file_path}", Fore.YELLOW))
        return True

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            result = True
            for i, line in enumerate(f, 1):
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue  # 忽略空行和注释行
                if ARN_PATTERN.search(stripped):
                    print(
                        color_text("[WARN] ", Fore.RED) +
                        f"Hard-coded AWS ARN found in {file_path} at line {i}:\n  {stripped}"
                    )
                    result = False
        return result
    except UnicodeDecodeError:
        print(color_text(f"[SKIPPED] Binary or non-text file: {file_path}", Fore.YELLOW))
        return True
    except Exception as e:
        print(color_text(f"[ERROR] Could not check {file_path}: {e}", Fore.RED))
        return False

if __name__ == "__main__":
    files_to_check = sys.argv[1:]
    has_error = False
    for file in files_to_check:
        if not check_aws_arn(file):
            has_error = True
    print("Check finished.")
    sys.exit(1 if has_error else 0)
