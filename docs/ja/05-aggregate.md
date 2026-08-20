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

```moonbit
@sql.from(users())
|> @sql.Query::filter(u => u.deleted_at.is_none())
|> @sql.Query::reduce(u => @sql.count().zip(@sql.min(u.age)).zip(@sql.max(u.age)))
```

```sql
SELECT COUNT(*), MIN(u."age"), MAX(u."age")
  FROM "users" AS u
 WHERE u."deleted_at" IS NULL
```

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
@sql.from(users())
|> @sql.Query::group_by(u => u.name, u => @sql.count().zip(@sql.avg(u.age)))
```

```sql
SELECT u."name", COUNT(*), AVG(u."age")
  FROM "users" AS u
 GROUP BY u."name"
```

実行は `run` で。異なるキーごとに 1 行返ります。

絞り込み・上限・結合はいつもどおりグループ化と合成できます。`filter` は
グループ化の前段の WHERE に落ち、`limit` は返るグループ数を制限します。

---

[← JOIN](04-join.md) · [実行 →](06-execution.md)
