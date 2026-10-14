# SPDX-License-Identifier: Apache-2.0
# Panel interaction model. docs/15. One state machine for every size
# class and every key map. The Waveshare profile is the first binding.
#
# Size class (docs/15 §1), first match: height <= 64 or width < 200 is
# compact; height > 200 or width >= 320 is wide; anything left is medium.
# A 240x240 framebuffer is wide because its height is over 200.

(defn size-class [w h]
  (cond
    (or (<= h 64) (< w 200)) :compact
    (or (> h 200) (>= w 320)) :wide
    :medium))

(defn pages-of [subjects]
  (def out @[:overview])
  (when (subjects :wan) (array/push out :wan))
  (when (subjects :lan) (array/push out :lan))
  (when (subjects :proxy) (array/push out :tunnel))
  (when (subjects :power) (array/push out :battery))
  out)

(def page-title
  {:overview "Overview"
   :wan "WAN"
   :lan "LAN"
   :tunnel "Tunnel"
   :battery "Battery"})

(defn copy-state [s]
  (def n @{})
  (eachk k s (put n k (s k)))
  n)

(defn make-state [width height caps subjects &opt single single-cap]
  (default single false)
  (def raw (or caps @{}))
  (def no-items (and (not (raw :item-prev)) (not (raw :item-next))))
  (def menu-mode (and (not single) (not (raw :page-prev)) (not (raw :page-next))))
  (def effective
    (if single
      @{:page-next true :refresh true}
      raw))
  @{
   :width width
   :height height
   :caps effective
   :single single
   :single-cap single-cap
   :no-items no-items
   :menu-mode menu-mode
   :can-nodes (and (not single) (not no-items) (raw :confirm))
   :pages (pages-of subjects)
   :screen (if menu-mode :menu :page)
   :page 0
   :focus 0
   :scroll 0
   :group nil
   :nodes @[]
   :saved-focus 0
   :hold nil
   :asleep false
   :ignore-release false
   :last-input 0
   :now 0})

(defn current-page [s]
  (get (s :pages) (s :page)))

(defn alarm-letter [snap]
  (cond
    (get-in snap ["battery" "warning"]) "B"
    (or (snap "tunnelError") (snap "refreshError")) "T"
    (some |(not ($ "up")) (or (snap "wans") @[])) "W"
    nil))

(defn alarm-line [snap]
  (cond
    (get-in snap ["battery" "warning"]) "battery"
    (or (snap "tunnelError") (snap "refreshError")) "tunnel"
    (some |(not ($ "up")) (or (snap "wans") @[])) "wan down"
    "ok"))

(defn body-rows [s snap]
  (cond
    (= (s :screen) :menu)
    (do
      (def rows @[])
      (for i 0 (length (s :pages))
        (array/push rows {:text (page-title (get (s :pages) i)) :focusable true :page-index i}))
      rows)
    (= (s :screen) :nodes)
    (do
      (def rows @[])
      (each name (s :nodes)
        (array/push rows {:text name :focusable true :node name :kind :node}))
      rows)
    (case (current-page s)
      :overview
      @[{:text (or (snap "host") "-") :focusable false}
        {:text (or (snap "uptime") "-") :focusable false}
        {:text (alarm-line snap) :focusable false}]
      :wan
      (do
        (def rows @[])
        (each wan (or (snap "wans") @[])
          (array/push rows
            {:text (string (wan "name") " " (if (wan "up") "up" "down") " " (or (wan "ipv4") "-"))
             :focusable true
             :kind :wan
             :detail @[(if (wan "up") "up" "down")
                       (or (wan "ipv4") "-")
                       (or (wan "ipv6") "-")
                       (or (wan "uptime") "-")]}))
        rows)
      :lan
      (do
        (def rows @[])
        (each lan (or (snap "lans") @[])
          (array/push rows
            {:text (string (lan "name") " " (lan "leases"))
             :focusable true
             :kind :lan
             :detail @[(or (lan "subnet") "-") (string (lan "leases"))]}))
        rows)
      :tunnel
      (do
        (def rows @[{:text (or (snap "mode") "-") :focusable false :kind :mode}])
        (each g (or (snap "groups") @[])
          (array/push rows
            {:text (string (g "name") " " (or (g "node") "-"))
             :focusable true
             :kind :group
             :group (g "name")
             :nodes (or (g "nodes") @[])
             :detail @[(or (g "node") "-") (or (g "strategy") "-")]}))
        rows)
      :battery
      (do
        (def battery (or (snap "battery") @{}))
        (def volts (or (battery "voltage") "-"))
        @[{:text (if (or (= volts "") (= volts "-")) "-" (string volts "V")) :focusable false}
          {:text (or (battery "direction") "idle") :focusable false}
          {:text (if (battery "armed") "armed" "unarmed") :focusable false}])
      @[])))

