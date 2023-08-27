(use judge)

(def- *subject* (gensym))
(def- *success* (gensym))
(def- *result* (gensym))

(defmacro- scope :fmt/block [body &opt if-broken invert]
  (default invert false)
  (def which-if (if invert 'if-not 'if))
  (with-syms [$success $result]
    ~(do
      (var ,$success true)
      (var ,$result nil)
      (while true
        (set ,$result (do
          ,(with-dyns [*success* $success *result* $result]
            (macex body))))
        (break))
      (,which-if ,$success
        ,$result
        ,if-broken))))

(defmacro- fail []
  ~(do
    (set ,(dyn *success*) false)
    (break)))

# we use this because of the janky way that we detect
# exported vars: by looking for `def` statements in
# the output of a compiled pattern. this allows us
# to define private, local variables without assuming
# that they're exported.
(defmacro- alias [x y] ~(def ,x ,y))

(deftest "scope macro"
  (test (scope (+ 1 2)) 3)
  (test (scope (do (fail) (+ 1 2)) 5) 5)
  (test (scope (do (scope (fail) "broke") "ok")) "ok")
  (test (scope (do (scope (fail) "inner") (fail) "ok") "outer") "outer"))

(defn- fallback* [cases final]
  (match cases
    [first-case & rest]
      (with-syms [$result]
        ~(let [,$result
          (as-macro ,scope
            (do ,;first-case)
            ,(fallback* rest final)
          )]))
    [] final))

(defmacro- fallback [cases final]
  ~(as-macro ,fallback* ,cases ,final))

(deftest "fallback"
  (test (fallback
    [[1]
     [2]]
    3) 1)

  (test (fallback
    [[1 (fail)]
     [2]]
    3) 2)

  (test (fallback
    [[1 (fail)]
     [2 (fail)]]
    3) 3))

(defn- type+ [form]
  (let [t (type form)]
    (case t
      :tuple (case (tuple/type form)
        :brackets :tuple-brackets
        :parens :tuple-parens)
      t)))

(var- compile-pattern nil)

(defn- assert-same-syms [list]
  (var result nil)
  (def canonical (list 0))
  (for i 1 (length list)
    (def this (list i))
    (unless (= (this :syms) (canonical :syms))
      (errorf "all branches of an or pattern must bind the same symbols\n%q binds %q, but %q binds %q"
        (canonical :pattern) (tuple/slice (keys (canonical :syms)))
        (this :pattern) (tuple/slice (keys (this :syms))))))
  (canonical :syms))

