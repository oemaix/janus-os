# SPDX-License-Identifier: Apache-2.0
# Shared HTTP listener for speech. docs/08 §1c, §1d.
# TLS is stunnel. This program speaks cleartext HTTP on a Unix socket.
# The token is not logged. Audio and text are not stored.

(def max-header 8192)
(def max-body 8388608)
# Four calls in flight. A fifth is 503. docs/08 §1c, T-0023.
(def default-active 4)

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

(defn strip-nl [s]
  (def b (string/bytes s))
  (def n (length b))
  (cond
    (and (>= n 2) (= (get b (- n 1)) 10) (= (get b (- n 2)) 13))
    (string/slice s 0 -3)
    (and (>= n 1) (= (get b (- n 1)) 10))
    (string/slice s 0 -2)
    s))

(defn scan-number [s]
  (var n 0)
  (var saw false)
  (each b (string/bytes s)
    (if (and (>= b 48) (<= b 57))
      (do
        (set saw true)
        (set n (+ (* n 10) (- b 48))))
      (break)))
  (if saw n nil))

(defn parse-head [buf sep]
  (def head (string/slice buf 0 sep))
  (def lines (string/split "\r\n" head))
  (def reqline (string/split " " (get lines 0)))
  (def target (or (get reqline 1) "/"))
  (def qat (string/find "?" target))
  (def path (if qat (string/slice target 0 qat) target))
  (def headers @{})
  (each line (array/slice lines 1)
    (def cut (string/find ":" line))
    (when cut
      (put headers
           (string/ascii-lower (string/slice line 0 cut))
           (string/trim (string/slice line (+ cut 1))))))
  @{:method (or (get reqline 0) "")
    :path path
    :headers headers
    :buf buf
    :sep sep})

(def digits (peg/compile ~(* (some (range "09")) -1)))

(defn digits? [s]
  (and (string? s) (peg/match digits s)))

# Headers only. The token is checked before the body is read. T-0023.
(defn read-headers [conn]
  (def buf @"")
  (var sep nil)
  (while (nil? sep)
    (when (> (length buf) max-header) (error "length"))
    (def n (length buf))
    (net/read conn 4096 buf 10)
    (when (= (length buf) n) (error "eof"))
    (set sep (string/find "\r\n\r\n" buf)))
  (parse-head buf sep))

(defn finish-body [conn req]
  (def headers (req :headers))
  (def te (get headers "transfer-encoding"))
  (when (and te (not= (string/ascii-lower te) "identity")) (error "length"))
  (def len-raw (get headers "content-length"))
  (when (or (nil? len-raw) (> (length len-raw) 10) (not (digits? len-raw))) (error "length"))
  (def len (scan-number len-raw))
  (when (or (nil? len) (> len max-body) (< len 0)) (error "length"))
  (def sep (req :sep))
  (def buf (req :buf))
  (var have (- (length buf) (+ sep 4)))
  (while (< have len)
    (when (>= (length buf) (+ sep 4 max-body)) (error "body"))
    (def n (length buf))
    (net/read conn 4096 buf 10)
    (when (= (length buf) n) (error "eof"))
    (set have (- (length buf) (+ sep 4))))
  (put req :body (string/slice buf (+ sep 4) (+ sep 4 len)))
  req)

(def http-reason
  {200 "OK" 400 "Bad Request" 401 "Unauthorized" 404 "Not Found" 409 "Conflict" 503 "Service Unavailable"})

(defn write-response [conn resp]
  (def body (or (resp :body) ""))
  (def parts @[(string "HTTP/1.1 " (resp :status) " " (or (get http-reason (resp :status)) "OK"))])
  (array/push parts (string "Content-Type: " (or (resp :ctype) "text/plain; charset=utf-8")))
  (array/push parts (string "Content-Length: " (length body)))
  (array/push parts "Cache-Control: no-store")
  (array/push parts "Connection: close")
  (net/write conn (string (string/join parts "\r\n") "\r\n\r\n" body)))

(defn capture [argv]
  (def inf (file/temp))
  (def outf (file/temp))
  (def errf (file/temp))
  # os/execute blocks every fiber. proc-wait suspends only this one (T-0016).
  (def proc (os/spawn argv :p {:in inf :out outf :err errf}))
  (def code (os/proc-wait proc))
  (os/proc-close proc)
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

(defn load-doc []
  # The shell exports these. The token stays out of this table.
  @{"asr" (= (os/getenv "JANUS_HTTP_ASR") "true")
    "tts" (= (os/getenv "JANUS_HTTP_TTS") "true")
    "socket" (or (os/getenv "JANUS_HTTP_SOCKET") "/run/janus-http/http.sock")})

(defn load-token []
  (def from-env (os/getenv "JANUS_HTTP_TOKEN"))
  (def raw
    (if from-env
      from-env
      (let [dir (os/getenv "CREDENTIALS_DIRECTORY")]
        (if (and dir (os/stat (string dir "/token")))
          (slurp (string dir "/token"))
          ""))))
  (strip-nl raw))

(defn bearer [headers]
  (def h (or (get headers "authorization") ""))
  (if (string/has-prefix? "Bearer " h)
    (string/slice h (length "Bearer "))
    ""))

(defn header-num [headers name]
  (def raw (get headers name))
  (if (and raw (digits? raw)) (scan-number raw) nil))

(var req-seq 0)

(defn run-speech [runtime req kind]
  (def runner (os/getenv "JANUS_SPEECH_RUN"))
  (if (or (nil? runner) (not (os/stat runner)))
    {:status 404 :body "unavailable"}
    (do
  (set req-seq (+ req-seq 1))
  (def seq (string req-seq))
  (def body-path (string runtime "/body-" seq))
  (def out-path (string runtime "/out-" seq))
  (def meta-path (string runtime "/meta-" seq))
  (spit body-path (req :body))
  (def ctype (or (get (req :headers) "content-type") ""))
  (def rate (header-num (req :headers) "x-janus-rate"))
  (def channels (header-num (req :headers) "x-janus-channels"))
  (def args @[runner kind "--body" body-path "--ctype" ctype])
  (when rate (array/push args "--rate" (string rate)))
  (when channels (array/push args "--channels" (string channels)))
  (array/concat args ["--out" out-path "--meta" meta-path])
  (def result (capture args))
  (os/rm body-path)
  (def status
    (case (result :exit)
      0 200
      5 409
      2 404
      400))
  (def payload
    (if (and (= status 200) (os/stat out-path))
      (slurp out-path)
      (if (= status 409) "busy" "unavailable")))
  (def meta
    (if (and (= status 200) (os/stat meta-path))
      (string/trim (slurp meta-path))
      "text/plain; charset=utf-8"))
  (when (os/stat out-path) (os/rm out-path))
  (when (os/stat meta-path) (os/rm meta-path))
  {:status status :body payload :ctype meta})))

(defn route [doc req]
  (def method (req :method))
  (def path (req :path))
  (cond
    (and (= method "POST") (= path "/speech/recognize") (get doc "asr"))
    (run-speech (or (os/getenv "JANUS_HTTP_RUNTIME") "/run/janus-http") req "recognize")
    (and (= method "POST") (= path "/speech/synthesize") (get doc "tts"))
    (run-speech (or (os/getenv "JANUS_HTTP_RUNTIME") "/run/janus-http") req "synthesize")
    {:status 404 :body "unavailable"}))

(defn handle [token doc req]
  (if (ct-eq (bearer (req :headers)) token)
    (route doc req)
    {:status 401 :body "rejected"}))

(defn access-line [method path status]
  (string (or method "-") " " (or path "-") " " status))

(var active 0)

(defn serve-conn [conn token doc]
  (var req nil)
  (def resp
    (try
      (do
        (set req (read-headers conn))
        (if (ct-eq (bearer (req :headers)) token)
          (do
            (set req (finish-body conn req))
            (route doc req))
          {:status 401 :body "rejected"}))
      ([_] {:status 400 :body "unavailable"})))
  # Method, path, status. Not the token, the query, or the body.
  (eprint (access-line (if req (req :method) nil) (if req (req :path) nil) (resp :status)))
  (try (write-response conn resp) ([_] nil))
  # Free the slot before close. Close yields, and the next call would otherwise see a full limit.
  (set active (- active 1))
  (try (net/close conn) ([_] nil)))

(defn active-limit []
  (def raw (os/getenv "JANUS_HTTP_MAX_ACTIVE"))
  (def n (if (and raw (digits? raw)) (scan-number raw) default-active))
  (if (and n (> n 0)) n default-active))

(defn accept-loop [server token doc]
  (def limit (active-limit))
  (while true
    (def conn (net/accept server))
    (if (>= active limit)
      (do
        # Read the headers first. Closing before the client writes resets the call.
        (try
          (do
            (read-headers conn)
            (write-response conn {:status 503 :body "busy"}))
          ([_] nil))
        (net/close conn))
      (do
        (set active (+ active 1))
        (ev/go (fn []
          (try
            (serve-conn conn token doc)
            ([_] (set active (- active 1))))))))))

(defn notify-ready []
  (def path (os/getenv "NOTIFY_SOCKET"))
  (when (and (string? path) (> (length path) 0))
    (def conn (net/connect :unix path :datagram))
    (net/write conn "READY=1\n")
    (net/close conn)))

(defn serve []
  (def token (load-token))
  (when (= token "")
    (eprint "janus edge api token file is missing or empty.")
    (os/exit 1))
  (def doc (load-doc))
  (def runtime (or (os/getenv "JANUS_HTTP_RUNTIME") "/run/janus-http"))
  (def sock (or (get doc "socket") "/run/janus-http/http.sock"))
  (os/mkdir runtime)
  (try (os/rm sock) ([_] nil))
  (def server (net/listen :unix sock))
  (os/chmod sock 8r660)
  (notify-ready)
  (accept-loop server token doc))

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

(defn http-raw [sock bytes]
  (def conn (net/connect :unix sock))
  (net/write conn bytes)
  (def buf @"")
  (net/read conn :all buf 3)
  (net/close conn)
  (string buf))

(defn check []
  (expect (ct-eq "same" "same") "ct equal")
  (expect (not (ct-eq "same" "other")) "ct differ")
  (expect (not (ct-eq "" "secret")) "ct empty")
  (expect (= (strip-nl "secret\n") "secret") "strip nl")
  (expect (= (strip-nl "secret\r\n") "secret") "strip crlf")
  (def tmp (or (os/getenv "TMPDIR") "/tmp"))
  (def dir (string tmp "/janus-speech-check"))
  (try (os/mkdir dir) ([_] nil))
  (each stale ["calls" "started" "http.sock"]
    (try (os/rm (string dir "/" stale)) ([_] nil)))
  (def runner (string dir "/run.sh"))
  (spit runner ```#!/bin/sh
out=
meta=
body=
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --meta) meta=$2; shift 2 ;;
    --body) body=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf x >> "$JANUS_HTTP_RUNTIME/calls"
if [ -n "$body" ] && grep -q WAIT "$body"; then
  touch "$JANUS_HTTP_RUNTIME/started"
  sleep 2
fi
printf '%s\n' '{"text":"ok"}' > "$out"
printf '%s\n' application/json > "$meta"
exit 0
```)
  (os/chmod runner 8r755)
  (os/setenv "JANUS_HTTP_ASR" "true")
  (os/setenv "JANUS_HTTP_TTS" "true")
  (os/setenv "JANUS_HTTP_TOKEN" "secret")
  (os/setenv "JANUS_HTTP_RUNTIME" dir)
  (os/setenv "JANUS_HTTP_MAX_ACTIVE" "1")
  (os/setenv "JANUS_SPEECH_RUN" runner)
  (def sock (string dir "/http.sock"))
  (try (os/rm sock) ([_] nil))
  (def doc (load-doc))
  (put doc "socket" sock)
  (def server (net/listen :unix sock))
  (ev/go (fn [] (accept-loop server "secret" doc)))
  (def ok (http-round sock "POST" "/speech/recognize" {"Authorization" "Bearer secret" "Content-Type" "audio/wav"} "RIFFxxxx"))
  (expect (string/find "200" ok) "authed recognize")
  (expect (string/find "ok" ok) "recognize body")
  (def bad (http-round sock "POST" "/speech/recognize?token=secret" {"Content-Type" "audio/wav"} "RIFFxxxx"))
  (expect (string/find "401" bad) "query is not the token")
  (expect (string/find "rejected" bad) "rejected")
  (def wrong (http-round sock "POST" "/speech/recognize" {"Authorization" "Bearer nope"} "RIFFxxxx"))
  (expect (string/find "401" wrong) "wrong token")
  (def missing (http-round sock "POST" "/speech/missing" {"Authorization" "Bearer secret"} ""))
  (expect (string/find "404" missing) "unknown route")
  (defn calls []
    (def p (string dir "/calls"))
    (if (os/stat p) (length (string/trim (slurp p))) 0))
  (def before (calls))
  (def early (http-round sock "POST" "/speech/recognize" {"Authorization" "Bearer nope" "Content-Length" "8000000" "Content-Type" "audio/wav"} "RIFFxxxx"))
  (expect (string/find "401" early) "token before body")
  (expect (= (calls) before) "rejected does not run")
  (def chunked (http-round sock "POST" "/speech/recognize" {"Authorization" "Bearer secret" "Content-Type" "audio/wav" "Transfer-Encoding" "chunked"} "RIFFxxxx"))
  (expect (string/find "400" chunked) "chunked refused")
  (expect (= (calls) before) "chunked does not run")
  (def bare (http-raw sock "POST /speech/recognize HTTP/1.1\r\nHost: janus\r\nAuthorization: Bearer secret\r\nContent-Type: audio/wav\r\n\r\nRIFFxxxx"))
  (expect (string/find "400" bare) "length required")
  (ev/go (fn [] (http-round sock "POST" "/speech/recognize" {"Authorization" "Bearer secret" "Content-Type" "audio/wav"} "WAIT")))
  (var i 0)
  (while (and (< i 50) (not (os/stat (string dir "/started"))))
    (ev/sleep 0.05)
    (set i (+ i 1)))
  (expect (os/stat (string dir "/started")) "slow started")
  (def busy (http-round sock "POST" "/speech/recognize" {"Authorization" "Bearer secret" "Content-Type" "audio/wav"} "RIFFxxxx"))
  (expect (string/find "503" busy) "too many calls")
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
      (eprint "speech.janet check|serve")
      (os/exit 2))))
