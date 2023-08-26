(use ../src/init)
(use judge)

(test (seq [[key binding] :pairs (require "../src/init")
            :when (and (table? binding) (not (binding :private)))]
        key)
  @[match])

(deftest "trivial patterns"
  (test (match 10 x x) 10)
  (test (match 10 _ 20) 20))

(deftest "nested indexed patterns"
  (test (match [[1 2] 3] [[x y] z] (+ x y z)) 6))

(deftest "empty indexed patterns"
  (test (match 10 [] "list" x x) 10)
  (test (match [] [] "list" x x) "list"))

(deftest "rest patterns"
  (test (match [] [&] :ok) :ok)
  (test (match [1 2 3] [x &] x) 1)
  (test (match [1 2 3] [x y &] (+ x y)) 3)
  (test (match [1 2 3] [x y z &] (+ x y z)) 6)
  (test-error (match [1 2 3] [x y z w &] (+ x y z w)) "(1 2 3) did not match"))

(deftest "aliasing rest patterns"
  (test (match [1 2 3] [_ & rest] rest) [2 3])
  (test (match [1 2 3] [x & [y z]] (+ x y z)) 6)
  (test-error (macex '(match [1 2 3] [x & y z] (+ x y z))) "cannot specify multiple patterns after &"))

(deftest "tuple patterns match arrays too"
  (test (match @[] [] "list" x x) "list"))

(deftest "multiple patterns"
  (test (match 10 x x y y) 10)
  (test (match 10 [x] x y y) 10))

(deftest "or"
  (test (match 10 (or x) x) 10)
  (test (match 10 (or [x] x) x) 10)
  (test (match [10] (or [x]) x) 10)
  (test (match [10] (or [x] x) x) 10)
  (test (match [10] (or x [x]) x) [10]))

(deftest "or fails the match if no branch matches"
  (test-error (match 10 (or []) 20) "10 did not match")
  (test-error (match 10 (or []) 20) "10 did not match")
  (test-error (match 10 (or [_] [_ _]) "ok") "10 did not match"))

(deftest "nested or"
  (test (match 10 (or (or (or x))) x) 10)
  (test-error (match 10 (or (or (or [x]))) x) "10 did not match")
  (test-error (match 10 (or [_] (or [_ _] [_ _ _])) "yeah") "10 did not match")
  (test (match [10] (or [x] x) x) 10))

(deftest "expansion raises if different branches of an or pattern bind distinct sets of symbols"
  (test-error (macex1 '(match 10 (or x y) x) "10 failed to match")
    "all branches of an or pattern must bind the same symbols\nx binds (x), but y binds (y)")
  (test-error (macex1 '(match 10 (or x _) x) "10 failed to match")
    "all branches of an or pattern must bind the same symbols\nx binds (x), but _ binds ()")
  (test-error (macex1 '(match 10 (or [x y] [x y z]) x) "10 failed to match")
    "all branches of an or pattern must bind the same symbols\n[x y] binds (x y), but [x y z] binds (x y z)"))

(deftest "& is an illegal symbol to bind"
  (test-error (macex1 '(match 10 & :ok) "10 failed to match") "cannot bind & as a regular symbol"))

(deftest "pattern that does not match raises unless a default is provided"
  (test-error (match 10 [x] x [x y] (+ x y)) "10 did not match")
  (test (match 10 [x] x [x y] (+ x y) "default") "default"))

(deftest "you can raise a custom error in the default"
  (test (match [10] [x] x [x y] (+ x y) (error "custom")) 10)
  (test-error (match 10 [x] x [x y] (+ x y) (error "custom")) "custom"))

(deftest "and patterns"
  (test (match 2 (and x y) (+ x y)) 4)
  (test (match [1 2 3] (and [x y z] list) [(+ x y z) list]) [6 [1 2 3]]))

(deftest "predicate patterns"
  (test (match 2 |(even? $) :even |(odd? $) :odd) :even)
  (test (match 3 |(even? $) :even |(odd? $) :odd) :odd))

(deftest "implicit predicate patterns"
  (test (match 2 |even? :even |odd? :odd) :even)
  (test (match 3 |even? :even |odd? :odd) :odd))

(deftest "dynamic predicates"
  (test (match [odd? 1] [f |f] :ok) :ok)
  (test-error (match [even? 1] [f |f] :ok) "(<function even?> 1) did not match"))

(deftest "boolean expression patterns"
  (test (match 2 |(> 2 1) :ok :wat) :ok)
  (test (match 2 |(> 1 2) :wat :ok) :ok))

(deftest "predicates can refer to previously bound values"
  (test (match [1 2] [x (and |(> $ x) y)] (+ x y)) 3)
  (test-error (match [2 1] [x (and |(> $ x) y)] (+ x y)) "(2 1) did not match")
  (test (match [1 2] [x (and y |(> y x))] (+ x y)) 3)
  (test-error (match [2 1] [x (and y |(> y x))] (+ x y)) "(2 1) did not match"))

(deftest "duplicate bound variables always overwrite each other"
  (test (match [1 2] [x x] x) 2)
  (test (match [1 1 2] [x |(= x $) x] x) 2)
  (test (match [1 [2] 3] [x [(and x y)] x] [x y]) [3 2]))

(deftest "equality patterns"
  (def x 10)
  (test (match 10 (= x) :ok) :ok)
  (test (match [10 10] [y (= x y)] y) 10)
  (test-error (match [1 2] [x (= 1 x)] x) "(1 2) did not match")
  (test-error (match [1 2] [x (= x)] x) "(1 2) did not match")
  (test (match [1 1] [x (= 1 x)] x) 1))

(deftest "literal patterns"
  (test (match 10 10 :ok) :ok)
  (test (match :foo :foo :ok) :ok)
  (test (match :bar (or :foo :bar) :ok) :ok)
  (test (match "foo" "foo" :ok) :ok)
  (test (match nil nil :ok) :ok)
  (test (match true true :ok) :ok)
  (test-error (match true false :ok) "true did not match"))

(deftest "quoted patterns"
  (test (match 'foo 'foo :ok) :ok)
  (test (match ['foo] '(foo) :ok) :ok))

(deftest "quasiquoted patterns"
  (def x 10)
  (test (match 'foo ~foo :ok) :ok)
  (test (match [10] ~(,x) :ok) :ok))

(deftest "unquote patterns"
  (def x 10)
  (test (match 10 ,x :ok) :ok))

(deftest "quoted patterns respect tuple bracketedness"
  (test-error (match ['foo] '[foo] :ok) "(foo) did not match"))

(deftest "dictionary patterns"
  (test (match {:x 1} {:x x} x) 1)
  (test (match {:x 1 :y 2} {:x x :y y} (+ x y)) 3)
  (test-error (match {:x 1} {:x x :y y} (+ x y)) "{:x 1} did not match")
  (test (match {:x 1} {:x x :y (? y)} [x y]) [1 nil])
  (test (match {:x 1} {:x &} x) 1)
  (test (match {:x 1} {:x & :y (? &)} [x y]) [1 nil]))

(deftest "not"
  (test (match 1 (and (not 2) (not 3)) :yes :no) :yes)
  (test (match [1] (not []) :yes :no) :yes)
  (test (match [] (not [_]) :yes :no) :yes)
  (test (match [1] (not [_]) :yes :no) :no)
  (test (match [[1]] (not [_]) :yes :no) :no)
  (test (match [[1]] [(not [_])] :yes :no) :no)
  (test (match [[1]] [(not [_ _])] :yes :no) :yes)
  (test-error (macex '(match foo (not x) 0)) "not patterns cannot create bindings")
  (test-error (macex '(match foo (not x y) 0)) "<function compile-not> called with 2 arguments, expected 1")
  (test-error (macex '(match foo (not) 0)) "<function compile-not> called with 0 arguments, expected 1"))

(deftest "not="
  (test (match 1 (not= 2) :yes :no) :yes)
  (test (match 2 (not= 2) :yes :no) :no))

(deftest "map"
  (test (match [1 2 3] (map first 1) :yes :no) :yes)
  (test (match [1 2 3] (map first 2) :yes :no) :no)
  (test (match [1 2 3] (map max-of |odd?) :yes :no) :yes))
