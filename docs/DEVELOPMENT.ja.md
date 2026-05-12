# `ParallelRunnerKit/` 開発者向けメモ

このドキュメントは、将来 `ParallelRunnerKit/` を再利用可能なパッケージ (仮称: `DistributedRunner.jl`) として切り出すための意図と設計上の制約を記録したもの。何が汎用で何がプロジェクト依存か、分離を実用化するために何を変える必要があるか、を理解したい開発者向け。

English: [DEVELOPMENT.md](DEVELOPMENT.md)

利用者向けのドキュメントは [README.ja.md](../README.ja.md) にある。このファイルは内部 / 将来の開発者向けの参照用。

**配布の切り分け:**
- **分散だけ足したい:** ほぼ **`ParallelRunnerKit/` をそのままコピー**し、スクリプト契約に加え **`ParallelRunnerKit/Project.toml`** の `[deps]` をアプリ側環境へマージ (または同等の依存を宣言)、必要なら **`--package NAME`** を使う (シミュレーションコードは別リポジトリのままでも可)。
- **シミュだけ欲しい:** **`ParallelRunnerKit/` を丸ごと削除**してよい。`src/`・`demo.jl`・`experiments/` とルート `Project.toml` は `ParallelRunnerKit/` に結合していない (README のリンク文だけ不要なら削る)。

**フォルダ名:** Julia のモジュール名・スタブ `Project.toml` の `name` (`ParallelRunnerKit`) と揃えてあり、将来このツリーを単独リポジトリ **`ParallelRunnerKit.jl`** として切り出すときの配置に寄せている。`resolve_pkg_project_dir` は **`name == ParallelRunnerKit`** でスタブ判定するので、アプリ側の `Project.toml` 解決はディレクトリ名に依存しない。

## `TCNashEvo` への依存状況

`ParallelRunnerKit/` はすでにほぼプロジェクト固有のコードから切り離されている。残っている結合は:

| 場所 | 前提 |
|----------|-----------------|
| `runner.jl` | 既定は `Project.toml` の `name` に対応するモジュールをワーカーでロード (`--package` で上書き可); ワーカー起動と `Main.main()` のオーケストレーション |
| `runner.jl` | include したスクリプトの `init_output_dir!(ARGS)` と `main()` を呼ぶ |
| `src/ParallelRunnerKit.jl` | 共有ヘルパ (パス・ログ・SSH/git・ランナー CLI・メモリ/git 整合チェック); `TCNashEvo` 非依存 |
| `setup.jl`  | プロジェクトルートが `Project.toml` を持つ Julia プロジェクトであること |

どのファイルも `TCNashEvo` を直接 import していない。runner は `Project.toml` を読んでパッケージ名を発見するので、**変更なしで他の Julia プロジェクトでも動く**。

## インターフェース契約 (スクリプト側)

`runner.jl` で動かすには、include 後の `Main` に次の 2 関数を定義する必要がある:

```julia
# ワーカーを追加する**前**に呼ばれる。
# ENV["DISTRIBUTED_OUTPUT_DIR"] を出力先パスに設定する必要がある。
# スクリプトが結果をマスターのみに保存する場合 (例: pmap でマスター側で
# マージするケース) は ENV["DISTRIBUTED_SKIP_COLLECT"] = "1" も設定する。
function init_output_dir!(args::Vector{String})::String
    ...
end

# ワーカーが準備完了した**後**に呼ばれる。
# nworkers() / workers() を見て自分で並列化戦略を決める。
# pmap か remotecall か @distributed かはここで選ぶ。
function main()
    ...
end
```

この 2 関数のインターフェースが `runner.jl` と実験スクリプト間の唯一の結合点。`ParallelRunnerKit/` を切り出す場合、このインターフェースは安定的に保つ必要がある。

## 現状で切り出しを難しくしているもの

1. **シングルリポジトリ前提**: `setup.jl` はプロジェクトルートが既知のリモートからクローンされた git リポジトリであることを前提にしている。リモート URL はマスターの `git remote get-url origin` から読まれてワーカーに複製される。独立パッケージなら、デプロイ対象プロジェクトをより一般的に指定できる仕組みが必要。

2. **`Project.toml` ベースのパッケージロード**: 既定はルートの `name` だが、**`--package NAME`** で上書きできる。将来の独立パッケージ化では、このフラグを主 API に据える余地がある。

3. **環境の二重性**: `ParallelRunnerKit/Project.toml` は **持ち込み用の依存一覧** (スタブパッケージ名) であり、通常の `julia --project=.` のシミュ用ルート環境とは別物。ルート `Project.toml` が依然として正とする。

