#!/bin/bash
# Multi-Model Review (MMR) Protocol 自動実行スクリプト
# 3モデル（Opus/GPT/Gemini）で批判的レビューを実施し、統合見解を生成する

# エラー時即座に終了（pipefail/nounsetは不使用: 03_Warp_Stability準拠）
set -e

# 設定
STATE_FILE="/tmp/warp-cross-pane/state.md"
REQUEST_FILE="/tmp/warp-cross-pane/review-request.md"
RESPONSE_DIR="/tmp/warp-cross-pane/responses"
FINAL_RESPONSE="/tmp/warp-cross-pane/review-response.md"

# 終了時クリーンアップ（Ctrl+C時のバックグラウンドプロセス孤児化防止）
cleanup() {
  local jobs_pids=$(jobs -p)
  if [ -n "$jobs_pids" ]; then
    echo "Cleaning up background processes: $jobs_pids"
    kill $jobs_pids 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# プロファイルID（warp agent profile listで取得済み）
OPUS_PROFILE="iUjCcjsL0otahWE5Y4HRLJ"
GPT_PROFILE="EfA29rT7V15t1UGYfqhba0"
GEMINI_PROFILE="ZhBegv65Pwb3syn28z5P3H"

# 必須ファイル存在確認
if [ ! -f "$STATE_FILE" ]; then
  echo "Error: $STATE_FILE が存在しません"
  exit 1
fi

if [ ! -f "$REQUEST_FILE" ]; then
  echo "Error: $REQUEST_FILE が存在しません"
  exit 1
fi

# レスポンスディレクトリ準備
mkdir -p "$RESPONSE_DIR"

# レビュープロンプト
REVIEW_PROMPT="Read $STATE_FILE and $REQUEST_FILE, then provide a critical review following the review guidelines. Output your review in markdown format."

# 各モデルでレビュー実行（並列）
echo "=== Starting parallel reviews ==="
echo "Launching Opus, GPT, and Gemini in parallel..."

# バックグラウンドで3モデル起動（stderr分離でMarkdown汚染防止）
warp agent run --profile "$OPUS_PROFILE" --prompt "$REVIEW_PROMPT" > "$RESPONSE_DIR/opus.md" 2> "$RESPONSE_DIR/opus.log" &
OPUS_PID=$!

warp agent run --profile "$GPT_PROFILE" --prompt "$REVIEW_PROMPT" > "$RESPONSE_DIR/gpt.md" 2> "$RESPONSE_DIR/gpt.log" &
GPT_PID=$!

warp agent run --profile "$GEMINI_PROFILE" --prompt "$REVIEW_PROMPT" > "$RESPONSE_DIR/gemini.md" 2> "$RESPONSE_DIR/gemini.log" &
GEMINI_PID=$!

echo "Opus PID: $OPUS_PID"
echo "GPT PID: $GPT_PID"
echo "Gemini PID: $GEMINI_PID"

# プロセス起動成功確認（kill -0は起動直後の生存確認用）
sleep 1
if ! kill -0 $OPUS_PID 2>/dev/null; then
  echo "Error: Opus process failed to start" >&2
  exit 1
fi
if ! kill -0 $GPT_PID 2>/dev/null; then
  echo "Error: GPT process failed to start" >&2
  exit 1
fi
if ! kill -0 $GEMINI_PID 2>/dev/null; then
  echo "Error: Gemini process failed to start" >&2
  exit 1
fi

echo "All processes started successfully. Waiting for completion..."

# 全プロセス完了待機（Wait-All戦略: 全モデル完了を待ち、失敗を集約）
wait $OPUS_PID
OPUS_RC=$?
if [ $OPUS_RC -eq 0 ]; then
  echo "✓ Opus review completed"
else
  echo "✗ Opus review failed (exit code: $OPUS_RC)"
fi

wait $GPT_PID
GPT_RC=$?
if [ $GPT_RC -eq 0 ]; then
  echo "✓ GPT review completed"
else
  echo "✗ GPT review failed (exit code: $GPT_RC)"
fi

wait $GEMINI_PID
GEMINI_RC=$?
if [ $GEMINI_RC -eq 0 ]; then
  echo "✓ Gemini review completed"
else
  echo "✗ Gemini review failed (exit code: $GEMINI_RC)"
fi

# エラーチェック（Wait-All: 全完了後に失敗判定）
if [ $OPUS_RC -ne 0 ] || [ $GPT_RC -ne 0 ] || [ $GEMINI_RC -ne 0 ]; then
  echo ""
  echo "=== Review failed ==="
  echo "Failed models:"
  [ $OPUS_RC -ne 0 ] && echo "  - Opus (see $RESPONSE_DIR/opus.log)"
  [ $GPT_RC -ne 0 ] && echo "  - GPT (see $RESPONSE_DIR/gpt.log)"
  [ $GEMINI_RC -ne 0 ] && echo "  - Gemini (see $RESPONSE_DIR/gemini.log)"
  exit 1
fi

echo ""
echo "=== All reviews completed successfully ==="

# 統合レビュー作成
echo "=== Integration ==="
INTEGRATION_PROMPT="Read the following 3 model reviews and create an integrated summary:
- Opus: $RESPONSE_DIR/opus.md
- GPT: $RESPONSE_DIR/gpt.md
- Gemini: $RESPONSE_DIR/gemini.md

Create a unified review-response.md that:
1. Summarizes common conclusions across all 3 models
2. Highlights where models disagree
3. Provides a recommended priority order for implementation

Output to $FINAL_RESPONSE"

warp agent run --profile "$OPUS_PROFILE" --prompt "$INTEGRATION_PROMPT" > "$FINAL_RESPONSE"
RC=$?
if [ $RC -ne 0 ]; then
  echo "Error: Integration failed (exit code: $RC)"
  exit $RC
fi

echo "=== Complete ==="
echo "Review saved to: $FINAL_RESPONSE"
echo ""
echo "Individual reviews:"
echo "  - Opus:   $RESPONSE_DIR/opus.md"
echo "  - GPT:    $RESPONSE_DIR/gpt.md"
echo "  - Gemini: $RESPONSE_DIR/gemini.md"
