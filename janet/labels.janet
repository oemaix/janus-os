# SPDX-License-Identifier: Apache-2.0
# Label assignment and selector matching. docs/07 §11.
# Loaded from janus.janet after the matchers exist.

(def label-protocols @["vless" "vmess" "trojan" "shadowsocks" "hysteria2" "tuic"])

(defn label-key-ok? [k]
  (and
    (string? k)
    (nil? (find |(= k $) ["any" "all" "not"]))
    (peg/match ~(sequence
                  (choice "_" (range "AZ") (range "az") (range "\xC2\xEF"))
                  (any (choice "_" "-" (range "09") (range "AZ") (range "az") (range "\x80\xEF")))
                  -1) k)))

(defn label-token-ok? [s]
  (and
    (string? s)
    (not= s "")
    (nil? (string/find " " s))
    (nil? (string/find "\n" s))
    (peg/match ~(sequence (some (choice
                                  (range "AZ") (range "az") (range "09") "-"
                                  (range "\x80\xEF"))) -1) s)))

(defn user-region? [c]
  (and
    (string? c)
    (= (length c) 2)
    (or
      (= c "zz")
      (and (= (c 0) (chr "q")) (>= (c 1) (chr "m")) (<= (c 1) (chr "z")))
      (and (= (c 0) (chr "x")) (>= (c 1) (chr "a")) (<= (c 1) (chr "z"))))))

(defn region-reason [official c]
  (cond
    (not (string? c)) "a region value is a lowercase code"
    (= c "uk") "uk is not a region code. The United Kingdom is gb."
    (= c "eu") "eu is not a region code."
    (or (get official c) (user-region? c)) nil
    (string c " is not an officially assigned or user-assigned region code.")))

(defn duration-ms [text default]
  (def s (if (string? text) text ""))
  (def m (peg/match ~(sequence (number :d+) (capture (choice "ms" "s" "m" "h")) -1) s))
  (if (nil? m)
    default
    (let [n (get m 0) unit (get m 1)]
      (case unit
        "ms" n
        "s" (* n 1000)
        "m" (* n 60000)
        "h" (* n 3600000)
        default))))

(defn read-json-file [path]
  (when (and (string? path) (not= path "") (os/stat path))
    (json-decode (slurp path))))

(defn label-defs [model]
  (def raw (or (get model "labels") @{}))
  (def defs @{})
  (eachk k raw (put defs (string k) (get raw k)))
  (unless (get defs "vendor")
    (put defs "vendor" @{"type" "string" "rules" @[]}))
  (unless (get defs "protocol")
    (put defs "protocol" @{"type" "enum" "values" label-protocols "rules" @[]}))
  (unless (get defs "latency")
    (put defs "latency" @{"type" "number" "timeout" "3s" "interval" "5m" "rules" @[]}))
  defs)

(defn official-set [model]
  (def out @{})
  (each c (or (get model "officialRegions") @[])
    (put out (string/ascii-lower (string c)) true))
  out)

(defn vendor-of [node]
  (def manual (at-in node [:labels :vendor]))
  (if (and (string? manual) (not= manual ""))
    manual
    (let [name (or (tag-of node) "")
          slash (string/find "/" name)]
      (if slash (string/slice name 0 slash) "unknown"))))

(defn ipv4-int [s]
  (when (string? s)
    (def parts (string/split "." s))
    (when (= (length parts) 4)
      (var n 0)
      (var ok true)
      (each part parts
        (def v (scan-number part))
        (if (and (number? v) (>= v 0) (<= v 255) (= (string (math/floor v)) part))
          (set n (int/s64 (+ (* n 256) v)))
          (set ok false)))
      (if ok n nil))))

(defn take-varint [buf i]
  (var n 0)
  (var shift 0)
  (var j i)
  (while (< j (length buf))
    (def b (get buf j))
    (set n (bor n (blshift (band b 127) shift)))
    (set j (+ j 1))
    (set shift (+ shift 7))
    (when (< b 128) (break)))
  [n j])

(defn skip-field [buf i wt]
  (case wt
    0 (get (take-varint buf i) 1)
    1 (+ i 8)
    2 (let [pair (take-varint buf i)
            n (get pair 0)
            j (get pair 1)]
        (+ j n))
    5 (+ i 4)
    i))

(defn parse-cidr [buf]
  (var i 0)
  (var ip nil)
  (var prefix 32)
  (while (< i (length buf))
    (def key (take-varint buf i))
    (def tag (get key 0))
    (def j (get key 1))
    (def field (brshift tag 3))
    (def wt (band tag 7))
    (cond
      (and (= field 1) (= wt 2))
      (let [pair (take-varint buf j)
            n (get pair 0)
            k (get pair 1)]
        (set ip (string/slice buf k (+ k n)))
        (set i (+ k n)))
      (and (= field 2) (= wt 0))
      (let [pair (take-varint buf j)]
        (set prefix (get pair 0))
        (set i (get pair 1)))
      (set i (skip-field buf j wt))))
  [ip prefix])

