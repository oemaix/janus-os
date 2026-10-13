# SPDX-License-Identifier: Apache-2.0
# Node normalizer, matchers, and the sing-box renderer.
# docs/07, ADR-0008. One program at build time and on the router.

(defn distinct [xs]
  (def seen @{})
  (def out @[])
  (each x xs
    (unless (in seen x)
      (put seen x true)
      (array/push out x)))
  out)

(defn die [msg]
  (eprint msg)
  (os/exit 1))

(defn bytes [s]
  (def out @[])
  (for i 0 (length s) (array/push out (s i)))
  out)

(defn from-bytes [bs]
  (string/from-bytes ;bs))

(def b64tab "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defn b64-val [c]
  (def i (string/find (string/from-bytes c) b64tab))
  (if i i -1))

(defn b64-decode [text]
  (def clean
    (string/replace-all "=" ""
      (string/replace-all "_" "/"
        (string/replace-all "-" "+"
          (string/replace-all "\n" "" (string/replace-all "\r" "" text))))))
  (def out @[])
  (var acc 0)
  (var bits 0)
  (each c (bytes clean)
    (def v (b64-val c))
    (when (>= v 0)
      (set acc (+ (* acc 64) v))
      (set bits (+ bits 6))
      (when (>= bits 8)
        (set bits (- bits 8))
        (var shifted acc)
        (for k 0 bits (set shifted (div shifted 2)))
        (array/push out (mod shifted 256))
        (var mask 1)
        (for k 0 bits (set mask (* mask 2)))
        (set acc (mod acc mask)))))
  (from-bytes out))

(var json-src "")
(var json-i 0)

(defn j-peek []
  (if (< json-i (length json-src)) (json-src json-i) -1))

(defn j-bump []
  (def c (j-peek))
  (++ json-i)
  c)

(defn j-skip []
  (while (find |(= (j-peek) $) [32 10 13 9]) (j-bump)))

(defn j-hex [n]
  (var v 0)
  (for k 0 n
    (def c (j-bump))
    (def d
      (cond
        (and (>= c 48) (<= c 57)) (- c 48)
        (and (>= c 97) (<= c 102)) (+ 10 (- c 97))
        (and (>= c 65) (<= c 70)) (+ 10 (- c 65))
        (die "bad json hex")))
    (set v (+ (* v 16) d)))
  v)

(defn utf8 [cp]
  (cond
    (< cp 0x80) (string/from-bytes cp)
    (< cp 0x800) (string/from-bytes (bor 0xc0 (brshift cp 6)) (bor 0x80 (band cp 0x3f)))
    (< cp 0x10000) (string/from-bytes (bor 0xe0 (brshift cp 12)) (bor 0x80 (band (brshift cp 6) 0x3f)) (bor 0x80 (band cp 0x3f)))
    (string/from-bytes (bor 0xf0 (brshift cp 18)) (bor 0x80 (band (brshift cp 12) 0x3f)) (bor 0x80 (band (brshift cp 6) 0x3f)) (bor 0x80 (band cp 0x3f)))))

(defn j-string []
  (when (not= (j-bump) 34) (die "json string"))
  (def out @"")
  (while true
    (def c (j-bump))
    (cond
      (= c 34) (break)
      (= c -1) (die "unterminated json string")
      (= c 92)
      (let [e (j-bump)]
        (buffer/push out
          (case e
            34 "\""
            92 "\\"
            47 "/"
            98 "\b"
            102 "\f"
            110 "\n"
            114 "\r"
            116 "\t"
            117 (utf8 (j-hex 4))
            (die "bad json escape"))))
      (buffer/push out (string/from-bytes c))))
  (string out))

(defn j-number []
  (def start json-i)
  (while (find |(= (j-peek) $) [45 43 46 101 69]) (j-bump))
  (while (and (>= (j-peek) 48) (<= (j-peek) 57)) (j-bump))
  (scan-number (string/slice json-src start json-i)))

(var j-value nil)

(defn j-array []
  (j-bump)
  (def out @[])
  (while true
    (j-skip)
    (cond
      (= (j-peek) 93) (do (j-bump) (break))
      (= (j-peek) 44) (j-bump)
      (array/push out (j-value))))
  out)

(defn j-object []
  (j-bump)
  (def out @{})
  (while true
    (j-skip)
    (cond
      (= (j-peek) 125) (do (j-bump) (break))
      (= (j-peek) 44) (j-bump)
      (do
        (j-skip)
        (def k (j-string))
        (j-skip)
        (when (not= (j-bump) 58) (die "json colon"))
        (put out k (j-value)))))
  out)