(defn geometry [s]
  [(max 1 (div (s :width) 6)) (max 1 (div (s :height) 8))])

(defn body-height [s]
  (def [_cols rows] (geometry s))
  (if (>= rows 3) (- rows 2) 0))

(defn reveal [s]
  (if (s :no-items)
    (put s :scroll 0)
    (let [vis (max 1 (body-height s))]
      (when (< (s :focus) (s :scroll))
        (put s :scroll (s :focus)))
      (when (>= (s :focus) (+ (s :scroll) vis))
        (put s :scroll (max 0 (- (+ (s :focus) 1) vis)))))))

(defn clamp-focus [s snap]
  (def rows (body-rows s snap))
  (def n (length rows))
  (cond
    (= n 0) (put s :focus 0)
    (>= (s :focus) n) (put s :focus (- n 1)))
  (reveal s))

(defn focus-first [s snap]
  (def rows (body-rows s snap))
  (var found nil)
  (for i 0 (length rows)
    (when (and (nil? found) (get (get rows i) :focusable))
      (set found i)))
  (put s :focus (or found 0))
  (put s :scroll 0))

(defn leave-nodes [s]
  (put s :screen :page)
  (put s :focus (or (s :saved-focus) 0))
  (put s :group nil)
  (put s :nodes @[])
  (reveal s))

(defn go-page [s snap dir]
  (cond
    (= (s :screen) :nodes)
    (when (< dir 0) (leave-nodes s))
    (= (s :screen) :menu) nil
    true
    (let [n (length (s :pages))]
      (when (> n 0)
        (put s :page (mod (+ (s :page) dir) n))
        (put s :screen :page)
        (focus-first s snap)))))

(defn move-item [s snap dir]
  (when (not (s :no-items))
    (def rows (body-rows s snap))
    (def n (length rows))
    (when (> n 0)
      (var i (s :focus))
      (var guard 0)
      (while (< guard n)
        (++ guard)
        (set i (mod (+ i dir) n))
        (when (get (get rows i) :focusable)
          (put s :focus i)
          (set guard n)))
      (reveal s))))

(defn go-back [s]
  (cond
    (= (s :screen) :nodes) (leave-nodes s)
    (and (s :menu-mode) (= (s :screen) :page))
    (do
      (put s :screen :menu)
      (put s :focus 0)
      (put s :scroll 0))))

(defn push-nodes [s row]
  (def copy @[])
  (each n (or (row :nodes) @[]) (array/push copy n))
  (put s :saved-focus (s :focus))
  (put s :group (row :group))
  (put s :nodes copy)
  (put s :screen :nodes)
  (put s :focus 0)
  (put s :scroll 0))

(defn do-confirm [s snap]
  (def rows (body-rows s snap))
  (def row (get rows (s :focus)))
  (cond
    (= (s :screen) :menu)
    (do
      (put s :screen :page)
      (put s :page (or (and row (row :page-index)) 0))
      (focus-first s snap)
      [s nil])
    (= (s :screen) :nodes)
    (if (and row (row :node))
      (let [action {:action :select :group (s :group) :node (row :node)}]
        (put s :screen :page)
        (put s :focus (or (s :saved-focus) 0))
        (put s :group nil)
        (put s :nodes @[])
        [s action])
      [s nil])
    (and
      (= (s :screen) :page)
      (= (current-page s) :tunnel)
      (s :can-nodes)
      row
      (= (row :kind) :group)
      (not (empty? (or (row :nodes) @[]))))
    (do
      (push-nodes s row)
      [s nil])
    true [s nil]))

(defn allowed? [s cap]
  (or ((s :caps) cap) (and (s :single) (= cap (s :single-cap)))))

(defn on-press [s event snap]
  (put s :last-input (event :ms))
  (def cap (event :cap))
  (cond
    (not (allowed? s cap)) [s nil]
    (and (s :single) (= cap (s :single-cap)))
    (do
      (put s :hold {:action :refresh :since (event :ms)})
      [s nil])
    (or (= cap :reboot-hold) (= cap :factory-reset))
    (do
      (put s :hold {:action (if (= cap :reboot-hold) :reboot :factory-reset) :since (event :ms)})
      [s nil])
    (= cap :refresh) [s {:action :refresh}]
    (= cap :page-next) (do (go-page s snap 1) [s nil])
    (= cap :page-prev) (do (go-page s snap -1) [s nil])
    (= cap :item-next) (do (move-item s snap 1) [s nil])
    (= cap :item-prev) (do (move-item s snap -1) [s nil])
    (= cap :confirm) (do-confirm s snap)
    (= cap :back) (do (go-back s) [s nil])
    true [s nil]))