(defn parse-geo-entry [buf]
  (var i 0)
  (var code "")
  (def cidrs @[])
  (while (< i (length buf))
    (def key (take-varint buf i))
    (def tag (get key 0))
    (def j (get key 1))
    (def field (brshift tag 3))
    (def wt (band tag 7))
    (cond
      (and (= field 1) (= wt 2))
      (let [pair (take-varint buf j)
            n (get pair 0)
            k (get pair 1)]
        (set code (string/ascii-lower (string/slice buf k (+ k n))))
        (set i (+ k n)))
      (and (= field 2) (= wt 2))
      (let [pair (take-varint buf j)
            n (get pair 0)
            k (get pair 1)
            got (parse-cidr (string/slice buf k (+ k n)))]
        (let [raw-str (get got 0)
              nbytes (if raw-str (length raw-str) 0)]
          (cond
            (= nbytes 4)
            (let [raw (bytes raw-str)]
              (array/push cidrs [(int/s64 (+ (* (get raw 0) 16777216)
                                              (* (get raw 1) 65536)
                                              (* (get raw 2) 256)
                                              (get raw 3)))
                                 (get got 1)]))
            (= nbytes 16)
            (array/push cidrs [raw-str (get got 1)])))
        (set i (+ k n)))
      (set i (skip-field buf j wt))))
  [code cidrs])

(defn as-int [n]
  (scan-number (string (int/s64 n))))

(defn empty-buckets []
  (def buckets @[])
  (for _ 0 256 (array/push buckets @[]))
  buckets)

(defn load-geoip [path]
  (def v4 (empty-buckets))
  (def v6 (empty-buckets))
  (when (and (string? path) (os/stat path))
    (def buf (slurp path))
    (var i 0)
    (while (< i (length buf))
      (def key (take-varint buf i))
      (def tag (get key 0))
      (def j (get key 1))
      (def field (brshift tag 3))
      (def wt (band tag 7))
      (if (and (= field 1) (= wt 2))
        (let [pair (take-varint buf j)
              n (get pair 0)
              k (get pair 1)
              got (parse-geo-entry (string/slice buf k (+ k n)))
              code (get got 0)]
          (each row (get got 1)
            (def ip (get row 0))
            (when ip
              (if (string? ip)
                (array/push (get v6 (get (bytes ip) 0)) [ip (get row 1) code])
                (array/push (get v4 (as-int (band (brshift ip 24) 255))) [ip (get row 1) code]))))
          (set i (+ k n)))
        (set i (skip-field buf j wt)))))
  @{:v4 v4 :v6 v6})

(var geoip-memo @{:path nil :buckets nil})

(defn geoip-buckets [path]
  (when (not= (geoip-memo :path) path)
    (put geoip-memo :path path)
    (put geoip-memo :buckets (load-geoip path)))
  (geoip-memo :buckets))

(defn cidr-hit? [ip prefix network]
  (def a (int/s64 ip))
  (def b (int/s64 network))
  (if (or (<= prefix 0) (> prefix 32))
    (<= prefix 0)
    (= (brshift a (- 32 prefix)) (brshift b (- 32 prefix)))))

(defn bits-hit? [addr network prefix]
  (def ab (bytes addr))
  (def nb (bytes network))
  (cond
    (<= prefix 0) true
    (> prefix (* (length ab) 8)) false
    (do
      (var left prefix)
      (var i 0)
      (var ok true)
      (while (and ok (> left 0))
        (def take (min 8 left))
        (def mask (brshift 255 (- 8 take)))
        (when (not= (band (get ab i) mask) (band (get nb i) mask))
          (set ok false))
        (set left (- left take))
        (++ i))
      ok)))

(defn hex-group [g]
  (when (and (string? g)
             (peg/match ~(sequence (between 1 4 (choice (range "09") (range "af") (range "AF"))) -1) g))
    (scan-number (string "0x" g))))

(defn split-groups [text]
  (if (= text "")
    @[]
    (do
      (def out @[])
      (var ok true)
      (each g (string/split ":" text)
        (if (string/find "." g)
          (let [v (ipv4-int g)]
            (if v
              (do
                (array/push out (brshift (int/s64 v) 16))
                (array/push out (band (int/s64 v) 0xffff)))
              (set ok false)))
          (let [n (hex-group g)]
            (if (number? n)
              (array/push out n)
              (set ok false)))))
      (if ok out nil))))

(defn groups-to-bytes [groups]
  (def b (buffer/new 16))
  (each n groups
    (def w (int/s64 n))
    (buffer/push b (as-int (brshift w 8)) (as-int (band w 255))))
  (string b))

