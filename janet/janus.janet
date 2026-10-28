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
          (put-in node [:tls :reality :shortId] (get reality "short_id")))
        (def utls (get tls "utls"))
        (when (and utls (get utls "enabled"))
          (put-in node [:tls :utls] (get utls "fingerprint"))))
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

(defn one-address [kind urls]
  (def list (or urls @[]))
  (when (> (length list) 1)
    (eprint (string "janus: " kind " queries " (first list) " only. A DNS rule names one server. sing-box has no failover group. xray 26 does not stably match one name on two servers.")))
  (if (empty? list) nil (first list)))

(defn encrypted-url? [url]
  (or
    (string/has-prefix? "https://" url)
    (string/has-prefix? "tls://" url)
    (string/has-prefix? "quic://" url)))

(defn reject-plaintext [encryption url]
  (when (and (= encryption "require") (not (encrypted-url? url)))
    (die (string "janus: encryption require rejects " url))))

(defn resolver-host [url]
  (def rest
    (cond
      (string/has-prefix? "https://" url) (string/slice url 8)
      (string/has-prefix? "tls://" url) (string/slice url 6)
      (string/has-prefix? "quic://" url) (string/slice url 7)
      (string/has-prefix? "udp://" url) (string/slice url 6)
      url))
  (def slash (string/find "/" rest))
  (def host (if slash (string/slice rest 0 slash) rest))
  (if (string/has-prefix? "[" host)
    (string/slice host 1 (string/find "]" host))
    (let [colon (string/find ":" host)]
      (if colon (string/slice host 0 colon) host))))

(defn ip-literal? [host]
  (def parts (string/split "." host))
  (or
    (and (= (length parts) 4)
      (all |(and (not (empty? $)) (number? (scan-number $))) parts))
    (string/find ":" host)))

(defn needs-bootstrap? [url]
  (and
    (encrypted-url? url)
    (not (ip-literal? (resolver-host url)))))

(defn dns-server [tag url resolver encryption]
  (reject-plaintext encryption url)
  (def host (resolver-host url))
  (def item
    (cond
      (string/has-prefix? "https://" url)
      (let [rest (string/slice url 8)
            slash (string/find "/" rest)
            path (if slash (string/slice rest slash) "/dns-query")]
        @{:type "https" :tag tag :server host :path path})
      (string/has-prefix? "tls://" url)
      @{:type "tls" :tag tag :server host}
      (string/has-prefix? "quic://" url)
      @{:type "quic" :tag tag :server host}
      @{:type "udp" :tag tag :server host}))
  (when (needs-bootstrap? url)
    (if resolver
      (put item :domain_resolver resolver)
      (die (string "janus: " url " needs janus.dns.bootstrap"))))
  item)

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
  (defn walk [rules]
    (each rule rules
      (def match (or (get rule "match") @{}))
      (add "geosite-" (or (get match "geosite") @[]))
      (add "geoip-" (or (get match "geoip") @[]))))
  (walk (or (get model "rules") @[]))
  (each view (or (get model "lans") @[])
    (walk (or (get view "rules") @[]))
    (def vdns (or (get view "dns") @{}))
    (each name (or (get (or (get vdns "domestic") @{}) "domains") @[])
      (when (string/has-prefix? "geosite:" name)
        (array/push tags (string "geosite-" (string/slice name 8)))))
    (each name (or (get (or (get vdns "fakeIp") @{}) "exclude") @[])
      (when (string/has-prefix? "geosite:" name)
        (array/push tags (string "geosite-" (string/slice name 8))))))
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

(defn rule-set-url [model tag]
  (def sources (or (get model "geodataSources") @{}))
  (def tags (or (get sources "tags") @{}))
  (def specific (get tags tag))
  (if specific
    specific
    (let [base
          (if (string/has-prefix? "geoip-" tag)
            (get sources "geoip")
            (get sources "geosite"))]
      (if (nil? base)
        (error (string "geodataSources has no URL for " tag))
        (string base "/" tag ".srs")))))

(defn bootstrap-ips [policy]
  (def raw (get policy "bootstrap"))
  (if (nil? raw) @["1.1.1.1"] raw))