(defn on-release [s event snap]
  (put s :last-input (event :ms))
  (def cap (event :cap))
  (def hold (s :hold))
  (cond
    (not (allowed? s cap)) [s nil]
    (or (and (s :single) (= cap (s :single-cap))) (= cap :reboot-hold) (= cap :factory-reset))
    (do
      (put s :hold nil)
      (cond
        (and hold (>= (- (event :ms) (hold :since)) 3000))
        [s {:action (hold :action)}]
        (and (s :single) (= cap (s :single-cap)) hold)
        (do (go-page s snap 1) [s nil])
        true [s nil]))
    true [s nil]))

(defn on-tick [s event]
  (def hold (s :hold))
  (if (and hold (>= (- (event :ms) (hold :since)) 3000))
    (do
      (def action {:action (hold :action)})
      (put s :hold nil)
      [s action])
    (do
      (when (and (nil? hold) (not (s :asleep)) (>= (- (event :ms) (s :last-input)) 60000))
        (put s :asleep true))
      [s nil])))

(defn wake [s event]
  (put s :asleep false)
  (put s :last-input (event :ms))
  (when (= (event :edge) "press")
    (put s :ignore-release true)))

(defn step [state event snap]
  (def s (copy-state state))
  (put s :now (or (event :ms) (s :now)))
  (case (event :edge)
    "tick" (on-tick s event)
    "press"
    (if (s :asleep)
      (do (wake s event) [s nil])
      (on-press s event snap))
    "release"
    (cond
      (s :asleep) (do (wake s event) [s nil])
      (s :ignore-release)
      (do
        (put s :ignore-release false)
        (put s :last-input (event :ms))
        [s nil])
      (on-release s event snap))
    [s nil]))

(defn cut [text n]
  (def width (if (< n 0) 0 n))
  (if (> (length text) width) (string/slice text 0 width) text))

(defn fit [text n]
  (def clipped (cut (or text "") n))
  (string clipped (string/repeat " " (- n (length clipped)))))

(defn hold-num [s]
  (def hold (s :hold))
  (def left (- 3000 (- (s :now) (hold :since))))
  (if (<= left 0) 1 (div (+ left 999) 1000)))

(defn header [s snap cols]
  (def title
    (case (s :screen)
      :menu "Pages"
      :nodes (or (s :group) "Nodes")
      (or (page-title (current-page s)) "")))
  (def alarm (alarm-letter snap))
  (if alarm
    (let [room (max 0 (- cols 1))
          name (cut title room)]
      (string name (string/repeat " " (- room (length name))) alarm))
    (fit title cols)))

(defn row-line [s row index cols]
  (def mark
    (if (and row (= index (s :focus)) (row :focusable) (not (s :no-items))) ">" " "))
  (fit (string mark (cut (if row (or (row :text) "") "") (max 0 (- cols 1)))) cols))

(defn detail-of [s snap]
  (def row (get (body-rows s snap) (s :focus)))
  (cond
    (or (nil? row) (s :asleep)) @[]
    (= (s :screen) :nodes) @[(or (row :text) "")]
    (not (row :focusable)) @[]
    (or (row :detail) @[])))

(defn footer [s cols]
  (if (s :hold)
    (fit (string "hold " (hold-num s)) cols)
    (fit "" cols)))

(defn render [state snap]
  (clamp-focus state snap)
  (def [cols rows] (geometry state))
  (def lines @[])
  (if (state :asleep)
    (for _i 0 rows (array/push lines (string/repeat " " cols)))
    (do
      (if (< rows 3)
        (do
          (array/push lines (header state snap cols))
          (for _i 1 rows (array/push lines (fit "" cols))))
        (do
          (array/push lines (header state snap cols))
          (def all (body-rows state snap))
          (def vis (body-height state))
          (def class (size-class (state :width) (state :height)))
          (def details (detail-of state snap))
          (def left (if (= class :wide) (max 1 (div cols 2)) cols))
          (def right (if (= class :wide) (- cols left) 0))
          (for i 0 vis
            (def abs (+ (state :scroll) i))
            (def row (get all abs))
            (if (= class :wide)
              (array/push lines (string (row-line state row abs left) (fit (or (get details i) "") right)))
              (array/push lines (row-line state row abs cols))))
          (array/push lines (footer state cols))))))
  lines)