(defn ipv6-bytes [s]
  (when (and (string? s) (not= s "") (nil? (string/find "%" s)) (nil? (string/find "/" s)))
    (def parts (string/split "::" s))
    (when (<= (length parts) 2)
      (def left (split-groups (get parts 0)))
      (def right (if (= (length parts) 2) (split-groups (get parts 1)) @[]))
      (when (and left right)
        (def missing (- 8 (+ (length left) (length right))))
        (when (if (= (length parts) 1) (= missing 0) (>= missing 1))
          (def all @[])
          (each n left (array/push all n))
          (for _ 0 missing (array/push all 0))
          (each n right (array/push all n))
          (groups-to-bytes all))))))

(defn v4-mapped [raw]
  (def b (bytes raw))
  (var zero true)
  (var i 0)
  (while (and zero (< i 10))
    (when (not= (get b i) 0) (set zero false))
    (++ i))
  (when (and zero (= (get b 10) 255) (= (get b 11) 255))
    (string (get b 12) "." (get b 13) "." (get b 14) "." (get b 15))))

(defn geoip-lookup [path ip]
  (def data (geoip-buckets path))
  (def v4 (ipv4-int ip))
  (if v4
    (do
      (var found nil)
      (var best -1)
      (each row (get (data :v4) (as-int (band (brshift v4 24) 255)))
        (when (and (cidr-hit? v4 (get row 1) (get row 0)) (> (get row 1) best))
          (set best (get row 1))
          (set found (get row 2))))
      found)
    (let [raw (ipv6-bytes ip)
          mapped (if raw (v4-mapped raw) nil)]
      (cond
        mapped (geoip-lookup path mapped)
        raw
        (do
          (var found nil)
          (var best -1)
          (each row (get (data :v6) (get (bytes raw) 0))
            (when (and (bits-hit? raw (get row 0) (get row 1)) (> (get row 1) best))
              (set best (get row 1))
              (set found (get row 2))))
          found)
        nil))))

(defn dns-name? [host]
  (and
    (string? host)
    (peg/match ~(sequence
                  (choice (range "09") (range "AZ") (range "az"))
                  (any (choice (range "09") (range "AZ") (range "az") "-" "."))
                  -1) host)))

(defn first-ip [text]
  (var v4 nil)
  (var v6 nil)
  (each line (string/split "\n" (string/trim (string text)))
    (def ip (first (string/split " " (string/trim line))))
    (cond
      (and (nil? v4) (ipv4-int ip)) (set v4 ip)
      (and (nil? v6) (ipv6-bytes ip)) (set v6 ip)))
  (or v4 v6))

(defn dig-out [dig host qtype]
  (def res (os/execute [dig "+short" "+time=2" "+tries=1" host qtype] :p {:out :pipe :err :pipe}))
  (when (= (res :exit) 0)
    (first-ip (or (res :out) ""))))

(defn resolve-name [host]
  (when (dns-name? host)
    (def dig (os/getenv "JANUS_DIG"))
    (if dig
      (or (dig-out dig host "A") (dig-out dig host "AAAA"))
      (let [res (os/execute ["getent" "hosts" host] :p {:out :pipe :err :pipe})]
        (when (= (res :exit) 0)
          (first-ip (or (res :out) "")))))))

(defn host-text [s]
  (if (and (string? s)
           (> (length s) 2)
           (= (string/slice s 0 1) "[")
           (= (string/slice s (- (length s) 1)) "]"))
    (string/slice s 1 (- (length s) 1))
    (if (string? s) s "")))

(defn node-address [node]
  (def server (host-text (or (at node :server) "")))
  (cond
    (ipv4-int server) server
    (ipv6-bytes server) server
    (dyn :label-resolve) (resolve-name server)
    nil))

(defn name-hit? [kind pattern fold text]
  (def compiled (compile-matcher kind pattern (if (nil? fold) true fold)))
  (matcher-hit? compiled text))

(defn check-manual [defs key value]
  (def spelled (if (label-key-ok? key) nil "bad key"))
  (when spelled (die (string "janus: label " key " " spelled)))
  (def spec (get defs key))
  (unless spec (die (string "janus: label " key " has no declaration")))
  (def ty (get spec "type"))
  (cond
    (= key "protocol") (die "janus: labels.protocol fails evaluation")
    (= ty "empty")
    (unless (= value key) (die (string "janus: " key " must be the key written again")))
    (= ty "bool")
    (unless (or (true? value) (false? value)) (die (string "janus: " key " must be true or false")))
    (= ty "number")
    (unless (number? value) (die (string "janus: " key " must be a number")))
    (= ty "string")
    (unless (label-token-ok? value) (die (string "janus: " key " is not a label token")))
    (= ty "enum")
    (unless (and (label-token-ok? value) (find |(= value $) (or (get spec "values") @[])))
      (die (string "janus: " key " is not in values")))
    (= ty "region")
    (let [why (region-reason (dyn :official-regions) value)]
      (when why (die (string "janus: " key " " why))))
    (die (string "janus: " key " has no type"))))

