#!/usr/bin/env python3
"""
MMD Processor - Multi-Model Debate用のテキスト処理ユーティリティ

Bashスクリプトからフィルタとして呼び出される。
Option Bテンプレート（Context/Constraint/Goal）の適用とエスケープ処理を提供。
"""

import sys
import argparse


def generate_prompt(context, constraint, goal, previous_output=None, state_content=None):
    """
    Option Bテンプレートでプロンプトを生成
    
    Args:
        context: 議論の背景・目的
        constraint: 順守すべき制約事項
        goal: 完了条件・成果物定義
        previous_output: 前ラウンドの出力（Optional）
        state_content: 背景知識・詳細コンテキスト（Optional）
    
    Returns:
        生成されたプロンプト文字列
    """
    prompt = ""
    
    # state（背景知識）があればプロンプト冒頭に配置
    if state_content:
        prompt += f"""# Background Knowledge & Context

{state_content}

---

"""
    
    prompt += f"""Context: {context}

Constraint: {constraint}

Goal: {goal}"""
    
    if previous_output:
        prompt += f"\n\n# Previous Round Output\n{previous_output}"
    
    return prompt


def escape_for_bash(text):
    """
    Bash引数用のエスケープ処理
    
    シングルクォート内で使用する想定のため、シングルクォートをエスケープ。
    
    Args:
        text: エスケープ対象のテキスト
    
    Returns:
        エスケープ済みテキスト
    """
    # シングルクォートを '\'\"'\"' に置換
    return text.replace("'", "'\"'\"'")


def main():
    parser = argparse.ArgumentParser(
        description="MMD Processor - Multi-Model Debate text processing utility"
    )
    parser.add_argument(
        "action",
        choices=["generate-prompt", "escape"],
        help="Action to perform"
    )
    parser.add_argument(
        "--context",
        help="Context for prompt generation"
    )
    parser.add_argument(
        "--constraint",
        help="Constraint for prompt generation"
    )
    parser.add_argument(
        "--goal",
        help="Goal for prompt generation"
    )
    parser.add_argument(
        "--state",
        help="Background knowledge & context file path (optional)"
    )
    parser.add_argument(
        "--previous",
        help="Previous round output file path"
    )
    parser.add_argument(
        "--input",
        help="Input file path (default: stdin for escape action)"
    )
    
    args = parser.parse_args()
    
    if args.action == "generate-prompt":
        # 必須引数チェック
        if not all([args.context, args.constraint, args.goal]):
            print("Error: generate-prompt requires --context, --constraint, and --goal", file=sys.stderr)
            return 1
        
        state_text = None
        if args.state:
            try:
                with open(args.state, 'r', encoding='utf-8') as f:
                    state_text = f.read()
            except IOError as e:
                print(f"Error: Failed to read state file: {e}", file=sys.stderr)
                return 1
        
        previous_text = None
        if args.previous:
            try:
                with open(args.previous, 'r', encoding='utf-8') as f:
                    previous_text = f.read()
            except IOError as e:
                print(f"Error: Failed to read previous output file: {e}", file=sys.stderr)
                return 1
        
        prompt = generate_prompt(args.context, args.constraint, args.goal, previous_text, state_text)
        print(prompt)
    
    elif args.action == "escape":
        try:
            if args.input:
                with open(args.input, 'r', encoding='utf-8') as f:
                    text = f.read()
            else:
                text = sys.stdin.read()
            
            print(escape_for_bash(text), end='')
        except IOError as e:
            print(f"Error: Failed to read input: {e}", file=sys.stderr)
            return 1
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
