# 並列計算スクリプト

Distributed.jl によるマルチプロセス並列で、Julia スクリプト (例: `experiments/sweep_run.jl`) をローカルおよびリモートのワーカーに分散実行する (マルチスレッドではない)。

English: [README.md](README.md)

**注**: マルチプロセス並列であり、マルチスレッドではない。単一プロセスのスレッド並列が必要なら、スクリプトを `julia -t N` で直接実行する。

**Julia / GitHub:** いまの構成は小パッケージ形 (`Project.toml` + `src/ParallelRunnerKit.jl`)。**`Manifest.toml`** は任意で、`julia --project=<kit_dir>` で **`Pkg.instantiate()`** すればローカルに生成できる。この上流リポジトリでは **コミットしない** (このディレクトリの **[`.gitignore`](.gitignore)** 参照)。単独公開するときはリポジトリ名 **`ParallelRunnerKit.jl`** で同じレイアウトを想定する (CLI の `runner.jl` などはルートのままか `scripts/` へ移すかは好みでよい)。

## 単体コピー (任意の `Manifest.toml`)

**`ParallelRunnerKit/`** だけをコピーしてランナー用依存 (`ArgParse`、`JSON3`、stdlib) を解決したいときは、一度:

```bash
julia --project=/path/to/ParallelRunnerKit -e 'using Pkg; Pkg.instantiate()'
```

とすると **`Project.toml`** の隣に **`Manifest.toml`** ができる。**`ParallelRunnerKit/.gitignore`** で追跡対象外にしてあるので、この上流ツリーではレジストリ解決の差分を常にコミットしなくてよい。厳密に固定したいフォークや私用配布では、**自分で `Manifest.toml` をコミット**してもよい。

```bash
julia --project=/path/to/ParallelRunnerKit /path/to/ParallelRunnerKit/runner.jl --help
```

**フルアプリに埋め込む場合:** シミュレーション本体はこれまでどおり **アプリケーションルート** の環境 (`julia --project=<リポジトリルート>`) を使い、ホストの `Project.toml` に **`[deps]` だけマージ**する従来の使い方でよい。

## `ParallelRunnerKit/` の位置づけ (一式ドロップイン)