(defn rule-sets [node rule spec official geo-path]
  (def match (or (get rule "match") @{}))
  (def kind (get match "kind"))
  (def ty (get spec "type"))
  (def name (or (tag-of node) ""))
  (cond
    (= kind "query") (die "janus: kind query is not accepted")
    (= kind "http")
    (let [key (dyn :rule-key)
          probes (or (dyn :http-probes) @{})
          row (or (get probes key) @{})]
      (when (get row name) (dyn :rule-key)))
    (= kind "geoip")
    (let [addr (node-address node)
          code (if addr (geoip-lookup geo-path addr) nil)
          countries (or (get match "countries") @[])]
      (when (and code (get official code) (or (empty? countries) (find |(= code $) countries)))
        code))
    (or (= kind "regex") (= kind "glob") (= kind "peg"))
    (when (name-hit? kind (or (get match "pattern") "") (get match "caseInsensitive") name)
      (if (= ty "empty") (dyn :rule-key) (get rule "value")))
    nil))

(defn apply-rules [node spec key official geo-path]
  (var found nil)
  (each rule (or (get spec "rules") @[])
    (when (nil? found)
      (setdyn :rule-key key)
      (set found (rule-sets node rule spec official geo-path))))
  found)

(defn node-labels [model node defs official samples geo-path]
  (def out @{})
  (def manual (or (at node :labels) @{}))
  (eachk k manual
    (check-manual defs (string k) (get manual k)))
  (put out "vendor" (vendor-of node))
  (put out "protocol" (or (at node :protocol) ""))
  (def timeout (duration-ms (get (get defs "latency") "timeout") 3000))
  (def sample (get samples (or (tag-of node) "")))
  (put out "latency" (if (number? sample) sample timeout))
  (eachk key defs
    (def name (string key))
    (unless (find |(= name $) ["vendor" "protocol" "latency"])
      (def spec (get defs key))
      (def written (get manual name))
      (def value
        (if (not (nil? written))
          written
          (apply-rules node spec name official geo-path)))
      (when (not (nil? value))
        (put out name value))))
  out)

(defn canon [v]
  (cond
    (string? v) (string "s:" v)
    (number? v) (string "n:" v)
    (true? v) "t"
    (false? v) "f"
    (nil? v) "z"
    (indexed? v) (string "l:" (string/join (sorted (map canon v)) ","))
    (dictionary? v)
    (let [ks (sorted (map string (keys v)))]
      (string "m:" (string/join (map |(string (canon $) "=" (canon (get v $))) ks) ",")))
    (string "u:" (string v))))

(defn fnv32 [s]
  (var h (int/s64 2166136261))
  (each b (bytes s)
    (set h (bxor h b))
    (set h (band (* h 16777619) (int/s64 0xffffffff))))
  h)

(defn hex8 [n]
  (string/format "%08x" (int/s64 n)))

(defn selector-tag-of [sel]
  (string "sel-" (hex8 (fnv32 (canon sel))) (hex8 (fnv32 (string "\x00" (canon sel))))))

(defn present? [labels key]
  (not (nil? (get labels key))))

(defn token-list [value]
  (cond
    (string? value) @[value]
    (indexed? value) value
    nil))

(defn match-tokens? [have items]
  (var hit false)
  (each item items
    (when (= have item) (set hit true)))
  hit)

(defn not-constraint? [constraint]
  (and
    (dictionary? constraint)
    (= (length (keys constraint)) 1)
    (not (nil? (get constraint "not")))))

(defn match-constraint? [ty key value constraint official]
  (cond
    (nil? value) false
    (not-constraint? constraint)
    (not (match-constraint? ty key value (get constraint "not") official))
    (= ty "empty") (= value key)
    (= ty "bool") (= value constraint)
    (= ty "number")
    (let [below (get constraint "below")
          above (get constraint "above")
          equal (get constraint "equal")]
      (cond
        (number? below) (< value below)
        (number? above) (> value above)
        (number? equal) (= value equal)
        false))
    (and (dictionary? constraint) (get constraint "kind"))
    (name-hit? (get constraint "kind") (or (get constraint "pattern") "") (get constraint "caseInsensitive") (string value))
    (let [items (token-list constraint)]
      (and items (match-tokens? value items)))))

(defn combinator-name? [name]
  (or (= name "any") (= name "all") (= name "not")))