(set j-value
  (fn []
    (j-skip)
    (def c (j-peek))
    (cond
      (= c 110) (do (set json-i (+ json-i 4)) nil)
      (= c 116) (do (set json-i (+ json-i 4)) true)
      (= c 102) (do (set json-i (+ json-i 5)) false)
      (= c 34) (j-string)
      (= c 91) (j-array)
      (= c 123) (j-object)
      (or (= c 45) (and (>= c 48) (<= c 57))) (j-number)
      (die (string "bad json at " json-i)))))

(defn json-decode [text]
  (set json-src text)
  (set json-i 0)
  (def v (j-value))
  (j-skip)
  (when (< json-i (length json-src)) (die "trailing json"))
  v)

(defn json-escape [s]
  (def out @"")
  (each c (bytes s)
    (cond
      (= c 34) (buffer/push out "\\\"")
      (= c 92) (buffer/push out "\\\\")
      (= c 10) (buffer/push out "\\n")
      (= c 13) (buffer/push out "\\r")
      (= c 9) (buffer/push out "\\t")
      (< c 32) (buffer/push out (string/format "\\u%04x" c))
      (buffer/push out (string/from-bytes c))))
  (string out))

(defn json-encode [x]
  (cond
    (nil? x) "null"
    (true? x) "true"
    (false? x) "false"
    (number? x)
    (if (= x (math/floor x)) (string (math/floor x)) (string x))
    (keyword? x) (json-encode (string x))
    (bytes? x) (string "\"" (json-escape x) "\"")
    (indexed? x) (string "[" (string/join (map json-encode x) ",") "]")
    (dictionary? x)
    (string "{"
      (string/join
        (seq [k :keys x] (string (json-encode k) ":" (json-encode (get x k))))
        ",")
      "}")
    (die "cannot encode json")))

(defn read-all [path]
  (if (= path "-")
    (string (file/read stdin :all))
    (slurp path)))

(defn write-out [path text]
  (if (= path "-")
    (print text)
    (spit path text)))

(defn pct-decode [s]
  (def out @"")
  (var i 0)
  (while (< i (length s))
    (if (and (= (s i) 37) (< (+ i 2) (length s)))
      (do
        (buffer/push out (string/from-bytes (scan-number (string "0x" (string/slice s (+ i 1) (+ i 3))))))
        (set i (+ i 3)))
      (do
        (buffer/push out (if (= (s i) 43) " " (string/from-bytes (s i))))
        (++ i))))
  (string out))

(defn query-parse [q]
  (def out @{})
  (when (and q (not= q ""))
    (each part (string/split "&" q)
      (def pair (string/split "=" part))
      (put out (pct-decode (get pair 0)) (pct-decode (or (get pair 1) "")))))
  out)

(defn blank-node [name protocol]
  @{
    :name name
    :protocol protocol
    :server ""
    :port 0
    :tags @[]
    :tls @{:enable false :serverName nil :alpn @[] :utls nil :insecure false
           :reality @{:publicKey nil :shortId nil}}
    :transport @{:type nil :path nil :host nil :serviceName nil}
    :vmess @{:uuid nil :security nil :alterId 0}
    :vless @{:uuid nil :flow nil}
    :trojan @{:password nil}
    :shadowsocks @{:method nil :password nil :plugin @{:name nil :options nil}}
    :hysteria2 @{:password nil :up nil :down nil :obfs nil}
    :tuic @{:uuid nil :password nil :congestion nil}})

(defn apply-transport [node q]
  (def typ (or (get q "type") (get q "net")))
  (when (and typ (not= typ "") (not= typ "tcp"))
    (put-in node [:transport :type] typ)
    (put-in node [:transport :path] (or (get q "path") nil))
    (put-in node [:transport :host] (or (get q "host") nil))
    (put-in node [:transport :serviceName] (or (get q "serviceName") nil))))

(defn apply-tls [node q]
  (def sec (or (get q "security") (get q "tls") ""))
  (when (or (= sec "tls") (= sec "reality") (= (get q "tls") "tls"))
    (put-in node [:tls :enable] true)
    (put-in node [:tls :serverName] (or (get q "sni") (get q "peer") nil))
    (put-in node [:tls :utls] (or (get q "fp") nil))
    (put-in node [:tls :insecure] (or (= (get q "allowInsecure") "1") (= (get q "insecure") "1")))
    (when (= sec "reality")
      (put-in node [:tls :reality :publicKey] (or (get q "pbk") nil))
      (put-in node [:tls :reality :shortId] (or (get q "sid") nil)))))