(defn action-argv [janus action]
  (case (action :action)
    :refresh @[janus "proxy" "refresh"]
    :reboot @[janus "reboot"]
    :factory-reset @[janus "reset" "--state" "--yes"]
    :select @[janus "proxy" "select" (action :group) (action :node)]
    @[]))

(defn field [line]
  (string/split "\t" (string/trim line)))

(defn parse-conf [text]
  (def conf @{
    :width 128 :height 64 :driver "" :spi "" :dc 24 :reset 25
    :chip "/dev/gpiochip0" :host "janus" :mode "-" :proxy false
    :controls @[] :subjects @{} :runtime "/run/janus-hmi"
    :bin-janus "janus" :bin-panel "" :bin-snapshot ""})
  (each line (string/split "\n" text)
    (def p (field line))
    (def k (get p 0))
    (case k
      "" nil
      "width" (put conf :width (scan-number (get p 1)))
      "height" (put conf :height (scan-number (get p 1)))
      "driver" (put conf :driver (get p 1))
      "spi" (put conf :spi (get p 1))
      "dc" (put conf :dc (scan-number (get p 1)))
      "reset" (put conf :reset (scan-number (get p 1)))
      "chip" (put conf :chip (get p 1))
      "host" (put conf :host (get p 1))
      "mode" (put conf :mode (get p 1))
      "proxy" (put conf :proxy (= (get p 1) "1"))
      "runtime" (put conf :runtime (get p 1))
      "bin" (case (get p 1)
              "janus" (put conf :bin-janus (get p 2))
              "panel" (put conf :bin-panel (get p 2))
              "snapshot" (put conf :bin-snapshot (get p 2)))
      "subject" (put (conf :subjects) (keyword (get p 1)) (= (get p 2) "1"))
      "control" (array/push (conf :controls) {:name (get p 1) :cap (keyword (get p 2)) :gpio (scan-number (get p 3))})))
  conf)

(defn parse-snapshot [text]
  (def snap @{
    "host" "-"
    "uptime" "-"
    "mode" "-"
    "wans" @[]
    "lans" @[]
    "groups" @[]
    "tunnelError" false
    "refreshError" false
    "battery" @{"voltage" "-" "direction" "idle" "armed" false "warning" false}})
  (each line (string/split "\n" text)
    (def p (field line))
    (def k (get p 0))
    (case k
      "" nil
      "host" (put snap "host" (get p 1))
      "uptime" (put snap "uptime" (get p 1))
      "mode" (put snap "mode" (get p 1))
      "tunnel-error" (put snap "tunnelError" (= (get p 1) "1"))
      "refresh-error" (put snap "refreshError" (= (get p 1) "1"))
      "wan" (array/push (snap "wans")
              @{"name" (get p 1)
                "up" (= (get p 2) "1")
                "ipv4" (or (get p 3) "-")
                "ipv6" (or (get p 4) "-")
                "uptime" (or (get p 5) "-")})
      "lan" (array/push (snap "lans")
              @{"name" (get p 1)
                "leases" (or (scan-number (get p 2)) 0)
                "subnet" (or (get p 3) "-")})
      "group" (do
                (def nodes @[])
                (def raw (or (get p 4) ""))
                (when (not= raw "")
                  (each n (string/split "\x1f" raw)
                    (when (not= n "") (array/push nodes n))))
                (array/push (snap "groups")
                  @{"name" (get p 1) "node" (get p 2) "strategy" (get p 3) "nodes" nodes}))
      "battery" (put snap "battery"
                  @{"voltage" (get p 1)
                    "direction" (get p 2)
                    "armed" (= (get p 3) "1")
                    "warning" (= (get p 4) "1")})))
  snap)

(defn caps-of [names]
  (def caps @{})
  (each name names (put caps (keyword name) true))
  caps)

(defn full-caps []
  (caps-of ["page-prev" "page-next" "item-prev" "item-next" "confirm" "refresh" "reboot-hold" "back"]))

(defn full-subjects []
  {:wan true :lan true :proxy true :power true})

(defn press [state snap cap ms]
  (step state {:edge "press" :cap cap :ms ms} snap))

(defn release [state snap cap ms]
  (step state {:edge "release" :cap cap :ms ms} snap))

(defn tick [state snap ms]
  (step state {:edge "tick" :ms ms} snap))

(var failed 0)

(defn expect [name ok]
  (when (not ok)
    (eprint (string "fail " name))
    (++ failed)))