(defn selector-match? [sel labels defs official]
  (def names (map string (keys sel)))
  (def combs (filter combinator-name? names))
  (cond
    (empty? names) true
    (and (not (empty? combs)) (not= (length names) 1))
    (die "janus: a selector mixes a combinator with a key constraint")
    (= (first names) "any")
    (do
      (var hit false)
      (each item (or (get sel "any") @[])
        (when (selector-match? item labels defs official) (set hit true)))
      hit)
    (= (first names) "all")
    (do
      (var hit true)
      (each item (or (get sel "all") @[])
        (when (not (selector-match? item labels defs official)) (set hit false)))
      hit)
    (= (first names) "not")
    (not (selector-match? (or (get sel "not") @{}) labels defs official))
    (do
      (var hit true)
      (each name names
        (def spec (get defs name))
        (unless spec (die (string "janus: selector names " name ", which has no declaration")))
        (def value (get labels name))
        (when (or (nil? value) (not (match-constraint? (get spec "type") name value (get sel name) official)))
          (set hit false)))
      hit)))

(defn selector-members [sel labeled defs official]
  (def out @[])
  (each row labeled
    (when (selector-match? sel (get row "labels") defs official)
      (array/push out (get row "name"))))
  (sorted out))

(defn check-selector [sel defs official]
  (def names (map string (keys sel)))
  (def combs (filter combinator-name? names))
  (cond
    (and (not (empty? combs)) (not= (length names) 1))
    (die "janus: a selector mixes a combinator with a key constraint")
    (or (= (first names) "any") (= (first names) "all"))
    (each item (or (get sel (first names)) @[])
      (check-selector item defs official))
    (= (first names) "not")
    (check-selector (or (get sel "not") @{}) defs official)
    (each name names
      (def spec (get defs name))
      (unless spec (die (string "janus: selector names " name ", which has no declaration")))
      (def constraint (get sel name))
      (def ty (get spec "type"))
      (cond
        (= ty "region")
        (let [items (token-list (if (and (dictionary? constraint) (get constraint "not")) (get constraint "not") constraint))]
          (when items
            (each item items
              (def why (region-reason official item))
              (when why (die (string "janus: region " why))))))
        (= ty "enum")
        (let [items (token-list (if (and (dictionary? constraint) (get constraint "not")) (get constraint "not") constraint))]
          (when items
            (each item items
              (unless (find |(= item $) (or (get spec "values") @[]))
                (die (string "janus: " name " is not in values"))))))
        (= ty "empty")
        (unless (= constraint name)
          (die (string "janus: " name " must be the key written again")))))))

(defn urltest-of [tag members]
  @{:type "urltest" :tag tag :outbounds members
    :url "https://www.gstatic.com/generate_204" :interval "5m" :tolerance 50})

(defn register-selector [ctx sel where]
  (check-selector sel (ctx :defs) (ctx :official))
  (def key (canon sel))
  (def cached (get (ctx :tags) key))
  (if cached
    cached
    (let [members (selector-members sel (ctx :labeled) (ctx :defs) (ctx :official))
          tag (selector-tag-of sel)]
      (if (empty? members)
        (do
          (unless (get (ctx :warned) key)
            (eprint (string "janus: " where " is empty; using direct"))
            (put (ctx :warned) key true))
          "direct")
        (do
          (put (ctx :tags) key tag)
          (array/push (ctx :sing) (urltest-of tag members))
          (array/push (ctx :xray) @{:tag tag :selector members :strategy @{:type "leastPing"}})
          (each m members (array/push (ctx :observed) m))
          tag)))))

(defn resolve-target [ctx target where]
  (cond
    (or (nil? target) (and (dictionary? target) (empty? (keys target))))
    (register-selector ctx @{} where)
    (or (= target "direct") (= target "block")) target
    (dictionary? target) (register-selector ctx target where)
    (string? target) (die (string "janus: " where " '" target "' is not direct, block, or a selector."))
    (die (string "janus: " where " is not direct, block, or a selector."))))

(defn resolve-failover [ctx entries where]
  (var chosen nil)
  (each entry entries
    (when (nil? chosen)
      (cond
        (or (= entry "direct") (= entry "block")) (set chosen entry)
        (dictionary? entry)
        (let [members (selector-members entry (ctx :labeled) (ctx :defs) (ctx :official))]
          (when (not (empty? members))
            (set chosen (register-selector ctx entry where))))
        (die (string "janus: " where " is not a selector, direct, or block.")))))
  (if chosen
    chosen
    (do
      (eprint (string "janus: " where " failover is empty; using direct"))
      "direct")))

(defn resolve-rule [ctx rule where]
  (def target (get rule "target"))
  (def labels (get rule "labels"))
  (def fail (get rule "failover"))
  (def count
    (+ (if target 1 0) (if labels 1 0) (if fail 1 0)))
  (when (not= count 1)
    (die (string "janus: " where " needs exactly one of target, labels, or failover.")))
  (cond
    target
    (if (or (= target "direct") (= target "block"))
      target
      (die (string "janus: " where " target is not direct or block.")))
    labels (resolve-target ctx labels where)
    (resolve-failover ctx fail where)))

