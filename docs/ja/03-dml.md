# 3. DML — 書く

[← Query](02-query.md) · [JOIN →](04-join.md)

文の型は 3 つ。組み立て方は `Query` と同じで、`Table` から値として作り、`run` を
呼ぶまで何も実行しません。

## 型

```moonbit
pub struct Insert {
  table_name : String
  columns    : Array[String]
  rows       : Array[Array[SqlValue]]
}

pub struct Update[Cols] {
  table_name : String
  tbl        : String
  cols       : Cols
  sets       : Array[(String, RawExpr)]
  wheres     : Array[RawExpr]
}

pub struct Delete[Cols] {
  table_name : String
  tbl        : String
  cols       : Cols
  wheres     : Array[RawExpr]
}
```

`Insert` は `Cols` を持ちません。行がテーブルの `Binding` を通ってエンコードされた
時点で、型付きの式を書く対象は残っていないからです。`Update` と `Delete` は持ちます。
述語と代入をクエリビルダと同じハンドルに対して書くためです。

## コンストラクタ

```moonbit
pub fn[C, R] insert(Table[C, R], R) -> Insert
pub fn[C, R] insert_many(Table[C, R], Array[R]) -> Insert
pub fn[C, R] insert_except(Table[C, R], R, omit~ : Array[String]) -> Insert

pub fn[C, R] update(Table[C, R], (C) -> Expr[Bool]) -> Update[C]
pub fn[C, R] update_all(Table[C, R]) -> Update[C]

pub fn[C, R] delete(Table[C, R], (C) -> Expr[Bool]) -> Delete[C]
pub fn[C, R] delete_all(Table[C, R]) -> Delete[C]
```

**`update` と `delete` は述語を必須引数として取ります。** チェーンの一段だと
書き忘れられますし、書き忘れればテーブル全体を書き換えてしまいます。全行を対象に
するときは `update_all` / `delete_all` を呼び、名前でそう宣言します。

```moonbit
@aya.insert(User::table(), user)
@aya.insert_except(User::table(), user, omit=["id"])  // 自動採番キーを DB に任せる
@aya.insert_many(User::table(), [a, b, c])            // 3 文ではなく 1 文

@aya.update(User::table(), u => u.id.eq(7))
|> @aya.Update::set(u => u.name, "bob")

@aya.delete(User::table(), u => u.age.lt(18))
```

```sql
INSERT INTO "users" ("id", "name", "age", "deleted_at")
 VALUES (?, ?, ?, ?)

UPDATE "users" AS u
    SET "name" = ?
  WHERE u."id" = ?

DELETE FROM "users" AS u
  WHERE u."age" < ?
```

### 書き込みが何をするか

この状態から始めます。

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | bob | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |

`update(users(), u => u.id.eq(2)) |> set(u => u.name, "robert")` —
パラメータは `["robert", 2]`、`run` は `1` を返します。

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | **robert** | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |

`delete(users(), u => u.age.lt(18))` — パラメータは `[18]`、`run` は `1` を
返します。

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 3 | carol | 42 | *NULL* |

UPDATE のパラメータ順に注目してください。述語を先に渡したにもかかわらず `"robert"`
が `2` より前に来ます。文中では SET が WHERE より先にあり、パラメータ列はつねに
テキストに従うからです。

`insert_many` は N 文ではなく 1 文を吐きます。そうするとパラメータが 1 本の
順序付き列にまとまり、それがドライバのバインドに必要な形になります。

`insert_except` は宣言順を保ったまま、指定した列をテーブルのバインディングから
落とします。主な用途は自動採番の主キーです。エンティティは `id` フィールドを
持っているが、INSERT ではデータベースに採番させたい、という場合です。

## 絞り込み

```moonbit
pub fn[C, T : SqlEncode] Update::set(Update[C], (C) -> Column[T], T) -> Update[C]
pub fn[C] Update::filter(Update[C], (C) -> Expr[Bool]) -> Update[C]
pub fn[C] Delete::filter(Delete[C], (C) -> Expr[Bool]) -> Delete[C]
```

`set` はテーブルのハンドルから列を選ぶので、値の型は列の型と一致していなければ
なりません。追加の `filter` は、コンストラクタが既に置いた条件に AND で足されます。

## 文を組み立てる

```moonbit
pub fn Insert::to_sql(Insert, dialect? : Dialect) -> (String, Array[SqlValue]) raise StatementError
pub fn[C] Update::to_sql(Update[C], dialect? : Dialect) -> (String, Array[SqlValue]) raise StatementError
pub fn[C] Delete::to_sql(Delete[C], dialect? : Dialect) -> (String, Array[SqlValue])
```

`Delete::to_sql` は送出しません。述語のない DELETE は `delete_all` であり、それは
正当な文なので、拒むべきものが残っていないからです。

`Update` では文中 SET が WHERE より先に来るので、パラメータも SET のものから
発行されます。列がテキスト順であるためです。

## 拒否されるもの

| 状況 | エラー |
|---|---|
| 行 0 件の INSERT | `EmptyInsert(table~)` |
| バインディングの列数と値の数が合わない行 | `ArityMismatch(table~, expected~, got~)` |
| 代入のない UPDATE | `EmptyUpdate(table~)` |
| 1 クエリ内で同じエイリアスを主張する 2 テーブル | `DuplicateAlias(tbl~)` |

4 つとも `StatementError` です。データベースが何を言うかとは無関係に、文そのものが
不正だという意味です。データベース「から」来る失敗は `DbError` で、
[6 章](06-execution.md)を参照してください。

## ドメイン型で型付けされたテーブルに対して

`insert` はテーブルの `R` を取ります。したがって `table_of` で作ったテーブルは
ドメインの値をそのまま受け取り、出ていく途中で `Binding::contramap` を通して
平坦化します。

```moonbit
@aya.insert(orders(), Submitted(id=2, items=1, submitted_at="2026-08-01"))
```

```sql
INSERT INTO "orders" ("id", "items", "status", "submitted_at", "tracking")
 VALUES (?, ?, ?, ?, ?)
```

行が必要とする NULL は `Order::to_row` が 1 か所で供給します。呼び出し側に
散らばることはありません。

---

[← Query](02-query.md) · [JOIN →](04-join.md)
