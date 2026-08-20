# 4. JOIN

[← DML](03-dml.md) · [集約 →](05-aggregate.md)

結合はクエリの `Cols` 型引数を広げます。以降の絞り込み・射影・整列はどれも
両テーブルのハンドルを見られるようになり、それ以外は見られません。

## 型

```moonbit
pub fn[C1, C2, R2, A] Query::join(
  Query[C1, A], Table[C2, R2], (C1, C2) -> Expr[Bool],
) -> Query[(C1, C2), A]

pub fn[C1, C2, R2, A] Query::left_join(
  Query[C1, A], Table[C2, R2], (C1, C2) -> Expr[Bool],
) -> Query[(C1, Nullable[C2, R2]), A]
```

**変わらないもの**に注目してください。`A` です。結合は FROM 句にテーブルを足すだけで、
1 行が何にデコードされるかは相変わらず射影が決めます。

### 例で追う

この章の 2 つの例はどちらもこの 2 テーブルに対するものです。

**`users`**

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | bob | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |

**`posts`**

| id | author_id | title |
|---:|----------:|-------|
| 10 | 1 | hello |
| 11 | 1 | draft |
| 12 | 3 | notes |

`bob` は何も書いていません。2 種類の結合で扱いが分かれるのがこの行です。

```moonbit
@aya.from(User::table())
|> @aya.Query::join(Post::table(), (u, p) => u.id.eq_col(p.author_id))
|> @aya.Query::filter(c => c.0.age.gte(18) & c.1.title.ne("draft"))
|> @aya.Query::map(c => @aya.sel2(c.0.name, c.1.title))
|> @aya.Query::order_by(c => [c.1.id.desc()])
```

```sql
SELECT u."name", p."title"
  FROM "users" AS u
  JOIN "posts" AS p ON u."id" = p."author_id"
 WHERE u."age" >= ? AND p."title" <> ?
 ORDER BY p."id" DESC
-- パラメータ: [18, "draft"]
```

**結果** — `Array[(String, String)]`

| name | title |
|------|-------|
| carol | notes |
| alice | hello |

結合からは 3 行 — alice/hello、alice/draft、carol/notes — が出て、絞り込みが
alice/draft を落とします。`bob` はそもそも現れません。内部結合には彼と組ませる
相手がいないからです。carol が alice より先に来るのは `ORDER BY p."id" DESC` の
ためです。

## タプルを分解する

Acadia の結合もタプルを作ります（`intersect : … -> Rows (a, b)`）。違うのは、Elm なら
ラムダの引数位置で `\((a, b), c) -> …` と分解できるのに対し、**MoonBit にはその構文が
ない**という点です。aya は代わりに 2 つの道具を用意し、`.0.0` がライブラリの中に
留まってあなたのコードに出てこないようにしています。

### 2 テーブル: `split2`

```moonbit
pub fn[A, B, R] split2((A, B) -> R) -> ((A, B)) -> R
```

引数 2 つの関数を、コンビネータが期待する 1 引数関数に変換します。

```moonbit
|> @aya.Query::filter(@aya.split2((u, p) => u.age.gte(18) & p.title.ne("draft")))
|> @aya.Query::map(@aya.split2((_u, p) => @aya.sel(p.title)))
```

2 つで止めているのは意図的です。3 テーブルになると引数に位置指定の `_` が必要に
なり始め、そうなると分解するより名前を付けたほうが読めるからです。

### 3 テーブル以上: `map_cols` で形に名前を付ける

```moonbit
pub fn[C, D, A] Query::map_cols(Query[C, A], (C) -> D) -> Query[D, A]
```

結合を連ねると左にネストします — `((C1, C2), C3)` — し、以降の各段でそのネストを
辿るのは読みづらいものです。`map_cols` はそれを一度だけ潰し、名前付きの構造体か
平坦なタプルにします。変わるのはハンドルだけで、ここまでに組み立てた SQL は
そのままです。

```moonbit
pub struct TicketJoin {
  ticket     : TicketCols
  assignment : @aya.Nullable[AssignmentCols, AssignmentRow]
  closure    : @aya.Nullable[ClosureCols, ClosureRow]
}

|> @aya.Query::map_cols(c => { ticket: c.0.0, assignment: c.0.1, closure: c.1 })
|> @aya.Query::filter(j => j.ticket.id.eq(id))
```