(defn copy-rule [rule target]
  (def copy @{})
  (eachk k rule (put copy k (get rule k)))
  (put copy "target" target)
  copy)

(defn resolved-rules [ctx rules prefix]
  (def out @[])
  (var i 0)
  (each rule rules
    (array/push out (copy-rule rule (resolve-rule ctx rule (string prefix (string i)))))
    (++ i))
  out)

(defn resolve-view [ctx view]
  (def copy @{})
  (eachk k view (put copy k (get view k)))
  (def name (or (get view "name") "router"))
  (put copy "rules" (resolved-rules ctx (or (get view "rules") @[]) (string name " rule ")))
  (put copy "defaultTarget" (resolve-target ctx (or (get view "defaultTarget") (get ctx :fallback)) (string "defaultTarget " name)))
  copy)

(defn label-context [model nodes]
  (def defs (label-defs model))
  (def official (official-set model))
  (setdyn :official-regions official)
  (def samples (or (read-json-file (dyn :latency-path)) @{}))
  (setdyn :http-probes (or (read-json-file (dyn :probes-path)) @{}))
  (def geo-path (or (dyn :geoip-path) (get model "nodeGeoip")))
  (def labeled @[])
  (each node nodes
    (array/push labeled @{
      "name" (tag-of node)
      "labels" (node-labels model node defs official samples geo-path)}))
  (def ctx @{
    :defs defs
    :official official
    :labeled labeled
    :tags @{}
    :warned @{}
    :sing @[]
    :xray @[]
    :observed @[]
    :fallback (get model "defaultTarget")})
  ctx)

(defn label-document [ctx]
  (def out @{})
  (each row (ctx :labeled)
    (put out (get row "name") (get row "labels")))
  out)

(defn tcp-argv [host port timeout-ms]
  (def p (if (number? port) port (scan-number (string port))))
  (def whole (if (number? timeout-ms) (string (max 1 (div (+ timeout-ms 999) 1000))) nil))
  (when (and whole
             (string? host)
             (not= host "")
             (nil? (string/find "\n" host))
             (nil? (string/find "\0" host))
             (number? p)
             (= p (math/floor p))
             (>= p 1)
             (<= p 65535))
    ["timeout" whole "bash" "-c" "echo >/dev/tcp/\"$1\"/\"$2\"" "_" host (string (math/floor p))]))

(defn tcp-sample [host port timeout-ms]
  (def argv (tcp-argv host port timeout-ms))
  (when argv
    (def start (os/clock))
    (def res (os/execute argv :p {:out :pipe :err :pipe}))
    (when (= (res :exit) 0)
      (math/floor (* 1000 (- (os/clock) start))))))

(defn hex-token [n]
  (string/join (map |(string/format "%02x" $) (os/cryptorand n)) ""))

(defn random-port []
  (def raw (os/cryptorand 2))
  (+ 20000 (mod (+ (* (get raw 0) 256) (get raw 1)) 20000)))