(defn policy-views [model]
  (def lans (or (get model "lans") @[]))
  (if (empty? lans)
    @[@{
      "name" "router"
      "cidr" nil
      "address" nil
      "inbound" nil
      "mode" (or (get model "mode") "rule-based")
      "defaultTarget" (or (get model "defaultTarget") "group:Auto")
      "rules" (or (get model "rules") @[])
      "dns" (or (get model "dns") @{})}]
    lans))

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
  (defn fake-on? [policy mode]
    (if (= mode "bypass")
      false
      (case (get (or (get policy "fakeIp") @{}) "enable")
        false false
        true true
        true)))
  (defn group-target? [target]
    (and target (string/has-prefix? "group:" target)))
  (defn name-match? [match]
    (and
      (or
        (not (empty? (or (get match "domains") @[])))
        (not (empty? (or (get match "domainSuffix") @[])))
        (not (empty? (or (get match "geosite") @[]))))
      (empty? (or (get match "geoip") @[]))
      (empty? (or (get match "ipCidr") @[]))
      (empty? (or (get match "port") @[]))
      (nil? (get match "protocol"))))
  (defn put-names [item match]
    (when (not (empty? (or (get match "domains") @[])))
      (put item :domain (get match "domains")))
    (when (not (empty? (or (get match "domainSuffix") @[])))
      (put item :domain_suffix (get match "domainSuffix")))
    (when (not (empty? (or (get match "geosite") @[])))
      (put item :rule_set (map |(string "geosite-" $) (get match "geosite"))))
    item)
  (defn domain-item [name server]
    (cond
      (string/has-prefix? "geosite:" name)
      @{:rule_set @[(string "geosite-" (string/slice name 8))] :action "route" :server server}
      (string/has-prefix? "*." name)
      @{:domain_suffix @[(string/slice name 2)] :action "route" :server server}
      @{:domain @[name] :action "route" :server server}))
  (defn views-of [model] (policy-views model))
  (def house (or (get model "dns") @{}))
  (def encryption (or (get house "encryption") "prefer"))
  (def cache (or (get house "cache") @{}))
  (def min-ttl (or (get cache "minTtl") 60))
  (defn stamp-dns [item]
    (def server (get item :server))
    (when (and (= (get item :action) "route") server (> min-ttl 0))
      (put item :rewrite_ttl min-ttl))
    item)
  (defn push-dns [rules item cidr inbound]
    (def base (stamp-dns (table/clone item)))
    (when cidr (put base :source_ip_cidr @[cidr]))
    (array/push rules base)
    (when inbound
      (def alt (stamp-dns (table/clone item)))
      (put alt :inbound @[(string inbound) (string inbound "-tcp")])
      (array/push rules alt)))
  (def servers @[])
  (def dns-rules @[])
  (var house-boot nil)
  (let [ip (one-address "bootstrap" (bootstrap-ips house))]
    (when ip
      (set house-boot "bootstrap-house-0")
      (array/push servers @{:type "udp" :tag house-boot :server ip})))
  (var saw-fake false)
  (each view (views-of model)
    (def policy (or (get view "dns") @{}))
    (def mode (or (get view "mode") "rule-based"))
    (def cidr (get view "cidr"))
    (def inbound (get view "inbound"))
    (def label (or (get view "name") "router"))
    (def domestic (or (get policy "domestic") @{}))
    (def remote (or (get policy "remote") @{}))
    (def fake (or (get policy "fakeIp") @{}))
    (def strip (or (get policy "ipv6Answers") "strip-for-proxied"))
    (def on (fake-on? policy mode))
    (def own-ips (get policy "bootstrap"))
    (def boot
      (if (or (nil? own-ips) (deep= own-ips (bootstrap-ips house)))
        house-boot
        (let [ip (one-address (string "bootstrap " label) own-ips)]
          (when ip
            (def tag (string "bootstrap-" label "-0"))
            (array/push servers @{:type "udp" :tag tag :server ip})
            tag))))
    (def domestic-list (or (get domestic "resolvers") @[]))
    (each url domestic-list (reject-plaintext encryption url))
    (def domestic-url (one-address (string "domestic " label) domestic-list))
    (var dom-tag nil)
    (when domestic-url
      (set dom-tag (string "domestic-" label "-0"))
      (array/push servers (dns-server dom-tag domestic-url boot encryption)))
    (def remote-list (or (get remote "resolvers") @[]))
    (var rem-tag nil)
    (when (not= mode "bypass")
      (each url remote-list (reject-plaintext encryption url))
      (let [remote-url (one-address (string "remote " label) remote-list)]
        (when remote-url
          (set rem-tag (string "remote-" label "-0"))
          (def item (dns-server rem-tag remote-url boot encryption))
          (when (= (get remote "via") "tunnel") (put item :detour "Auto"))
          (array/push servers item))))
    (when (and on (not saw-fake))
      (array/push servers @{
        :type "fakeip" :tag "fakeip"
        :inet4_range (or (get fake "v4Range") "198.18.0.0/15")
        :inet6_range (or (get fake "v6Range") "fc00::/18")})
      (set saw-fake true))
    (def hosts (or (get policy "hosts") @{}))
    (when (not (empty? (keys hosts)))
      (def host-tag (string "hosts-" label))
      (array/push servers @{:type "hosts" :tag host-tag :predefined hosts})
      (each host (keys hosts)
        (push-dns dns-rules @{:domain @[host] :action "route" :server host-tag} cidr inbound)))
    (def real (or dom-tag house-boot))
    (when (= (get policy "recursive") false)
      (push-dns dns-rules @{:action "reject"} cidr inbound))
    (when (not= (get policy "recursive") false)
      (var fi 0)
      (each domain (keys (or (get policy "forwarders") @{}))
        (def urls (get (get policy "forwarders") domain))
        (when (and urls (not (empty? urls)))
          (each url urls (reject-plaintext encryption url))
          (def url (one-address (string "forwarder " domain) urls))
          (def tag (string "forward-" label "-" fi))
          (array/push servers (dns-server tag url boot encryption))
          (push-dns dns-rules @{:domain_suffix @[domain] :action "route" :server tag} cidr inbound)
          (++ fi)))
      (when (= strip "strip-all")
        (push-dns dns-rules @{:query_type @["AAAA"] :action "reject"} cidr inbound))
      (cond
        (= mode "bypass")
        (when real
          (push-dns dns-rules @{:action "route" :server real} cidr inbound))
        (= mode "proxy-all")
        (do
          (each name (or (get fake "exclude") @[])
            (when real (push-dns dns-rules (domain-item name real) cidr inbound)))
          (each rule (or (get view "rules") @[])
            (def match (or (get rule "match") @{}))
            (when (name-match? match)
              (cond
                (= (get rule "target") "block")
                (push-dns dns-rules (put-names @{:action "reject"} match) cidr inbound)
                (= (get rule "target") "direct")
                (when real (push-dns dns-rules (put-names @{:action "route" :server real} match) cidr inbound)))))
          (when (not= strip "keep")
            (push-dns dns-rules @{:query_type @["AAAA"] :action "reject"} cidr inbound))
          (when on
            (push-dns dns-rules @{:query_type @["A" "AAAA"] :action "route" :server "fakeip"} cidr inbound))
          (when rem-tag
            (push-dns dns-rules @{:action "route" :server rem-tag} cidr inbound)))
        (do
          (each name (or (get domestic "domains") @[])
            (when real (push-dns dns-rules (domain-item name real) cidr inbound)))
          (each name (or (get fake "exclude") @[])
            (when real (push-dns dns-rules (domain-item name real) cidr inbound)))
          (each rule (or (get view "rules") @[])
            (def match (or (get rule "match") @{}))
            (def target (get rule "target"))
            (when (name-match? match)
              (cond
                (= target "block")
                (push-dns dns-rules (put-names @{:action "reject"} match) cidr inbound)
                (= target "direct")
                (when real (push-dns dns-rules (put-names @{:action "route" :server real} match) cidr inbound))
                (group-target? target)
                (do
                  (when (not= strip "keep")
                    (push-dns dns-rules (put-names @{:query_type @["AAAA"] :action "reject"} match) cidr inbound))
                  (when on
                    (push-dns dns-rules (put-names @{:query_type @["A" "AAAA"] :action "route" :server "fakeip"} match) cidr inbound))
                  (when (and (not on) rem-tag)
                    (push-dns dns-rules (put-names @{:action "route" :server rem-tag} match) cidr inbound))))))
          (def target (or (get view "defaultTarget") "group:Auto"))
          (cond
            (= target "block")
            (push-dns dns-rules @{:action "reject"} cidr inbound)
            (= target "direct")
            (when real (push-dns dns-rules @{:action "route" :server real} cidr inbound))
            (group-target? target)
            (do
              (when (not= strip "keep")
                (push-dns dns-rules @{:query_type @["AAAA"] :action "reject"} cidr inbound))
              (when on
                (push-dns dns-rules @{:query_type @["A" "AAAA"] :action "route" :server "fakeip"} cidr inbound))
              (when rem-tag
                (push-dns dns-rules @{:action "route" :server rem-tag} cidr inbound))))))))
  (def rules @[
    @{:action "sniff"}
    @{:port @[53] :action "hijack-dns"}])
  (each view (views-of model)
    (def mode (or (get view "mode") "rule-based"))
    (when (not= mode "bypass")
      (def cidr (get view "cidr"))
      (each rule (or (get view "rules") @[])
        (def item (one-rule rule))
        (def existing (get item :source_ip_cidr))
        (when (and cidr (or (nil? existing) (empty? existing)))
          (put item :source_ip_cidr @[cidr]))
        (array/push rules item))
      # After direct rules, so a domestic QUIC flow is not rejected.
      (when (get model "blockQuic")
        (def quic @{:network "udp" :port @[443] :action "reject"})
        (when cidr (put quic :source_ip_cidr @[cidr]))
        (array/push rules quic))
      (def target (or (get view "defaultTarget") (get model "defaultTarget") "group:Auto"))
      (def catch @{})
      (if (= target "block")
        (put catch :action "reject")
        (do
          (put catch :action "route")
          (put catch :outbound (or (rule-outbound target) "Auto"))))
      (when cidr (put catch :source_ip_cidr @[cidr]))
      (array/push rules catch)))
  (def final-target (or (get model "defaultTarget") "group:Auto"))
  (def sets @[])
  (each tag (referenced-sets model)
    (array/push sets
      (if (= rule-set-mode "local")
        @{:type "local" :tag tag :format "binary" :path (string "/var/lib/janus/geodata/" tag ".srs")}
        @{:type "remote" :tag tag :format "binary" :url (rule-set-url model tag)})))
  (def final
    (if (not (empty? (or (get model "lans") @[])))
      "direct"
      (if (= final-target "block") "direct" (or (rule-outbound final-target) "Auto"))))
  (def inbounds @[
    @{:type "tun" :tag "tun-in" :interface_name "tun0"
      :address @["172.19.0.1/30" "fdfe:dcba:9876::1/126"]
      # gvisor answers a SYN that policy routing delivered to tun0.
      # The system stack does not (ADR-0025).
      :stack "gvisor"
      :auto_route false :strict_route false}
    @{:type "redirect" :tag "dns-tcp" :listen "::" :listen_port 5353}
    # TProxy delivers a packet only to a socket of the same family.
    @{:type "tproxy" :tag "dns-udp4" :listen "0.0.0.0" :listen_port 5353 :network "udp"}
    @{:type "tproxy" :tag "dns-udp6" :listen "::" :listen_port 5353 :network "udp"}])
  (each view (views-of model)
    (def address (get view "address"))
    (def inbound (get view "inbound"))
    (when (and address inbound)
      (array/push inbounds @{:type "direct" :tag inbound :listen address :listen_port 53 :network "udp"})
      (array/push inbounds @{:type "direct" :tag (string inbound "-tcp") :listen address :listen_port 53 :network "tcp"})))
  (array/push inbounds @{:type "socks" :tag "refresh" :listen "127.0.0.1" :listen_port 2080})
  (def dns-final (or house-boot (if (empty? servers) "bootstrap-house-0" (get (first servers) :tag))))
  @{
    :log @{:level "info"}
    :dns @{
      :servers servers
      :rules dns-rules
      :final dns-final
      :strategy "prefer_ipv4"
      :cache_capacity (or (get cache "size") 4096)}
    :inbounds inbounds
    :outbounds outbounds
    :route @{
      :rules rules
      :rule_set sets
      :final final
      :default_domain_resolver dns-final
      :auto_detect_interface true}
    :experimental @{
      :clash_api @{:external_controller "127.0.0.1:9090"}
      :cache_file @{:enabled true :path "/var/lib/janus/engine/cache.db"}}})