(defn blank-line? [line]
  (var i 0)
  (var ok true)
  (while (< i (length line))
    (when (not= (string/slice line i (+ i 1)) " ")
      (set ok false)
      (set i (length line)))
    (++ i))
  ok)

(defn mark-panel-dead [dead generation]
  (when (= (get dead 1) generation)
    (put dead 0 true))
  dead)

(defn check []
  (expect "compact" (= (size-class 128 64) :compact))
  (expect "narrow" (= (size-class 100 80) :compact))
  (expect "medium" (= (size-class 240 135) :medium))
  (expect "wide-square" (= (size-class 240 240) :wide))
  (expect "wide-short" (= (size-class 320 100) :wide))
  (expect "wide" (= (size-class 320 240) :wide))
  (expect "pages" (deep= (map string (pages-of {:wan false :lan true :proxy false :power true})) @["overview" "lan" "battery"]))

  (def snap @{
    "host" "janus"
    "uptime" "1h"
    "mode" "rule-based"
    "wans" @[@{"name" "main" "up" false "ipv4" "-" "ipv6" "-" "uptime" "5m"}]
    "lans" @[@{"name" "lan" "leases" 2 "subnet" "192.168.10.0/24"}]
    "groups" @[@{"name" "Auto" "node" "hk" "strategy" "url-test" "nodes" @["hk" "us"]}]
    "battery" @{"voltage" "3.40" "direction" "discharge" "armed" true "warning" true}
    "tunnelError" false
    "refreshError" false})
  (expect "alarm-b" (= (alarm-letter snap) "B"))
  (expect "line-b" (= (alarm-line snap) "battery"))
  (put-in snap ["battery" "warning"] false)
  (put snap "refreshError" true)
  (expect "alarm-t" (= (alarm-letter snap) "T"))
  (put snap "refreshError" false)
  (expect "alarm-w" (= (alarm-letter snap) "W"))
  (expect "line-w" (= (alarm-line snap) "wan down"))
  (put (get (snap "wans") 0) "up" true)
  (expect "alarm-ok" (= (alarm-letter snap) nil))
  (expect "line-ok" (= (alarm-line snap) "ok"))
  (put (get (snap "wans") 0) "up" false)

  (def state (make-state 128 64 (full-caps) (full-subjects)))
  (def frame (render state snap))
  (expect "rows" (= (length frame) 8))
  (expect "cols" (= (length (get frame 0)) 21))
  (expect "header" (= (get frame 0) (string "Overview" (string/repeat " " 12) "W")))
  (expect "host" (= (get frame 1) (string " janus" (string/repeat " " 15))))
  (expect "no-hold" (blank-line? (get frame 7)))

  (def [still _] (press state snap :item-next 10))
  (expect "overview-item" (and (= (still :page) 0) (= (still :focus) 0)))

  (def [p1 _] (press state snap :page-next 20))
  (def [p2 _] (press p1 snap :page-next 21))
  (def [p3 _] (press p2 snap :page-next 22))
  (expect "tunnel-page" (= (current-page p3) :tunnel))
  (def [nodes action] (press p3 snap :confirm 30))
  (expect "pushed" (= (nodes :screen) :nodes))
  (expect "confirm-not-reboot" (nil? action))
  (def node-frame (render nodes snap))
  (expect "node-header" (string/has-prefix? "Auto" (get node-frame 0)))
  (expect "node-focus" (string/has-prefix? ">hk" (get node-frame 1)))
  (def [back-page back-action] (press nodes snap :page-prev 40))
  (expect "page-prev-back" (and (= (back-page :screen) :page) (nil? back-action)))
  (def [nodes2 _] (press p3 snap :confirm 50))
  (def [chosen select-action] (press nodes2 snap :confirm 60))
  (expect "select" (and (= (select-action :action) :select) (= (select-action :group) "Auto") (= (select-action :node) "hk")))
  (expect "returned" (= (chosen :screen) :page))
  (expect "argv" (deep= (action-argv "/bin/janus" select-action) @["/bin/janus" "proxy" "select" "Auto" "hk"]))
  (expect "reset-argv" (deep= (action-argv "/bin/janus" {:action :factory-reset}) @["/bin/janus" "reset" "--state" "--yes"]))

  (def [held _] (press state snap :reboot-hold 0))
  (expect "hold3" (string/has-prefix? "hold 3" (get (render held snap) 7)))
  (def [later _] (tick held snap 1000))
  (expect "hold2" (string/has-prefix? "hold 2" (get (render later snap) 7)))
  (def [cancelled cancel-action] (release later snap :reboot-hold 2000))
  (expect "short-reboot" (nil? cancel-action))
  (expect "hold-cleared" (blank-line? (get (render cancelled snap) 7)))
  (def [again _] (press state snap :reboot-hold 0))
  (def [fired reboot-action] (tick again snap 3000))
  (expect "reboot" (= (reboot-action :action) :reboot))

  (def [ref refresh-action] (press state snap :refresh 5))
  (expect "refresh" (= (refresh-action :action) :refresh))

  (def factory-caps (full-caps))
  (put factory-caps :factory-reset true)
  (def factory (make-state 128 64 factory-caps (full-subjects)))
  (def [f1 _] (press factory snap :factory-reset 0))
  (def [fshort short-reset] (release f1 snap :factory-reset 1000))
  (expect "short-reset" (nil? short-reset))
  (def [f2 _] (press factory snap :factory-reset 0))
  (def [_f3 reset-action] (tick f2 snap 3000))
  (expect "factory" (= (reset-action :action) :factory-reset))

  (def [slept _] (tick state snap 60000))
  (expect "asleep" (slept :asleep))
  (expect "blank" (blank-line? (get (render slept snap) 0)))
  (def [woke wake-action] (press slept snap :page-next 60000))
  (expect "wake-page" (and (= (woke :page) 0) (not (woke :asleep)) (nil? wake-action)))
  (def [ignored _] (release woke snap :page-next 60100))
  (expect "wake-release" (= (ignored :page) 0))

  (var lastp state)
  (for _i 0 5
    (def [n _] (press lastp snap :page-next 70))
    (set lastp n))
  (expect "wrap-next" (= (current-page lastp) :overview))
  (def [prev _] (press state snap :page-prev 80))
  (expect "wrap-prev" (= (current-page prev) :battery))

  (def many @[])
  (each name ["a" "b" "c" "d" "e" "f" "g" "h"]
    (array/push many @{"name" name "up" true "ipv4" "1.1.1.1" "ipv6" "-" "uptime" "1m"}))
  (def long (table/clone snap))
  (put long "wans" many)
  (var wan-page state)
  (def [wp _] (press state long :page-next 90))
  (set wan-page wp)
  (var moved wan-page)
  (for _i 0 6
    (def [n _] (press moved long :item-next 100))
    (set moved n))
  (def scrolled (render moved long))
  (expect "scrolled-off" (string/has-prefix? " b " (get scrolled 1)))
  (expect "focus-kept" (string/find ">g " (string/join scrolled "\n")))

  (def cut-snap (table/clone snap))
  (put cut-snap "wans" @[@{"name" "verylongname" "up" true "ipv4" "100.100.100.100" "ipv6" "-" "uptime" "-"}])
  (def [cut-page _] (press (make-state 128 64 (full-caps) (full-subjects)) cut-snap :page-next 1))
  (def cut-line (get (render cut-page cut-snap) 1))
  (expect "cut" (nil? (string/find "100.100.100.100" cut-line)))
  (def [med _] (press (make-state 240 135 (full-caps) (full-subjects)) cut-snap :page-next 1))
  (expect "medium-full" (string/find "100.100.100.100" (get (render med cut-snap) 1)))

  (def wide-snap (table/clone snap))
  (put wide-snap "wans" @[@{"name" "main" "up" true "ipv4" "10.0.0.8" "ipv6" "2001:db8::1" "uptime" "9m"}])
  (put-in wide-snap ["battery" "warning"] false)
  (def wide (make-state 320 240 (full-caps) (full-subjects)))
  (def overview (render wide wide-snap))
  (expect "wide-cols" (= (length (get overview 0)) 53))
  (expect "wide-empty" (= (string/slice (get overview 1) 26) (string/repeat " " 27)))
  (def [wide-wan _] (press wide wide-snap :page-next 2))
  (def wide-frame (render wide-wan wide-snap))
  (def wide-text (string/join wide-frame "\n"))
  (expect "wide-v4" (string/find "10.0.0.8" wide-text))
  (expect "wide-v6" (string/find "2001:db8::1" wide-text))
  (expect "wide-age" (string/find "9m" wide-text))
  (def [wide-tunnel _] (press wide-wan wide-snap :page-next 3))
  (def [wide-tunnel2 _] (press wide-tunnel wide-snap :page-next 4))
  (def [wide-nodes _] (press wide-tunnel2 wide-snap :confirm 5))
  (def node-wide (string/join (render wide-nodes wide-snap) "\n"))
  (expect "wide-node" (string/find "hk" node-wide))
  (expect "wide-node-only" (nil? (string/find "url-test" (string/slice (get (render wide-nodes wide-snap) 1) 26))))

  (def menu (make-state 128 64 (caps-of ["item-next" "confirm" "back"]) {:wan true :lan false :proxy false :power false}))
  (expect "menu" (= (menu :screen) :menu))
  (def [menu2 _] (press menu snap :item-next 1))
  (def [entered _] (press menu2 snap :confirm 2))
  (expect "entered" (and (= (entered :screen) :page) (= (current-page entered) :wan)))
  (def [menu3 _] (press entered snap :back 3))
  (expect "menu-back" (= (menu3 :screen) :menu))

  (def no-items (make-state 128 64 (caps-of ["page-next" "page-prev" "confirm"]) (full-subjects)))
  (var tunnel no-items)
  (for _i 0 3
    (def [n _] (press tunnel snap :page-next 1))
    (set tunnel n))
  (def [stuck _] (press tunnel snap :confirm 2))
  (expect "no-node-list" (= (stuck :screen) :page))
  (expect "no-marker" (= (string/slice (get (render tunnel snap) 1) 0 1) " "))

  (def no-confirm (make-state 128 64 (caps-of ["page-next" "page-prev" "item-next" "item-prev"]) (full-subjects)))
  (var status no-confirm)
  (for _i 0 3
    (def [n _] (press status snap :page-next 1))
    (set status n))
  (def [status2 _] (press status snap :confirm 2))
  (expect "status-only" (= (status2 :screen) :page))

  (def one (make-state 128 64 (caps-of ["reboot-hold"]) (full-subjects) true :reboot-hold))
  (expect "one-page" (= (one :screen) :page))
  (def [one-hold _] (press one snap :reboot-hold 0))
  (def [_one refresh-only] (tick one-hold snap 3000))
  (expect "one-refresh" (= (refresh-only :action) :refresh))
  (def [tap _] (press one snap :reboot-hold 0))
  (def [tapped _] (release tap snap :reboot-hold 400))
  (expect "one-next" (= (current-page tapped) :wan))

  (def parsed (parse-snapshot "host\trouter\nuptime\t2m\nmode\trule-based\ntunnel-error\t1\nwan\tmain\t0\t-\t-\t-\ngroup\tAuto\thk\turl-test\thk\x1fus\nbattery\t4.10\tdischarge\t1\t0\n"))
  (expect "parsed-host" (= (parsed "host") "router"))
  (expect "parsed-tunnel" (parsed "tunnelError"))
  (expect "parsed-nodes" (= (length (get (get (parsed "groups") 0) "nodes")) 2))
  (expect "parsed-volts" (= (get (parsed "battery") "voltage") "4.10"))

  (def panel-dead @[false 1])
  (mark-panel-dead panel-dead 1)
  (expect "panel-dead" (get panel-dead 0))
  (put panel-dead 0 false)
  (put panel-dead 1 2)
  (mark-panel-dead panel-dead 1)
  (expect "panel-stale" (not (get panel-dead 0)))

  (if (> failed 0) (os/exit 1))
  (print "ok"))

