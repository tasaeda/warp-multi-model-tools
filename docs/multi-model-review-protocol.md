# Multi-Model Review (MMR) Protocol

> 複数のLLMモデルを使用した相互レビュープロトコル。
> 単一モデルの盲点を補完し、バランスの取れた結論を導出する。

---

## 概要

### 目的
- 単一モデルの「癖」や「盲点」を複数モデルの視点で補完
- 設計判断、批判的分析、修正案などの品質向上
- 「深さ優先」「継続性優先」などの異なる評価軸のバランス

### 実証済みユースケース
- GTJ v2 週次レビュー手順書の批判的分析（2026-01-04）
  - Sonnetの批判をOpus/GPT/Geminiがメタ批判
  - 3モデル統合見解で修正案の優先順位を再評価
  - 結果: 修正1（anomalies追加）却下、代替案採用

---

## 実装方式

### 方式1: 手動ペイン分割（現行）

**構成**:
- 左ペイン: 主実行者（Sonnet等）
- 右ペイン: レビュワー（Opus/GPT/Gemini切り替え）
- 連携: `/tmp/warp-cross-pane/` 経由のファイル共有

**ファイル構成**:
```
/tmp/warp-cross-pane/
├── state.md          # 現在の議論状態（主実行ペインが更新）
├── review-request.md # レビュー依頼（主実行ペインが書く）
└── review-response.md # レビュー結果（レビューペインが書く）
```

**運用フロー**:
1. 主実行ペイン: 「sync」「保存」指示 → state.md更新
2. 主実行ペイン: review-request.mdにレビュー観点を記載
3. 人間: 右ペインのモデルを切り替え（UI操作）
4. レビューペイン: 「レビューして」指示 → state.md, review-request.md読む
5. レビューペイン: 批判・代替案・見落とし指摘を出力
6. 人間: モデル切り替え、3で繰り返し
7. 最後のモデル: 統合レビューをreview-response.mdに出力

**課題**:
- モデル切り替えがUI手動操作
- 統合作業は人間が担当

---

### 方式2: Warp CLI自動化（推奨・実装済み）

**概要**:
Warp CLIのAgent Profileを使用し、モデル切り替えをスクリプト化。
実装: `scripts/multi-model-review.sh`（並列実行版、7分で完走実績）

**前提条件**:
1. Warp CLIがインストール済み（Warpアプリ同梱）
2. モデル別Agent Profileを事前作成

**Agent Profile作成手順**:
1. Warp Settings > AI > Agents > Profiles を開く
2. 以下の3プロファイルを作成:
   - `Reviewer-Opus` (Base Model: Claude Opus 4.5)
   - `Reviewer-GPT` (Base Model: GPT-5.2)
   - `Reviewer-Gemini` (Base Model: Gemini 3)
3. 各プロファイルで必要な権限を設定:
   - ファイル読み書き: 許可
   - コマンド実行: 制限（レビュワーは実行禁止推奨）

**プロファイルID取得**:
```bash
warp agent profile list
```

**自動化スクリプト案** (`multi-model-review.sh`):

> **注**: これは理解用の簡易版テンプレート。  
> 実装版（`scripts/multi-model-review.sh`）は並列実行・安全対策を追加し、
> 18分→7分への短縮を実現している。実際の利用は実装版を推奨。

```bash
#!/bin/bash
set -e

# 設定
STATE_FILE="/tmp/warp-cross-pane/state.md"
REQUEST_FILE="/tmp/warp-cross-pane/review-request.md"
RESPONSE_DIR="/tmp/warp-cross-pane/responses"
FINAL_RESPONSE="/tmp/warp-cross-pane/review-response.md"

# プロファイルID（warp agent profile listで取得した値に置換）
OPUS_PROFILE="<OPUS_PROFILE_ID>"
GPT_PROFILE="<GPT_PROFILE_ID>"
GEMINI_PROFILE="<GEMINI_PROFILE_ID>"

# レビュープロンプト
REVIEW_PROMPT="Read $STATE_FILE and $REQUEST_FILE, then provide a critical review following the review guidelines. Output your review in markdown format."

# 準備
mkdir -p "$RESPONSE_DIR"

# 各モデルでレビュー実行
echo "=== Opus Review ==="
warp agent run --profile "$OPUS_PROFILE" "$REVIEW_PROMPT" > "$RESPONSE_DIR/opus.md"

echo "=== GPT Review ==="
warp agent run --profile "$GPT_PROFILE" "$REVIEW_PROMPT" > "$RESPONSE_DIR/gpt.md"

echo "=== Gemini Review ==="
warp agent run --profile "$GEMINI_PROFILE" "$REVIEW_PROMPT" > "$RESPONSE_DIR/gemini.md"

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

warp agent run --profile "$OPUS_PROFILE" "$INTEGRATION_PROMPT"

echo "=== Complete ==="
echo "Review saved to: $FINAL_RESPONSE"
```

**期待効果**:
- 1コマンドで3モデルレビュー＋統合まで自動実行
- モデル切り替えの手間ゼロ
- WARP.mdが自動読み込み（同一cwdで実行）

---

## state.md フォーマット

```markdown
# Session State [HH:MM JST]

## 目的
{この議論で達成したいこと}

## 現状認識
- {合意済みの事項}
- {確認済みの事実}

## 結論案
{提案している結論}

## 根拠
{結論の根拠、参照ファイル等}

## 未確定点
{まだ決まっていないこと、懸念点}
```

---

## review-request.md フォーマット

```markdown
# Review Request

## レビュー対象
{レビュー対象の説明、state.mdへの参照}

## レビュー観点
### 1. メタ批判
- この分析は妥当か？過剰評価・過小評価はないか？
- 論理の飛躍、根拠不足、推測による決めつけはないか？

### 2. 見落としている観点
- 手順書やフロー設計で見落としている脆弱性はないか？
- 特殊条件が隠している問題で、分析が言及していないものはないか？

### 3. 実現可能性
- 提案された改善案は実装可能か？
- 改善によって新たな認知負荷や継続性リスクが発生しないか？

### 4. 優先順位の妥当性
- 提案された優先順位は適切か？
- 他に優先すべき項目はないか？

## レビュー制約
- 実行・編集は禁止（純粋な批判者として振る舞う）
- 推測禁止（記述に基づく）
- 具体的な代替案を提示する場合は、根拠を明示
```

---

## 実装状況

### Phase 1-3: 完了 ✅
- [x] Agent Profile作成（Opus/GPT/Gemini）
- [x] プロファイルID取得
- [x] スクリプト作成・動作検証完了
- [x] 並列実行版実装（`scripts/multi-model-review.sh`）

### Phase 4: 次のステップ
- [ ] WARP.md Section 8をCLI版に更新（本分析で対応予定）
- [ ] GTJ設計議論での継続的な実運用

---

## 参照

- Warp CLI Docs: https://docs.warp.dev/developers/cli
- Model Choice: https://docs.warp.dev/agents/using-agents/model-choice
- 初回実装セッション: 2026-01-04 (GTJ v2 週次レビュー手順書修正)