(defn xray-stream [node]
  (def tls (at node :tls))
  (def transport (or (at-in node [:transport :type]) "tcp"))
  (def utls (at-in node [:tls :utls]))
  (def stream @{:network transport :sockopt @{:mark 74}})
  (when (and tls (at tls :enable))
    (def reality (at-in tls [:reality :publicKey]))
    (if reality
      (do
        (put stream :security "reality")
        (put stream :realitySettings @{
          :serverName (at tls :serverName)
          :publicKey reality
          :shortId (or (at-in tls [:reality :shortId]) "")}))
      (do
        (put stream :security "tls")
        (def settings @{})
        (when (at tls :serverName) (put settings :serverName (at tls :serverName)))
        (put stream :tlsSettings settings)))
    # xray rejects an unknown fingerprint at `xray run -test`.
    (when utls
      (put-in stream [(if reality :realitySettings :tlsSettings) :fingerprint] utls)))
  (when (not= transport "tcp")
    (def extra @{})
    (when (at-in node [:transport :path]) (put extra :path (at-in node [:transport :path])))
    (when (at-in node [:transport :host]) (put extra :headers @{:Host (at-in node [:transport :host])}))
    (put stream (keyword (string transport "Settings")) extra))
  stream)

(defn xray-outbound [node]
  (def tag (tag-of node))
  (def proto (at node :protocol))
  (def addr (at node :server))
  (def port (at node :port))
  (def settings
    (case proto
      "vless"
      (let [user @{:id (at-in node [:vless :uuid]) :encryption "none"}]
        (when (at-in node [:vless :flow]) (put user :flow (at-in node [:vless :flow])))
        @{:vnext @[@{:address addr :port port :users @[user]}]})
      "vmess"
      @{:vnext @[@{:address addr :port port :users @[@{:id (at-in node [:vmess :uuid]) :security (or (at-in node [:vmess :security]) "auto") :alterId (or (at-in node [:vmess :alterId]) 0)}]}]}
      "trojan"
      @{:servers @[@{:address addr :port port :password (or (at-in node [:trojan :password]) "")}]}
      "shadowsocks"
      @{:servers @[@{:address addr :port port :method (at-in node [:shadowsocks :method]) :password (or (at-in node [:shadowsocks :password]) "")}]}
      @{}))
  @{:tag tag :protocol proto :settings settings :streamSettings (xray-stream node)})