(defn probe-config [engine node port user pass]
  (def env (curenv))
  (if (= engine "xray")
    (let [ob ((get env 'xray-outbound) node)]
      @{:inbounds @[@{:listen "127.0.0.1" :port port :protocol "socks"
                      :settings @{:auth "password" :accounts @[@{:user user :pass pass}] :udp false}}]
        :outbounds @[ob]})
    (let [ob ((get env 'outbound-for-node) node)]
      @{:inbounds @[@{:type "socks" :tag "in" :listen "127.0.0.1" :listen_port port
                      :users @[@{:username user :password pass}]}]
        :outbounds @[ob @{:type "direct" :tag "direct"}]
        :route @{:final (tag-of node)}})))

(defn ensure-probe-dir []
  (unless (os/stat "/var/lib/janus/engine")
    (os/mkdir "/var/lib/janus/engine"))
  (def dir "/var/lib/janus/engine/probe")
  (unless (os/stat dir) (os/mkdir dir))
  (os/chmod dir 8r700)
  dir)

(defn port-open? [port]
  (def res (os/execute ["timeout" "1" "bash" "-c" "echo >/dev/tcp/127.0.0.1/\"$1\"" "_" (string port)] :p {:out :pipe :err :pipe}))
  (= (res :exit) 0))

(defn proc-running? [proc]
  (def path (string "/proc/" (proc :pid) "/stat"))
  (if (not (os/stat path))
    false
    (let [text (slurp path)
          close (string/find ")" text)]
      (and close (not= (string/slice text (+ close 2) (+ close 3)) "Z")))))

(defn stop-proc [proc]
  (try (os/proc-kill proc) ([_] nil))
  (try (os/proc-wait proc) ([_] nil)))

(defn wait-port [port proc]
  (var i 0)
  (var open false)
  (while (< i 30)
    (unless (proc-running? proc) (break))
    (when (port-open? port) (set open true) (break))
    (os/sleep 0.1)
    (++ i))
  (and open (proc-running? proc)))

(defn http-status [engine node url timeout-ms port]
  (def dir (ensure-probe-dir))
  (def path (string dir "/" port ".json"))
  (def user (hex-token 9))
  (def pass (hex-token 9))
  (defer (when (os/stat path) (os/rm path))
    (spit path (json-encode (probe-config engine node port user pass)))
    (os/chmod path 8r600)
    (def args (if (= engine "xray") @["xray" "run" "-c" path] @["sing-box" "run" "-c" path]))
    (def proc (os/spawn args :p {:out :pipe :err :pipe}))
    (defer (stop-proc proc)
      (when (wait-port port proc)
        (def sec (string (max 1 (div (+ timeout-ms 999) 1000))))
        (def res (os/execute ["curl" "-sS" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" sec
                              "-x" (string "socks5h://" user ":" pass "@127.0.0.1:" port) url]
                             :p {:out :pipe :err :pipe}))
        (scan-number (string/trim (string (or (res :out) ""))))))))

(defn constrained-keys [value into]
  (cond
    (dictionary? value)
    (let [names (map string (keys value))]
      (cond
        (or (= (first names) "any") (= (first names) "all"))
        (each item (or (get value (first names)) @[]) (constrained-keys item into))
        (= (first names) "not")
        (constrained-keys (get value "not") into)
        (each name names
          (unless (find |(= name $) ["any" "all" "not"])
            (put into name true)))))
    (indexed? value)
    (each item value (constrained-keys item into))))

(defn model-constrained [model]
  (def into @{})
  (constrained-keys (get model "defaultTarget") into)
  (defn walk [rules]
    (each rule rules
      (constrained-keys (get rule "labels") into)
      (each entry (or (get rule "failover") @[])
        (when (dictionary? entry) (constrained-keys entry into)))))
  (walk (or (get model "rules") @[]))
  (each view (or (get model "lans") @[])
    (constrained-keys (get view "defaultTarget") into)
    (walk (or (get view "rules") @[])))
  into)

(defn node-name-set [nodes]
  (def names @{})
  (each node nodes (put names (tag-of node) true))
  names)

(defn keep-current [prev names]
  (def out @{})
  (when (dictionary? prev)
    (eachk k prev
      (def name (string k))
      (when (get names name)
        (put out name (get prev k)))))
  out)

(defn stamp-due? [prev now-s interval-ms]
  (or (not (number? prev))
      (>= (* (- now-s prev) 1000) interval-ms)))

(defn sibling-path [path name]
  (var slash -1)
  (var i 0)
  (each c path
    (when (= c "/") (set slash i))
    (++ i))
  (string (string/slice path 0 (+ slash 1)) name))

(defn spit-atomic [path text]
  (def tmp (string path ".tmp"))
  (spit tmp text)
  (os/chmod tmp 8r600)
  (os/rename tmp path))

(defn run-probes [model nodes engine latency-path probes-path]
  (def defs (label-defs model))
  (def want (model-constrained model))
  (def names (node-name-set nodes))
  (def stamp-path (sibling-path latency-path "probe-stamp.json"))
  (def stamps (or (read-json-file stamp-path) @{}))
  (def http-stamps (if (dictionary? (get stamps "http")) (get stamps "http") @{}))
  (def now (os/time))
  (def prev-lat (or (read-json-file latency-path) @{}))
  (def latency (keep-current prev-lat names))
  (when (and (get want "latency")
             (stamp-due? (get stamps "latency") now (duration-ms (get (get defs "latency") "interval") 300000)))
    (def timeout (duration-ms (get (get defs "latency") "timeout") 3000))
    (each node nodes
      (def name (tag-of node))
      (def sample (tcp-sample (or (at node :server) "") (or (at node :port) 0) timeout))
      (when (number? sample) (put latency name sample)))
    (put stamps "latency" now))
  (def prev-http (or (read-json-file probes-path) @{}))
  (def probes @{})
  (var port (random-port))
  (eachk key defs
    (def name (string key))
    (def spec (get defs key))
    (def rules (or (get spec "rules") @[]))
    (when (and (get want name) (= (length rules) 1) (= (get (get (get rules 0) "match") "kind") "http"))
      (def match (get (get rules 0) "match"))
      (def row (keep-current (get prev-http name) names))
      (def interval (duration-ms (get match "interval") 3600000))
      (when (stamp-due? (get http-stamps name) now interval)
        (def url (get match "url"))
        (def timeout (duration-ms (get match "timeout") 5000))
        (each node nodes
          (def status (http-status engine node url timeout port))
          (set port (+ 20000 (mod (+ (- port 20000) 1) 20000)))
          (when (number? status)
            (put row (tag-of node) (and (>= status 200) (<= status 299)))))
        (put http-stamps name now))
      (put probes name row)))
  (put stamps "http" http-stamps)
  (spit-atomic latency-path (json-encode latency))
  (spit-atomic probes-path (json-encode probes))
  (spit-atomic stamp-path (json-encode stamps)))

(defn label-expect [ok msg]
  (unless ok (die (string "janus: label-check " msg))))

(defn unhex [s]
  (def b (buffer/new (div (length s) 2)))
  (var i 0)
  (while (< i (length s))
    (buffer/push b (scan-number (string "0x" (string/slice s i (+ i 2)))))
    (set i (+ i 2)))
  b)

(defn pb-varint [n]
  (def b @"")
  (var x n)
  (while true
    (def byte (band x 127))
    (set x (brshift x 7))
    (if (> x 0)
      (buffer/push b (bor byte 128))
      (do (buffer/push b byte) (break))))
  b)

(defn pb-cat [& parts]
  (def b @"")
  (each p parts (buffer/push-string b (string p)))
  b)

(defn pb-ld [field payload]
  (pb-cat (pb-varint (bor (blshift field 3) 2)) (pb-varint (length payload)) payload))

(defn pb-var [field n]
  (pb-cat (pb-varint (blshift field 3)) (pb-varint n)))

(defn label-self-check []
  (def argv (tcp-argv "127.0.0.1;id" 443 1000))
  (label-expect (= (get argv 4) "echo >/dev/tcp/\"$1\"/\"$2\"") "tcp script stays a template")
  (label-expect (= (get argv 6) "127.0.0.1;id") "tcp host is one argument")
  (label-expect (nil? (tcp-argv "h" 0 1000)) "port 0 is rejected")
  (label-expect (nil? (tcp-argv "h" 70000 1000)) "port above 65535 is rejected")
  (def kept (keep-current @{"stay" 40 "gone" 5} @{"stay" true}))
  (label-expect (and (= (get kept "stay") 40) (nil? (get kept "gone"))) "departed latency is dropped")
  (label-expect (stamp-due? nil 1000 5000) "missing stamp is due")
  (label-expect (not (stamp-due? 1000 1000 5000)) "fresh stamp waits")
  (label-expect (stamp-due? 990 1000 5000) "old stamp is due")
  (label-expect (match-constraint? "bool" "flag" false @{"not" true} @{}) "present false matches not true")
  (label-expect (not (match-constraint? "bool" "flag" true @{"not" true} @{})) "present true fails not true")
  (label-expect (not (match-constraint? "bool" "flag" nil @{"not" true} @{})) "absent bool fails a key not")
  (label-expect (not (match-constraint? "number" "latency" 50 @{"not" @{"below" 100}} @{})) "number not inverts below")
  (def addr (ipv6-bytes "2001:db8::1"))
  (label-expect (= (host-text "[2001:db8::1]") "2001:db8::1") "brackets strip")
  (label-expect (and addr (= (length addr) 16) (= (get (bytes addr) 0) 0x20) (= (get (bytes addr) 1) 0x01)) "ipv6 parses")
  (label-expect (nil? (ipv6-bytes "gg")) "bad ipv6 is rejected")
  (label-expect (bits-hit? (ipv6-bytes "2001:db8::1") (ipv6-bytes "2001:db8::") 32) "ipv6 prefix hits")
  (label-expect (not (bits-hit? (ipv6-bytes "2001:db9::1") (ipv6-bytes "2001:db8::") 32)) "ipv6 prefix misses")
  (def v4-path (string "/tmp/janus-label-v4-" (os/time) ".dat"))
  (def v6-path (string "/tmp/janus-label-v6-" (os/time) ".dat"))
  (spit v4-path (unhex "0a0e0a026a7012080a04cb0071001018"))
  (def v6-ip (ipv6-bytes "2001:db8::"))
  (def cidr (pb-cat (pb-ld 1 v6-ip) (pb-var 2 32)))
  (def entry (pb-cat (pb-ld 1 "jp") (pb-ld 2 cidr)))
  (spit v6-path (pb-ld 1 entry))
  (label-expect (= (geoip-lookup v4-path "203.0.113.10") "jp") "ipv4 geoip")
  (label-expect (nil? (geoip-lookup v4-path "198.51.100.8")) "ipv4 miss")
  (label-expect (= (geoip-lookup v4-path "::ffff:203.0.113.10") "jp") "v4-mapped geoip")
  (label-expect (= (geoip-lookup v6-path "2001:db8::1") "jp") "ipv6 geoip")
  (label-expect (nil? (geoip-lookup v6-path "2001:db9::1")) "ipv6 miss")
  (os/rm v4-path)
  (os/rm v6-path)
  (print "ok"))