(defn parse-url-node [line]
  (def hash-at (string/find "#" line))
  (def name
    (if hash-at (pct-decode (string/slice line (+ hash-at 1))) "node"))
  (def body (if hash-at (string/slice line 0 hash-at) line))
  (def scheme-at (string/find "://" body))
  (if (not scheme-at)
    nil
    (do
  (def scheme (string/slice body 0 scheme-at))
  (def rest (string/slice body (+ scheme-at 3)))
  (def q-at (string/find "?" rest))
  (def authority (if q-at (string/slice rest 0 q-at) rest))
  (def q (query-parse (if q-at (string/slice rest (+ q-at 1)) "")))
  (def at (string/find "@" authority))
  (def user (if at (pct-decode (string/slice authority 0 at)) ""))
  (def hostport (if at (string/slice authority (+ at 1)) authority))
  (def colon (string/find ":" hostport))
  (def host (if colon (string/slice hostport 0 colon) hostport))
  (def port (if colon (scan-number (string/slice hostport (+ colon 1))) 443))
  (def node (blank-node name scheme))
  (put node :server host)
  (put node :port port)
  (apply-transport node q)
  (apply-tls node q)
  (case scheme
    "vless" (do (put-in node [:vless :uuid] user) (put-in node [:vless :flow] (or (get q "flow") nil)))
    "trojan" (put-in node [:trojan :password] user)
    "hy2" (do (put node :protocol "hysteria2") (put-in node [:hysteria2 :password] user))
    "hysteria2" (put-in node [:hysteria2 :password] user)
    "tuic"
    (let [pair (string/split ":" user)]
      (put-in node [:tuic :uuid] (get pair 0))
      (put-in node [:tuic :password] (or (get pair 1) nil))
      (put-in node [:tuic :congestion] (or (get q "congestion_control") nil)))
    "ss"
    (let [decoded (if (string/find "@" user) user (b64-decode user))
          pair (string/split ":" decoded)]
      (put-in node [:shadowsocks :method] (get pair 0))
      (put-in node [:shadowsocks :password] (get pair 1))
      (put-in node [:shadowsocks :plugin :name] (or (get q "plugin") nil)))
    nil)
  node)))

(defn parse-vmess [line]
  (def raw (b64-decode (string/slice line 8)))
  (def obj (json-decode raw))
  (def node (blank-node (or (get obj "ps") "vmess") "vmess"))
  (put node :server (or (get obj "add") ""))
  (put node :port (scan-number (string (or (get obj "port") "0"))))
  (put-in node [:vmess :uuid] (get obj "id"))
  (put-in node [:vmess :security] (or (get obj "scy") "auto"))
  (put-in node [:vmess :alterId] (scan-number (string (or (get obj "aid") "0"))))
  (def net (get obj "net"))
  (when (and net (not= net "tcp"))
    (put-in node [:transport :type] net)
    (put-in node [:transport :path] (or (get obj "path") nil))
    (put-in node [:transport :host] (or (get obj "host") nil)))
  (when (or (= (get obj "tls") "tls") (= (get obj "tls") "reality"))
    (put-in node [:tls :enable] true)
    (put-in node [:tls :serverName] (or (get obj "sni") nil)))
  node)

(defn parse-share [text]
  (def out @[])
  (each line (string/split "\n" text)
    (def item (string/trim line))
    (when (and (not= item "") (not (string/has-prefix? "#" item)))
      (def node
        (cond
          (string/has-prefix? "vmess://" item) (parse-vmess item)
          (string/find "://" item) (parse-url-node item)
          nil))
      (when node (array/push out node))))
  out)

(defn clash-scalar [text]
  (def t (string/trim text))
  (cond
    (or (= t "null") (= t "~") (= t "")) nil
    (or (= t "true") (= t "yes")) true
    (or (= t "false") (= t "no")) false
    (scan-number t) (scan-number t)
    (and (string/has-prefix? "\"" t) (string/has-suffix? "\"" t)) (string/slice t 1 -1)
    (and (string/has-prefix? "'" t) (string/has-suffix? "'" t)) (string/slice t 1 -1)
    t))

(defn clash-map [body]
  (def out @{})
  (var cur @"")
  (var depth 0)
  (var quote 0)
  (each c (bytes body)
    (cond
      (or (= c 34) (= c 39)) (set quote (if (= quote 0) c (if (= quote c) 0 quote)))
      (and (= quote 0) (= c 123)) (++ depth)
      (and (= quote 0) (= c 125)) (-- depth)
      (and (= quote 0) (= c 44) (= depth 0))
      (do
        (def pair (string/split ":" (string cur) 0 2))
        (when (>= (length pair) 2)
          (put out (string/trim (get pair 0)) (clash-scalar (get pair 1))))
        (set cur @""))
      (buffer/push cur (string/from-bytes c))))
  (def pair (string/split ":" (string cur) 0 2))
  (when (>= (length pair) 2)
    (put out (string/trim (get pair 0)) (clash-scalar (get pair 1))))
  out)