(defn node-tag [target]
  (if (and target (string/has-prefix? "node:" target)) (string/slice target 5) (or target "direct")))

(defn xray-balancer-strategy [strategy]
  (case strategy
    "load-balance" "roundRobin"
    "url-test" "leastPing"
    "manual" "leastPing"
    "fallback" (die "xray cannot express group strategy fallback")
    (die (string "xray cannot express group strategy " strategy))))

(defn xray-dispatch [model target]
  (cond
    (= target "direct") ["outbound" "direct"]
    (= target "block") ["outbound" "block"]
    (string/has-prefix? "group:" target)
    (let [name (string/slice target 6)
          group (or (get (or (get model "groups") @{}) name) @{})
          strategy (or (get group "strategy") "url-test")]
      (if (= strategy "manual")
        ["outbound" (node-tag (or (get group "default") "direct"))]
        ["balancer" name]))
    ["outbound" (node-tag (or target "direct"))]))

(defn xray-name-only? [match]
  (and
    (or
      (not (empty? (or (get match "domains") @[])))
      (not (empty? (or (get match "domainSuffix") @[])))
      (not (empty? (or (get match "geosite") @[]))))
    (empty? (or (get match "geoip") @[]))
    (empty? (or (get match "ipCidr") @[]))
    (empty? (or (get match "port") @[]))
    (nil? (get match "protocol"))))

