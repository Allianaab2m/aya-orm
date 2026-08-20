# 7. Repository パターン

[← 実行](06-execution.md) · [スキーマ →](08-schema.md)

これについて aya は何も提供しません。Repository はふつうのアプリケーションコード
です。この章は、その下に aya を敷いたときにそのコードが取る形についての話です。

> ここのコードは `src/example` から抜き出したものではなく説明用です。例題は
> エンティティ 2 つだけに絞ってあります。理由は[設計ノート](09-design.md)を
> 参照してください。

## 形は MoonBit のトレイトが決める

トレイトのメソッドは自前の型引数を導入できないので、**汎用の
`Repository[T, ID]` は書けません**。代わりに得られるのは集約ごとの、ドメインの
語彙によるインタフェースです。そしてそれはそもそも良い形です。`unassigned` は
汎用の `find_by(criteria)` には言えないことを言っています。

```moonbit
// ポート: ドメインの語彙。aya に依存しない。
pub(open) trait TicketRepository {
  async fn find(Self, Int) -> Ticket?
  async fn save(Self, Ticket) -> Unit
  async fn unassigned(Self) -> Array[Ticket]
}

// アダプタ: ドライバに対して総称で、その上の Tx を接続として持つ。
struct SqlTickets[D] {
  db : @sql.Tx[D]
}

pub fn[D] SqlTickets::new(db : @sql.Tx[D]) -> SqlTickets[D] {
  { db, }
}

pub impl[D : @sql.Driver] TicketRepository for SqlTickets[D] with fn find(self, id) {
  (ticket_query() |> @sql.Query::filter(j => j.ticket.id.eq(id))).first(self.db)
}
```

`impl` には `pub` が必要です。付けないとパッケージ外の呼び出し側が
「no `impl` is defined」になります。

**フィールドは `D` ではなく `Tx[D]` です。** これが `save` に、既に誰かが括って
いるかどうかを知らずに自分の仕事を括らせます。[6 章](06-execution.md)を参照。

## 集約が複数テーブルに分散するとき

Repository が真価を発揮するのはここです。フェーズテーブルに分割された集約を
考えます。エンティティの不変データ用に 1 つ、各フェーズが確立する事実だけを持つ
テーブルをフェーズごとに 1 つ。全列 NOT NULL で、FK の連鎖がフェーズの順序を
強制します。

```
tickets(id, subject)
ticket_assignments(ticket_id -> tickets.id, assignee)
ticket_closures(ticket_id -> ticket_assignments.ticket_id, resolution)
```

`find` は外部結合 2 つを含む単一の文です。

```moonbit
pub struct TicketJoin {
  ticket     : TicketCols
  assignment : @sql.Nullable[AssignmentCols, AssignmentRow]
  closure    : @sql.Nullable[ClosureCols, ClosureRow]
}

pub fn ticket_query() -> @sql.Query[TicketJoin, Ticket] {
  @sql.from(TicketRow::table())
  |> @sql.Query::left_join(AssignmentRow::table(), (t, a) => t.id.eq_col(a.ticket_id))
  |> @sql.Query::left_join(ClosureRow::table(), (c, cl) => c.0.id.eq_col(cl.ticket_id))
  |> @sql.Query::map_cols(c => { ticket: c.0.0, assignment: c.0.1, closure: c.1 })
  |> @sql.Query::map(j => TicketRow::all(j.ticket)
    .zip(j.assignment.row())
    .zip(j.closure.row())
    .map(assemble))
}
```

ネストは `map_cols` の 1 行に封じ込められています。以降はすべて `c.0.1` ではなく
`j.assignment` と読めます。

**どのフェーズ行が返ってきたかが状態そのものです。** 判別用の列は存在しません。