4. **モジュール境界**: 共有コードは **`src/ParallelRunnerKit.jl`** (`ParallelRunnerKit`) に集約。エントリスクリプトは `include` のあと `using .ParallelRunnerKit`、アクティブ環境にパッケージが入っていれば `using ParallelRunnerKit` に置き換え可能。

## 分離手順 (時が来たら)

1. ~~**共有コードをモジュールに集約**~~ — 完了 (`src/ParallelRunnerKit.jl`)
2. **`setup.jl` を一般化** し、ローカルの git config から読むのではなく任意のリモート URL を受け付ける
3. **`init_output_dir!` / `main()` インターフェースを公開 API として明文化** (軽量な abstract interface か、ドキュメントだけでもよい)
4. **`DistributedRunner.jl` として登録** (もしくは研究室内利用なら未登録のままでもよい)

すでにリポジトリ内にあるもの: **`src/ParallelRunnerKit.jl`** (正式モジュール)、**`Project.toml`** (依存マニフェスト)、**`templates/script_template.jl`**、**`runner.jl --package`**。

## バージョン管理と再現性

**いま (ベンダードツリー):**

- **`ParallelRunnerKit/Project.toml` の `version`** がキットのセマンティックバージョン。 **`parallel_runner_kit_version()`** / **`PARALLEL_RUNNER_KIT_VERSION`** として公開され、**`runner.jl`** 起動時に解決したアプリ側 **`Project.toml`** とあわせてログに出る。
- **`runner.jl`** はアプリ側プロジェクトディレクトリ (ワーカーが `activate` する環境) の **git 短縮ハッシュ** をログに出す。リモート追加前でもログとコミットを対応づけやすい。
- **リモート利用時**は従来どおり **`check_git_hashes`** が **`DISTRIBUTED_PROJECT_ROOT`** (既定はリポジトリルート) 基準で **完全同一コミット** を要求する (**`--skip-hash-check`** で無効化可能)。

**あとから厳しくする候補:**

- **ローカル検証 (リポ内に CI は置かない):** リポジトリルートで `julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test(; coverage=false)'` と `julia --project=. ParallelRunnerKit/test/runtests.jl`。後者は (**ほぼ** すべての) **`ParallelRunnerKit/Project.toml`** の **`[deps]`** がルート **`Project.toml`** に **同じ UUID** で載っていることを検証する。**`Distributed`** だけ除外する。Julia 同梱の stdlibであり、現在の **`Pkg.resolve`** ではルート **`[deps]`** に並べても Registry 依存としては解決できない。ランナーは **`using Distributed`** で同梱版を読めば足りる。
- **リリース運用:** `Project.toml` の `version` と一致する git タグ、**`CHANGELOG.md`**、タグとバージョン不一致で CI を落とす、など。
- **環境の固定:** 各ホストで同じ **`Manifest.toml`** を使う (または `setup.jl` で `Pkg.resolve` を前提化する) ことで、**アプリのコミットが同じでも依存解決が食い違う**事故を防ぐ。
- **ワーカの自己申告:** `using` 後に各ワーカが **`VERSION`**・プロジェクトパス・**`parallel_runner_kit_version()`** を一度出すオプションで、取り残しや古い depot を検知する。
- **運用ポリシー:** **`--skip-hash-check`** は監査用に限定し、本番設定では禁止する、など。

## やらないこと

- シミュレーション固有のロジック (`SimulationConfig`、結果フォーマットなど) を `ParallelRunnerKit/` に**入れない**。runner はシミュレーションに対して中立であり続けるべき。
- 非 Julia ワーカーや非 SSH トランスポートを**サポートしない**。スコープが膨張して保守が辛くなる。
- 現在のハートビート + 接続安定化待ち以上の自動リトライや fault-tolerance を**追加しない**。本物の fault-tolerance (失敗タスクの再キュー) は別問題で、`pmap` のエラー処理がスクリプトレベルで既にカバーしている。

## Julia 1.12 の安定性メモ

Julia 1.12 で `tunnel=true` + 多数の SSH ワーカーという組み合わせは、`addprocs` がすべての TCP 接続登録完了前に return してしまう競合を起こすことがある。`runner.jl` では `DISTRIBUTED_INIT_DELAY_SEC` (デフォルト 5 秒) とワーカーごとの ping リトライ (デフォルト 6 回) で回避している。

パッケージ化する場合、この回避策は目立つ場所に明記し、API レベルで設定可能にすることを検討すべき。