(defn- definitions [body]
  (def symbols-defined @{})
  (each form body
    (when (and (> (length form) 2) (= (form 0) 'def))
      (put symbols-defined (form 1) true)))
  (table/to-struct symbols-defined))

(defn- compile-or [patterns]
  (def compiled (seq [pattern :in patterns]
    (def body (compile-pattern pattern))
    {:body body
     :syms (definitions body)
     :pattern pattern}))
  (def syms (assert-same-syms compiled))
  (def sym-to-gen (tabseq [sym :keys syms] sym (gensym)))
  [;(seq [$sym :in sym-to-gen] ~(var ,$sym nil))
   (fallback*
     (seq [{:body body} :in compiled]
       [;body
        ;(seq [[sym $sym] :pairs sym-to-gen]
           ~(set ,$sym ,sym))])
     ~(as-macro ,fail))
   ;(seq [[sym $sym] :pairs sym-to-gen]
      ~(def ,sym ,$sym))])

(defn- compile-and [patterns]
  (mapcat compile-pattern patterns))

(defn- compile-not [pattern]
  (def body (compile-pattern pattern))
  (unless (empty? (definitions body))
    (error "not patterns cannot create bindings"))
  [~(as-macro ,scope
      (do ,;body)
      (as-macro ,fail)
      true)])

(defn- check [f x]
  (if (or (function? f) (cfunction? f))
    (f x)
    f))

(defn- check-predicate [f x]
  (if (= ((disasm f) :max-arity) 0)
    (check (f) x)
    (f x)))

(defn- subject []
  (array/peek (dyn *subject*)))

(defmacro- with-subject [subject & exprs]
  (with-syms [$result] ~(do
    (array/push (dyn *subject*) ,subject)
    (def ,$result ,;exprs)
    (array/pop (dyn *subject*))
    ,$result)))

(defn- definitely-nullary? [body]
  (var result true)
  (prewalk (fn [x]
    (when (and (symbol? x) (string/has-prefix? "$" x))
      (set result false))
    x)
    body)
  result)

(test (definitely-nullary? ~(> $ 1)) false)
(test (definitely-nullary? ~(> x 1)) true)
(test (definitely-nullary? ~(|($ 1) 1)) false)

(defn- compile-predicate [body]
  [(if (definitely-nullary? body)
     ~(unless (,check ,body ,(subject))
       (as-macro ,fail))
     ~(unless (,check-predicate (short-fn ,body) ,(subject))
       (as-macro ,fail)))])

(defn- compile-equality [& args]
  [~(unless (= ,(subject) ,;args) (as-macro ,fail))])

(defn- compile-inequality [& args]
  [~(when (= ,(subject) ,;args) (as-macro ,fail))])

(defn- compile-map [f pattern]
  (with-syms [$subject]
    [~(as-macro ,alias ,$subject (,f ,(subject)))
    ;(with-subject $subject
      (compile-pattern pattern))]))

(defn- compile-operator-pattern [pattern]
  (when (empty? pattern)
    (errorf "illegal pattern %q" pattern))
  (def [instr & args] pattern)
  (case instr
    'not (compile-not ;args)
    'and (compile-and args)
    'or (compile-or args)
    'short-fn (compile-predicate ;args)
    'quote (compile-equality pattern)
    'quasiquote (compile-equality pattern)
    'unquote (compile-equality ;args)
    '= (compile-equality ;args)
    'not= (compile-inequality ;args)
    'map (compile-map ;args)
    (errorf "unknown operator %q in pattern %q" instr pattern)))

(defn- slice [list i]
  (if (array? list)
    (array/slice list i)
    (tuple/slice list i)))

(defn- compile-indexed-pattern [patterns]
  (def rest-index (find-index |(= $ '&) patterns))
  (when rest-index
    (assert (<= (length patterns) (+ 2 rest-index))
      "cannot specify multiple patterns after &"))
  (def rest-pattern (if rest-index
    (get patterns (+ 1 rest-index))))
  (with-syms [$list]
    [~(as-macro ,alias ,$list ,(subject))
     ;(with-subject $list
      [~(unless (indexed? ,(subject))
          (as-macro ,fail))
       (if rest-index
        ~(unless (>= (length ,(subject)) ,rest-index)
           (as-macro ,fail))
        ~(unless (= (length ,(subject)) ,(length patterns))
           (as-macro ,fail)))
       ;(catseq [[i pattern] :pairs patterns :when (or (not rest-index) (< i rest-index))]
          (with-subject ~(,$list ,i)
            (compile-pattern pattern)))
       ;(if (nil? rest-pattern)
          []
          (with-subject ~(,slice ,$list ,rest-index)
            (compile-pattern rest-pattern)))
       ])]))

(defn- optional-pattern [pattern]
  (match pattern ['? p] p))

(defn- symbol-of-key [key]
  (match (type key)
    :keyword (symbol key)
    :symbol key
    nil))

(defn- compile-struct-value-pattern [pattern key]
  (def $sym (symbol-of-key key))
  (if (and (= pattern '&) $sym)
    [~(def ,$sym ,(subject))]
    (compile-pattern pattern)))

(defn- compile-dictionary-pattern [pattern]
  (with-syms [$dict]
    [~(as-macro ,alias ,$dict ,(subject))
     ;(catseq [[key pattern] :pairs pattern]
       (with-subject ~(,$dict ,key)
        (if-let [pattern (optional-pattern pattern)]
          (compile-struct-value-pattern pattern key)
          [~(unless (has-key? ,$dict ,key) (as-macro ,fail))
           ;(compile-struct-value-pattern pattern key)])))]))

(defn- compile-symbol-pattern [pattern]
  (case pattern
    '_ []
    '& (error "cannot bind & as a regular symbol")
    [~(def ,pattern ,(subject))]))

(varfn compile-pattern [pattern]
  (case (type+ pattern)
    :symbol (compile-symbol-pattern pattern)
    :keyword (compile-equality pattern)
    :string (compile-equality pattern)
    :number (compile-equality pattern)
    :nil (compile-equality pattern)
    :boolean (compile-equality pattern)
    :tuple-parens (compile-operator-pattern pattern)
    :tuple-brackets (compile-indexed-pattern pattern)
    :struct (compile-dictionary-pattern pattern)
    (errorf "unknown pattern %q" pattern)))

(def- no-default (gensym))

(defmacro- match1 [value pattern expr]
  (with-dyns [*subject* @[value]]
    ~(scope
      (do ,;(compile-pattern pattern) ,expr))))

(defmacro match [value & cases]
  (def [cases default-value]
    (if (odd? (length cases))
      [(drop -1 cases) (last cases)]
      [cases no-default]))
  (with-dyns [*subject* @[value]]
    (fallback*
      (seq [[pattern expr] :in (partition 2 cases)]
        [;(compile-pattern pattern) expr])
      (if (= default-value no-default)
        ~(errorf "%q did not match" ,(subject))
        default-value))))

# ---------------------------------------------------

(deftest "trivial pattern expansions"
  (test-macro (match1 foo x x)
    (scope
      (do
        (def x foo)
        x)))
  (test-macro (match1 foo _ x)
    (scope
      (do
        x))))

(deftest "indexed pattern expansion"
  (test-macro (match1 foo [x y] (+ x y))
    (scope
      (do
        (as-macro @alias <1> foo)
        (unless (indexed? <1>)
          (as-macro @fail))
        (unless (= (length <1>) 2)
          (as-macro @fail))
        (def x (<1> 0))
        (def y (<1> 1))
        (+ x y))))

  (test-macro (match1 foo [x y &] (+ x y))
    (scope
      (do
        (as-macro @alias <1> foo)
        (unless (indexed? <1>)
          (as-macro @fail))
        (unless (>= (length <1>) 2)
          (as-macro @fail))
        (def x (<1> 0))
        (def y (<1> 1))
        (+ x y))))

  (test-macro (match1 foo [x y & z] (+ x y))
    (scope
      (do
        (as-macro @alias <1> foo)
        (unless (indexed? <1>)
          (as-macro @fail))
        (unless (>= (length <1>) 2)
          (as-macro @fail))
        (def x (<1> 0))
        (def y (<1> 1))
        (def z (@slice <1> 2))
        (+ x y)))))

(deftest "nested indexed patterns"
  (test-macro (match1 foo [[x y] z] (+ x y z))
    (scope
      (do
        (as-macro @alias <1> foo)
        (unless (indexed? <1>)
          (as-macro @fail))
        (unless (= (length <1>) 2)
          (as-macro @fail))
        (as-macro @alias <2> (<1> 0))
        (unless (indexed? <2>)
          (as-macro @fail))
        (unless (= (length <2>) 2)
          (as-macro @fail))
        (def x (<2> 0))
        (def y (<2> 1))
        (def z (<1> 1))
        (+ x y z)))))

(deftest "multiple patterns"
  (test-macro (match foo x x y y)
    (let [<1> (as-macro @scope (do (def x foo) x) (let [<2> (as-macro @scope (do (def y foo) y) (errorf "%q did not match" foo))]))])))

(deftest "or expansion"
  (test-macro (match1 10 (or []) 20)
    (scope
      (do
        (let [<1> (as-macro @scope (do (as-macro @alias <2> 10) (unless (indexed? <2>) (as-macro @fail)) (unless (= (length <2>) 0) (as-macro @fail))) (as-macro @fail))])
        20))))

(deftest "dictionary pattern expansion"
  (test-macro (match1 foo {:x x} x)
    (scope
      (do
        (as-macro @alias <1> foo)
        (unless (has-key? <1> :x)
          (as-macro @fail))
        (def x (<1> :x))
        x))))

(deftest "not expansion"
  (test-macro (match1 foo (not nil) :ok)
    (scope
      (do
        (as-macro @scope
          (do
            (unless (= foo nil)
              (as-macro @fail)))
          (as-macro @fail)
          true)
        :ok))))