(defn xray-pattern [name]
  (cond
    (string/has-prefix? "geosite:" name) name
    (string/has-prefix? "full:" name) name
    (string/has-prefix? "domain:" name) name
    (string/has-prefix? "*." name) (string "domain:" (string/slice name 2))
    (string "full:" name)))

(defn xray-match-names [match]
  (def names @[])
  (each name (or (get match "domains") @[]) (array/push names (xray-pattern name)))
  (each name (or (get match "domainSuffix") @[]) (array/push names (string "domain:" name)))
  (each name (or (get match "geosite") @[]) (array/push names (string "geosite:" name)))
  names)

(defn xray-dns-fp [view]
  (def policy (or (get view "dns") @{}))
  (def name-rules @[])
  (each rule (or (get view "rules") @[])
    (def match (or (get rule "match") @{}))
    (when (xray-name-only? match)
      (array/push name-rules @{
        "domains" (or (get match "domains") @[])
        "domainSuffix" (or (get match "domainSuffix") @[])
        "geosite" (or (get match "geosite") @[])
        "target" (get rule "target")})))
  @{
    "mode" (or (get view "mode") "rule-based")
    "defaultTarget" (or (get view "defaultTarget") "group:Auto")
    "recursive" (get policy "recursive")
    "domestic" (or (get policy "domestic") @{})
    "remote" (or (get policy "remote") @{})
    "fakeIp" (or (get policy "fakeIp") @{})
    "ipv6Answers" (or (get policy "ipv6Answers") "strip-for-proxied")
    "forwarders" (or (get policy "forwarders") @{})
    "bootstrap" (get policy "bootstrap")
    "nameRules" name-rules})

(defn xray-rule [model rule]
  (def match (or (get rule "match") rule))
  (def item @{:type "field"})
  (def domains @[])
  (each name (or (get match "domains") @[])
    (array/push domains (if (string/has-prefix? "full:" name) name (string "full:" name))))
  (each name (or (get match "domainSuffix") @[]) (array/push domains (string "domain:" name)))
  (each name (or (get match "geosite") @[]) (array/push domains (string "geosite:" name)))
  (when (not (empty? domains)) (put item :domain domains))
  (def ips @[])
  (each name (or (get match "geoip") @[]) (array/push ips (string "geoip:" name)))
  (each cidr (or (get match "ipCidr") @[]) (array/push ips cidr))
  (when (not (empty? ips)) (put item :ip ips))
  (when (not (empty? (or (get match "port") @[]))) (put item :port (get match "port")))
  (when (get match "protocol") (put item :network (get match "protocol")))
  (def sources @[])
  (each cidr (or (get match "sourceIp") @[]) (array/push sources cidr))
  (when (not (empty? sources)) (put item :source sources))
  (def where (xray-dispatch model (get rule "target")))
  (if (= (get where 0) "balancer")
    (put item :balancerTag (get where 1))
    (put item :outboundTag (get where 1)))
  item)