(defn node-from-clash [item]
  (def typ (string (or (get item "type") "")))
  (def protocol
    (case typ
      "ss" "shadowsocks"
      "hysteria2" "hysteria2"
      typ))
  (if (not (find |(= protocol $) ["vmess" "vless" "trojan" "shadowsocks" "hysteria2" "tuic"]))
    nil
    (do
  (def node (blank-node (string (or (get item "name") "node")) protocol))
  (put node :server (string (or (get item "server") "")))
  (put node :port (or (get item "port") 0))
  (case protocol
    "vmess"
    (do
      (put-in node [:vmess :uuid] (get item "uuid"))
      (put-in node [:vmess :security] (or (get item "cipher") "auto"))
      (put-in node [:vmess :alterId] (or (get item "alterId") 0)))
    "vless"
    (do
      (put-in node [:vless :uuid] (get item "uuid"))
      (put-in node [:vless :flow] (get item "flow")))
    "trojan" (put-in node [:trojan :password] (get item "password"))
    "shadowsocks"
    (do
      (put-in node [:shadowsocks :method] (get item "cipher"))
      (put-in node [:shadowsocks :password] (get item "password")))
    "hysteria2" (put-in node [:hysteria2 :password] (get item "password"))
    "tuic"
    (do
      (put-in node [:tuic :uuid] (get item "uuid"))
      (put-in node [:tuic :password] (get item "password"))))
  (when (or (get item "tls") (= (get item "security") "tls"))
    (put-in node [:tls :enable] true)
    (put-in node [:tls :serverName] (or (get item "sni") (get item "servername") nil)))
  node)))

(defn parse-clash [text]
  (def out @[])
  (each line (string/split "\n" text)
    (def t (string/trim line))
    (when (string/has-prefix? "- {" t)
      (def body (string/slice t 3 (if (string/has-suffix? "}" t) -1 (length t))))
      (def node (node-from-clash (clash-map body)))
      (when node (array/push out node))))
  out)

(defn parse-sing-box [text]
  (def obj (json-decode text))
  (def list (or (get obj "outbounds") (if (indexed? obj) obj @[])))
  (def out @[])
  (each item list
    (def typ (get item "type"))
    (when (find |(= typ $) ["vmess" "vless" "trojan" "shadowsocks" "hysteria2" "tuic"])
      (def node (blank-node (or (get item "tag") typ) typ))
      (put node :server (or (get item "server") ""))
      (put node :port (or (get item "server_port") 0))
      (case typ
        "vmess"
        (do
          (put-in node [:vmess :uuid] (get item "uuid"))
          (put-in node [:vmess :security] (or (get item "security") "auto"))
          (put-in node [:vmess :alterId] (or (get item "alter_id") 0)))
        "vless"
        (do
          (put-in node [:vless :uuid] (get item "uuid"))
          (put-in node [:vless :flow] (get item "flow")))
        "trojan" (put-in node [:trojan :password] (get item "password"))
        "shadowsocks"
        (do
          (put-in node [:shadowsocks :method] (get item "method"))
          (put-in node [:shadowsocks :password] (get item "password")))
        "hysteria2" (put-in node [:hysteria2 :password] (get item "password"))
        "tuic"
        (do
          (put-in node [:tuic :uuid] (get item "uuid"))
          (put-in node [:tuic :password] (get item "password"))))
      (def tls (get item "tls"))
      (when (and tls (get tls "enabled"))
        (put-in node [:tls :enable] true)
        (put-in node [:tls :serverName] (get tls "server_name"))
        (put-in node [:tls :insecure] (get tls "insecure"))
        (def reality (get tls "reality"))
        (when reality
          (put-in node [:tls :reality :publicKey] (get reality "public_key"))
          (put-in node [:tls :reality :shortId] (get reality "short_id"))))
      (array/push out node)))
  out)

(defn detect-format [text format]
  (if (not= format "auto")
    format
    (cond
      (string/has-prefix? "{" (string/trim text)) "sing-box"
      (string/find "proxies:" text) "clash"
      "share-links")))

(defn normalize [text format]
  (def kind (detect-format text format))
  (case kind
    "share-links"
    (let [body (string/trim text)
          decoded (if (string/find "://" body) body (b64-decode body))]
      (parse-share decoded))
    "clash" (parse-clash text)
    "sing-box" (parse-sing-box text)
    (die (string "unknown format " kind))))

(defn lower-text [s]
  (string/ascii-lower s))

(defn glob-to-peg [pattern]
  (def out @["(* "])
  (var i 0)
  (while (< i (length pattern))
    (def c (pattern i))
    (cond
      (= c (chr "*")) (array/push out "(any 1) ")
      (= c (chr "?")) (array/push out "1 ")
      (= c (chr "{"))
      (let [end (string/find "}" pattern i)]
        (when (not end) (die "unterminated glob brace"))
        (def alts (string/split "," (string/slice pattern (+ i 1) end)))
        (array/push out "(+ ")
        (each alt alts (array/push out (string "\"" alt "\" ")))
        (array/push out ") ")
        (set i end))
      (= c (chr "\\"))
      (do
        (++ i)
        (array/push out (string "\"" (string/from-bytes (pattern i)) "\" ")))
      (array/push out (string "\"" (string/from-bytes c) "\" ")))
    (++ i))
  (array/push out "-1)")
  (string ;out))

