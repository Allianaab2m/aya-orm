# 2. Query — 読む

[← Table](01-table.md) · [DML →](03-dml.md)

`Query` は値です。組み立てただけでは何も動きません。`to_sql` が文字列と
パラメータに変換し、`run` / `one` / `first`（[6 章](06-execution.md)）が
データベースに送ります。

## 型

```moonbit
pub struct Query[Cols, A] {
  source      : String
  source_tbl  : String
  joins       : Array[Join]
  cols        : Cols
  projection  : Array[RawExpr]
  wheres      : Array[RawExpr]
  group       : Array[RawExpr]
  order       : Array[OrderKey]
  limit_n     : Int?
  decode      : (Row) -> A raise DecodeError
}
```

型引数は 2 つ、役割も 2 つです。

- **`Cols`** はコンビネータを書く「対象」— スコープにあるカラムハンドルです。
  最初は 1 テーブルの `Cols` 構造体で、結合を足すとタプルになります。
- **`A`** は 1 行が「何になるか」です。最初はテーブルのエンティティで、
  `map` / `reduce` / `group_by` が言った場合にだけ変わります。

すべてのコンビネータは新しい `Query` を返します。破壊的な変更はしません。

## コンビネータ

```moonbit
pub fn[C, R] from(Table[C, R]) -> Query[C, R]

pub fn[C, A]       Query::filter(Query[C, A], (C) -> Expr[Bool])        -> Query[C, A]
pub fn[C, A]       Query::order_by(Query[C, A], (C) -> Array[OrderKey]) -> Query[C, A]
pub fn[C, A]       Query::limit(Query[C, A], Int)                       -> Query[C, A]
pub fn[C, R, O]    Query::map(Query[C, R], (C) -> Selection[O])         -> Query[C, O]
pub fn[C, D, A]    Query::map_cols(Query[C, A], (C) -> D)               -> Query[D, A]
```

どれもカラムハンドルそのものではなく**カラムハンドルを受け取る関数**を取ります。
そのおかげで、述語はそのクエリが実際にスコープに持っている列しか言及できません。
`join` でテーブルを足して `C` が広がって初めて、新しいテーブルの列を名指しできます。

| コンビネータ | 変えるもの | 変えないもの |
|---|---|---|
| `filter` | `wheres`（蓄積し、AND で結合） | それ以外すべて |
| `order_by` | `order`（置き換え。最後の呼び出しが勝つ） | それ以外すべて |
| `limit` | `limit_n` | それ以外すべて |
| `map` | `projection` と `decode`、したがって `A` | `cols`、したがって `C` |
| `map_cols` | `cols`、したがって `C` | ここまでに組み立てた SQL |
| `join` / `left_join` | `joins`, `cols` | `projection`, `decode` |
| `reduce` / `group_by` | `projection`, `group`, `decode` | `cols` |

`map` と `map_cols` の区別は押さえておく価値があります。`map` は**何が返ってくるか**を
変え、`map_cols` は**列をどう参照するか**を変えます。`map_cols` は SQL に一切
触れません — その真価は [4 章](04-join.md)で発揮されます。

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

## 式の言語

```moonbit
pub struct Column[T] { tbl : String; name : String }
pub struct Expr[T](RawExpr)
```

どちらも**幽霊型 `T`** を持ちます。SQL には現れず、`u.age.eq("eighteen")` が
コンパイルを通らないようにするためだけに存在します。

比較演算子は `Column[T]` に直接生えています。比較の左辺に来るのは圧倒的に列だからです。
列向けの近道でまかなえないものを組み立てるときは、`Column::expr()` で `Expr[T]` に
持ち上げます。

| `Column[T]` / `Expr[T]` 上 | SQL | 必要な制約 |
|---|---|---|
| `eq(v)` / `ne(v)` | `= ?` / `<> ?` | `T : SqlEncode` |
| `gt(v)` / `gte(v)` / `lt(v)` / `lte(v)` | `> ?` など | `T : SqlEncode + SqlOrd` |
| `eq_col(other)` | `a."x" = b."y"` | — |
| `in_([v, ..])` | `IN (?, ?)` | `T : SqlEncode` |
| `is_none()` / `is_some()` | `IS NULL` / `IS NOT NULL` | レシーバが `T?` |
| `asc()` / `desc()` | `ORDER BY … ASC` | `T : SqlOrd` |
| `a & b` / `a \| b` | `AND` / `OR` | 両辺が `Expr[Bool]` |

`&` と `\|` は `Expr[Bool]` に対する `BitAnd` / `BitOr` なので、優先順位は MoonBit の
ものになり、SQL 側で必要な括弧はエミッタが補います。

```moonbit
|> @sql.Query::filter(u => (u.age.gte(18) | u.name.eq("root")) & u.deleted_at.is_none())
```

```sql
 WHERE (u."age" >= ? OR u."name" = ?) AND u."deleted_at" IS NULL
```

NULL 許容の列も比較・整列できます。SQL は NULL を含む列でも問題なく並べ替えますし、
`T?` を拒めば `ORDER BY submitted_at DESC` のようなふつうのクエリが書けなくなります。

## 何を返すか選ぶ

```moonbit
pub fn[T : SqlDecode] sel(Column[T]) -> Selection[T]
pub fn[A : SqlDecode, B : SqlDecode] sel2(Column[A], Column[B]) -> Selection[(A, B)]
pub fn[A : SqlDecode, B : SqlDecode, C : SqlDecode] sel3(Column[A], Column[B], Column[C]) -> Selection[(A, B, C)]
```

4 列以上は `zip` と `into2` / `into3` の組み合わせで、アリティの梯子を作らずに
合成できます。

```moonbit
|> @sql.Query::map(u => @sql.sel2(u.id, u.name).into2((id, name) => Summary::{ id, name }))
```

`map` を挟まなければ、クエリはテーブルの `all` を射影し、テーブルのエンティティに
デコードします。ドメイン型で型付けされたテーブルなら、ドメインの値がそのまま
返ってきて行型は姿を見せません。

## 文を組み立てる

```moonbit
pub fn[C, A] Query::to_sql(
  Query[C, A],
  dialect? : Dialect,   // Sqlite (既定) | Postgres
  shape? : RowShape,    // Plain (既定) | Typed
) -> (String, Array[SqlValue]) raise StatementError
```

パラメータ列は常に**テキスト順**です。文中の n 番目のプレースホルダが列の n 番目の
パラメータに対応します。`$1` 形式の採番と `?` 形式の位置バインドを差し替え可能に
しているのがこの不変条件です。

`run` / `one` / `first` は、エグゼキュータが要求する方言と行の形を使って `to_sql` を
呼んでくれます。直接呼ぶのは、文をログに出したいときや、データベースなしで
テストしたいときです。

この段階で起きうる失敗は 2 系統、どちらも `StatementError` です。

| | |
|---|---|
| `DuplicateAlias(tbl~)` | 1 つのクエリ内で 2 つのテーブルが同じエイリアスを主張した |
| その他 | [DML](03-dml.md) を参照 |

---

[← Table](01-table.md) · [DML →](03-dml.md)
