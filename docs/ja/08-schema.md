# 8. スキーマとマイグレーション

[← Repository](07-repository.md) · [設計ノート →](09-design.md)

カラムハンドルを生成するのと同じ注釈から、**データベースのスキーマそのもの**も
出せます。定義は行型ひとつだけで、DDL はそこから導かれ、前回からの差分は
`cairn-kit` が割り出します。

## 設定

```json
// cairn.json
{
  "dialect": "sqlite",
  "schema": ["src/example"],
  "out": "migrations"
}
```

どのキーも省略できます。`--schema` / `--out` / `--dialect` でその場限りの上書きが
でき、`cairn-kit init` が雛形を書き出します。

## コマンド

```bash
cairn-kit status      スナップショットとの差分を表示（何も書かない）
cairn-kit generate    差分から次のマイグレーションを書き出す
cairn-kit ddl         スキーマ全体の CREATE 文を標準出力へ
cairn-kit codegen     .g.mbt を再生成する
cairn-kit init        cairn.json と migrations/ を用意する
```

このリポジトリでは `moon run src/kit/cmd -- <サブコマンド>` で動きます。

## 出力されるもの

```
migrations/
  0000_initial.sql
  0001_add_column_users_nickname.sql
  meta/
    _journal.json          何が生成済みか、どの方言か
    0000_snapshot.json     そのマイグレーション適用後のスキーマ
    0001_snapshot.json
```

差分は**直前のスナップショットとの比較**であって、データベースとの比較では
ありません。マイグレーションの生成に接続は要らず、CI でも同じ結果になります。
スナップショットはキー順を固定して書くので、diff がレビューできます。

ファイル名は変更内容から作られるので、ディレクトリがそのままスキーマの
変更履歴として読めます。`--name` で上書きできます。

```
$ moon run src/kit/cmd -- status
  add column users.nickname
run `cairn-kit generate` to write the migration

$ moon run src/kit/cmd -- generate
  add column users.nickname
cairn-kit: wrote migrations/0001_add_column_users_nickname.sql
```

```sql
ALTER TABLE "users" ADD "nickname" TEXT;
```

## 列の型

推論するのは `SqlValue` が表せる範囲だけです。

| MoonBit | SQLite | PostgreSQL |
|---|---|---|
| `Int` | `INTEGER` | `INTEGER` |
| `Int64` | `INTEGER` | `BIGINT` |
| `Bool` | `INTEGER` | `BOOLEAN` |
| `Double` | `REAL` | `DOUBLE PRECISION` |
| `String` | `TEXT` | `TEXT` |
| `Bytes` | `BLOB` | `BYTEA` |
| `T?` | `T` の型（`NOT NULL` なし） | 同左 |

ラッパ型は、何を格納するのかを自分で言う必要があります。推測すると、`Int` を
包んだだけの新しい型が黙って `TEXT` 列になる事故が起きます。

```moonbit
#cairn.table(name="accounts", alias="a")
#cairn.index(name="idx_accounts_email", columns="email", unique="true")
pub(all) struct Account {
  #cairn.id
  #cairn.column(sql_type="INTEGER")
  id : AccountId
  email : String
  #cairn.column(sql_type="TEXT", default="'free'")
  plan : Plan
} derive(Debug, Eq)
```

```sql
CREATE TABLE "accounts" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "email" TEXT NOT NULL,
  "plan" TEXT NOT NULL DEFAULT 'free'
);
--> statement-breakpoint
CREATE UNIQUE INDEX "idx_accounts_email" ON "accounts" ("email");
```

## 属性

[1 章](01-table.md)の表への追加分です。ここにあるものは、生成される MoonBit の
見た目には影響しません。