(defn regex-to-peg [pattern]
  # Literals, ., *, +, ?, |, (), [], and escapes. Enough for the region patterns.
  (var i 0)
  (var atom nil)
  (var read-seq nil)
  (set atom
    (fn []
      (def c (pattern i))
      (++ i)
      (cond
        (= c (chr ".")) "(any 1)"
        (= c (chr "("))
        (do
          (when (and (< (+ i 2) (length pattern)) (= (string/slice pattern i (+ i 3)) "?i)"))
            (set i (+ i 3)))
          (def inner (read-seq))
          (def alts @[inner])
          (while (and (< i (length pattern)) (= (pattern i) (chr "|")))
            (++ i)
            (array/push alts (read-seq)))
          (when (or (>= i (length pattern)) (not= (pattern i) (chr ")")))
            (die "unterminated regex group"))
          (++ i)
          (string "(+ " (string/join alts " ") ")"))
        (= c (chr "["))
        (do
          (def neg (= (pattern i) (chr "^")))
          (when neg (++ i))
          (def chars @"")
          (while (and (< i (length pattern)) (not= (pattern i) (chr "]")))
            (buffer/push chars (string/from-bytes (pattern i)))
            (++ i))
          (++ i)
          (string "(" (if neg "if-not" "if") " (set \"" (string chars) "\") 1)"))
        (= c (chr "\\"))
        (do
          (def e (pattern i))
          (++ i)
          (if (= e (chr "b"))
            "(if-not (set \"abcdefghijklmnopqrstuvwxyz0123456789_\") 1)"
            (string "\"" (string/from-bytes e) "\"")))
        (string "\"" (string/from-bytes c) "\""))))
  (set read-seq
    (fn []
      (def parts @[])
      (while (and (< i (length pattern)) (not (find |(= (pattern i) $) [(chr ")") (chr "|")])))
        (def a (atom))
        (def op (if (< i (length pattern)) (pattern i) 0))
        (cond
          (= op (chr "*")) (do (++ i) (array/push parts (string "(any " a ")")))
          (= op (chr "+")) (do (++ i) (array/push parts (string "(some " a ")")))
          (= op (chr "?")) (do (++ i) (array/push parts (string "(opt " a ")")))
          (array/push parts a)))
      (string "(* " (string/join parts " ") ")")))
  (def alts @[(read-seq)])
  (while (and (< i (length pattern)) (= (pattern i) (chr "|")))
    (++ i)
    (array/push alts (read-seq)))
  (string "(+ " (string/join alts " ") ")"))

(defn compile-matcher [kind pattern case-insensitive]
  (def raw (if (string/has-prefix? "(?i)" pattern) (string/slice pattern 4) pattern))
  (def folded (if case-insensitive (lower-text raw) raw))
  (def inner
    (case kind
      "glob" (glob-to-peg folded)
      "regex" (regex-to-peg folded)
      "peg" (string "(* " pattern " -1)")
      (die (string "unknown matcher " kind))))
  (def peg-src
    (if (= kind "regex")
      (string "(* (any (if-not " inner " 1)) " inner ")")
      inner))
  (def peg (peg/compile (parse peg-src)))
  (unless peg (die (string "bad " kind " pattern: " pattern)))
  {:peg peg :fold case-insensitive :kind kind})

(defn matcher-hit? [compiled text]
  (def sample (if (get compiled :fold) (lower-text text) text))
  (def padded
    (if (= (get compiled :kind) "regex")
      (string " " sample " ")
      sample))
  (not (nil? (peg/match (get compiled :peg) padded))))

(defn name-ok? [node filter]
  (if (nil? filter)
    true
    (matcher-hit? filter (or (get node "name") (get node :name)))))

(defn at [t k]
  (when t
    (def s (if (keyword? k) (string k) k))
    (def a (get t s))
    (if (not (nil? a)) a (get t (keyword s)))))

(defn at-in [t ks]
  (var cur t)
  (each k ks (set cur (if cur (at cur k) nil)))
  cur)

(defn tag-of [node] (at node :name))

(defn members-of [model nodes group-name]
  (def groups (or (get model "groups") @{}))
  (def group (or (get groups group-name) @{}))
  (def match (or (get group "match") @{}))
  (def kind (get match "kind"))
  (def fold
    (if (nil? (get match "caseInsensitive")) true (get match "caseInsensitive")))
  (def compiled
    (when kind
      (compile-matcher kind (get match "pattern") fold)))
  (def scope (or (get group "fromSubscriptions") @[]))
  (def found @[])
  (when compiled
    (each node nodes
      (def tag (tag-of node))
      (def sub (if tag (first (string/split "/" tag)) ""))
      (when (and (or (empty? scope) (find |(= sub $) scope)) (matcher-hit? compiled tag))
        (array/push found tag))))
  (each ref (or (get group "members") @[])
    (cond
      (string/has-prefix? "node:" ref) (array/push found (string/slice ref 5))
      (string/has-prefix? "group:" ref) (array/push found (string/slice ref 6))
      (string/has-prefix? "sub:" ref) (array/push found ref)
      (array/push found ref)))
  (distinct found))