(defn now-ms []
  (math/floor (* (os/clock :monotonic) 1000)))

(defn capture [argv]
  (def tmp (file/temp))
  (def code (os/execute argv :p {:out tmp :err stderr}))
  (file/seek tmp :set 0)
  (def text (file/read tmp :all))
  (file/close tmp)
  [code (or text "")])

(defn send-frame [proc lines]
  (def buf @"FRAME\n")
  (each line lines
    (buffer/push buf line "\n"))
  (buffer/push buf "END\n")
  (ev/write (proc :in) buf))

(defn take-lines [inbox]
  (def out @[])
  (while (not (empty? inbox))
    (array/push out (array/remove inbox 0)))
  out)

(defn gpio-arg [controls]
  (def parts @[])
  (each c controls
    (when (and (c :gpio) (not= (c :cap) :unbound))
      (array/push parts (string (c :name) "=" (c :gpio)))))
  (string/join parts ","))

(defn spawn-panel [conf]
  (def spi (conf :spi))
  (when (and (= (conf :driver) "sh1106") spi (not= spi "") (os/stat spi) (not= (conf :bin-panel) ""))
    (def args @[(conf :bin-panel)
                "--spi" spi
                "--dc" (string (conf :dc))
                "--reset" (string (conf :reset))
                "--chip" (conf :chip)
                "--gpio" (gpio-arg (conf :controls))])
    (try
      (os/spawn args :p {:in :pipe :out :pipe :err stderr})
      ([_] nil))))

(defn watch-keys [proc inbox dead generation]
  (ev/spawn
    (fn []
      (while true
        (def line (ev/read (proc :out) :line))
        (if (nil? line)
          (do
            (mark-panel-dead dead generation)
            (break))
          (array/push inbox (string/trim line)))))))

(defn run-action [conf action refresh-bad]
  (def argv (action-argv (conf :bin-janus) action))
  (when (not (empty? argv))
    (eprint (string "janus-hmi: " (string/join (array/slice argv 1) " ")))
    (def code (os/execute argv :p {:out stderr :err stderr}))
    (when (= (action :action) :refresh)
      (put refresh-bad 0 (not= code 0)))))

(defn load-snap [conf previous refresh-bad]
  (if (or (nil? (conf :bin-snapshot)) (= (conf :bin-snapshot) ""))
    previous
    (let [[code text] (capture @[(conf :bin-snapshot) (or (conf :path) "")])]
      (if (= code 0)
        (let [snap (parse-snapshot text)]
          (when (get refresh-bad 0) (put snap "refreshError" true))
          snap)
        previous))))

(defn daemon [path]
  (def text (slurp path))
  (def conf (parse-conf text))
  (put conf :path path)
  (def bound @[])
  (each c (conf :controls)
    (when (not= (c :cap) :unbound)
      (array/push bound c)))
  (def caps @{})
  (each c bound (put caps (c :cap) true))
  (def single (= (length bound) 1))
  (def single-cap (if single ((get bound 0) :cap) nil))
  (var state (make-state (conf :width) (conf :height) caps (conf :subjects) single single-cap))
  (def by-name @{})
  (each c bound (put by-name (c :name) (c :cap)))
  (var snap @{
    "host" (conf :host) "uptime" "-" "mode" (conf :mode)
    "wans" @[] "lans" @[] "groups" @[]
    "tunnelError" false "refreshError" false
    "battery" @{"voltage" "-" "direction" "idle" "armed" false "warning" false}})
  (def refresh-bad @[false])
  (set snap (load-snap conf snap refresh-bad))
  (def started (now-ms))
  (put state :last-input started)
  (put state :now started)
  (def inbox @[])
  (def dead @[false 0])
  (var panel nil)
  (var panel-noted false)
  (var next-panel 0)
  (var last-snap started)
  (def frame-dir (conf :runtime))
  (try (os/mkdir frame-dir) ([_] nil))
  (while true
    (def ms (now-ms))
    (when (and (or (nil? panel) (get dead 0)) (>= ms next-panel))
      (when panel
        (try (os/proc-wait panel) ([_] nil))
        (set panel nil))
      (def generation (+ (get dead 1) 1))
      (put dead 0 false)
      (put dead 1 generation)
      (set panel (spawn-panel conf))
      (if panel
        (do
          (set panel-noted false)
          (watch-keys panel inbox dead generation))
        (do
          (set next-panel (+ ms 5000))
          (when (and (= (conf :driver) "sh1106") (not panel-noted))
            (eprint "janus-hmi: panel device is not open")
            (set panel-noted true)))))
    (each line (take-lines inbox)
      (def parts (string/split " " line))
      (def cap (get by-name (get parts 0)))
      (def edge (get parts 1))
      (when (and cap edge)
        (def [ns action] (step state {:edge edge :cap cap :ms (now-ms)} snap))
        (set state ns)
        (when action (run-action conf action refresh-bad))))
    (def [ns action] (step state {:edge "tick" :ms (now-ms)} snap))
    (set state ns)
    (when action (run-action conf action refresh-bad))
    (when (>= (- ms last-snap) 1000)
      (set snap (load-snap conf snap refresh-bad))
      (set last-snap ms))
    (def lines (render state snap))
    (spit (string frame-dir "/frame.txt") (string (string/join lines "\n") "\n"))
    (when (and panel (not (get dead 0)))
      (def wrote (try (do (send-frame panel lines) true) ([_] nil)))
      (when (not wrote) (put dead 0 true)))
    (ev/sleep 0.2)))

(defn main [&]
  (def args (dyn :args))
  (cond
    (find |(= $ "check") args) (check)
    (find |(= $ "class") args)
    (let [i (index-of "class" args)]
      (print (string (size-class (scan-number (get args (+ i 1))) (scan-number (get args (+ i 2)))))))
    (find |(= $ "run") args)
    (let [i (index-of "run" args)]
      (def path (get args (+ i 1)))
      (if path (daemon path) (do (eprint "hmi.janet run CONF") (os/exit 2))))
    (do
      (eprint "hmi.janet check|class W H|run CONF")
      (os/exit 2))))
