///|
test "s6: ArrayView / nested view / struct に入れた raising closure" {
  let xs : Array[Int] = [10, 20, 30, 40, 50]
  let v = xs[1:4]
  inspect(v.length(), content="3")

  // ★ ビューをさらにスライスできるか（and のネストで必須）
  let w = v[1:]
  inspect(w[0], content="30")
}

///|
struct Box[T] {
  f : (ArrayView[Int]) -> T raise DecodeError
}

///|
test "s6b" {
  let b : Box[Int] = { f: r => r[0] }
  inspect((b.f)([1, 2][0:]), content="1")
}
