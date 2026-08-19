# cairn

A thin, type-safe SQL toolkit for MoonBit.

[English](README.md) | **日本語**

行型を 1 つ書けば、カラムハンドル・射影・デコーダ・エンコーダが生成され、型の付いた
クエリと DML を組み立てられます。**行型とドメインエンティティは別物として扱い**、
両者の対応づけはプログラマが書きます。クエリパイプラインの設計は
[Acadia](https://acadia.engineering/) を参考にしています。

実行は `Driver` トレイトを実装した任意のバインディングに委ねます。cairn 自体は
どのデータベースにも依存しません。

## 型の変遷

```mermaid
flowchart LR
    S0["⓪ 名前引き Row"] --> S1["① 位置ベース化"]
    S1 --> S2["② コード生成"]
    S2 --> S3["③ DML"]
    S3 --> S4["④ JOIN"]
    S4 --> S5["⑤ 行型 / ドメイン型の分離"]
    S5 --> S6["⑥ 外部結合の nullability"]
    S6 --> S7["⑦ 実行層"]

    S0 -.- D0["Table が decoder を持つ<br/>row.get(name)"]
    S1 -.- D1["Selection 導入<br/>射影とデコーダを一体化"]
    S2 -.- D2["Selection::new 公開<br/>生成コードから構築可能に"]
    S3 -.- D3["Binding 導入<br/>Table に write"]
    S4 -.- D4["Query に joins<br/>Cols がタプル化"]
    S5 -.- D5["Binding::contramap<br/>table_of で継ぎ目を明示"]
    S6 -.- D6["抽象型 Nullable<br/>col / row でしか触れない"]
    S7 -.- D7["Driver トレイト<br/>transaction コンビネータ"]

    classDef note fill:#f6f8fa,stroke:#d0d7de,color:#24292f
    class D0,D1,D2,D3,D4,D5,D6,D7 note
```

各段階で `Table` と `Query` の形がどう変わったかです。

| 段階 | 変更 | 動機 |
|---|---|---|
| ⓪ | `Table { cols, decoder }`、`Row` は列名→値のマップ | 初期案 |
| ① | `Row = ArrayView[SqlValue]`、`Selection[Out]` が射影とデコーダを保持し `Table { .., all }` へ | 射影の順序とデコード順序が必ず一致する |
| ② | `Selection::new` を公開 | `Selection` は `pub struct` で、生成コードが置かれる外部パッケージから構築できなかった |
| ③ | `Binding[In]` を追加し `Table { .., write }` へ | INSERT には「値 → 行」の向きが要る |
| ④ | `Query { .., joins }`、`Query::join` が `Cols` をタプルにする | 複数テーブル |
| ⑤ | `Binding::contramap` を追加、生成器が `table_of` を吐く。属性は `#cairn.table` へ | 行型とドメイン型は別物で、対応づけはプログラマが書く |
| ⑥ | `left_join` が抽象型 `Nullable[C, R]` を返す。`Selection::optional` を追加 | 外部結合の nullability を型で強制する |
| ⑦ | `Driver` トレイトと `transaction`、各文に `run` / `one` / `first` | SQL を組み立てるだけでなく走らせる |

### ① なぜ `Selection` なのか

`Selection[Out]` は「どの列を読むか（`exprs`）」と「行をどう値に変えるか（`read`）」を
1 つの値に束ねたものです。別々に持つと、射影に列を足したのにデコーダを直し忘れる、
という壊れ方をします。

```mermaid
flowchart LR
    E["エンティティ定義<br/>フィールドの並び"] --> P["exprs<br/>SELECT の列順"]
    E --> R["read<br/>row 0, row 1, ..."]
    P -.->|同じ順序| R
```

`read` は**位置**で読みます。手書きだとこれが脆いのですが、生成器が `exprs` と `read` を
同じフィールドループから吐くため、実際には食い違えません。

### ③ 読みと書きの対称性

`Binding[In]` は `Selection[Out]` の鏡像です。

```mermaid
flowchart LR
    DB1[("DB")] -->|"ArrayView&lt;SqlValue&gt;"| SEL["Selection&lt;R&gt;<br/>exprs / read"]
    SEL --> R1["R"]
    R2["R"] --> BND["Binding&lt;R&gt;<br/>columns / write"]
    BND -->|"Array&lt;SqlValue&gt;"| DB2[("DB")]
```

同じフィールドリストから両方を生成するので、SELECT と INSERT が列の意味について
食い違うことがありません。

## 現在の型

```mermaid
classDiagram
    class Table~Cols,R~ {
        table_name : String
        tbl : String
        cols : Cols
        all : Selection~R~
        write : Binding~R~
    }
    class Selection~Out~ {
        exprs : Array~RawExpr~
        read : row to Out
    }
    class Binding~In~ {
        columns : Array~String~
        write : In to values
    }
    class Query~Cols,A~ {
        source : String
        source_tbl : String
        joins : Array~Join~
        cols : Cols
        projection : Array~RawExpr~
        wheres : Array~RawExpr~
        order : Array~OrderKey~
        limit_n : Int?
        decode : row to A
    }
    class Column~T~ {
        tbl : String
        name : String
    }
    class Expr~T~ {
        raw : RawExpr
    }
    class RawExpr {
        Col
        Lit
        Bin
        Unary
        InList
        Agg
    }
    class Insert
    class Update~Cols~
    class Delete~Cols~

    Table --> Selection : all
    Table --> Binding : write
    Table --> Query : from
    Table --> Insert : insert
    Table --> Update : update
    Table --> Delete : delete
    Query --> RawExpr : projection / wheres
    Selection --> RawExpr : exprs
    Column --> Expr : expr
    Expr --> RawExpr : raw
```

`Cols` はエンティティごとの生成型（`UserCols` など）で、`Column[T]` を並べた構造体です。
`Expr[T]` と `Column[T]` の `T` はファントム型で SQL 側には現れません。比較の型安全性
（`Column[Int]` に文字列を渡せない）だけを担います。

比較演算子は `Column[T]` に直接生えているので、`u.age.gte(18)` と書けます。両者を 1 つの
型に統合しないのは、`Column` が列名も持っており、`sel` / `Binding` / `Update::set` が
それを必要とする一方、一般の式は名前を持たないためです。`Column::expr()` は集約など
式を直接組み立てるときの逃げ道として残っています。

## 使い方

cairn は**行型とドメインエンティティを別物として扱います**。生成されるのは行型まわりの
配管だけで、両者の対応づけはプログラマが書きます。

### 1. 行型を書く

```moonbit
#cairn.table(name="users", alias="u")
pub(all) struct User {
  #cairn.id
  id : Int
  name : String
  age : Int
  deleted_at : String?
} derive(Debug, Eq)
```

注釈が付いた構造体は**テーブル 1 行の平たい形**です。`pub(all)` が必要で、呼び出し側が
値を組み立てて `insert` に渡すため、`pub` のままだと外部から読み取り専用になります。

`cols="..."` で列ハンドル型の名前を上書きできます（既定は `<型名>Cols`）。

### 2. 生成する

```
moon run src/gen/cmd -- src/example/entities.mbt -o src/example/entities.g.mbt
```

`UserCols` / `User::cols()` / `User::all()` / `User::binding()` / `User::table()` /
`User::table_of()` / `User::primary_key_name()` が出力されます。生成物は普通の
MoonBit コードなので、読めますし diff も取れます。

配布時は `moon.pkg` の `pre-build` からビルド済みの `cairn-gen` を呼びます。
**同一モジュール内で `moon run` を呼ぶフックは無限再帰する**ので、このリポジトリの例は
明示実行にしてあります。

### 3. 行型とドメインエンティティが一致しないとき

ドメイン側が和型で状態遷移を表す場合、テーブルとは 1-1 対応しません。行は
`submitted_at` や `tracking` を nullable にせざるを得ませんが、ドメイン型では
それぞれの状態が持つべきフィールドを無条件にできます。

```moonbit
#cairn.table(name="orders", alias="o", cols="OrderCols")
pub(all) struct OrderRow {
  #cairn.id
  id : Int
  items : Int
  status : String
  submitted_at : String?
  tracking : String?
}

pub(all) enum Order {
  Draft(id~ : Int, items~ : Int)
  Submitted(id~ : Int, items~ : Int, submitted_at~ : String)
  Shipped(id~ : Int, items~ : Int, submitted_at~ : String, tracking~ : String)
}
```

対応づけは手で書きます。ドメイン知識が実際に宿るのはここだけです。

```moonbit
pub fn Order::of_row(r : OrderRow) -> Order raise @sql.DecodeError {
  match (r.status, r.submitted_at, r.tracking) {
    ("draft", _, _) => Draft(id=r.id, items=r.items)
    ("submitted", Some(at), _) => Submitted(id=r.id, items=r.items, submitted_at=at)
    ("shipped", Some(at), Some(t)) =>
      Shipped(id=r.id, items=r.items, submitted_at=at, tracking=t)
    _ => raise @sql.Malformed("orders id=\{r.id}: illegal stored state")
  }
}

pub fn Order::to_row(self : Order) -> OrderRow { ... }
```

そして**ドメイン型で型付けされたテーブル**を作ります。

```moonbit
pub fn orders() -> @sql.Table[OrderCols, Order] {
  OrderRow::table_of(Order::of_row, Order::to_row)
}
```

以降、クエリも DML も `Order` を返し、`Order` を受け取ります。`OrderRow` は境界の外に
出てきません。読み取り方向だけが `raise` するのは意図的で、**テーブルはドメイン型が
拒む組み合わせを保持しうる**からです。書き込み方向は全域関数です。

```mermaid
flowchart LR
    ROW["OrderRow<br/>生成される行型"] -->|"of_row（失敗しうる）"| DOM["Order<br/>手書きのドメイン型"]
    DOM -->|"to_row（全域）"| ROW
    ROW -.-|"Selection::map / Binding::contramap"| SEAM["Table&lt;OrderCols, Order&gt;"]
```

行型とドメイン型が一致するなら、この段は不要です。生成済みの `User::table()` を
そのまま使えます。

### 4. クエリ

```moonbit
@sql.from(User::table())
|> @sql.Query::filter(u => u.age.gte(18) & u.deleted_at.is_none())
|> @sql.Query::map(u => @sql.sel(u.name))
|> @sql.Query::order_by(u => [u.name.asc()])
|> @sql.Query::limit(20)
```

```sql
SELECT u."name"
  FROM "users" AS u
 WHERE u."age" >= ? AND u."deleted_at" IS NULL
 ORDER BY u."name" ASC
 LIMIT ?
```

絞り込みは**行の列**に対して書きます。データベースが持っているのはそれだからです。
返ってくる型を決めるのはドメイン型のほうです。

### 5. DML

```moonbit
@sql.insert(User::table(), user)
@sql.insert_except(User::table(), user, omit=["id"])  // 自動採番キーを DB に任せる
@sql.update(User::table(), u => u.id.eq(7))
|> @sql.Update::set(u => u.name, "bob")
@sql.delete(User::table(), u => u.age.lt(18))
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

`update` / `delete` は述語を**必須引数**で取ります。チェーンの一段にすると書き忘れが
全行更新になるため、テーブル全体を対象にする場合は `update_all` / `delete_all` という
名前で意図を明示します。

### 6. JOIN

```moonbit
@sql.from(User::table())
|> @sql.Query::join(Post::table(), (u, p) => u.id.eq_col(p.author_id))
|> @sql.Query::filter(c => c.0.age.gte(18) & c.1.title.ne("draft"))
|> @sql.Query::map(c => @sql.sel2(c.0.name, c.1.title))
|> @sql.Query::order_by(c => [c.1.id.desc()])
```

```sql
SELECT u."name", p."title"
  FROM "users" AS u
  JOIN "posts" AS p ON u."id" = p."author_id"
 WHERE u."age" >= ? AND p."title" <> ?
 ORDER BY p."id" DESC
```

`join` は `Query[C1, A]` と `Table[C2, R2]` から `Query[(C1, C2), A]` を作ります。
`Cols` がタプルになるので、以降は `.0` / `.1` で各テーブルの列に届きます。
3 本目は `((C1, C2), C3)` と入れ子になります。

複数テーブルから 1 つのドメイン値を組み立てる場合も同じ道具立てで、
`Query::map(c => ...)` が返す `Selection[D]` にドメイン型を書きます。

#### LEFT JOIN

外部結合の右側は `Nullable[C2, R2]` として返ります。これは**表現を持たない抽象型**で、
中の `Column[T]` を取り出す経路が存在しません。到達手段は 2 つだけです。

```moonbit
c.1.col(p => p.title)   // Column[String?]  ── 列が欲しいとき
c.1.row()               // Selection[Post?] ── 行ごと欲しいとき
```

`row()` のほうが LEFT JOIN の意味論に近いはずです。外部結合が言っているのは
「各列が独立に NULL になりうる」ではなく**「右の行が有るか無いか」**であり、
`Some` の中では各フィールドはテーブルが宣言した型のままです。

```moonbit
@sql.from(User::table())
|> @sql.Query::left_join(Post::table(), (u, p) => u.id.eq_col(p.author_id))
|> @sql.Query::map(c => @sql.sel(c.0.name).zip(c.1.row()))
```

```
一致した行   → ("alice", Some({ id: 7, title: "hello" }))
一致しない行 → ("bob", None)
```

不一致の判定は「右側の列がすべて NULL」で行います。主キーを含む射影なら常に正しく、
`Table::all` は必ず含みます。全列 nullable な射影を自前で組む場合は
`Selection::optional_on(key~)` で判定列を指定してください。

## 実行

### ドライバ

cairn が実際のデータベースに求めるのは、SQL 文と順序付きパラメータを受け取って動かす
ことだけです。

```moonbit
pub(open) trait Driver {
  query(Self, String, Array[SqlValue]) -> Array[Array[SqlValue]] raise DbError
  execute(Self, String, Array[SqlValue]) -> Int raise DbError
  dialect(Self) -> Dialect
  begin(Self) -> Unit raise DbError
  commit(Self) -> Unit raise DbError
  rollback(Self) -> Unit raise DbError
}
```

ドライバがそのまま接続です。コネクションプールを被せるならこの外側になります。

### 実行

```moonbit
query.run(db)     // Array[A]  ── 全行
query.one(db)     // A         ── ちょうど 1 行。0 なら NotFound、2 以上なら TooManyRows
query.first(db)   // A?        ── 先頭 1 行、なければ None
insert.run(db)    // Int       ── 影響行数
update.run(db)    // Int
delete.run(db)    // Int
```

ドメイン型で型付けしたテーブルなら、返るのはドメイン値です。行型は出てきません。

```moonbit
@sql.from(orders()).run(db)
// => [Shipped(id=1, items=3, submitted_at="2026-08-01", tracking="ZZ123"),
//     Draft(id=2, items=1)]
```

### トランザクション

**トランザクションモナドはありません。** MoonBit のエラー効果が同じ仕事をするので、
本体は普通の関数で、途中で `raise` できます。

```moonbit
@sql.transaction(db, conn => {
  let removed = @sql.delete(DraftRow::table(), d => d.id.eq(2)).run(conn)
  let added = @sql.insert(SubmittedRow::table(), { id: 2, items: 1, submitted_at: at }).run(conn)
  (removed, added)
})
```

begin / commit / rollback を個別に公開せずコンビネータにしてあるのは、本体の途中の
`raise` がトランザクションを開いたまま残せないようにするためです。

```mermaid
flowchart LR
    B["begin"] --> BODY["body(conn)"]
    BODY -->|"返る"| C["commit"] --> R1["結果"]
    BODY -->|"raise"| RB["rollback"] --> R2["同じ例外を再送出"]
    B -->|"raise"| R3["そのまま送出<br/>rollback しない"]
```

- 本体が返れば COMMIT、`raise` すれば ROLLBACK して**同じ例外を再送出**
- rollback 自体が失敗しても、**元の例外を握り潰しません**。原因のほうが有用なので
- `begin` が失敗した場合は取り消すものが無いので ROLLBACK を送りません

上の 3 つはいずれもテストで固定してあります（`["BEGIN", "EXEC", "EXEC", "COMMIT"]` /
`["BEGIN", "EXEC", "ROLLBACK"]` / `[]`）。

## Repository パターン

cairn 側に専用の仕組みはありません。Repository はアプリケーション側のコードとして
そのまま書けます。

### 形は MoonBit のトレイトが決める

トレイトメソッドは自前の型パラメータを持てないため、**`Repository[T, ID]` のような
汎用リポジトリは書けません**。集約ごとにドメイン語彙のインタフェースを持つ形になります
（`unassigned` は汎用の `find_by(criteria)` には書けない意味を持ちます）。

```moonbit
// ポート：ドメインの語彙で書く。cairn に依存しない
pub(open) trait TicketRepository {
  find(Self, Int) -> Ticket? raise
  save(Self, Ticket) -> Unit raise
  unassigned(Self) -> Array[Ticket] raise
}

// アダプタ：ドライバを型パラメータに取り、接続として保持する
struct SqlTickets[D] {
  db : D
}

pub impl[D : @sql.Driver] TicketRepository for SqlTickets[D] with find(self, id) {
  (ticket_query() |> @sql.Query::filter(c => c.0.0.id.eq(id))).first(self.db)
}
```

`impl` には `pub` が要ります。付け忘れると外部から
「no `impl` is defined」になります。

### 集約が複数テーブルに分散するとき

Repository が本当に効くのはここです。フェーズ表に分けた集約を例にします。

```
tickets(id, subject)
ticket_assignments(ticket_id → tickets.id, assignee)
ticket_closures(ticket_id → ticket_assignments.ticket_id, resolution)
```

`find` は 2 段 LEFT JOIN の 1 文で済みます。

```moonbit
@sql.from(TicketRow::table())
|> @sql.Query::left_join(AssignmentRow::table(), (t, a) => t.id.eq_col(a.ticket_id))
|> @sql.Query::left_join(ClosureRow::table(), (c, cl) => c.0.id.eq_col(cl.ticket_id))
|> @sql.Query::map(c => TicketRow::all(c.0.0).zip(c.0.1.row()).zip(c.1.row()).map(assemble))
```

**どのフェーズ行が返ったかがそのまま状態**です。判別子カラムは存在しません。

| 返った行 | 復元される集約 |
|---|---|
| base のみ | `Open(id=1, subject="printer on fire")` |
| base + assignment | `Assigned(..., assignee="dana")` |
| 3 つとも | `Closed(..., resolution="unplugged it")` |

ドメイン語彙のクエリも「フェーズ行が無い」で表現できます。

```moonbit
|> @sql.Query::filter(c => c.0.1.col(a => a.ticket_id).is_none())
// → WHERE ta."ticket_id" IS NULL
```

### `save` が「生成できない仕事」の置き場

フェーズ行は不変の事実なので、保存は加算的です。現状を読んで足りないものだけ入れます。

```moonbit
@sql.transaction(self.db, conn => {
  let before = self.find(id)
  if before is None { /* base 行を挿入 */ }
  if ticket.assignee() is Some(a) && recorded_assignee is None { /* assignment を挿入 */ }
  if ticket.resolution() is Some(r) && recorded_resolution is None { /* closure を挿入 */ }
})
```

| 操作 | 発行される文 |
|---|---|
| 新規 `Open` を保存 | `INSERT INTO "tickets" ("id", "subject")` |
| `Open` → `Assigned` | `INSERT INTO "ticket_assignments" ("ticket_id", "assignee")` |
| 途中で失敗 | `["BEGIN", "QUERY", "EXEC", "ROLLBACK"]` |

base 行は書き直されません。**集約の形とテーブルの形が出会う場所**がここで、生成器には
書けない部分です。

### トランザクションとの噛み合わせ

ドライバが接続そのものなので、`transaction(self.db, conn => ...)` の `conn` は
`self.db` と同一です。結果として**リポジトリは外側のトランザクションに自動的に参加します**。

裏返しに、リポジトリは自分がトランザクション内かを知れません。複数リポジトリを 1 つの
Unit of Work にまとめたい場合は、トランザクション内で `conn` に束ね直します。

```moonbit
@sql.transaction(db, conn => {
  let tickets = SqlTickets::new(conn)
  let users = SqlUsers::new(conn)
  ...
})
```

リポジトリの生成は構造体 1 個なので安価です。

## 安全側に倒している点

| 状況 | 挙動 |
|---|---|
| 行ゼロの INSERT | `EmptyInsert` を送出 |
| 代入ゼロの UPDATE | `EmptyUpdate` を送出 |
| 列数と値数の不一致 | `ArityMismatch` を送出 |
| 同一エイリアスの結合（自己結合） | `DuplicateAlias` を送出 |
| 述語なしの UPDATE / DELETE | `update_all` / `delete_all` を明示的に呼ぶ必要がある |
| `one` が 0 件 / 2 件以上 | `NotFound` / `TooManyRows` を送出 |
| トランザクション本体の失敗 | ROLLBACK して同じ例外を再送出 |

## 未実装

- **エイリアス指定と自己結合** — `Cols` の `Column` がエイリアスを焼き込んでいるため、
  `Table` が `cols` を `(String) -> Cols` として持つ形への変更が要る
- **セキュリティ型パラメータ** — Acadia の `Table Unrestricted Food` に相当する
  `Table[Sec, Cols, R]`。`#cairn.entity(security=...)` のスロットは空けてある
- **インデックス / 制約 / マイグレーション** — 属性は未知の名前を黙って無視する設計なので、
  後から足しても古い生成器を壊さない
- **集約** — `count_sel()` はスタブ（`read` が行を無視して 0 を返す）

## 開発

```
moon check      # 型検査
moon test       # テスト
moon fmt        # 整形
moon info       # .mbti 更新
```

パッケージ構成:

```
src/sql/        コアライブラリ（式・射影・クエリ・DML・出力）
src/gen/        コード生成器（属性解析 → IR → 出力）
src/gen/cmd/    CLI (cairn-gen)
src/example/    エンティティと生成物の実例
```

生成器は [`moonbitlang/parser`](https://mooncakes.io/docs/moonbitlang/parser) で
MoonBit ソースを解析します。属性は `Attribute.raw` の生テキストから読みます
（`parsed` はユーザー定義名前空間では埋まらず、`name()` は名前空間を落とすため）。

README のコードブロックは型検査されていません。検査したい場合は `.mbt.md` として
`src/` 配下のパッケージに置く必要があります（モジュールの `source = "src"` の外にある
ファイルは対象外です）。
