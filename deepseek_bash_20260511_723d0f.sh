#!/bin/bash
# 一键创建 PR Review Agent 项目

PROJECT_DIR="pr_review_agent"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# 创建 requirements.txt
cat > requirements.txt << 'EOF'
langchain==0.1.0
langchain-openai==0.0.2
python-dotenv==1.0.0
PyGithub==2.1.1
gitpython==3.1.40
tenacity==8.2.3
pydantic==2.5.0
httpx==0.25.0
requests==2.31.0
EOF

# 创建 .env 模板
cat > .env.example << 'EOF'
GITHUB_TOKEN=ghp_your_github_token_here
OPENAI_API_KEY=sk-your-openai-key-here
OPENAI_BASE_URL=https://api.openai.com/v1
REPO_OWNER=your_username
REPO_NAME=your_repo
PR_NUMBER=1
MODEL_NAME=gpt-4o-mini
EOF

# 创建 config.py
cat > config.py << 'EOF'
import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")
    REPO_OWNER = os.getenv("REPO_OWNER")
    REPO_NAME = os.getenv("REPO_NAME")
    PR_NUMBER = int(os.getenv("PR_NUMBER", "1"))
    
    OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
    OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    MODEL_NAME = os.getenv("MODEL_NAME", "gpt-4o-mini")
    
    MAX_TOKENS_PER_REVIEW = 4000
    AUTO_FIX_SIMPLE_ISSUES = True
    
    CODE_STANDARDS = """
    1. 变量/函数命名使用 snake_case，类名使用 PascalCase
    2. 避免魔法数字，应定义为常量
    3. 函数长度不超过 50 行
    4. 避免重复代码（DRY 原则）
    5. 异常处理要具体，不要使用 bare except
    6. 类型注解必须完整
    7. 每行代码不超过 120 字符
    """
EOF

# 创建 github_client.py
cat > github_client.py << 'EOF'
from github import Github, GithubException
from github.PullRequest import PullRequest
from config import Config
import logging
import requests

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class GitHubClient:
    def __init__(self):
        self.g = Github(Config.GITHUB_TOKEN)
        self.repo = self.g.get_repo(f"{Config.REPO_OWNER}/{Config.REPO_NAME}")
        self.pr: PullRequest = self.repo.get_pull(Config.PR_NUMBER)
    
    def get_pr_diff(self) -> str:
        diff_url = self.pr.diff_url
        headers = {"Authorization": f"token {Config.GITHUB_TOKEN}"}
        response = requests.get(diff_url, headers=headers)
        if response.status_code == 200:
            return response.text
        raise Exception(f"Failed to fetch diff: {response.status_code}")
    
    def get_pr_files(self):
        return list(self.pr.get_files())
    
    def post_review_comment(self, body: str, path: str = None, line: int = None):
        try:
            if path and line:
                commit = list(self.pr.get_commits())[-1]
                self.pr.create_review_comment(body=body, commit=commit, path=path, line=line)
            else:
                self.pr.create_issue_comment(body)
            logger.info(f"Comment posted")
        except GithubException as e:
            logger.error(f"Failed to post comment: {e}")
    
    def create_fix_branch(self, base_branch: str, fix_branch_name: str) -> bool:
        try:
            base_ref = self.repo.get_git_ref(f"heads/{base_branch}")
            self.repo.create_git_ref(ref=f"refs/heads/{fix_branch_name}", sha=base_ref.object.sha)
            logger.info(f"Created branch: {fix_branch_name}")
            return True
        except GithubException as e:
            logger.error(f"Failed to create branch: {e}")
            return False
    
    def create_pull_request(self, title: str, body: str, head: str, base: str):
        try:
            new_pr = self.repo.create_pull(title=title, body=body, head=head, base=base)
            logger.info(f"Created PR #{new_pr.number}")
            return new_pr
        except GithubException as e:
            logger.error(f"Failed to create PR: {e}")
            return None
EOF

# 创建 review_agent.py
cat > review_agent.py << 'EOF'
from langchain_openai import ChatOpenAI
from langchain.schema import HumanMessage
from config import Config
from github_client import GitHubClient
import re
import json
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class ReviewAgent:
    def __init__(self, github_client: GitHubClient):
        self.github = github_client
        self.llm = ChatOpenAI(
            api_key=Config.OPENAI_API_KEY,
            base_url=Config.OPENAI_BASE_URL,
            model=Config.MODEL_NAME,
            temperature=0.3,
            max_tokens=Config.MAX_TOKENS_PER_REVIEW
        )
    
    def _parse_diff_by_file(self, diff_text: str) -> dict:
        files = {}
        current_file = None
        current_content = []
        for line in diff_text.split('\n'):
            if line.startswith('diff --git'):
                if current_file:
                    files[current_file] = '\n'.join(current_content)
                match = re.search(r'diff --git a/(.+) b/(.+)', line)
                if match:
                    current_file = match.group(1)
                current_content = []
            elif current_file:
                current_content.append(line)
        if current_file and current_content:
            files[current_file] = '\n'.join(current_content)
        return files
    
    def review_pr(self) -> dict:
        logger.info("Starting PR review...")
        diff_text = self.github.get_pr_diff()
        files_diff = self._parse_diff_by_file(diff_text)
        
        review_results = {'overall_summary': '', 'issues': [], 'fixable_issues': [], 'risk_level': 'low'}
        
        for file_path, file_diff in files_diff.items():
            logger.info(f"Reviewing {file_path}")
            if len(file_diff) > 50:
                llm_prompt = f"""
                请对以下代码变更进行 Code Review：
                变更文件: {file_path}
                代码变更: