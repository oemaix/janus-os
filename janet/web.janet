# SPDX-License-Identifier: Apache-2.0
# Maintenance page. docs/20. HTTP on a Unix socket; stunnel owns TLS.

(def idle-seconds 43200)
(def fail-limit 5)
(def fail-seconds 60)
(def max-sessions 8)
(def csp "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")

(def ident
  (peg/compile ~(* (some (+ (range "az") (range "AZ") (range "09") "_" "-" (range ".."))) -1)))

(defn ident? [s]
  (and (string? s) (> (length s) 0) (peg/match ident s)))

(defn middle [s pre suf]
  (if (and (string/has-prefix? pre s) (string/has-suffix? suf s) (> (length s) (+ (length pre) (length suf))))
    (string/slice s (length pre) (- (length s) (length suf)))
    nil))

(defn key-kind [k]
  (cond
    (not (string? k)) nil
    (ident? (middle k "proxy.subscriptions." ".url")) :url
    (let [rest (middle k "network.lans." "")]
      (when rest
        (def at (string/find ".dhcp.staticLeases." rest))
        (when at
          (def lan (string/slice rest 0 at))
          (def host (string/slice rest (+ at (length ".dhcp.staticLeases."))))
          (and (ident? lan) (ident? host)))))
    :lease
    (ident? (middle k "network.wifi." ".passphrase")) :wifi
    nil))

(defn valid-arg [s]
  (and
    (string? s)
    (> (length s) 0)
    (< (length s) 256)
    (not= (string/slice s 0 1) "-")
    (not (string/find "/" s))
    (not (some |(< $ 32) (string/bytes s)))))

(defn ct-eq [a b]
  (def ba (string/bytes a))
  (def bb (string/bytes b))
  (var d (if (= (length ba) (length bb)) 0 1))
  (def n (max (length ba) (length bb)))
  (for i 0 n
    (def xa (if (< i (length ba)) (in ba i) 0))
    (def xb (if (< i (length bb)) (in bb i) 0))
    (set d (bor d (bxor xa xb))))
  (= d 0))

(defn json-quote [s]
  (def buf @"\"")
  (each b (string/bytes s)
    (cond
      (= b 34) (buffer/push-string buf "\\\"")
      (= b 92) (buffer/push-string buf "\\\\")
      (= b 10) (buffer/push-string buf "\\n")
      (= b 13) (buffer/push-string buf "\\r")
      (= b 9) (buffer/push-string buf "\\t")
      (= b 60) (buffer/push-string buf "\\u003c")
      (= b 62) (buffer/push-string buf "\\u003e")
      (= b 38) (buffer/push-string buf "\\u0026")
      (< b 32) (buffer/push-string buf (string/format "\\u%04x" b))
      (buffer/push-byte buf b)))
  (buffer/push-byte buf 34)
  (string buf))

(defn json-encode [x]
  (cond
    (nil? x) "null"
    (string? x) (json-quote x)
    (boolean? x) (if x "true" "false")
    (number? x) (string x)
    (indexed? x) (string "[" (string/join (map json-encode x) ",") "]")
    (dictionary? x)
    (string "{"
            (string/join
              (seq [k :keys x]
                (string (json-quote (string k)) ":" (json-encode (get x k))))
              ",")
            "}")
    (error "json")))

(defn json-error [exit message]
  (string "{\"exit\":" exit ",\"message\":" (json-quote (string/trim message)) "}"))