```moonbit
fn assemble(
  parts : ((TicketRow, AssignmentRow?), ClosureRow?),
) -> Ticket raise @sql.DecodeError {
  let ((base, assignment), closure) = parts
  match (assignment, closure) {
    (None, None) => Open(id=base.id, subject=base.subject)
    (Some(a), None) => Assigned(id=base.id, subject=base.subject, assignee=a.assignee)
    (Some(a), Some(c)) =>
      Closed(id=base.id, subject=base.subject, assignee=a.assignee, resolution=c.resolution)
    // FK の連鎖により、assignment のない closure はデータベース上ありえない。
    // 型はそれを言えないので、この分岐が要る。
    (None, Some(_)) => raise @sql.Malformed("ticket \{base.id}: closed but never assigned")
  }
}
```

| 返ってきた行 | 再構成される集約 |
|---|---|
| ベースのみ | `Open(id=1, subject="printer on fire")` |
| ベース + assignment | `Assigned(..., assignee="dana")` |
| 3 つすべて | `Closed(..., resolution="unplugged it")` |

ドメイン的に意味のあるクエリが、フェーズ行の*不在*になります。

```moonbit
|> @sql.Query::filter(j => j.assignment.col(a => a.ticket_id).is_none())
// -> WHERE ta."ticket_id" IS NULL
```

## `save` が「生成できない仕事」の置き場

フェーズ行は不変の事実なので、保存は追加的です。今あるものを読み、足りないものだけを
挿入します。

```moonbit
pub impl[D : @sql.Driver] TicketRepository for SqlTickets[D] with fn save(self, ticket) {
  @sql.transaction(self.db, conn => {
    let id = ticket.id()
    let before = self.find(id)
    if before is None {
      @sql.insert(TicketRow::table(), { id, subject: ticket.subject() }).run(conn) |> ignore
    }
    let recorded_assignee = match before { Some(t) => t.assignee(); None => None }
    if ticket.assignee() is Some(assignee) && recorded_assignee is None {
      @sql.insert(AssignmentRow::table(), { ticket_id: id, assignee }).run(conn) |> ignore
    }
    let recorded_resolution = match before { Some(t) => t.resolution(); None => None }
    if ticket.resolution() is Some(resolution) && recorded_resolution is None {
      @sql.insert(ClosureRow::table(), { ticket_id: id, resolution }).run(conn) |> ignore
    }
  })
}
```

| 操作 | 発行される文 |
|---|---|
| 新規 `Open` の保存 | `INSERT INTO "tickets" ("id", "subject")` |
| `Open` から `Assigned` へ | `INSERT INTO "ticket_assignments" ("ticket_id", "assignee")` |
| 途中で失敗 | `["BEGIN", "QUERY", "EXEC", "ROLLBACK"]` |

ベース行は書き換えません。ここが**集約の形とテーブルの形が出会う場所**であり、
ジェネレータには書けない部分です。

## 配線

```moonbit
let db = @sql.Tx::new(@sqlite.Sqlite::open("app.db"))
let tickets = SqlTickets::new(db)
let users = SqlUsers::new(db)

@sql.transaction(db, _ => {
  tickets.save(a)
  users.save(b)
})   // BEGIN 1 回、COMMIT 1 回
```

深さの共有が仕組みのすべてです。同じ接続に対して 2 つの Repository に別々の `Tx` を
持たせると、データベースに `BEGIN` を 2 回要求することになり、SQLite はこれを明確に
拒否します。トランザクションの中で何かを組み直す必要はありません。上の Repository
は最初から最後まで同じオブジェクトです。

## テスト

アダプタが `D : @sql.Driver` に対して総称なので、フェイクをそのまま差し込めます。
データベースもフィクスチャも要らず、検証するのは実際に出ていった文です。

```moonbit
let db = @fake.FakeDb::new(counts=[1, 1])
let repo = SqlTickets::new(@sql.Tx::new(db))
repo.save(Open(id=1, subject="printer on fire"))
db.log  // ["BEGIN", "QUERY", "EXEC", "COMMIT"]
```

---

[← 実行](06-execution.md) · [スキーマ →](08-schema.md)