**SSH / マルチホストの分散実行**に必要なのは、ざっくり言って **この `ParallelRunnerKit/` ディレクトリの中身一式** (`runner.jl`、`setup.jl`、`suggest_workers.jl`、**[`Project.toml`](Project.toml)** (ランナー専用依存。必要ならホストへ `[deps]` をマージ)、**`src/ParallelRunnerKit.jl`** (前述スクリプトが読み込む共有モジュール)、**[`templates/script_template.jl`](templates/script_template.jl)** (`init_output_dir!` / `main()` の最小例)。別リポジトリへ持ち込むときも **フォルダごとコピー**し、レイアウトを保てばよい。ドライバスクリプト側に **`init_output_dir!(args)`** と **`main()`** を実装する (契約は [DEVELOPMENT.ja.md](docs/DEVELOPMENT.ja.md) の「インターフェース契約 (スクリプト側)」節)。既定ではルート **`Project.toml`** の `name` に対応するモジュールをワーカーで `using` し、名前が違うときは **`--package NAME`**。

**シミュレーションだけ欲しい場合:** 本体は [`src/`](../src/)、[`demo.jl`](../demo.jl)、[`experiments/`](../experiments/) にあり、**`ParallelRunnerKit/` は不要ならフォルダごと削除してよい。** `Project.toml` は `ParallelRunnerKit/` を参照しない。単機の `demo.jl`、逐次スイープ、自分で起動する `julia -p N` / `julia -t N` はそのまま使える。

## 手順

```
ParallelRunnerKit/runner.jl [--local N] [host1:W host2:W ...] script.jl [args...]
        │
        ▼
[1] ワーカーを追加 (ローカル + リモート)
        │
        ▼
[2] スクリプトを実行 (例: experiments/sweep_run.jl --config experiments/configs/main.json)
        │
        │    sweep_run.jl の場合: Main.main() がスイープセルを pmap し、各セルで
        │    run_simulation + save_results (experiments/README の分散実行を参照)
        │
        ▼
[3] リモートから結果ファイルを回収
```

**対応関係**:
- [ルート README Overview](../README.md#overview): `run_batch` → `run_simulation` → ステップループ [1]–[4]
- [experiments/README.ja.md — 分散実行](../experiments/README.ja.md#分散実行): `sweep_run.jl` の `main()` → `(demands, ratio)` セルを `pmap` → `run_simulation` + `save_results` → `data/sweep/<設定ファイル名>/` 以下にセルごとの CSV/JSON
- **ランナーキット** (`ParallelRunnerKit/`): ワーカーを足し、マスターでスクリプトを `ARGS` 付きで実行し、リモートの新しい結果ファイルを回収する (`runner.jl` のワークフロー)

**再現性:** `runner.jl` は **`parallel_runner_kit_version()`** (`ParallelRunnerKit/Project.toml` の `version`) と、アプリ側プロジェクトディレクトリの **git 短縮ハッシュ** をログに出す。リモート利用時は従来どおりホスト間で **完全同一コミット** を要求する (**`--skip-hash-check`** で無効化可)。タグ・`Manifest.toml`・ワーカ自己申告など、より厳しくする候補は [DEVELOPMENT.ja.md](docs/DEVELOPMENT.ja.md) の「バージョン管理と再現性」を参照。

## ファイル

| ファイル | 説明 |
|------|-------------|
| `runner.jl` | ワーカープロセス (ローカル + リモート) を追加、スクリプトを実行、結果を回収 |
| `setup.jl` | リモートホストでクローン、git の確認/同期、パッケージインストール、クリーンアップ |
| `suggest_workers.jl` | 各ホストでパッケージをロードし RSS を計測、ワーカー割り当てを提案 |
| `src/ParallelRunnerKit.jl` | モジュール: パス・ログ・SSH/git・ランナー CLI・メモリ/git 整合チェック (自前スクリプトからは `include(...); using .ParallelRunnerKit`、インストール済みなら `using ParallelRunnerKit`) |
| `test/runtests.jl` | キット用テストの入口 (リポジトリルートで `julia --project=. ParallelRunnerKit/test/runtests.jl`) |
| `test/test_parallel_runner_kit.jl` | `ParallelRunnerKit` のパス等のテスト (`test/runtests.jl` から include) |
| `Project.toml` | ランナー用依存の明示 (`src/` 用の環境ではなく、持ち込み用の一覧) |
| `.gitignore` | このディレクトリ単体を `--project` にしたときにできる `Manifest.toml` を無視 |
| `templates/script_template.jl` | 動く最小ドライバ。試し: `ParallelRunnerKit/runner.jl --local 2 ParallelRunnerKit/templates/script_template.jl` |
| `docs/` | 開発者向け: [DEVELOPMENT.md](docs/DEVELOPMENT.md)、[DEVELOPMENT.ja.md](docs/DEVELOPMENT.ja.md)、[目次 README](docs/README.md) |

## 前提

- 全リモートホストへの **SSH 鍵認証** (パスワードなしログイン)
- 全リモートホストからの **GitHub SSH アクセス** (`ssh -T git@github.com` で確認)
- 全マシンで **同じプロジェクトパス** (例: `~/GitHub/TCNashAgentsEvo.jl-dev`)
- リモートホストに **Julia がインストール済み** (一般的な場所を自動検出)

## クイックスタート

```bash
# 1. クローン (初回のみ)
julia --project=. ParallelRunnerKit/setup.jl --clone HOST1 HOST2 ...

# 2. 依存関係のインストール (初回のみ)
julia --project=. ParallelRunnerKit/setup.jl --instantiate HOST1 HOST2 ...

# 3. 前提条件の確認
julia --project=. ParallelRunnerKit/setup.jl --check HOST1 HOST2 ...

# 4. コードの同期 (ローカルでコミット後)
julia --project=. ParallelRunnerKit/setup.jl --sync HOST1 HOST2 ...

# 5. (任意) ベンチマークからワーカー数を提案
julia --project=. ParallelRunnerKit/suggest_workers.jl --local HOST1 HOST2 ...

# 6. ローカル + リモートワーカーでスクリプトを実行
julia --project=. ParallelRunnerKit/runner.jl --local N HOST1:W HOST2:W ... path/to/script.jl [script_args...]
```

`HOST1 HOST2 ...` をホスト名に、`N` / `W` をホストごとのワーカー数に、`path/to/script.jl` をスクリプトと引数に置き換える。

HTTPS の origin URL は自動で SSH 形式に変換される。

## runner.jl

ローカルとリモートのワーカープロセスを追加し、分散 `pmap` 対応のスクリプトを実行する。

**ワークフロー**: git ハッシュ確認 → 残骸ワーカーのクリーンアップ → メモリ確認 → ワーカー追加 → 初期化 (プロジェクトの activate、パッケージのロード) → スクリプト実行 → リモートから結果回収

### 使い方

```bash
julia --project=. ParallelRunnerKit/runner.jl [options] [hosts...] script.jl [script_args...]

# ローカル + リモート (例: パラメータスイープ)
julia --project=. ParallelRunnerKit/runner.jl --local 9 host1:10 host2:10 \
  experiments/sweep_run.jl --config experiments/configs/main.json

# リモートのみ (マスターはローカル、ワーカーはリモート)
julia --project=. ParallelRunnerKit/runner.jl host1:10 host2:10 \
  experiments/sweep_run.jl --config experiments/configs/main.json

# ローカルのみ
julia --project=. ParallelRunnerKit/runner.jl --local 9 \
  experiments/sweep_run.jl --config experiments/configs/main.json

# data/sweep 以下でホストにあってローカルに無いファイルだけ再帰的に取得
julia --project=. ParallelRunnerKit/runner.jl --collect-missing \
  data/sweep m4-mini-lan m4-mini2-tb

# リモート側を正として同一パスを上書きマージ
julia --project=. ParallelRunnerKit/runner.jl --collect-overwrite data/sweep m4-mini-lan m4-mini2-tb
```

### オプション

| オプション | 説明 |
|--------|-------------|
| `-l, --local N` | ローカルのワーカープロセス数 (デフォルト: 0) |
| `-w, --workers N` | `:N` を明示しないリモートホストのデフォルトワーカー数 |
| `--julia PATH` | リモートホストの Julia 実行ファイルパス |
| `--skip-hash-check` | git のコミット検証をスキップ |
| `--no-log` | コンソール出力をログファイルに書き込まない |
| `--log-dir PATH` | ログ出力先 (デフォルト: スクリプトの出力先、または `<script_dir>/results`) |
| `--collect-missing ROOT HOST...` | rsync: `ROOT` 以下でローカルに無い相対パスのファイルだけ取得 (`mkdir -p`、スクリプトは実行しない) |
| `--collect-overwrite ROOT HOST...` | rsync: `ROOT` 以下を丸ごとマージ (同名はリモートで上書き) |
| `--collect-tree`, `--collect-tree-sync` | `--collect-missing` / `--collect-overwrite` の別名 |
| `hostname:N` | このホストで N ワーカーを使う (例: `host1:10`) |

| 環境変数 | 説明 |
|----------|-------------|
| `DISTRIBUTED_OUTPUT_DIR` | 分散実行時の出力ディレクトリ (既定のランナーログ先・収集ルート未指定時の単一ツリー既定) |
| `DISTRIBUTED_COLLECT_DIRS` | ラン終了後に rsync するローカルツリー (コロン区切り、絶対パスまたはリポジトリ相対)。指定時は単一ツリー既定を上書き |
| `DISTRIBUTED_REMOTE_PROJECT_ROOT` | SSH ワーカー上のリポジトリルートの絶対パス (このマシンと違うときに指定; collect / sentinel の rsync がルート相対で合わせる) |
| `DISTRIBUTED_SSH_OPTS` | カスタム SSH オプション (スペース区切り) |
| `JULIA_DISTRIBUTED_EXE` | リモートホストのデフォルト Julia パス |
| `DISTRIBUTED_INIT_DELAY_SEC` | `addprocs` 後の接続安定化待ち (秒、デフォルト: 5) |
| `DISTRIBUTED_PING_RETRIES` | ワーカー疎通確認のリトライ回数 (デフォルト: 6) |

![Parallel runner usage](../images/parallel_runner_usage.jpeg)

## setup.jl

分散ジョブの実行前後にリモートホストを確認、同期、管理する。

```bash
julia --project=. ParallelRunnerKit/setup.jl --clone host1 host2       # リポジトリをクローン
julia --project=. ParallelRunnerKit/setup.jl --check host1 host2       # 前提条件を確認
julia --project=. ParallelRunnerKit/setup.jl --sync host1 host2        # push + pull
julia --project=. ParallelRunnerKit/setup.jl --pull host1 host2        # 最新コードを pull (ローカル + リモート)
julia --project=. ParallelRunnerKit/setup.jl --instantiate host1 host2 # Pkg.instantiate
julia --project=. ParallelRunnerKit/setup.jl --cleanup host1 host2     # 残骸ワーカーを kill
julia --project=. ParallelRunnerKit/setup.jl --delete host1 host2      # リモートのリポジトリを削除
```

## 注意

- **完全リセット**: `--delete` → `--clone` → `--instantiate` の順で実行

## 結果の手動同期 (rsync)

ジョブ終了時、runner はリモートホストから結果ファイルを回収する。実行が中断された (切断や Ctrl+C など) 場合や手動で結果を取りに行きたい場合は、ローカルマシンから `rsync` を使う。リモートのプロジェクトパスはローカルと同じにする。

```bash
# 単一ホスト — リモートの結果をローカルに pull (PROJ とサブパスを調整)
rsync -avz HOST:PROJ/path/to/results/ ./path/to/results/

# 複数ホスト
for h in host1 host2 host3; do
  rsync -avz $h:PROJ/path/to/results/ ./path/to/results/
done
```

`PROJ` をリモートのプロジェクトルート (例: `~/GitHub/TCNashAgentsEvo.jl-dev`) に、`path/to/results/` をスクリプトが使う出力ディレクトリに置き換える。

## 長時間実行のジョブ

- **tmux**: 切断に耐えられるよう `tmux new -s sweep` で実行 (デタッチ: `Ctrl+B, D`)
- **ロギング**
  - **tee** (tmux なし): stdout/stderr を表示しつつ保存:
    ```bash
    julia --project=. ParallelRunnerKit/runner.jl ... script.jl 2>&1 | tee run.log
    ```
  - **tmux pipe-pane** (tmux 内蔵、tmux セッション内で):
    1. 通常通り tmux ペインでジョブを開始
    2. ロギング**開始**: `Ctrl+B` を押して離し `:` (コロン) を入力。プロンプトで:
       ```text
       pipe-pane -o 'cat >> session.log'
       ```
       と入力して Enter。そのペインの全出力が `session.log` (パスはペインの cwd 相対) に追記される
    3. ロギング**停止**: ステップ 2 と同じ — `Ctrl+B`、`:`、同じ `pipe-pane -o '...'` を再実行 (トグル)
  - **キーバインド** (任意): `~/.tmux.conf` に追加:
    ```text
    bind P pipe-pane -o 'cat >> $HOME/tmux-#{session_name}.log'
    ```
    設定をリロード (`tmux source-file ~/.tmux.conf` または tmux を再起動)。以降、`Ctrl+B` の後 `P` で `~/tmux-SESSIONNAME.log` へのロギングをトグルできる
  - **実行後に保存** (スクロールバックのみ): 実行中にロギングしなかった場合、ペインのスクロールバックに残っている分は保存できる。ペイン内で `Ctrl+B` の後 `:` を押して:
    ```text
    capture-pane -S -3000 -p > session.log
    ```
    そのペインの直近 3000 行を `session.log` に書き出す。`-3000` を変えれば行数を増減できる (`-S -` で全履歴)。ペインの履歴上限 (tmux の `history-limit`) が保持量の上限になる
- **リモートのスリープ防止** (macOS): `sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1`
- **Thunderbolt ネットワーク** (macOS): Thunderbolt 経由で接続しているとき、TB サブシステムの電源遷移でリンクが切れることがある。全リモートホストで:
  ```bash
  sudo pmset -a powernap 0
  sudo pmset -a displaysleep 0   # ヘッドレスなら 0、ディスプレイ使用なら 10 など
  ```
  `pmset -g` で確認。ジョブ後に戻すなら `sudo pmset -a powernap 1` と `sudo pmset -a displaysleep 10`
- **SSH KeepAlive**: 組み込み済み (`ServerAliveInterval=60`、`ServerAliveCountMax=10` = 約 10 分まで許容)

## suggest_workers.jl

各ホストでプローブワーカーにプロジェクトパッケージをロードし、RSS を計測してから、RAM と CPU 制約からワーカー数を提案する。実験の種類を問わず動く — シミュレーション本体は不要。

```bash
julia --project=. ParallelRunnerKit/suggest_workers.jl [options] [--local] [hosts...]

# ローカル + リモート
julia --project=. ParallelRunnerKit/suggest_workers.jl --local host1 host2

# リモートのみ
julia --project=. ParallelRunnerKit/suggest_workers.jl host1 host2

# 計測をスキップし、ワーカー 1 つあたり 1.5 GB を仮定
julia --project=. ParallelRunnerKit/suggest_workers.jl --gb-per-worker 1.5 --local host1 host2
```

| オプション | 説明 |
|--------|-------------|
| `-l, --local` | 提案にローカルホストを含める |
| `--gb-per-worker N` | 計測をスキップし、ワーカー 1 つあたり N GB を仮定 |
| `--mem-headroom N` | メモリ上限の比率 (デフォルト: 0.75) |
| `--master-gb N` | マスタープロセスに確保する量 (デフォルト: 0.4) |

出力にはホストごとの RAM、コア数、計測されたワーカーあたりメモリ、`runner.jl` のコマンドテンプレートが含まれる。

**なぜパッケージのロードだけ?** 検証済み: レプリケーション規模のシミュレーション (1100 エージェント、100 試行、300k ステップ) はパッケージロードに比べて約 0.04 GB しか追加で消費しない。10% のバッファと 0.5 GB の下限ですでに十分な余裕がある。シミュレーションベースの計測は不要として削除した。

## メモリチェック

runner は前回実行から残っているワーカーをクリーンアップした後にメモリ容量を確認する:

1. **残骸ワーカーのクリーンアップ** — メモリ計測を正確にするため、全ホストで残っている Julia ワーカープロセスを kill する
2. **ワーカーあたりの推定** — マスタープロセスの RSS (`Sys.maxrss()`) × 1.2、下限 0.5GB (RSS が取れない場合は 1.5GB)
3. **容量チェック** — `N ワーカー × 推定値` がいずれかのホストの全 RAM の 70% を超えると警告
   - ローカル: `Sys.total_memory()` から取得
   - リモート: SSH 経由で取得 (macOS は `sysctl`、Linux は `/proc/meminfo`)

**ヒント**:
- 16GB RAM のホストなら最大 ~9 ワーカーが安全圏
- ワーカー数は CPU コア数**と**メモリの両方に合わせる
- 実行中は `htop` などでリモートを監視

## 開発者向け

`ParallelRunnerKit/` の設計意図と、将来 `DistributedRunner.jl` (仮称) として再利用可能なパッケージに切り出すためのロードマップは [DEVELOPMENT.ja.md](docs/DEVELOPMENT.ja.md) にまとめている。

## トラブルシューティング

| 問題 | 解決策 |
|---------|----------|
| git ハッシュの不一致 | リモートで `--sync` または `--pull` を実行 |
| リモートで Julia が見つからない | `--julia /path/to/julia` か `JULIA_DISTRIBUTED_EXE` を設定 |
| SSH タイムアウト | `DISTRIBUTED_SSH_OPTS="-o ConnectTimeout=10"` を調整 |
| 実行中にワーカーが落ちる | リモートでパッケージが precompile 済みか確認、手動実行でエラーを確認 |
| Broken pipe エラー | リモートワーカーがクラッシュ、メモリ・ディスク容量・テストジョブを確認 |
| 接続リセット (長時間ジョブ) | リモートのスリープを無効化、ローカルで tmux を使う |
| TB リンク断 (Thunderbolt) | リモートで `powernap 0` と `displaysleep 0` (長時間実行のジョブを参照) |
| 起動時のメモリ警告 | `--local N` か `host:N` を減らす。残骸ワーカーは自動でクリーンアップされる |
| クラッシュ後の残骸ワーカー | `--cleanup host1 host2` を実行、または runner を再起動 (自動クリーンアップ) |
| `attempt to send to unknown socket` | `addprocs` 直後の競合。`DISTRIBUTED_INIT_DELAY_SEC=10` などで待機を延長 |