(defn parse-json [s]
  (var i 0)
  (defn at []
    (if (>= i (length s)) "" (string/slice s i (+ i 1))))
  (defn skip []
    (while (let [c (at)] (or (= c " ") (= c "\t") (= c "\n") (= c "\r")))
      (++ i)))
  (defn eat [lit]
    (def n (length lit))
    (unless (= (string/slice s i (+ i n)) lit) (error "json"))
    (set i (+ i n)))
  (defn hex4 []
    (def h (string/slice s i (+ i 4)))
    (set i (+ i 4))
    (scan-number (string "0x" h)))
  (defn push-utf8 [buf cp]
    (cond
      (< cp 128) (buffer/push-byte buf cp)
      (< cp 2048)
      (do
        (buffer/push-byte buf (bor 192 (brshift cp 6)))
        (buffer/push-byte buf (bor 128 (band cp 63))))
      (do
        (buffer/push-byte buf (bor 224 (brshift cp 12)))
        (buffer/push-byte buf (bor 128 (band (brshift cp 6) 63)))
        (buffer/push-byte buf (bor 128 (band cp 63))))))
  (defn parse-string []
    (eat "\"")
    (def buf @"")
    (while (not= (at) "\"")
      (when (= (at) "") (error "json"))
      (if (= (at) "\\")
        (do
          (++ i)
          (def e (at))
          (++ i)
          (cond
            (= e "\"") (buffer/push-string buf "\"")
            (= e "\\") (buffer/push-string buf "\\")
            (= e "/") (buffer/push-string buf "/")
            (= e "b") (buffer/push-byte buf 8)
            (= e "f") (buffer/push-byte buf 12)
            (= e "n") (buffer/push-byte buf 10)
            (= e "r") (buffer/push-byte buf 13)
            (= e "t") (buffer/push-byte buf 9)
            (= e "u") (push-utf8 buf (hex4))
            (error "json")))
        (do
          (buffer/push-string buf (at))
          (++ i))))
    (eat "\"")
    (string buf))
  (defn parse-number []
    (def start i)
    (while (let [c (at)] (and (not= c "") (string/find c "0123456789+-eE.")))
      (++ i))
    (def n (scan-number (string/slice s start i)))
    (unless n (error "json"))
    n)
  (var parse-value nil)
  (defn parse-array []
    (eat "[")
    (skip)
    (def out @[])
    (unless (= (at) "]")
      (while true
        (array/push out (parse-value))
        (skip)
        (cond
          (= (at) "]") (break)
          (= (at) ",") (do (eat ",") (skip))
          (error "json"))))
    (eat "]")
    out)
  (defn parse-object []
    (eat "{")
    (skip)
    (def out @{})
    (unless (= (at) "}")
      (while true
        (def k (parse-string))
        (skip)
        (eat ":")
        (skip)
        (put out k (parse-value))
        (skip)
        (cond
          (= (at) "}") (break)
          (= (at) ",") (do (eat ",") (skip))
          (error "json"))))
    (eat "}")
    out)
  (set parse-value
    (fn []
      (skip)
      (def c (at))
      (cond
        (= c "\"") (parse-string)
        (= c "{") (parse-object)
        (= c "[") (parse-array)
        (= c "t") (do (eat "true") true)
        (= c "f") (do (eat "false") false)
        (= c "n") (do (eat "null") nil)
        (parse-number))))
  (try
    (do
      (def v (parse-value))
      (skip)
      (if (= i (length s)) v nil))
    ([_] nil)))

(defn capture [argv stdin]
  (def inf (file/temp))
  (def outf (file/temp))
  (def errf (file/temp))
  (when stdin
    (file/write inf stdin)
    (file/flush inf)
    (file/seek inf :set 0))
  (def code (os/execute argv :p {:in inf :out outf :err errf}))
  (file/seek outf :set 0)
  (file/seek errf :set 0)
  (def out (file/read outf :all))
  (def err (file/read errf :all))
  (file/close inf)
  (file/close outf)
  (file/close errf)
  {:exit (if (number? code) code 1)
   :out (if out (string out) "")
   :err (if err (string err) "")})

(defn openssl-bin []
  (or (os/getenv "JANUS_WEB_OPENSSL") "openssl"))

(defn sha256 [s]
  (def r (capture [(openssl-bin) "dgst" "-sha256" "-r"] s))
  (get (string/split " " (string/trim (r :out))) 0))

(defn hex-token []
  (string/join (map |(string/format "%02x" $) (string/bytes (os/cryptorand 32)))))

(defn percent-decode [s]
  (def buf @"")
  (var i 0)
  (while (< i (length s))
    (def c (string/slice s i (+ i 1)))
    (cond
      (= c "+")
      (do (buffer/push-string buf " ") (++ i))
      (= c "%")
      (do
        (def hex (string/slice s (+ i 1) (+ i 3)))
        (def n (scan-number (string "0x" hex)))
        (if n (buffer/push-byte buf n) (buffer/push-string buf c))
        (set i (+ i 3)))
      (do
        (buffer/push-string buf c)
        (++ i))))
  (string buf))

(defn form-get [body key]
  (var found nil)
  (each pair (string/split "&" (or body ""))
    (def parts (string/split "=" pair))
    (when (= (percent-decode (or (get parts 0) "")) key)
      (set found (percent-decode (or (get parts 1) "")))))
  found)

(defn parse-query [q]
  (def out @{})
  (each pair (string/split "&" (or q ""))
    (when (not= pair "")
      (def parts (string/split "=" pair))
      (put out (percent-decode (or (get parts 0) "")) (percent-decode (or (get parts 1) "")))))
  out)

(defn sessions-dir [st]
  (string (st :runtime) "/sessions"))

(defn ensure-dirs [st]
  (try (os/mkdir (st :runtime)) ([_] nil))
  (try (os/mkdir (sessions-dir st)) ([_] nil)))

(defn session-file [st hash]
  (string (sessions-dir st) "/" hash))

(defn read-expiry [st hash]
  (def p (session-file st hash))
  (when (os/stat p)
    (scan-number (string/trim (slurp p)))))

(defn write-session [st hash expiry]
  (spit (session-file st hash) (string expiry "\n")))

(defn prune-sessions [st]
  (def t ((st :now)))
  (def dir (sessions-dir st))
  (each name (or (os/dir dir) @[])
    (def exp (read-expiry st name))
    (when (or (nil? exp) (< exp t))
      (os/rm (session-file st name))))
  (while (>= (length (or (os/dir dir) @[])) max-sessions)
    (var oldest nil)
    (var oldest-exp math/inf)
    (each name (os/dir dir)
      (def exp (or (read-expiry st name) 0))
      (when (< exp oldest-exp)
        (set oldest name)
        (set oldest-exp exp)))
    (if oldest
      (os/rm (session-file st oldest))
      (break))))

(defn issue-session [st]
  (prune-sessions st)
  (def token (hex-token))
  (write-session st (sha256 token) (+ ((st :now)) idle-seconds))
  token)

(defn token-shape [s]
  (and
    (string? s)
    (= (length s) 64)
    (not (some |(or (< $ 48) (and (> $ 57) (< $ 97)) (> $ 102)) (string/bytes s)))))

(defn touch-session [st token]
  (if (not (token-shape token))
    nil
    (let [exp (read-expiry st (sha256 token))
          t ((st :now))]
      (if (or (nil? exp) (< exp t))
        nil
        (do
          (write-session st (sha256 token) (+ t idle-seconds))
          token)))))

(defn failures-path [st]
  (string (st :runtime) "/failures"))

(defn read-failures [st]
  (def p (failures-path st))
  (if (os/stat p)
    (let [parts (string/split " " (string/trim (slurp p)))]
      {:count (or (scan-number (get parts 0)) 0)
       :until (or (scan-number (get parts 1)) 0)})
    {:count 0 :until 0}))

(defn write-failures [st f]
  (spit (failures-path st) (string (f :count) " " (f :until) "\n")))

(defn note-failure [st]
  (def f (read-failures st))
  (def t ((st :now)))
  (def expired (and (> (f :until) 0) (>= t (f :until))))
  (def base (if expired 0 (f :count)))
  (def count (+ base 1))
  (if (>= count fail-limit)
    (do
      (write-failures st {:count 0 :until (+ t fail-seconds)})
      :closed)
    (do
      (write-failures st {:count count :until 0})
      :rejected)))

(defn cookie-token [headers]
  (var token nil)
  (each pair (string/split ";" (or (get headers "cookie") ""))
    (def bits (string/split "=" (string/trim pair)))
    (when (= (string/trim (or (get bits 0) "")) "janus_session")
      (set token (string/trim (or (get bits 1) "")))))
  token)

(defn session-cookie [token]
  (string "janus_session=" token "; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=" idle-seconds))

(defn default-exec [op args stdin]
  (def argv @[])
  (when (= (os/getenv "JANUS_WEB_USE_SUDO") "1")
    (array/push argv (or (os/getenv "JANUS_WEB_SUDO_BIN") "sudo"))
    (array/push argv "-n"))
  (array/push argv (os/getenv "JANUS_WEB_EXEC") op)
  (each a args (array/push argv a))
  (capture argv stdin))

(defn cli-call [st op args stdin]
  (def result ((st :exec) op args stdin))
  (def err (string/trim (or (result :err) "")))
  (def text (if (= err "") "failed" err))
  (cond
    (= (result :exit) 0)
    (let [body (or (result :out) "")
          trimmed (string/triml body)]
      {:status 200
       :ctype (if (or (string/has-prefix? "{" trimmed) (string/has-prefix? "[" trimmed))
                "application/json"
                "text/plain; charset=utf-8")
       :body body})
    (= (result :exit) 2)
    {:status 400 :ctype "application/json" :body (json-error 2 text)}
    {:status 409 :ctype "application/json" :body (json-error (or (result :exit) 1) text)}))

(defn bad [message]
  {:status 400 :ctype "application/json" :body (json-error 2 message)})

(defn unauthorized [message]
  {:status 401 :ctype "application/json" :body (json-error 2 message)})

(defn object-body [req]
  (def parsed (parse-json (or (req :body) "")))
  (if (dictionary? parsed) parsed nil))

(defn login [st req]
  (def f (read-failures st))
  (def ctype (or (get (req :headers) "content-type") ""))
  (def given
    (if (string/find "json" ctype)
      (let [obj (object-body req)] (if obj (get obj "passphrase") nil))
      (form-get (req :body) "passphrase")))
  (cond
    (< ((st :now)) (f :until)) (unauthorized "closed")
    (= (st :passphrase) "") (unauthorized "rejected")
    (and (string? given) (ct-eq given (st :passphrase)))
    (do
      (write-failures st {:count 0 :until 0})
      (def token (issue-session st))
      {:status 303
       :ctype "text/plain; charset=utf-8"
       :headers @{"Location" "/" "Set-Cookie" (session-cookie token)}
       :body ""})
    (unauthorized (if (= (note-failure st) :closed) "closed" "rejected"))))

(defn need [s]
  (if (valid-arg s) s nil))

(defn public-doc [st]
  {"hostname" (or (get (st :doc) "hostname") "")
   "fingerprint" (or (st :fingerprint) "")})

(defn private-doc [st]
  {"proxy" (get (st :doc) "proxy")
   "subscriptions" (or (get (st :doc) "subscriptions") @[])
   "lans" (or (get (st :doc) "lans") @[])
   "wifi" (or (get (st :doc) "wifi") @[])
   "monitoringScope" (or (get (st :doc) "monitoringScope") "counters")
   "audit" (get (st :doc) "audit")})

(defn dispatch [st req]
  (def method (req :method))
  (def path (req :path))
  (def q (req :query))
  (def obj (if (= method "POST") (object-body req) nil))
  (cond
    (and (= method "GET") (= path "/api/meta"))
    {:status 200 :ctype "application/json" :body (json-encode (private-doc st))}
    (and (= method "GET") (= path "/api/status"))
    (cli-call st "status" [] nil)
    (and (= method "GET") (= path "/api/proxy/groups"))
    (cli-call st "proxy-groups" [] nil)
    (and (= method "POST") (= path "/api/proxy/refresh"))
    (let [name (get obj "name")]
      (if (or (nil? name) (= name ""))
        (cli-call st "proxy-refresh" [] nil)
        (if (need name)
          (cli-call st "proxy-refresh" [name] nil)
          (bad "rejected"))))
    (and (= method "POST") (= path "/api/proxy/geodata/refresh"))
    (cli-call st "proxy-geodata-refresh" [] nil)
    (and (= method "POST") (= path "/api/proxy/select"))
    (let [group (need (get obj "group"))
          node (need (get obj "node"))]
      (if (and group node)
        (cli-call st "proxy-select" [group node] nil)
        (bad "rejected")))
    (and (= method "POST") (= path "/api/proxy/test"))
    (let [group (need (get obj "group"))]
      (if group
        (cli-call st "proxy-test" [group] nil)
        (bad "rejected")))
    (and (= method "POST") (= path "/api/wan/restart"))
    (let [name (need (get obj "name"))]
      (if name (cli-call st "wan-restart" [name] nil) (bad "rejected")))
    (and (= method "GET") (= path "/api/wan/show"))
    (let [name (need (or (get q "name") (get obj "name")))]
      (if name (cli-call st "wan-show" [name] nil) (bad "rejected")))
    (and (= method "GET") (= path "/api/lan/leases"))
    (let [lan (or (get q "lan") "")]
      (if (= lan "")
        (cli-call st "lan-leases" [] nil)
        (if (need lan)
          (cli-call st "lan-leases" [lan] nil)
          (bad "rejected"))))
    (and (= method "GET") (= path "/api/traffic"))
    (let [iface (or (get q "iface") "")
          period (or (get q "period") "")
          args @[]]
      (cond
        (and (not= iface "") (not (need iface))) (bad "rejected")
        (and (not= period "") (not= period "daily") (not= period "monthly")) (bad "rejected")
        (do
          (when (not= iface "") (array/push args iface))
          (when (= period "daily") (array/push args "--daily"))
          (when (= period "monthly") (array/push args "--monthly"))
          (cli-call st "traffic" args nil))))
    (and (= method "GET") (= path "/api/traffic/top"))
    (cli-call st "traffic-top" [] nil)
    (and (= method "POST") (= path "/api/dns/query"))
    (let [name (need (get obj "name"))]
      (if name (cli-call st "dns-query" [name] nil) (bad "rejected")))
    (and (= method "POST") (= path "/api/dns/flush"))
    (cli-call st "dns-flush" [] nil)
    (and (= method "GET") (= path "/api/dns/stats"))
    (cli-call st "dns-stats" [] nil)
    (and (= method "POST") (= path "/api/dns/check"))
    (cli-call st "dns-check" [] nil)
    (and (= method "GET") (= path "/api/override"))
    (cli-call st "override-show" [] nil)
    (and (= method "POST") (= path "/api/override"))
    (let [key (get obj "key")
          kind (key-kind key)]
      (cond
        (= kind :url)
        (let [value (get obj "value")]
          (if (string? value)
            (cli-call st "override-set" [key] value)
            (bad "rejected")))
        (= kind :wifi)
        (let [value (get obj "value")]
          (if (string? value)
            (cli-call st "override-set" [key] value)
            (bad "rejected")))
        (= kind :lease)
        (let [mac (get obj "mac")
              ip (get obj "ip")]
          (if (and (string? mac) (string? ip))
            (cli-call st "override-set" [key mac ip] nil)
            (bad "rejected")))
        (bad "rejected")))
    (and (= method "POST") (= path "/api/override/unset"))
    (let [key (get obj "key")]
      (if (key-kind key)
        (cli-call st "override-unset" [key] nil)
        (bad "rejected")))
    (and (= method "GET") (= path "/api/version"))
    (cli-call st "version" [] nil)
    (and (= method "POST") (= path "/api/reboot"))
    (if (= (get obj "confirm") "reboot")
      (cli-call st "reboot" [] nil)
      (bad "rejected"))
    (and (= method "GET") (= path "/api/audit"))
    (cli-call st "audit-status" [] nil)
    {:status 404 :ctype "text/plain; charset=utf-8" :body ""}))

(defn page-html [st]
  (string/replace (slurp (st :html)) "__JANUS_META__" (json-encode (public-doc st))))

(defn access-line [method path status]
  (string (if method method "-") " " (if path path "-") " " status))

(defn handle [st req]
  (def method (req :method))
  (def path (req :path))
  (cond
    (and (= method "GET") (or (= path "/") (= path "/login")))
    {:status 200 :ctype "text/html; charset=utf-8" :body (page-html st)}
    (and (= method "POST") (= path "/login"))
    (login st req)
    (do
      (def token (touch-session st (cookie-token (req :headers))))
      (if (nil? token)
        (unauthorized "rejected")
        (if (and (= method "POST") (not= (string/trim (or (get (req :headers) "x-janus") "")) "1"))
          (bad "rejected")
          (let [resp (merge @{} (dispatch st req))
                headers (merge @{} (or (resp :headers) @{}))]
            (put headers "Set-Cookie" (session-cookie token))
            (put resp :headers headers)
            resp))))))

(defn read-request [conn]
  (def buf @"")
  (while (not (string/find "\r\n\r\n" buf))
    (when (>= (length buf) 16384) (error "headers"))
    (def n (length buf))
    (net/read conn 4096 buf 10)
    (when (= (length buf) n) (error "eof")))
  (def sep (string/find "\r\n\r\n" buf))
  (def head (string/slice buf 0 sep))
  (def lines (string/split "\r\n" head))
  (def reqline (string/split " " (get lines 0)))
  (def target (or (get reqline 1) "/"))
  (def qat (string/find "?" target))
  (def path (if qat (string/slice target 0 qat) target))
  (def query (if qat (parse-query (string/slice target (+ qat 1))) @{}))
  (def headers @{})
  (each line (array/slice lines 1)
    (def cut (string/find ":" line))
    (when cut
      (put headers
           (string/ascii-lower (string/slice line 0 cut))
           (string/trim (string/slice line (+ cut 1))))))
  (def len (scan-number (or (get headers "content-length") "0")))
  (when (or (nil? len) (> len 65536) (< len 0)) (error "length"))
  (var have (- (length buf) (+ sep 4)))
  (while (< have len)
    (when (>= (length buf) (+ sep 4 65536)) (error "body"))
    (def n (length buf))
    (net/read conn 4096 buf 10)
    (when (= (length buf) n) (error "eof"))
    (set have (- (length buf) (+ sep 4))))
  {:method (or (get reqline 0) "")
   :path path
   :query query
   :headers headers
   :body (string/slice buf (+ sep 4) (+ sep 4 len))})

(def http-reason
  {200 "OK" 303 "See Other" 400 "Bad Request" 401 "Unauthorized" 404 "Not Found" 409 "Conflict"})

(defn write-response [conn resp]
  (def body (or (resp :body) ""))
  (def parts @[(string "HTTP/1.1 " (resp :status) " " (or (get http-reason (resp :status)) "OK"))])
  (array/push parts (string "Content-Type: " (or (resp :ctype) "text/plain; charset=utf-8")))
  (array/push parts (string "Content-Length: " (length body)))
  (array/push parts "Cache-Control: no-store")
  (array/push parts (string "Content-Security-Policy: " csp))
  (array/push parts "Connection: close")
  (eachp [k v] (or (resp :headers) @{})
    (array/push parts (string k ": " v)))
  (net/write conn (string (string/join parts "\r\n") "\r\n\r\n" body)))

(defn serve-conn [conn st]
  (var req nil)
  (def resp
    (try
      (do
        (set req (read-request conn))
        (handle st req))
      ([_] (bad "rejected"))))
  (eprint (access-line (if req (req :method) nil) (if req (req :path) nil) (resp :status)))
  (try (write-response conn resp) ([_] nil))
  (net/close conn))

(defn accept-loop [server st]
  (while true
    (def conn (net/accept server))
    (ev/go (fn [] (serve-conn conn st)))))

(defn fingerprint-of [cert]
  (when (and cert (os/stat cert))
    (def r (capture [(openssl-bin) "x509" "-in" cert "-noout" "-fingerprint" "-sha256"] nil))
    (when (= (r :exit) 0)
      (string/trim (get (string/split "=" (string/trim (r :out))) 1)))))

(defn load-doc []
  (def path (os/getenv "JANUS_WEB_JSON"))
  (if (and path (os/stat path))
    (or (parse-json (slurp path)) @{})
    @{}))

(defn strip-nl [s]
  (if (and (> (length s) 0) (= (string/slice s -1) "\n"))
    (string/slice s 0 -2)
    s))

(defn load-passphrase []
  (def from-env (os/getenv "JANUS_WEB_PASSPHRASE"))
  (def raw
    (if from-env
      from-env
      (let [dir (os/getenv "CREDENTIALS_DIRECTORY")]
        (if (and dir (os/stat (string dir "/passphrase")))
          (slurp (string dir "/passphrase"))
          ""))))
  (strip-nl raw))

(defn html-path []
  (or (os/getenv "JANUS_WEB_HTML")
      (do
        (var found nil)
        (each a (dyn :args)
          (when (and (string? a) (string/has-suffix? "web.janet" a))
            (set found (string (string/slice a 0 (- (length a) (length "web.janet"))) "web.html"))))
        found)))

(defn make-state [runtime passphrase exec doc now html cert fingerprint]
  (def st @{
            :runtime runtime
            :passphrase passphrase
            :exec exec
            :doc (or doc @{})
            :now now
            :html html
            :cert cert
            :fingerprint (or fingerprint "")})
  (ensure-dirs st)
  st)

(defn notify-ready []
  (def path (os/getenv "NOTIFY_SOCKET"))
  (when (and (string? path) (> (length path) 0))
    # Datagram from this process. systemd accepts it when this PID is the main PID.
    (def conn (net/connect :unix path :datagram))
    (net/write conn "READY=1\n")
    (net/close conn)))

(defn serve []
  (def pass (load-passphrase))
  (when (= pass "")
    (eprint "janus web passphrase file is missing or empty.")
    (os/exit 1))
  (def doc (load-doc))
  (def runtime (or (os/getenv "JANUS_WEB_RUNTIME") "/run/janus-web"))
  (def sock (or (get doc "socket") "/run/janus-web/http.sock"))
  (def cert (or (get doc "cert") "/var/lib/janus/web/cert.pem"))
  (def st (make-state runtime pass default-exec doc (fn [] (math/floor (os/time))) (html-path) cert (fingerprint-of cert)))
  (try (os/rm sock) ([_] nil))
  (def server (net/listen :unix sock))
  (os/chmod sock 8r660)
  (notify-ready)
  (accept-loop server st))

(defn expect [cond msg]
  (unless cond
    (eprint msg)
    (os/exit 1)))

(defn http-round [sock method path headers body]
  (def conn (net/connect :unix sock))
  (def payload (or body ""))
  (def head @[(string method " " path " HTTP/1.1") "Host: janus" (string "Content-Length: " (length payload))])
  (eachp [k v] headers (array/push head (string k ": " v)))
  (net/write conn (string (string/join head "\r\n") "\r\n\r\n" payload))
  (def buf @"")
  (net/read conn :all buf 3)
  (net/close conn)
  (string buf))

