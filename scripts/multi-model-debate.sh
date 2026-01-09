#!/bin/bash
# Multi-Model Debate (MMD) Protocol - Phase 1 & Phase 3 Implementation
# Phase 1: 3モデル並列提案
# Phase 3: Sequential収束（Opus→GPT→Gemini→Opus最終統合）

# エラー時即座に終了（pipefail/nounsetは不使用: 03_Warp_Stability準拠）
set -e

# ディレクトリ設定
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
MMD_PROCESSOR="$SCRIPT_DIR/mmd/processor.py"

# 共通ライブラリ読み込み
if [ ! -f "$LIB_DIR/parallel_executor.sh" ]; then
  echo "Error: $LIB_DIR/parallel_executor.sh not found" >&2
  exit 1
fi
source "$LIB_DIR/parallel_executor.sh"

# Python3存在確認
if ! command -v python3 &> /dev/null; then
  echo "Error: python3 not found. Please install Python 3." >&2
  exit 1
fi

# processor.py存在確認
if [ ! -f "$MMD_PROCESSOR" ]; then
  echo "Error: $MMD_PROCESSOR not found" >&2
  exit 1
fi

# 設定
WORK_DIR="${MMD_WORK_DIR:-/tmp/warp-mmd}"
RESPONSE_DIR="$WORK_DIR/responses"

# プロファイルID（warp agent profile listで取得済み）
OPUS_PROFILE="iUjCcjsL0otahWE5Y4HRLJ"
GPT_PROFILE="EfA29rT7V15t1UGYfqhba0"
GEMINI_PROFILE="ZhBegv65Pwb3syn28z5P3H"

# 使用法表示
usage() {
  echo "Usage:"
  echo "  $0 [--state <file>] <context> <constraint> <goal>  # Phase 1: 並列提案"
  echo "  $0 --phase3                                         # Phase 3: Sequential収束"
  echo ""
  echo "Phase 1: 3モデル並列提案"
  echo "Phase 2: 手動で focus.md 作成（Warpに依頼）"
  echo "Phase 3: Sequential収束（Opus→GPT→Gemini→Opus最終統合）"
  echo ""
  echo "Options:"
  echo "  --state <file>  - 背景知識・詳細コンテキストファイル（optional, MMR state.md相当）"
  echo ""
  echo "Arguments:"
  echo "  context         - 議論の背景・目的（簡潔に）"
  echo "  constraint      - 順守すべき制約事項"
  echo "  goal            - 完了条件・成果物定義"
  echo ""
  echo "Environment Variables:"
  echo "  MMD_WORK_DIR - 作業ディレクトリ（default: /tmp/warp-mmd）"
  echo ""
  echo "Example:"
  echo "  $0 --state exmon-context.md \\"
  echo "    \"RBAによるメモリ逼迫対応の自動化\" \\"
  echo "    \"既存手動フロー3〜5を置換、SLO 99.9%維持\" \\"
  echo "    \"Automation Actions起動からResolveまでの詳細フロー設計\""
  exit 1
}

# 引数チェック
STATE_FILE=""
if [ "$1" = "--phase3" ]; then
  PHASE=3
