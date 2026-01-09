#!/bin/bash
# Parallel Execution Library
# 並列実行制御の共通ライブラリ（MMR/MMD共通）
#
# Usage:
#   source "$(dirname "$0")/lib/parallel_executor.sh"
#   setup_parallel_execution
#   launch_parallel_task "TaskName" "command with args > output.log 2> error.log"
#   wait_all_tasks

# エラー時即座に終了（pipefail/nounsetは不使用: 03_Warp_Stability準拠）
set -e

# グローバル変数
declare -a PARALLEL_PIDS=()
declare -a PARALLEL_NAMES=()
declare -a PARALLEL_STATUSES=()
declare -a PARALLEL_WAITED=()  # wait済みフラグ（二重wait防止）

# クリーンアップ関数（Ctrl+C時のバックグラウンドプロセス孤児化防止）
#
# 🔧 FIX: jobs -p ではなく PARALLEL_PIDS を使用（副作用軽減）
# jobs -p は他のバックグラウンドジョブも巻き込む可能性があるため、
# このライブラリで管理しているPIDのみをクリーンアップする。
cleanup_parallel_tasks() {
  if [ ${#PARALLEL_PIDS[@]} -eq 0 ]; then
    return 0
  fi
  
  echo "Cleaning up background processes: ${PARALLEL_PIDS[*]}"
  for pid in "${PARALLEL_PIDS[@]}"; do
    # プロセスが存在する場合のみkill
    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
    fi
  done
}

# trap設定
setup_parallel_execution() {
  trap cleanup_parallel_tasks EXIT INT TERM
}

# タスク起動
# Usage: launch_parallel_task "task_name" "command > output.log 2> error.log"
# Note: コマンドにはリダイレクト（stderr分離）を含めること
#
# ⚠️ SECURITY WARNING: This function uses `eval` which can be a security risk.
# Ensure that all input to this function is from trusted sources only.
# TODO: Refactor to use array-based API or --prompt-file approach to eliminate `eval`.
launch_parallel_task() {
  if [ $# -lt 2 ]; then
    echo "Error: launch_parallel_task requires 2 arguments: task_name command" >&2
    return 1
  fi
  
  local task_name="$1"
  shift
  local command="$@"
  
  # バックグラウンド実行（eval使用 - セキュリティ上の懸念あり）
  eval "$command" &
  local pid=$!
  
  local idx=${#PARALLEL_PIDS[@]}
  PARALLEL_PIDS+=("$pid")
  PARALLEL_NAMES+=("$task_name")
  PARALLEL_WAITED+=(0)  # 未wait
  
  echo "$task_name PID: $pid"
  
  # 起動確認（1秒後）
  # 🔧 FIX: 1秒以内に正常終了した高速タスクを誤判定しないよう、wait で確認
  sleep 1
  if ! kill -0 $pid 2>/dev/null; then
    # プロセスが既に終了している可能性
    # wait で終了コードを確認（既に終了している場合は即座に戻る）
    set +e
    wait $pid 2>/dev/null
    local rc=$?
    set -e
    
    # 🔧 FIX: wait済みをマーク（二重wait防止）
    PARALLEL_WAITED[$idx]=1
    PARALLEL_STATUSES[$idx]=$rc
    
    if [ $rc -eq 0 ]; then
      # 1秒以内に正常終了（高速タスク）
      echo "$task_name completed quickly (exit code: 0)"
    else
      # 起動失敗
      echo "Error: $task_name process failed to start (exit code: $rc)" >&2
      return 1
    fi
  fi
  
  return 0
}

# 全タスク完了待機（Wait-All戦略: 全完了を待ち、失敗を集約）
#
# 🔧 FIX: errexit (set -e) を一時無効化し、全タスクの失敗を集約してから判定する。
# `wait $pid` が非0を返しても即座にシェル終了しないようにする。
wait_all_tasks() {
  local all_success=true
  
  if [ ${#PARALLEL_PIDS[@]} -eq 0 ]; then
    echo "Warning: No parallel tasks to wait for" >&2
    return 0
  fi
  
  echo "All processes started successfully. Waiting for completion..."
  
  # errexit一時無効化（wait失敗時にシェル終了を防ぐ）
  set +e
  
  for i in "${!PARALLEL_PIDS[@]}"; do
    local pid="${PARALLEL_PIDS[$i]}"
    local name="${PARALLEL_NAMES[$i]}"
    
    # 🔧 FIX: 既にwait済みならスキップ（二重wait防止）
    if [ "${PARALLEL_WAITED[$i]:-0}" -eq 1 ]; then
      local rc="${PARALLEL_STATUSES[$i]}"
      if [ $rc -eq 0 ]; then
        echo "✓ $name completed (already waited)"
      else
        echo "✗ $name failed (exit code: $rc, already waited)"
        all_success=false
      fi
      continue
    fi
    
    wait $pid
    local rc=$?
    PARALLEL_STATUSES[$i]=$rc
    PARALLEL_WAITED[$i]=1
    
    if [ $rc -eq 0 ]; then
      echo "✓ $name completed"
    else
      echo "✗ $name failed (exit code: $rc)"
      all_success=false
    fi
  done
  
  # errexit再有効化
  set -e
  
  # エラーチェック（Wait-All: 全完了後に失敗判定）
  if [ "$all_success" = false ]; then
    echo ""
    echo "=== Parallel execution failed ==="
    echo "Failed tasks:"
    for i in "${!PARALLEL_STATUSES[@]}"; do
      if [ "${PARALLEL_STATUSES[$i]}" -ne 0 ]; then
        echo "  - ${PARALLEL_NAMES[$i]}"
      fi
    done
    return 1
  fi
  
  echo ""
  echo "=== All tasks completed successfully ==="
  return 0
}

# 状態リセット（複数回使用時）
reset_parallel_execution() {
  PARALLEL_PIDS=()
  PARALLEL_NAMES=()
  PARALLEL_STATUSES=()
  PARALLEL_WAITED=()
}