(defn outbound-for-node [node]
  (def tag (tag-of node))
  (def base @{:type (at node :protocol) :tag tag :server (at node :server) :server_port (at node :port) :routing_mark 74})
  (when (at-in node [:tls :enable])
    (def tls @{:enabled true :server_name (at-in node [:tls :serverName]) :insecure (at-in node [:tls :insecure])})
    (when (at-in node [:tls :utls])
      (put tls :utls @{:enabled true :fingerprint (at-in node [:tls :utls])}))
    (when (at-in node [:tls :reality :publicKey])
      (put tls :reality @{:enabled true :public_key (at-in node [:tls :reality :publicKey]) :short_id (at-in node [:tls :reality :shortId])}))
    (put base :tls tls))
  (def transport (at-in node [:transport :type]))
  (when transport
    (put base :transport @{:type transport :path (at-in node [:transport :path]) :host (at-in node [:transport :host]) :service_name (at-in node [:transport :serviceName])}))
  (case (at node :protocol)
    "vmess"
    (do
      (put base :uuid (at-in node [:vmess :uuid]))
      (put base :security (or (at-in node [:vmess :security]) "auto"))
      (put base :alter_id (or (at-in node [:vmess :alterId]) 0)))
    "vless"
    (do
      (put base :uuid (at-in node [:vless :uuid]))
      (when (at-in node [:vless :flow]) (put base :flow (at-in node [:vless :flow]))))
    "trojan" (put base :password (at-in node [:trojan :password]))
    "shadowsocks"
    (do
      (put base :method (at-in node [:shadowsocks :method]))
      (put base :password (at-in node [:shadowsocks :password])))
    "hysteria2" (put base :password (at-in node [:hysteria2 :password]))
    "tuic"
    (do
      (put base :uuid (at-in node [:tuic :uuid]))
      (put base :password (at-in node [:tuic :password]))))
  base)

(defn strategy-type [strategy]
  (case strategy
    "manual" "selector"
    "url-test" "urltest"
    (die (string "sing-box cannot express group strategy " strategy))))

(defn group-outbound [model nodes name]
  (def groups (or (get model "groups") @{}))
  (def group (or (get groups name) @{}))
  (def strategy (or (get group "strategy") "url-test"))
  (var mem (members-of model nodes name))
  (when (empty? mem)
    (eprint (string "janus: group " name " is empty; using " (or (get group "emptyFallback") "direct")))
    (def fb (or (get group "emptyFallback") "direct"))
    (set mem @[(if (string/has-prefix? "group:" fb) (string/slice fb 6) "direct")]))
  (def ob @{:type (strategy-type strategy) :tag name :outbounds mem})
  (when (= strategy "manual")
    (put ob :default (or (get group "default") (first mem))))
  (def test (or (get group "test") @{}))
  (when (= strategy "url-test")
    (put ob :url (or (get test "url") "https://www.gstatic.com/generate_204"))
    (put ob :interval (or (get test "interval") "5m"))
    (put ob :tolerance (or (get test "tolerance") 50)))
  ob)

(defn dns-server [tag url via]
  (cond
    (string/has-prefix? "https://" url)
    (let [rest (string/slice url 8)
          slash (string/find "/" rest)
          host (if slash (string/slice rest 0 slash) rest)
          path (if slash (string/slice rest slash) "/dns-query")]
      @{:type "https" :tag tag :server host :path path :domain_resolver "bootstrap"})
    (string/has-prefix? "tls://" url)
    @{:type "tls" :tag tag :server (string/slice url 6) :domain_resolver "bootstrap"}
    (string/has-prefix? "udp://" url)
    @{:type "udp" :tag tag :server (string/slice url 6)}
    @{:type "udp" :tag tag :server url}))

(defn rule-outbound [target]
  (cond
    (= target "direct") "direct"
    (= target "block") nil
    (string/has-prefix? "group:" target) (string/slice target 6)
    target))