| 属性 | 位置 | 引数 | 効果 |
|---|---|---|---|
| `#cairn.index` | 構造体 | `name=` | 索引名。既定は `idx_<テーブル>_<列>` |
| | | `columns=` | 索引する**フィールド**をカンマ区切りで |
| | | `unique=` | `"true"` でユニーク索引 |
| `#cairn.column` | フィールド | `sql_type=` | SQL 型。`SqlValue` の範囲外の型では必須 |
| | | `default=` | `DEFAULT` の後にそのまま出る SQL 式 |
| | | `unique=` | `"true"` で列レベルの `UNIQUE` |
| | | `autoincrement=` | `"true"`。`INTEGER PRIMARY KEY` に付ける |
| | | `references=` | 外部キー。`"tickets.id"` の形式 |
| | | `on_delete=` / `on_update=` | `cascade` / `restrict` / `set null` / `set default` / `no action` |

索引は列名ではなくフィールド名で指定します。`#cairn.column(name=...)` で列名を
変えても索引が黙って壊れないようにするためです。

`type=` ではなく `sql_type=` なのは、`moon fmt` が `#cairn.column(type="...")` を
`##cairn.column(...)` に書き換えてしまい、以後 lex に失敗するためです。`type=` は
受け付けずに理由を添えてエラーにしています（受け付けると、次に誰かが整形した
瞬間に壊れます）。

NULL 可否は属性ではなく**型**が決めます。`String?` なら NULL 可、`String` なら
`NOT NULL` です。属性で上書きできるようにすると、デコーダが信じている形と
スキーマが食い違えるようになります。

## SQLite の制約への向き合い方

SQLite の `ALTER TABLE` は、ふつうの列の追加と削除しかできません。型の変更、
制約の追加、索引の張られた列の削除は、テーブルを作り直す以外に方法がないので、
そう出力します。

```sql
PRAGMA foreign_keys=OFF;
--> statement-breakpoint
CREATE TABLE "__new_accounts" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "email" TEXT
);
--> statement-breakpoint
INSERT INTO "__new_accounts" ("id", "email")
SELECT "id", "email" FROM "accounts";
--> statement-breakpoint
DROP TABLE "accounts";
--> statement-breakpoint
ALTER TABLE "__new_accounts" RENAME TO "accounts";
--> statement-breakpoint
PRAGMA foreign_keys=ON;
```

文の区切りは `;` ではなく `--> statement-breakpoint` です。`DEFAULT` 式や
トリガ本体は、それ自身が `;` を含むためです。

`CREATE TABLE` は、参照先のテーブルが先に来る順に並べます。SQLite は外部キーを
遅延解決するので気にしませんが、生成された SQL は人も読むものです。

## 安全側に倒している点

| 状況 | 挙動 |
|---|---|
| 列が消えて別の列が現れた | 削除と追加として出す（リネームは推測しない） |
| 既定値のない `NOT NULL` 列の追加 | 列名を挙げて拒否 |
| 列が `NOT NULL` に変わった | `coalesce("col", <既定値>)` 経由でコピー |
| `sql_type=` のないラッパ型 | MoonBit の型名を挙げて拒否 |
| `sql_type=` でなく `type=` | 拒否（`moon fmt` がファイルを壊すため） |
| 同じテーブル名を主張するエンティティが 2 つ | 拒否 |
| journal と設定で方言が食い違う | 拒否 |

**リネームは検出しません。** 消えた列と現れた列が同じものかは、ソースのどこにも
書かれていません。推測して外すと黙ってデータが消えるので、削除と追加として
出します。生成された SQL を読めば、実行前に気付けます。

**既定値のない `NOT NULL` 列の追加は拒否します。** `ALTER TABLE` でもテーブル
再作成でも、既存行に入れる値がないためです。`default=` を付けるか、フィールドを
`T?` にしてください。既存の列が `NOT NULL` に**変わる**場合は
`coalesce` 経由でコピーします。既定値は、既に入っている NULL については何も
言わないためです。

再作成を伴わない列削除は `ALTER TABLE ... DROP COLUMN` を使うので、
SQLite 3.35（2021）以降が必要です。

## 未実装

PostgreSQL は型対応表だけがあり、DDL の出力はまだです（`generate` は SQLite 向け）。
`.sql` を `Executor` で流す `migrate` サブコマンドもありません。`#cairn.id` は
1 列だけを指すので、複合主キーと複数列のユニーク制約は書けません。

---

[← Repository](07-repository.md) · [設計ノート →](09-design.md)