(defn check []
  (expect (ct-eq "same" "same") "ct equal")
  (expect (not (ct-eq "same" "other")) "ct differ")
  (expect (not (ct-eq "same" "same!")) "ct length")
  (expect (= (key-kind "proxy.subscriptions.a.url") :url) "url key")
  (expect (= (key-kind "network.lans.home.dhcp.staticLeases.nas") :lease) "lease key")
  (expect (= (key-kind "network.wifi.ap.passphrase") :wifi) "wifi key")
  (expect (nil? (key-kind "firewall.rules.x")) "off list")
  (def parsed (parse-json "{\"a\":\"b\",\"n\":1,\"ok\":true}"))
  (expect (and (= (get parsed "a") "b") (= (get parsed "n") 1) (= (get parsed "ok") true)) "json")
  (def html (html-path))
  (expect html "html path")
  (def page (slurp html))
  (expect (string/find "border-radius: 0" page) "radius")
  (expect (string/find "box-shadow: none" page) "shadow")
  (expect (string/find "janus-theme" page) "theme key")
  (expect (string/find "janus-lang" page) "lang key")
  (expect (string/find "prefers-color-scheme" page) "scheme")
  (expect (string/find "navigator.languages" page) "languages")
  (expect (string/find "ui-monospace" page) "mono")
  (expect (string/find "Noto Naskh Arabic" page) "arabic")
  (expect (string/find "72ch" page) "measure")
  (expect (string/find "createElement(\"wbr\")" page) "fingerprint wrap")
  (expect (string/find "хост" page) "russian host")
  (expect (string/find "میزبان" page) "persian host")
  (expect (string/find "简中" page) "chinese label")
  (expect (string/find "主机" page) "chinese host")
  (expect (string/find "Noto Sans CJK SC" page) "cjk")
  (expect (not (string/find "toUpperCase" page)) "host case")
  (def palette
    ["002b36" "073642" "93a1a1" "586e75" "eee8d5" "fdf6e3"
     "3b94d2" "0674c2" "2aa198" "217d76" "859900" "687800"
     "b58900" "8f6c00" "f9514e" "d5302d" "e76630" "c44915"
     "ec549d" "cb347d" "7e84e6" "4f55c4"])
  (def allowed @{})
  (each h palette
    (put allowed h true)
    (expect (string/find h page) (string "palette " h)))
  (var i 0)
  (while (def at (string/find "#" page i))
    (def hex (string/slice page (+ at 1) (+ at 7)))
    (when (peg/match ~(* (repeat 6 :h) -1) hex)
      (unless (get allowed hex)
        (eprint (string "color " hex))
        (os/exit 1)))
    (set i (+ at 1)))

  (def calls @[])
  (defn spy [op args stdin]
    (array/push calls [op args stdin])
    {:exit 0 :out "{\"ok\":true}\n" :err ""})
  (var clock 1700000000)
  (def runtime (string "/tmp/jw-" (string/slice (hex-token) 0 8)))
  (def st (make-state runtime "secret" spy {:hostname "router" :proxy true} (fn [] clock) html nil ""))
  (defn authed [token method path body]
    (handle st {:method method :path path :query @{}
                :headers {"cookie" (string "janus_session=" token) "x-janus" "1" "content-type" "application/json"}
                :body (or body "")}))
  (def bad-login
    (handle st {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=nope"}))
  (expect (= (bad-login :status) 401) "bad login")
  (def good
    (handle st {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=secret"}))
  (expect (= (good :status) 303) "login")
  (def token (string/slice (get (good :headers) "Set-Cookie") 14 78))
  (expect (= (length token) 64) "token")
  (def status (authed token "GET" "/api/status" ""))
  (expect (= (status :status) 200) "status")
  (expect (= (get (get calls 0) 0) "status") "status op")
  (def no-header
    (handle st {:method "POST" :path "/api/reboot" :query @{}
                :headers {"cookie" (string "janus_session=" token) "content-type" "application/json"}
                :body "{\"confirm\":\"reboot\"}"}))
  (expect (= (no-header :status) 400) "missing header")
  (def reboot-no (authed token "POST" "/api/reboot" "{\"confirm\":\"no\"}"))
  (expect (= (reboot-no :status) 400) "reboot word")
  (expect (= (length calls) 1) "reboot did not run")
  (def reboot-yes (authed token "POST" "/api/reboot" "{\"confirm\":\"reboot\"}"))
  (expect (= (reboot-yes :status) 200) "reboot")
  (expect (= (get (get calls 1) 0) "reboot") "reboot op")
  (def secret-url "https://example.invalid/secret")
  (def set-url
    (authed token "POST" "/api/override"
            (string "{\"key\":\"proxy.subscriptions.a.url\",\"value\":" (json-quote secret-url) "}")))
  (expect (= (set-url :status) 200) "set url")
  (def url-call (get calls 2))
  (expect (= (get url-call 0) "override-set") "override op")
  (expect (= (get (get url-call 1) 0) "proxy.subscriptions.a.url") "override key")
  (expect (= (length (get url-call 1)) 1) "url not an argument")
  (expect (= (get url-call 2) secret-url) "url stdin")
  (def off
    (authed token "POST" "/api/override" "{\"key\":\"firewall.x\",\"value\":\"y\"}"))
  (expect (= (off :status) 400) "off allowlist")
  (expect (= (length calls) 3) "off allowlist did not run")
  (def hidden (make-state (string runtime "-meta") "secret" spy @{"hostname" "router" "subscriptions" ["secret-sub"] "proxy" true} (fn [] clock) html nil "AA:BB"))
  (def rendered (page-html hidden))
  (expect (string/find "router" rendered) "login shows host")
  (expect (string/find "AA:BB" rendered) "login shows fingerprint")
  (expect (not (string/find "secret-sub" rendered)) "login hides subscriptions")
  (def meta-login
    (handle hidden {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=secret"}))
  (def meta-token (string/slice (get (meta-login :headers) "Set-Cookie") 14 78))
  (def meta-resp
    (handle hidden {:method "GET" :path "/api/meta" :query @{}
                    :headers {"cookie" (string "janus_session=" meta-token)}
                    :body ""}))
  (expect (= (meta-resp :status) 200) "meta")
  (expect (string/find "secret-sub" (meta-resp :body)) "meta after login")
  (def meta-open (handle hidden {:method "GET" :path "/api/meta" :query @{} :headers @{} :body ""}))
  (expect (= (meta-open :status) 401) "meta needs session")
  (expect (= (access-line "GET" "/api/status" 200) "GET /api/status 200") "access line")
  (def missing (handle st {:method "GET" :path "/api/status" :query @{} :headers @{} :body ""}))
  (expect (= (missing :status) 401) "no session")
  (def nowhere (authed token "GET" "/missing" ""))
  (expect (= (nowhere :status) 404) "missing path")
  (set clock (+ clock idle-seconds 1))
  (def expired (authed token "GET" "/api/status" ""))
  (expect (= (expired :status) 401) "idle")

  (def lock-runtime (string runtime "-lock"))
  (var lock-clock 1700000000)
  (def lock (make-state lock-runtime "secret" spy {} (fn [] lock-clock) html nil ""))
  (for _ 0 4
    (def resp (handle lock {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=no"}))
    (expect (string/find "rejected" (resp :body)) "fail"))
  (def fifth (handle lock {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=no"}))
  (expect (string/find "closed" (fifth :body)) "fifth closes")
  (def during (handle lock {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=secret"}))
  (expect (string/find "closed" (during :body)) "closed ignores passphrase")
  (set lock-clock (+ lock-clock fail-seconds 1))
  (def after (handle lock {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=secret"}))
  (expect (= (after :status) 303) "open again")

  (def cap-runtime (string runtime "-cap"))
  (def cap (make-state cap-runtime "secret" spy {} (fn [] 10) html nil ""))
  (for _ 0 9
    (handle cap {:method "POST" :path "/login" :query @{} :headers @{} :body "passphrase=secret"}))
  (expect (<= (length (os/dir (sessions-dir cap))) max-sessions) "session cap")

  (def sock (string runtime "/s"))
  (def server (net/listen :unix sock))
  (os/chmod sock 8r660)
  (ev/go (fn [] (accept-loop server st)))
  (ev/sleep 0.05)
  (def raw (http-round sock "POST" "/login" {"Content-Type" "application/x-www-form-urlencoded"} "passphrase=secret"))
  (expect (string/find "303" raw) "socket login")
  (def cookie-at (string/find "janus_session=" raw))
  (expect cookie-at "socket cookie")
  (def live-token (string/slice raw (+ cookie-at 14) (+ cookie-at 78)))
  (def raw-status
    (http-round sock "GET" "/api/status" {"Cookie" (string "janus_session=" live-token)} ""))
  (expect (string/find "200" raw-status) "socket status")
  (expect (string/find "Content-Security-Policy" raw-status) "csp")
  (expect (string/find "Cache-Control: no-store" raw-status) "nostore")

  (def note-path (string runtime "-note"))
  (def note (net/listen :unix note-path :datagram))
  (os/setenv "NOTIFY_SOCKET" note-path)
  (notify-ready)
  (def note-buf @"")
  (net/read note 64 note-buf 1)
  (expect (= (string note-buf) "READY=1\n") "ready datagram")
  (os/setenv "NOTIFY_SOCKET" nil)
  (net/close note)
  (os/exit 0))

(defn main [&]
  (def args (dyn :args))
  (cond
    (find |(= $ "check") args)
    (try
      (check)
      ([e]
        (eprint e)
        (os/exit 1)))
    (find |(= $ "serve") args) (serve)
    (do
      (eprint "web.janet check|serve")
      (os/exit 2))))