(defn one-rule [rule]
  (def match (or (get rule "match") rule))
  (def target (get rule "target"))
  (def item @{})
  (when (not (empty? (or (get match "domains") @[]))) (put item :domain (get match "domains")))
  (when (not (empty? (or (get match "domainSuffix") @[]))) (put item :domain_suffix (get match "domainSuffix")))
  (when (not (empty? (or (get match "geosite") @[])))
    (put item :rule_set (map |(string "geosite-" $) (get match "geosite"))))
  (when (not (empty? (or (get match "geoip") @[])))
    (put item :rule_set (array/concat (or (get item :rule_set) @[]) (map |(string "geoip-" $) (get match "geoip")))))
  (when (not (empty? (or (get match "ipCidr") @[]))) (put item :ip_cidr (get match "ipCidr")))
  (when (not (empty? (or (get match "port") @[]))) (put item :port (get match "port")))
  (when (get match "protocol") (put item :network (get match "protocol")))
  (when (not (empty? (or (get match "sourceIp") @[])))
    (put item :source_ip_cidr (get match "sourceIp")))
  (if (= target "block")
    (put item :action "reject")
    (do
      (put item :action "route")
      (put item :outbound (rule-outbound target))))
  item)

(defn referenced-sets [model]
  (def tags @[])
  (defn add [prefix names]
    (each name names (array/push tags (string prefix name))))
  (each rule (or (get model "rules") @[])
    (def match (or (get rule "match") @{}))
    (add "geosite-" (or (get match "geosite") @[]))
    (add "geoip-" (or (get match "geoip") @[])))
  (def dns (or (get model "dns") @{}))
  (def domestic (or (get dns "domestic") @{}))
  (each name (or (get domestic "domains") @[])
    (when (string/has-prefix? "geosite:" name)
      (array/push tags (string "geosite-" (string/slice name 8)))))
  (def fake (or (get dns "fakeIp") @{}))
  (each name (or (get fake "exclude") @[])
    (when (string/has-prefix? "geosite:" name)
      (array/push tags (string "geosite-" (string/slice name 8)))))
  (distinct tags))

(defn render [model nodes rule-set-mode]
  (def outbounds @[])
  (each node nodes (array/push outbounds (outbound-for-node node)))
  (def groups (or (get model "groups") @{}))
  (each name (keys groups)
    (array/push outbounds (group-outbound model nodes name)))
  (def subs (or (get model "subscriptionNames") @[]))
  (each sub subs
    (def tag (string "sub:" sub))
    (def mem (filter |(string/has-prefix? (string sub "/") $) (map tag-of nodes)))
    (array/push outbounds
      (if (empty? mem)
        @{:type "selector" :tag tag :outbounds @["direct"] :default "direct"}
        @{:type "urltest" :tag tag :outbounds mem :url "https://www.gstatic.com/generate_204" :interval "5m" :tolerance 50})))
  (unless (get groups "Auto")
    (def all (map tag-of nodes))
    (array/push outbounds
      (if (empty? all)
        @{:type "selector" :tag "Auto" :outbounds @["direct"] :default "direct"}
        @{:type "urltest" :tag "Auto" :outbounds all :url "https://www.gstatic.com/generate_204" :interval "5m" :tolerance 50})))
  (array/push outbounds @{:type "direct" :tag "direct" :routing_mark 74})
  (def dns (or (get model "dns") @{}))
  (def domestic (or (get dns "domestic") @{}))
  (def remote (or (get dns "remote") @{}))
  (def fake (or (get dns "fakeIp") @{}))
  (def mode (or (get model "mode") "rule-based"))
  (def fake-on
    (case (get fake "enable")
      false false
      true true
      (not= mode "bypass")))
  (def servers @[
    @{:type "udp" :tag "bootstrap" :server "1.1.1.1"}])
  (var n 0)
  (each url (or (get domestic "resolvers") @[])
    (array/push servers (dns-server (string "domestic-" n) url "direct"))
    (++ n))
  (set n 0)
  (each url (or (get remote "resolvers") @[])
    (def item (dns-server (string "remote-" n) url (get remote "via")))
    (when (= (get remote "via") "tunnel") (put item :detour "Auto"))
    (array/push servers item)
    (++ n))
  (when fake-on
    (array/push servers @{:type "fakeip" :tag "fakeip" :inet4_range (or (get fake "v4Range") "198.18.0.0/15") :inet6_range (or (get fake "v6Range") "fc00::/18")}))
  (def hosts (or (get dns "hosts") @{}))
  (when (not (empty? (keys hosts)))
    (array/push servers @{:type "hosts" :tag "hosts" :predefined hosts}))
  (def dns-rules @[])
  (each host (keys hosts)
    (array/push dns-rules @{:domain @[host] :server "hosts"}))
  (each name (or (get domestic "domains") @[])
    (if (string/has-prefix? "geosite:" name)
      (array/push dns-rules @{:rule_set @[(string "geosite-" (string/slice name 8))] :server "domestic-0"})
      (array/push dns-rules @{:domain_suffix @[name] :server "domestic-0"})))
  (var fi 0)
  (each domain (keys (or (get dns "forwarders") @{}))
    (def urls (get (get dns "forwarders") domain))
    (def tag (string "forward-" fi))
    (when (and urls (not (empty? urls)))
      (array/push servers (dns-server tag (first urls) nil))
      (array/push dns-rules @{:domain_suffix @[domain] :server tag})
      (++ fi)))
  (def real-dns (if (empty? (or (get domestic "resolvers") @[])) "bootstrap" "domestic-0"))
  (each name (or (get fake "exclude") @[])
    (cond
      (string/has-prefix? "geosite:" name)
      (array/push dns-rules @{:rule_set @[(string "geosite-" (string/slice name 8))] :server real-dns})
      (string/has-prefix? "*." name)
      (array/push dns-rules @{:domain_suffix @[(string/slice name 2)] :server real-dns})
      (array/push dns-rules @{:domain @[name] :server real-dns})))
  (when fake-on
    (array/push dns-rules @{:query_type @["A" "AAAA"] :server "fakeip"}))
  (def rules @[
    @{:action "sniff"}
    @{:port @[53] :action "hijack-dns"}])
  (when (get model "blockQuic")
    (array/push rules @{:network "udp" :port @[443] :action "reject"}))
  (each rule (or (get model "rules") @[])
    (array/push rules (one-rule rule)))
  (def final-target (or (get model "defaultTarget") "group:Auto"))
  (when (= final-target "block")
    (array/push rules @{:action "reject"}))
  (def sets @[])
  (each tag (referenced-sets model)
    (array/push sets
      (if (= rule-set-mode "local")
        @{:type "local" :tag tag :format "binary" :path (string "/var/lib/janus/geodata/" tag ".srs")}
        @{:type "remote" :tag tag :format "binary" :url (string "https://raw.githubusercontent.com/SagerNet/" (if (string/has-prefix? "geoip-" tag) "sing-geoip" "sing-geosite") "/rule-set/" tag ".srs")})))
  (def final
    (if (= final-target "block") "direct" (or (rule-outbound final-target) "Auto")))
  @{
    :log @{:level "info"}
    :dns @{
      :servers servers
      :rules dns-rules
      :final (if (empty? (or (get remote "resolvers") @[])) "bootstrap" "remote-0")
      :strategy (if (= (get dns "ipv6Answers") "strip-all") "ipv4_only" "prefer_ipv4")}
    :inbounds @[
      @{:type "tun" :tag "tun-in" :interface_name "tun0"
        :address @["172.19.0.1/30" "fdfe:dcba:9876::1/126"]
        :auto_route false :strict_route false}
      @{:type "redirect" :tag "dns-tcp" :listen "::" :listen_port 5353}
      @{:type "tproxy" :tag "dns-udp" :listen "::" :listen_port 5353 :network "udp"}
      @{:type "socks" :tag "refresh" :listen "127.0.0.1" :listen_port 2080}]
    :outbounds outbounds
    :route @{
      :rules rules
      :rule_set sets
      :final final
      :default_domain_resolver "bootstrap"
      :auto_detect_interface true}
    :experimental @{
      :clash_api @{:external_controller "127.0.0.1:9090"}
      :cache_file @{:enabled true :path "/var/lib/janus/engine/cache.db"}}})