elif [ "$1" = "--state" ]; then
  # --state <file> context constraint goal
  if [ $# -lt 5 ]; then
    usage
  fi
  PHASE=1
  STATE_FILE="$2"
  CONTEXT="$3"
  CONSTRAINT="$4"
  GOAL="$5"
  
  # state file存在確認
  if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found: $STATE_FILE" >&2
    exit 1
  fi
elif [ $# -eq 3 ]; then
  PHASE=1
  CONTEXT="$1"
  CONSTRAINT="$2"
  GOAL="$3"
else
  usage
fi

# =============================================================================
# Phase 1: 並列提案
# =============================================================================
if [ $PHASE -eq 1 ]; then
echo "=== Phase 1: Parallel Proposals ==="

# 作業ディレクトリ準備
mkdir -p "$RESPONSE_DIR"

# プロンプト生成
echo "Generating prompt with Option B template..."
if [ -n "$STATE_FILE" ]; then
  echo "Using state file: $STATE_FILE"
  PROMPT_RAW=$("$MMD_PROCESSOR" generate-prompt \
    --state "$STATE_FILE" \
    --context "$CONTEXT" \
    --constraint "$CONSTRAINT" \
    --goal "$GOAL")
else
  PROMPT_RAW=$("$MMD_PROCESSOR" generate-prompt \
    --context "$CONTEXT" \
    --constraint "$CONSTRAINT" \
    --goal "$GOAL")
fi

RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Failed to generate prompt" >&2
  exit $RC
fi

# エスケープ処理（Bash引数用）
PROMPT_ESCAPED=$(echo "$PROMPT_RAW" | "$MMD_PROCESSOR" escape)

# 並列実行準備
setup_parallel_execution

# 3モデル並列起動（stderr分離でMarkdown汚染防止）
echo "Launching Opus, GPT, and Gemini in parallel..."

launch_parallel_task "Opus" \
  "warp agent run --profile \"$OPUS_PROFILE\" --prompt '$PROMPT_ESCAPED' > \"$RESPONSE_DIR/r1_opus.md\" 2> \"$RESPONSE_DIR/r1_opus.log\""

launch_parallel_task "GPT" \
  "warp agent run --profile \"$GPT_PROFILE\" --prompt '$PROMPT_ESCAPED' > \"$RESPONSE_DIR/r1_gpt.md\" 2> \"$RESPONSE_DIR/r1_gpt.log\""

launch_parallel_task "Gemini" \
  "warp agent run --profile \"$GEMINI_PROFILE\" --prompt '$PROMPT_ESCAPED' > \"$RESPONSE_DIR/r1_gemini.md\" 2> \"$RESPONSE_DIR/r1_gemini.log\""

# Wait-All: 全完了待機
wait_all_tasks
RC=$?

if [ $RC -ne 0 ]; then
  echo ""
  echo "=== Phase 1 failed ==="
  echo "See logs in: $RESPONSE_DIR"
  exit $RC
fi

echo ""
echo "=== Phase 1 completed ==="
echo "Outputs:"
echo "  - Opus:   $RESPONSE_DIR/r1_opus.md"
echo "  - GPT:    $RESPONSE_DIR/r1_gpt.md"
echo "  - Gemini: $RESPONSE_DIR/r1_gemini.md"
echo ""
echo "Next: Phase 2 (Manual)"
echo "  1. Read the 3 outputs above"
echo "  2. Ask Warp to analyze and create $WORK_DIR/focus.md"
echo "  3. Run: $0 --phase3"
echo ""
echo "Note: Phase 2 is a manual step. Ask Warp to analyze the outputs and create focus.md."
exit 0
fi

# =============================================================================
# Phase 3: Sequential収束
# =============================================================================
if [ $PHASE -eq 3 ]; then
echo "=== Phase 3: Sequential Convergence ==="

# focus.md存在確認
FOCUS_FILE="$WORK_DIR/focus.md"
if [ ! -f "$FOCUS_FILE" ]; then
  echo "Error: $FOCUS_FILE not found" >&2
  echo "Please complete Phase 2 first (create focus.md)" >&2
  exit 1
fi

# Phase 1出力存在確認
if [ ! -f "$RESPONSE_DIR/r1_opus.md" ] || [ ! -f "$RESPONSE_DIR/r1_gpt.md" ] || [ ! -f "$RESPONSE_DIR/r1_gemini.md" ]; then
  echo "Error: Phase 1 outputs not found in $RESPONSE_DIR" >&2
  echo "Please run Phase 1 first" >&2
  exit 1
fi

echo "Focus file: $FOCUS_FILE"
echo ""

# Round 2: Opus (前ラウンド: r1全て + focus)
echo "Round 2: Opus refinement..."

# r1全出力を連結
PREVIOUS_R1="# Round 1 Outputs

## Opus
$(cat "$RESPONSE_DIR/r1_opus.md")

## GPT
$(cat "$RESPONSE_DIR/r1_gpt.md")

## Gemini
$(cat "$RESPONSE_DIR/r1_gemini.md")"

# 一時ファイルに保存
echo "$PREVIOUS_R1" > "$WORK_DIR/r1_combined.md"

PROMPT_R2_OPUS=$("$MMD_PROCESSOR" generate-prompt \
  --context "$(cat "$FOCUS_FILE")" \
  --constraint "Refine based on all 3 initial proposals above. Do NOT implement code changes, create commits, or create PRs. Output evaluation and recommendations only." \
  --goal "Provide refined proposal addressing the focus points" \
  --previous "$WORK_DIR/r1_combined.md")

RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Failed to generate Round 2 prompt" >&2
  exit $RC
fi

# Phase 3はforeground実行のためescape不要（ダブルクォートで直接渡す）
warp agent run --profile "$OPUS_PROFILE" --prompt "$PROMPT_R2_OPUS" > "$RESPONSE_DIR/r2_opus.md" 2> "$RESPONSE_DIR/r2_opus.log"
RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Round 2 (Opus) failed (exit code: $RC)" >&2
  echo "See log: $RESPONSE_DIR/r2_opus.log" >&2
  exit $RC
fi
echo "✓ Round 2 completed: $RESPONSE_DIR/r2_opus.md"

# Round 3: GPT (前ラウンド: r2_opus)
echo "Round 3: GPT refinement..."

PROMPT_R3_GPT=$("$MMD_PROCESSOR" generate-prompt \
  --context "$(cat "$FOCUS_FILE")" \
  --constraint "Refine based on Opus's refined proposal. Do NOT implement code changes, create commits, or create PRs. Output evaluation and recommendations only." \
  --goal "Provide further refined proposal" \
  --previous "$RESPONSE_DIR/r2_opus.md")

RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Failed to generate Round 3 prompt" >&2
  exit $RC
fi

warp agent run --profile "$GPT_PROFILE" --prompt "$PROMPT_R3_GPT" > "$RESPONSE_DIR/r3_gpt.md" 2> "$RESPONSE_DIR/r3_gpt.log"
RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Round 3 (GPT) failed (exit code: $RC)" >&2
  echo "See log: $RESPONSE_DIR/r3_gpt.log" >&2
  exit $RC
fi
echo "✓ Round 3 completed: $RESPONSE_DIR/r3_gpt.md"

# Round 4: Gemini (前ラウンド: r3_gpt)
echo "Round 4: Gemini refinement..."

PROMPT_R4_GEMINI=$("$MMD_PROCESSOR" generate-prompt \
  --context "$(cat "$FOCUS_FILE")" \
  --constraint "Refine based on GPT's refined proposal. Do NOT implement code changes, create commits, or create PRs. Output evaluation and recommendations only." \
  --goal "Provide further refined proposal" \
  --previous "$RESPONSE_DIR/r3_gpt.md")

RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Failed to generate Round 4 prompt" >&2
  exit $RC
fi

warp agent run --profile "$GEMINI_PROFILE" --prompt "$PROMPT_R4_GEMINI" > "$RESPONSE_DIR/r4_gemini.md" 2> "$RESPONSE_DIR/r4_gemini.log"
RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Round 4 (Gemini) failed (exit code: $RC)" >&2
  echo "See log: $RESPONSE_DIR/r4_gemini.log" >&2
  exit $RC
fi
echo "✓ Round 4 completed: $RESPONSE_DIR/r4_gemini.md"

# Round 5: Opus 最終統合 (前ラウンド: r4_gemini)
echo "Round 5: Opus final integration..."

PROMPT_R5_OPUS=$("$MMD_PROCESSOR" generate-prompt \
  --context "$(cat "$FOCUS_FILE")" \
  --constraint "Provide final integrated proposal. Do NOT implement code changes, create commits, or create PRs. Output evaluation and recommendations only." \
  --goal "Final decision with clear rationale and implementation plan" \
  --previous "$RESPONSE_DIR/r4_gemini.md")

RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Failed to generate Round 5 prompt" >&2
  exit $RC
fi

warp agent run --profile "$OPUS_PROFILE" --prompt "$PROMPT_R5_OPUS" > "$RESPONSE_DIR/r5_opus_final.md" 2> "$RESPONSE_DIR/r5_opus_final.log"
RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Round 5 (Opus final) failed (exit code: $RC)" >&2
  echo "See log: $RESPONSE_DIR/r5_opus_final.log" >&2
  exit $RC
fi
echo "✓ Round 5 completed: $RESPONSE_DIR/r5_opus_final.md"

echo ""
echo "=== Phase 3 completed ==="
echo "Final output: $RESPONSE_DIR/r5_opus_final.md"
echo ""
echo "All rounds:"
echo "  - Round 2 (Opus):   $RESPONSE_DIR/r2_opus.md"
echo "  - Round 3 (GPT):    $RESPONSE_DIR/r3_gpt.md"
echo "  - Round 4 (Gemini): $RESPONSE_DIR/r4_gemini.md"
echo "  - Round 5 (Opus):   $RESPONSE_DIR/r5_opus_final.md"
exit 0
fi
