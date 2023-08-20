# `pat/match`

A supercharged `match` macro for Janet.

Here's a quick diff between `pat/match` and Janet's built-in `match`:

- `[x y z]` patterns match exactly, instead of matching prefixes of their input
- failure to match any pattern raises an error by default, instead of returning `nil`
- `(@ foo)` is spelled `(= foo)`
- parens mean something completely different (see "operator patterns" below)

`pat/match` is a bit more powerful than the built-in `match`, supporting pattern alternatives (with `or`) and pattern aliases (with `and`), making it just as expressive as patterns in OCaml or Haskell.

# Symbol patterns

Symbols match any values, and bind that value.

```janet
(pat/match 10
  x (* 2 x))
# 20
```

There are two exceptions:

- `_` is a pattern that matches any value, but creates no binding.
- `&` is not a legal symbol pattern, as it has special meaning in struct and tuple patterns.

# Literal patterns

Numbers, strings, keywords, and booleans match values exactly.

```janet
(pat/match (type [1 2 3])
  :tuple "yep")
```

# Predicate and expression patterns

Use `|` to evaluate arbitrary predicates or expressions. For example:

```janet
(def x 5)
(pat/match x
  |even? "it's even"
  |odd? "it's odd")
# "it's odd"
```

Which is the same as:

```janet
(def x 5)
(pat/match x
  |(even? $) "it's even"
  |(odd? $) "it's odd")
# "it's odd"
```

You can also write arbitrary expressions that don't refer to the value being matched at all:

```janet
(def x 5)
(pat/match x
  |(< 1 2) :trivial)
# :trivial
```

The way this works is that `short-fn`s of zero arguments are invoked, and if they return a function or cfunction, then their result is invoked again with the value being matched. Otherwise, if they don't return a function or cfunction, their result is interpreted as a normal truthy or falsey value.

# Tuple and array patterns

```janet
(def values [1 2])
(pat/match values
  [x y] (+ x y))
```

## Matching prefixes

```janet
(def values [1 2 3])
(pat/match values
  [x y &] (+ x y))
```

```janet
(def values [1 2 3])
(pat/match values
  [car cadr & rest] rest)
# [3]
```

`& rest` patterns match a sliced value of the same type as their input:

```janet
(def values @[1 2 3])
(pat/match values
  [car cadr & rest] rest)
# @[3]
```

You can put any pattern after the `&`, not just a symbol. For example, this pattern will only match tuples of length `2`, `3`, or `4`:

```janet
(def values [1 2 3])
(pat/match values
  [car cadr & |(<= (length $) 2)]
    (+ car cadr))
```

# Structs and table patterns

```janet
(def point {:x 1 :y 2})
(pat/match point
  {:x x :y y} (+ x y))
```

## Optional matching

Because structs and tables cannot contain `nil` as a pattern, the following can never match:

```janet
(pat/match {:foo nil}
  {:foo _} ...)
```

Because `{:foo nil}` is actually `{}`, and the pattern `{:foo _}` needs to match against the key `:foo`, which does not exist.

You can fix this by making an optional match like this:

```janet
(pat/match {:foo nil}
  {:foo (? x)} x)
```

This will bind `x` to `nil` if the keyword `:foo` does not exist in the input.

## Keyword punning

Instead of:

```janet
(def person {:name "ian"})
(pat/match person
  {:name name} (print name))
```

You can write:

```janet
(pat/match person
  {:name &} (print name))
```

## Evaluation order

Note that, due to the way Janet abstract syntax trees work, there is no way to guarantee the order of the match in a struct pattern. This means you cannot refer to variables bound by other keys. That is, don't write code like this:

```janet
(pat/match foo
  {:a a :b |(> $ a)} ...)
```

Such a construct is allowed using `[]` patterns or `and` patterns, but not `{}` patterns: the order that the keys in a struct appear is not part of the parsed abstract syntax tree that `pat` operates on. This *might* work, sometimes, but it's fragile, and working code could break in a future version of Janet.

Similarly, you cannot write duplicate keys in a struct pattern:

```janet
(pat/match foo
  {:a a :a 10} ...)
```

All but the final instance of a key is erased at Janet parse time, so `pat` cannot even warn you if you make this mistake.

# Operator patterns

## `(and patterns...)`

You can use `and` to match multiple patterns against a single value. You can use this to alias values, like "`as` patterns" in other languages:

```janet
(pat/match [1 2]
  (and [x y] p)
    (printf "%q = <%q %q>" p x y))
```

Or to check conditions, like "`when` patterns" in other languages:

```janet
(pat/match point
  (and [x y] |(< x y))
    (print "ascending order"))
```

## `(or patterns...)`

`or` allows you to try multiple patterns and match if any one of them succeeds:

```janet
(pat/match (type value)
  (or :tuple :array) "indexed")
```

Every subpattern in an `or` pattern must bind exactly the same set of symbols. For example, this is allowed:

```janet
(pat/match value
  (or [x] x) (* x 2))
```

But this will fail to compile:

```janet
(pat/match value
  (or [x] y) (* x 2))
```

You can use `_` to perform structural matching without binding any new symbols.

## `(= value)`

Check a value for equality:

```janet
(def origin [0 0])
(pat/match point
  (= origin) :origin)
```

This is the same as:

```janet
(pat/match point
  |(= origin $) :origin)
```

But a little more convenient to write.