(defn arg-value [args flag]
  (def i (index-of flag args))
  (if i (get args (+ i 1)) nil))

(defn main [&]
  (def args (dyn :args))
  (def cmd
    (or (find |(= $ "normalize") args)
        (find |(= $ "render") args)
        (find |(= $ "match") args)))
  (unless cmd
    (eprint "janus.janet normalize|render|match")
    (os/exit 2))
  (case cmd
    "normalize"
    (let [format (or (arg-value args "--format") "auto")
          src (or (arg-value args "--input") "-")
          dst (or (arg-value args "--output") "-")
          prefix (or (arg-value args "--prefix") "")
          filter-kind (arg-value args "--filter-kind")
          filter-pattern (arg-value args "--filter-pattern")
          filt (when filter-kind (compile-matcher filter-kind filter-pattern true))
          nodes (filter |(name-ok? $ filt) (normalize (read-all src) format))]
      (when (not= prefix "")
        (each node nodes (put node :name (string prefix "/" (get node :name)))))
      (write-out dst (json-encode nodes)))
    "render"
    (let [model (json-decode (read-all (or (arg-value args "--model") "-")))
          nodes (json-decode (read-all (or (arg-value args "--nodes") (die "--nodes is required"))))
          mode (or (arg-value args "--rule-set") "remote")
          dst (or (arg-value args "--output") "-")]
      (write-out dst (json-encode (render model nodes mode))))
    "match"
    (let [kind (get args (+ (index-of "match" args) 1))
          pattern (get args (+ (index-of "match" args) 2))
          text (get args (+ (index-of "match" args) 3))
          compiled (compile-matcher kind pattern true)]
      (print (if (matcher-hit? compiled text) "yes" "no")))))