(defn render-xray [model nodes]
  (def outbounds @[])
  (each node nodes (array/push outbounds (xray-outbound node)))
  (array/push outbounds @{:tag "direct" :protocol "freedom" :streamSettings @{:sockopt @{:mark 74}}})
  (array/push outbounds @{:tag "block" :protocol "blackhole"})
  (array/push outbounds @{:tag "dns-out" :protocol "dns"})
  (def groups (or (get model "groups") @{}))
  (def balancers @[])
  (def observed @[])
  (each name (keys groups)
    (def group (get groups name))
    (def strategy (or (get group "strategy") "url-test"))
    (when (not= strategy "manual")
      (def mem (members-of model nodes name))
      (array/push balancers @{:tag name :selector (if (empty? mem) @["direct"] mem) :strategy @{:type (xray-balancer-strategy strategy)}})
      (each tag mem (array/push observed tag))))
  (unless (get groups "Auto")
    (def all (map tag-of nodes))
    (array/push balancers @{:tag "Auto" :selector (if (empty? all) @["direct"] all) :strategy @{:type "leastPing"}})
    (each tag all (array/push observed tag)))
  (def views (policy-views model))
  (def anchor (first views))
  (def anchor-fp (xray-dns-fp anchor))
  (each view views
    (when (not (deep= (xray-dns-fp view) anchor-fp))
      (die (string "janus: xray has one DNS module, and " (get view "name") " does not share it with " (get anchor "name")))))
  (def hosts @{})
  (each view views
    (def hostmap (or (get (or (get view "dns") @{}) "hosts") @{}))
    (each name (keys hostmap)
      (def ip (get hostmap name))
      (def prev (get hosts name))
      (when (and prev (not= prev ip))
        (die (string "janus: xray hosts disagree on " name)))
      (put hosts name ip)))
  (def policy (or (get anchor "dns") @{}))
  (def encryption (or (get (or (get model "dns") @{}) "encryption") "prefer"))
  (def xcache (or (get (or (get model "dns") @{}) "cache") @{}))
  (when (or
    (and (get xcache "size") (not= (get xcache "size") 4096))
    (and (get xcache "minTtl") (not= (get xcache "minTtl") 60)))
    (die "janus: xray 26 has no DNS cache size or minimum TTL"))
  (def mode (or (get anchor "mode") "rule-based"))
  (def fake (or (get policy "fakeIp") @{}))
  (def strip (or (get policy "ipv6Answers") "strip-for-proxied"))
  (def target (or (get anchor "defaultTarget") "group:Auto"))
  (def fake-on
    (if (or (= mode "bypass") (= (get policy "recursive") false))
      false
      (case (get fake "enable")
        false false
        true true
        true)))
  (def fallback
    (cond
      (= (get policy "recursive") false) "none"
      (= mode "bypass") "domestic"
      (= mode "proxy-all") (if fake-on "fake" "remote")
      (= target "block") "block"
      (= target "direct") "domestic"
      (if fake-on "fake" "remote")))
  (def direct-qs (if (= strip "strip-all") nil "UseIP"))
  (def proxy-qs (if (= strip "keep") "UseIP" "UseIPv4"))
  (defn xray-ns [url domains strategy]
    (def item @{:address url})
    (when (and domains (not (empty? domains)))
      (put item :domains (distinct domains))
      (put item :skipFallback true))
    (when strategy (put item :queryStrategy strategy))
    item)
  (defn xray-remote [url domains strategy]
    (def item (xray-ns url domains strategy))
    (when (= (get (or (get policy "remote") @{}) "via") "tunnel")
      (put item :tag "dns-remote"))
    item)
  (def real @[])
  (def blocked @[])
  (def proxied @[])
  (def forwarded @[])
  (defn placed? [name]
    (or (index-of name real) (index-of name blocked) (index-of name proxied) (index-of name forwarded)))
  (defn place [bag name]
    (when (not (placed? name)) (array/push bag name)))
  (def forward-servers @[])
  (def domestic-all (or (get (or (get policy "domestic") @{}) "resolvers") @[]))
  (def remote-all (or (get (or (get policy "remote") @{}) "resolvers") @[]))
  (each url domestic-all (reject-plaintext encryption url))
  (when (not= mode "bypass")
    (each url remote-all (reject-plaintext encryption url)))
  (def domestic-one (one-address "domestic" domestic-all))
  (def remote-one (if (= mode "bypass") nil (one-address "remote" remote-all)))
  (def domestic-urls (if domestic-one @[domestic-one] @[]))
  (def remote-urls (if remote-one @[remote-one] @[]))
  (when (not= fallback "none")
    (each domain (keys (or (get policy "forwarders") @{}))
      (def urls (get (get policy "forwarders") domain))
      (def pattern (string "domain:" domain))
      (when (and urls (not (empty? urls)))
        (each url urls (reject-plaintext encryption url))
        (def url (one-address (string "forwarder " domain) urls))
        (place forwarded pattern)
        (array/push forward-servers (xray-ns url @[pattern] direct-qs))))
    (when (and (= mode "rule-based") (not= fallback "domestic"))
      (each name (or (get (or (get policy "domestic") @{}) "domains") @[])
        (place real (xray-pattern name)))
      (each name (or (get fake "exclude") @[])
        (place real (xray-pattern name))))
    (when (= mode "proxy-all")
      (each name (or (get fake "exclude") @[])
        (place real (xray-pattern name))))
    (when (not= mode "bypass")
      (each rule (or (get anchor "rules") @[])
        (def match (or (get rule "match") @{}))
        (when (xray-name-only? match)
          (def want (get rule "target"))
          (def bag
            (cond
              (= want "block") (if (= fallback "block") nil blocked)
              (= want "direct") (if (= fallback "domestic") nil real)
              (and want (string/has-prefix? "group:" want))
              (if (or (= fallback "fake") (= fallback "remote")) nil proxied)
              nil))
          (when bag
            (each name (xray-match-names match) (place bag name)))))))
  (def boot-one (one-address "bootstrap" (bootstrap-ips policy)))
  (def boots (if boot-one @[boot-one] @[]))
  (def hostnames @[])
  (each url (array/concat @[] domestic-urls remote-urls)
    (when (needs-bootstrap? url) (array/push hostnames (resolver-host url))))
  (each item forward-servers
    (def url (get item :address))
    (when (and url (needs-bootstrap? url)) (array/push hostnames (resolver-host url))))
  (when (and (not= fallback "none") (not (empty? hostnames)) (empty? boots))
    (die "janus: URL needs janus.dns.bootstrap"))
  (def servers @[])
  (when (and (not= fallback "none") (not (empty? boots)) (not (empty? hostnames)))
    (array/push servers (xray-ns (first boots) (map |(string "full:" $) (distinct hostnames)) "UseIPv4")))
  (each item forward-servers (array/push servers item))
  (when (not (empty? real))
    (each url domestic-urls (array/push servers (xray-ns url real direct-qs))))
  (when (not (empty? blocked))
    # xray 26 has no DNS reject code. This address is the resolver, on the
    # router, at a closed port. The client receives the lookup failure.
    (def item (xray-ns "127.0.0.1" blocked nil))
    (put item :port 1)
    (array/push servers item))
  (when (not (empty? proxied))
    (if fake-on
      (array/push servers (xray-ns "fakedns" proxied proxy-qs))
      (each url remote-urls (array/push servers (xray-remote url proxied proxy-qs)))))
  (case fallback
    "domestic" (each url domestic-urls (array/push servers (xray-ns url nil direct-qs)))
    "fake" (array/push servers (xray-ns "fakedns" nil proxy-qs))
    "remote" (each url remote-urls (array/push servers (xray-remote url nil proxy-qs)))
    "block" (array/push servers @{:address "127.0.0.1" :port 1})
    nil)
  (when (empty? servers)
    (each ip boots (array/push servers @{:address ip})))
  (when (empty? servers)
    (array/push servers @{:address "1.1.1.1"}))
  (defn fakedns-server? [item]
    (and (dictionary? item) (= (get item :address) "fakedns")))
  (defn source-rule [item cidr]
    (when (and cidr (or (nil? (get item :source)) (empty? (get item :source))))
      (put item :source @[cidr]))
    item)
  (def dns-tags @["dns-tcp" "dns-udp4" "dns-udp6"])
  (def inbounds @[
    @{:tag "api" :listen "127.0.0.1" :port 8080 :protocol "dokodemo-door"
      :settings @{:address "127.0.0.1"}}
    @{:tag "tproxy-in" :listen "0.0.0.0" :port 12345 :protocol "dokodemo-door"
      :settings @{:network "tcp,udp" :followRedirect true}
      :sniffing @{:enabled true :destOverride
                  (array/concat
                    (if (some fakedns-server? servers) @["fakedns" "http" "tls"] @["http" "tls"])
                    (if (get model "blockQuic") @["quic"] @[]))}
      :streamSettings @{:sockopt @{:tproxy "tproxy"}}}
    @{:tag "dns-tcp" :listen "::" :port 5353 :protocol "dokodemo-door"
      :settings @{:address "1.1.1.1" :port 53 :network "tcp"}}
    @{:tag "dns-udp4" :listen "0.0.0.0" :port 5353 :protocol "dokodemo-door"
      :settings @{:address "1.1.1.1" :port 53 :network "udp"}
      :streamSettings @{:sockopt @{:tproxy "tproxy"}}}
    @{:tag "dns-udp6" :listen "::" :port 5353 :protocol "dokodemo-door"
      :settings @{:address "1.1.1.1" :port 53 :network "udp"}
      :streamSettings @{:sockopt @{:tproxy "tproxy" :v6only true}}}])
  (each view views
    (def address (get view "address"))
    (def inbound (get view "inbound"))
    (when (and address inbound)
      (array/push dns-tags inbound)
      (array/push dns-tags (string inbound "-tcp"))
      (array/push inbounds @{
        :tag inbound :listen address :port 53 :protocol "dokodemo-door"
        :settings @{:address "1.1.1.1" :port 53 :network "udp"}})
      (array/push inbounds @{
        :tag (string inbound "-tcp") :listen address :port 53 :protocol "dokodemo-door"
        :settings @{:address "1.1.1.1" :port 53 :network "tcp"}})))
  (def rules @[
    @{:type "field" :inboundTag @["api"] :outboundTag "api"}])
  (when (some |(= (get $ :tag) "dns-remote") servers)
    (array/push rules @{:type "field" :inboundTag @["dns-remote"] :balancerTag "Auto"}))
  (array/push rules @{:type "field" :inboundTag dns-tags :outboundTag "dns-out"})
  (each view views
    (when (not= (or (get view "mode") "rule-based") "bypass")
      (def cidr (get view "cidr"))
      (each rule (or (get view "rules") @[])
        (array/push rules (source-rule (xray-rule model rule) cidr)))
      (when (get model "blockQuic")
        (array/push rules (source-rule @{:type "field" :network "udp" :port "443" :outboundTag "block"} cidr)))
      (def where (xray-dispatch model (or (get view "defaultTarget") "group:Auto")))
      (def catch @{:type "field" :network "tcp,udp"})
      (if (= (get where 0) "balancer")
        (put catch :balancerTag (get where 1))
        (put catch :outboundTag (get where 1)))
      (array/push rules (source-rule catch cidr))))
  (when (not (empty? (or (get model "lans") @[])))
    (array/push rules @{:type "field" :network "tcp,udp" :outboundTag "direct"}))
  (def dns @{
    :servers servers
    :queryStrategy (if (= strip "strip-all") "UseIPv4" "UseIP")
    :disableFallbackIfMatch true})
  (when (= fallback "none") (put dns :disableFallback true))
  (when (not (empty? (keys hosts))) (put dns :hosts hosts))
  (def cfg @{
    :log @{:loglevel "warning"}
    :api @{:tag "api" :services @["RoutingService"]}
    :inbounds inbounds
    :outbounds outbounds
    :routing @{:domainStrategy "AsIs" :rules rules :balancers balancers}
    :dns dns})
  (when (some fakedns-server? servers)
    (put cfg :fakedns @[
      @{:ipPool (or (get fake "v4Range") "198.18.0.0/15") :poolSize 65535}
      @{:ipPool (or (get fake "v6Range") "fc00::/18") :poolSize 65535}]))
  (when (some |(= (get-in $ [:strategy :type]) "leastPing") balancers)
    (put cfg :observatory @{
      :subjectSelector (if (empty? observed) @["direct"] (distinct observed))
      :probeUrl "https://www.gstatic.com/generate_204"
      :probeInterval "10s"}))
  cfg)

(defn arg-value [args flag]
  (def i (index-of flag args))
  (if i (get args (+ i 1)) nil))

(defn merge-raw [base over]
  # engineSettings merges last. JSON keys are strings. The rendered
  # config uses keywords. Arrays replace.
  (def out (table/clone base))
  (eachp [k v] over
    (def nk (if (string? k) (keyword k) k))
    (def b (get out nk))
    (put out nk (if (and (table? b) (table? v)) (merge-raw b v) v)))
  out)

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
          engine (or (arg-value args "--engine") "sing-box")
          dst (or (arg-value args "--output") "-")
          rendered (if (= engine "xray") (render-xray model nodes) (render model nodes mode))
          raw (or (get model "engineSettings") @{})
          merged (if (empty? raw) rendered (merge-raw rendered raw))]
      (write-out dst (json-encode merged)))
    "match"
    (let [kind (get args (+ (index-of "match" args) 1))
          pattern (get args (+ (index-of "match" args) 2))
          text (get args (+ (index-of "match" args) 3))
          compiled (compile-matcher kind pattern true)]
      (print (if (matcher-hit? compiled text) "yes" "no")))))