ネストは 1 行に封じ込められました。以降はすべて `c.0.1` ではなく `j.assignment` と
読めます。

構造体が大げさに感じるなら、`typealias` だけでもシグネチャは読めるようになります。

```moonbit
pub typealias ((UserCols, PostCols), TagCols) as UserPostTag
```

## LEFT JOIN と `Nullable`

```moonbit
type Nullable[C, R]                                     // 抽象型: 表現は公開されない

pub fn[C, R, T] Nullable::col(Nullable[C, R], (C) -> Column[T]) -> Column[T?]
pub fn[C, R]    Nullable::row(Nullable[C, R])                   -> Selection[R?]
```

外部結合の右辺は包まれて返ってきます。**中の `Column[T]` に到達する経路はありません。**
ラッパは表現を公開していないので、外部結合が持ち込む NULL 許容性をうっかり
失うことができません。入口はちょうど 2 つです。

```moonbit
c.1.col(p => p.title)   // Column[String?]   -- 1 列がほしいとき
c.1.row()               // Selection[Post?]  -- 行全体がほしいとき
```

外部結合の意味に近いのはたいてい `row()` のほうです。「各列が独立に NULL かもしれない」
ではなく「**右側の行が存在するかしないか**」であり、`Some` の中では各フィールドが
テーブルの宣言どおりの型を保ちます。

```moonbit
@aya.from(User::table())
|> @aya.Query::left_join(Post::table(), (u, p) => u.id.eq_col(p.author_id))
|> @aya.Query::map(c => @aya.sel(c.0.name).zip(c.1.row()))
```

```sql
SELECT u."name", p."id", p."title"
  FROM "users" AS u
  LEFT JOIN "posts" AS p ON u."id" = p."author_id"
```

`row()` は結合先テーブルの射影全体に展開されます。2 要素の結果に対して SELECT
リストが 3 列あるのはそのためです。

**結果** — `Array[(String, Post?)]`

| name | `Post?` |
|------|---------|
| alice | `Some({ id: 10, title: "hello" })` |
| alice | `Some({ id: 11, title: "draft" })` |
| bob | `None` |
| carol | `Some({ id: 12, title: "notes" })` |

`bob` こそが要点です。内部結合は彼を失いますが、外部結合は右辺を `None` にして
彼を残します。そして型がそう言っています — `None` を処理せずにそこの `Post` に
到達することはできません。

`on` の条件が見るのはラッパではなく結合先テーブルの**生の列**です。結合条件は
外部結合のパディングより前に評価されるので、NULL 許容性は適用されません。
そのあとクエリが運ぶのがラッパです。

### 「一致しなかった」の判定

`Selection::optional` は、**右側の全列が NULL** のときその射影を「不在」として
読みます。データベースが決して NULL にしない列を射影が含んでいれば常に正しく、
`Table::all` は必ずそういう列を含みます。すべて NULL 許容の列だけで手組みした
射影については、判定に使う列を名指ししてください。

```moonbit
pub fn[Out] Selection::optional_on(Selection[Out], key~ : Int) -> Selection[Out?]
```

`key` はその射影自身の列を 0 から数えた添字です。

### 「行がないこと」がクエリになる

外部結合したテーブルの列に到達すると `Column[T?]` が得られます。これは
「何も一致しなかった」を検査するのにちょうどよい形です。

```moonbit
|> @aya.Query::filter(j => j.assignment.col(a => a.ticket_id).is_none())
// -> WHERE ta."ticket_id" IS NULL
```

## エイリアス

1 つのクエリに現れるテーブルはそれぞれ固有のエイリアスを持たなければなりません。
さもないと `u."id"` はデータベースが選んだどちらかを黙って指すことになります。
`Query::to_sql` はそういう SQL を吐く代わりに `DuplicateAlias(tbl~)` を送出します。

エイリアスはクエリごとではなくテーブルごとに固定（`#aya.table(alias="u")`）です。
**自己結合がまだ書けない**のはそのためで、[設計ノート](09-design.md)を参照してください。

---

[← DML](03-dml.md) · [集約 →](05-aggregate.md)
