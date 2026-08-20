# 5. 集約

[← JOIN](04-join.md) · [実行 →](06-execution.md)

## 型

```moonbit
type Reducer[Out]   // 抽象型
```

構造としては `Reducer` は `Selection` です。式の列と位置ベースのリーダという
同じ組を持っています。型を**意図的に分け、かつ抽象にしている**ことが設計の核心です。

`Reducer` が持てるのは集約式だけであり、それ以外を入れられるコンストラクタは
存在しません。したがって、集約の隣に裸の非グループ列を射影すること — SQL が
拒む形 — が**そもそも書けません**。`Query::reduce` と `Query::group_by` が
`Selection` ではなく `Reducer` を要求するのは、まさにそのためです。

## 集約関数

```moonbit
pub fn count() -> Reducer[Int]
pub fn[T] count_of(Column[T]) -> Reducer[Int]
pub fn[T : SqlDecode + SqlOrd] min(Column[T]) -> Reducer[T?]
pub fn[T : SqlDecode + SqlOrd] max(Column[T]) -> Reducer[T?]
pub fn[T : SqlDecode + SqlNum] sum(Column[T]) -> Reducer[T?]
pub fn[T : SqlNum]             avg(Column[T]) -> Reducer[Double?]
```

| | SQL | 行が 0 件のとき |
|---|---|---|
| `count()` | `COUNT(*)` | `0` |
| `count_of(c)` | `COUNT(c)` — NULL は数えない | `0` |
| `min(c)` / `max(c)` | `MIN(c)` / `MAX(c)` | `None` |
| `sum(c)` | `SUM(c)` | `None` |
| `avg(c)` | `AVG(c)` | `None` |

**`count` だけが `Int` で、残りは `T?`** です。SQL に合わせています。0 件に対する
`COUNT(*)` はゼロですが、`MIN` は NULL です。

`avg` は列の型によらず `Double?` を返します。整数の平均は一般に整数ではないからです。

`sum` と `avg` は `SqlNum` を、`min` と `max` は `SqlOrd` を要求します。どちらも
メソッドのないマーカートレイトで、`Column[String]` を合計させないためだけに
存在します。

## 合成

```moonbit
pub fn[A, B] Reducer::zip(Reducer[A], Reducer[B]) -> Reducer[(A, B)]
pub fn[A, B] Reducer::map(Reducer[A], (A) -> B raise DecodeError) -> Reducer[B]
```

Acadia はここに `map2` から `map9` までを用意しています。`zip` と `map` の組み合わせは
アリティの梯子なしで同じ範囲をカバーします。

## 結果全体を畳む

```moonbit
pub fn[C, A, S] Query::reduce(Query[C, A], (C) -> Reducer[S]) -> Query[C, S]
```

射影が集約だけになるので、結果は 1 行です。`A` が `S` になる一方 `C` は手つかずで
あることに注目してください。カラムハンドルは依然スコープにありますが、1 行が
デコードされる先は要約になりました。

**`users`**

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | bob | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |
| 4 | dave | 25 | 2026-01-09 |

```moonbit
@aya.from(users())
|> @aya.Query::filter(u => u.deleted_at.is_none())
|> @aya.Query::reduce(u => @aya.count().zip(@aya.min(u.age)).zip(@aya.max(u.age)))
```

```sql
SELECT COUNT(*), MIN(u."age"), MAX(u."age")
  FROM "users" AS u
 WHERE u."deleted_at" IS NULL
```

**結果** — 1 行、`((Int, Int?), Int?)`

| COUNT(*) | MIN(age) | MAX(age) |
|---------:|---------:|---------:|
| 3 | 17 | 42 |

デコードすると `((3, Some(17)), Some(42))` になります。入れ子は `zip` を連ねた
結果で、自分の型に平坦化したければ `map` を使います。`dave` は絞り込みで除かれる
ので、件数は 4 ではなく 3 です。

実行は `one` で。行はつねにちょうど 1 つです。

## グループ化

```moonbit
pub fn[C, A, K : SqlDecode, S] Query::group_by(
  Query[C, A],
  (C) -> Column[K],      // キー
  (C) -> Reducer[S],     // 要約
) -> Query[C, (K, S)]
```

グループ化キーは射影に含めうる唯一の非集約であり、それはまさにグループ化の対象と
なっている列です。したがって**結果はつねに正当な集約クエリ**になります。行は
`(K, S)` の組で返ります。

```moonbit
@aya.from(users())
|> @aya.Query::group_by(u => u.name, u => @aya.count().zip(@aya.avg(u.age)))
```

```sql
SELECT u."name", COUNT(*), AVG(u."age")
  FROM "users" AS u
 GROUP BY u."name"
```

実行は `run` で。異なるキーごとに 1 行返ります。

グループ化が面白くなるのは結合をまたぐとき、つまりキーが実際に重複するときです。
[4 章](04-join.md)の 2 テーブルに対して、著者ごとの投稿数を数えてみます。

```moonbit
@aya.from(users())
|> @aya.Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
|> @aya.Query::group_by(
  @aya.split2((u, _p) => u.name),
  @aya.split2((_u, p) => @aya.count_of(p.id)),
)
```

```sql
SELECT u."name", COUNT(p."id")
  FROM "users" AS u
  JOIN "posts" AS p ON u."id" = p."author_id"
 GROUP BY u."name"
```

**結果** — `Array[(String, Int)]`

| name | COUNT(p."id") |
|------|--------------:|
| alice | 2 |
| carol | 1 |

`bob` は 0 ではなく**不在**です。内部結合が彼の行を 1 つも作らなかったので、
数えるべきグループがありません。`0` として取り戻すには、外部結合にしたうえで
ラッパ越しに到達した列を数えます。`count_of` は NULL を数えず、埋められた行は
全列 NULL だからです。

```moonbit
|> @aya.Query::left_join(posts(), (u, p) => u.id.eq_col(p.author_id))
|> @aya.Query::group_by(
  @aya.split2((u, _p) => u.name),
  @aya.split2((_u, p) => @aya.count_of(p.col(x => x.id))),
)
```

| name | COUNT(p."id") |
|------|--------------:|
| alice | 2 |
| bob | 0 |
| carol | 1 |

絞り込み・上限・結合はいつもどおりグループ化と合成できます。`filter` は
グループ化の前段の WHERE に落ち、`limit` は返るグループ数を制限します。

---

[← JOIN](04-join.md) · [実行 →](06-execution.md)
