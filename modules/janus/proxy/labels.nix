# SPDX-License-Identifier: Apache-2.0
# Label keys, selectors, and the checks in docs/07 §11.
{lib}: let
  official = lib.filter (s: s != "") (lib.splitString "\n" (builtins.readFile ./iso3166-alpha2.txt));
  officialSet = lib.listToAttrs (map (c: {
    name = c;
    value = true;
  })
  official);
  user =
    map (c: "q${c}") (lib.stringToCharacters "mnopqrstuvwxyz")
    ++ map (c: "x${c}") (lib.stringToCharacters "abcdefghijklmnopqrstuvwxyz")
    ++ ["zz"];
  userSet = lib.listToAttrs (map (c: {
    name = c;
    value = true;
  })
  user);
  protocols = ["vless" "vmess" "trojan" "shadowsocks" "hysteria2" "tuic"];
  combinators = ["any" "all" "not"];

  keyError = key:
    if builtins.elem key combinators
    then "the words any, all, and not are selector combinators"
    else let
      chars = lib.stringToCharacters key;
      first =
        if chars == []
        then ""
        else builtins.head chars;
      okRest = c: let
        n = builtins.stringLength c;
      in
        n < 4 && (builtins.match "[A-Za-z0-9_-]" c != null || n > 1);
      firstOk =
        builtins.match "[A-Za-z_]" first != null
        || (builtins.stringLength first > 1 && builtins.stringLength first < 4);
    in
      if chars == [] || !firstOk || !lib.all okRest chars
      then "a key starts with a letter or _, then letters, digits, _, or -"
      else null;

  tokenOk = s:
    builtins.isString s
    && s != ""
    && !lib.hasInfix " " s
    && !lib.hasInfix "\n" s
    && lib.all (c: let
      n = builtins.stringLength c;
    in
      n < 4 && (builtins.match "[A-Za-z0-9-]" c != null || n > 1))
    (lib.stringToCharacters s);

  regionMessage = c:
    if c == "uk"
    then "uk is not a region code. The United Kingdom is gb."
    else if c == "eu"
    then "eu is not a region code."
    else if (officialSet.${c} or false) || (userSet.${c} or false)
    then null
    else "${c} is not an officially assigned or user-assigned region code.";

  durationOk = s: builtins.isString s && builtins.match "[0-9]+(ms|s|m|h)" s != null;

  durationSeconds = s: let
    parts = builtins.match "([0-9]+)(ms|s|m|h)" s;
    n = lib.toInt (builtins.elemAt parts 0);
    unit = builtins.elemAt parts 1;
  in
    if unit == "ms"
    then 1
    else if unit == "s"
    then n
    else if unit == "m"
    then n * 60
    else n * 3600;

  numberValue = v: builtins.isInt v || builtins.isFloat v;

  defsOf = cfg: let
    lat = cfg.labels.latency or {};
  in
    {
      vendor = {
        type = "string";
        values = [];
      };
      protocol = {
        type = "enum";
        values = protocols;
      };
      latency = {
        type = "number";
        values = [];
        timeout = lat.timeout or "3s";
        interval = lat.interval or "5m";
      };
    }
    // lib.mapAttrs (_: spec: {
      type = spec.type;
      values = spec.values or [];
    }) (lib.removeAttrs cfg.labels ["vendor" "protocol" "latency"]);

  tokenListErrors = where: def: value: let
    items =
      if builtins.isString value
      then [value]
      else if builtins.isList value
      then value
      else null;
  in
    if items == null
    then ["${where} is not a token or a list of tokens."]
    else
      lib.concatMap (item:
        if !tokenOk item
        then ["${where} value '${toString item}' is not a label token."]
        else if def.type == "enum" && !(builtins.elem item def.values)
        then ["${where} value '${item}' is not in values."]
        else if def.type == "region" && regionMessage item != null
        then ["${where}: ${regionMessage item}"]
        else [])
      items;

  matcherErrors = where: value:
    if !builtins.isAttrs value
    then ["${where} is not a matcher."]
    else if !(builtins.elem (value.kind or null) ["regex" "glob" "peg"])
    then ["${where}.kind is not regex, glob, or peg."]
    else if !builtins.isString (value.pattern or null) || value.pattern == ""
    then ["${where}.pattern is required."]
    else [];

  compareErrors = where: value:
    if !builtins.isAttrs value
    then ["${where} is not a number comparison."]
    else let
      present = lib.filter (n: value ? ${n}) ["below" "above" "equal"];
    in
      if present != ["below"] && present != ["above"] && present != ["equal"]
      then ["${where} needs exactly one of below, above, or equal."]
      else if !numberValue value.${builtins.head present}
      then ["${where}.${builtins.head present} is not a number."]
      else [];

  constraintErrors = where: def: key: value:
    if def.type == "empty"
    then
      if value == key
      then []
      else ["${where} must be the key written again."]
    else if def.type == "bool"
    then
      if builtins.isAttrs value && value ? not && builtins.attrNames value == ["not"]
      then
        if builtins.isBool value.not
        then []
        else ["${where}.not must be true or false."]
      else if builtins.isBool value
      then []
      else ["${where} must be true or false."]
    else if def.type == "number"
    then
      if builtins.isAttrs value && value ? not && builtins.attrNames value == ["not"]
      then compareErrors "${where}.not" value.not
      else compareErrors where value
    else if builtins.isAttrs value && value ? not && builtins.attrNames value == ["not"]
    then
      if def.type == "string" && builtins.isAttrs value.not
      then matcherErrors "${where}.not" value.not
      else tokenListErrors "${where}.not" def value.not
    else if builtins.isAttrs value && def.type == "string"
    then matcherErrors where value
    else tokenListErrors where def value;

  selectorErrors = defs: where: sel:
    if !builtins.isAttrs sel
    then ["${where} is not a selector."]
    else let
      names = builtins.attrNames sel;
      combs = lib.filter (n: builtins.elem n combinators) names;
    in
      if names == []
      then []
      else if combs != [] && (lib.length names != 1 || lib.length combs != 1)
      then ["${where} mixes a combinator with a key constraint."]
      else if names == ["any"] || names == ["all"]
      then let
        kind = builtins.head names;
        items = sel.${kind};
      in
        if !builtins.isList items
        then ["${where}.${kind} is not a list."]
        else
          lib.concatLists (lib.imap0 (i: item:
            selectorErrors defs "${where}.${kind}.${toString i}" item)
          items)
      else if names == ["not"]
      then
        if !builtins.isAttrs sel.not
        then ["${where}.not is not a selector."]
        else selectorErrors defs "${where}.not" sel.not
      else
        lib.concatLists (map (name: let
          spelled = keyError name;
        in
          if spelled != null
          then ["${where}.${name}: ${spelled}."]
          else if !(defs ? ${name})
          then ["${where} names '${name}', which has no declaration."]
          else constraintErrors "${where}.${name}" defs.${name} name sel.${name})
        names);

  failoverErrors = defs: where: entries:
    if !builtins.isList entries
    then ["${where} is not a list."]
    else
      lib.concatLists (lib.imap0 (i: entry:
        if entry == "direct" || entry == "block"
        then []
        else if builtins.isString entry
        then ["${where}.${toString i} is not a selector, direct, or block."]
        else selectorErrors defs "${where}.${toString i}" entry)
      entries);

  oneTarget = where: rule:
    let
      hasT = (rule.target or null) != null;
      hasL = (rule.labels or null) != null;
      hasF = (rule.failover or null) != null;
      n =
        (if hasT
        then 1
        else 0)
        + (
          if hasL
          then 1
          else 0
        )
        + (
          if hasF
          then 1
          else 0
        );
    in
      if n != 1
      then ["${where} needs exactly one of target, labels, or failover."]
      else if hasT && rule.target != "direct" && rule.target != "block"
      then ["${where}.target '${toString rule.target}' is not direct or block."]
      else [];

  ruleShapeErrors = defs: where: rule:
    oneTarget where rule
    ++ (
      if (rule.labels or null) != null
      then selectorErrors defs "${where}.labels" rule.labels
      else if (rule.failover or null) != null
      then failoverErrors defs "${where}.failover" rule.failover
      else []
    );

  countryErrors = where: codes:
    lib.concatMap (c:
      if c == "uk"
      then ["${where}: uk is not a region code. The United Kingdom is gb."]
      else if c == "eu"
      then ["${where}: eu is not a region code."]
      else if userSet.${c} or false
      then ["${where}: ${c} is user-assigned and is not a geoip result."]
      else if !(officialSet.${c} or false)
      then ["${where}: ${c} is not an officially assigned region code."]
      else [])
    codes;

  valueOfType = where: def: key: value:
    if def.type == "empty"
    then
      if value == key
      then []
      else ["${where} must be the key written again."]
    else if def.type == "bool"
    then
      if builtins.isBool value
      then []
      else ["${where} must be true or false."]
    else if def.type == "number"
    then
      if numberValue value
      then []
      else ["${where} must be a number."]
    else if def.type == "string"
    then
      if tokenOk value
      then []
      else ["${where} is not a label token."]
    else if def.type == "enum"
    then
      if tokenOk value && builtins.elem value def.values
      then []
      else ["${where} is not in values."]
    else if def.type == "region"
    then
      if builtins.isString value && regionMessage value == null
      then []
      else ["${where}: ${
        if builtins.isString value
        then regionMessage value
        else "a region value is a lowercase code."
      }"]
    else ["${where} has no type."];

  labelingErrors = where: def: rules:
    let
      kinds = map (r: r.match.kind or null) rules;
      http = lib.filter (k: k == "http") kinds;
    in
      lib.optionals (lib.any (k: k == "query") kinds) [
        "${where} uses kind query, which is not accepted."
      ]
      ++ lib.optionals (http != [] && (def.type != "empty" || lib.length rules != 1)) [
        "${where} allows http only on type empty, as its one rule."
      ]
      ++ lib.concatLists (lib.imap0 (i: rule: let
        w = "${where}.${toString i}";
        kind = rule.match.kind or null;
        value = rule.value or null;
      in
        if kind == "query"
        then []
        else if kind == "http"
        then
          lib.optionals (value != null) ["${w} has a value. An http rule does not."]
          ++ lib.optionals ((rule.match.url or null) == null) ["${w}.url is required."]
          ++ lib.optionals ((rule.match.timeout or null) != null && !durationOk rule.match.timeout) [
            "${w}.timeout is not a duration."
          ]
          ++ lib.optionals ((rule.match.interval or null) != null && !durationOk rule.match.interval) [
            "${w}.interval is not a duration."
          ]
        else if kind == "geoip"
        then
          lib.optionals (def.type != "region") ["${w} geoip is legal only on type region."]
          ++ lib.optionals (value != null) ["${w} has a value. A geoip rule does not."]
          ++ countryErrors "${w}.countries" (rule.match.countries or [])
        else if builtins.elem kind ["regex" "glob" "peg"]
        then
          lib.optionals (!builtins.isString (rule.match.pattern or null) || rule.match.pattern == "") [
            "${w}.pattern is required."
          ]
          ++ (
            if def.type == "empty"
            then lib.optionals (value != null) ["${w} has a value. An empty rule does not."]
            else if value == null
            then ["${w} needs a value."]
            else valueOfType "${w}.value" def "" value
          )
        else ["${w}.kind is not a labeling rule."])
      rules);

  declarationErrors = cfg:
    lib.optionals (cfg.labels ? vendor) [
      "janus.proxy.labels.vendor is declared by the module."
    ]
    ++ lib.optionals (cfg.labels ? protocol) [
      "janus.proxy.labels.protocol is declared by the module."
    ]
    ++ lib.concatMap (name: let
      spec = cfg.labels.${name};
      spelled = keyError name;
      lat = name == "latency";
    in
      if spelled != null
      then ["janus.proxy.labels.${name}: ${spelled}."]
      else if lat
      then
        lib.optionals ((spec.type or null) != null && spec.type != "number") [
          "janus.proxy.labels.latency is a number. The operator does not set type."
        ]
        ++ lib.optionals ((spec.values or []) != []) [
          "janus.proxy.labels.latency has no values list."
        ]
        ++ lib.optionals ((spec.rules or []) != []) [
          "janus.proxy.labels.latency has no rules."
        ]
        ++ lib.optionals (!durationOk (spec.timeout or "3s")) [
          "janus.proxy.labels.latency.timeout is not a duration."
        ]
        ++ lib.optionals (!durationOk (spec.interval or "5m")) [
          "janus.proxy.labels.latency.interval is not a duration."
        ]
      else
        lib.optionals (!builtins.elem (spec.type or "") ["string" "number" "bool" "enum" "empty" "region"]) [
          "janus.proxy.labels.${name}.type is not string, number, bool, enum, empty, or region."
        ]
        ++ lib.optionals (spec.type or null == "enum" && (spec.values or []) == []) [
          "janus.proxy.labels.${name} needs a non-empty values list."
        ]
        ++ lib.optionals ((spec.type or null) != "enum" && (spec.values or []) != []) [
          "janus.proxy.labels.${name} has a values list. Only enum uses one."
        ]
        ++ lib.concatMap (item:
          if tokenOk item
          then []
          else ["janus.proxy.labels.${name} values entry is not a token."])
        (spec.values or [])
        ++ labelingErrors "janus.proxy.labels.${name}.rules" {
          type = spec.type or "";
          values = spec.values or [];
        } (spec.rules or []))
    (builtins.attrNames cfg.labels);

  nodeErrors = cfg: defs:
    lib.concatLists (lib.mapAttrsToList (name: node:
      lib.optionals (node.labels ? protocol) [
        "janus.proxy.nodes.${name}.labels.protocol fails evaluation."
      ]
      ++ lib.concatLists (lib.mapAttrsToList (key: value: let
        spelled = keyError key;
      in
        if key == "protocol"
        then []
        else if spelled != null
        then ["janus.proxy.nodes.${name}.labels.${key}: ${spelled}."]
        else if !(defs ? ${key})
        then ["janus.proxy.nodes.${name}.labels.${key} has no declaration."]
        else valueOfType "janus.proxy.nodes.${name}.labels.${key}" defs.${key} key value)
      (lib.removeAttrs node.labels ["protocol"])))
    cfg.nodes);

  targetErrors = cfg: lans: defs: let
    top =
      if builtins.isString cfg.defaultTarget
      then
        if cfg.defaultTarget == "direct" || cfg.defaultTarget == "block"
        then []
        else ["janus.proxy.defaultTarget '${cfg.defaultTarget}' is not direct, block, or a selector."]
      else selectorErrors defs "janus.proxy.defaultTarget" cfg.defaultTarget;
    rules = lib.concatLists (lib.imap0 (i: rule: ruleShapeErrors defs "janus.proxy.rules.${toString i}" rule) cfg.rules);
    lanTargets = lib.concatLists (lib.mapAttrsToList (name: lan:
      (lib.optionals (lan.proxy.defaultTarget != null) (
        if builtins.isString lan.proxy.defaultTarget
        then
          if lan.proxy.defaultTarget == "direct" || lan.proxy.defaultTarget == "block"
          then []
          else ["janus.network.lans.${name}.proxy.defaultTarget is not direct, block, or a selector."]
        else selectorErrors defs "janus.network.lans.${name}.proxy.defaultTarget" lan.proxy.defaultTarget
      ))
      ++ lib.optionals (lan.proxy.rules != null) (lib.concatLists (lib.imap0 (i: rule:
        ruleShapeErrors defs "janus.network.lans.${name}.proxy.rules.${toString i}" rule)
      lan.proxy.rules)))
    lans);
  in
    top ++ rules ++ lanTargets;

  collectKeys = sel:
    if !builtins.isAttrs sel
    then []
    else let
      names = builtins.attrNames sel;
    in
      if names == ["any"] || names == ["all"]
      then lib.concatMap collectKeys (sel.${builtins.head names} or [])
      else if names == ["not"]
      then collectKeys (sel.not or {})
      else lib.filter (n: !(builtins.elem n combinators)) names;

  selectorsOf = cfg: lans: let
    fromRule = rule:
      (lib.optional ((rule.labels or null) != null) rule.labels)
      ++ lib.optionals ((rule.failover or null) != null) (lib.filter builtins.isAttrs rule.failover);
    fromRules = rules: lib.concatMap fromRule rules;
    lanSels = lib.concatLists (lib.mapAttrsToList (_: lan:
      (lib.optional (lan.proxy.defaultTarget != null && builtins.isAttrs lan.proxy.defaultTarget) lan.proxy.defaultTarget)
      ++ lib.optionals (lan.proxy.rules != null) (fromRules lan.proxy.rules))
    lans);
  in
    (lib.optional (builtins.isAttrs cfg.defaultTarget) cfg.defaultTarget)
    ++ fromRules cfg.rules
    ++ lanSels;

  httpInterval = spec: let
    rule = lib.head (spec.rules or []);
  in
    (rule.match.interval or null);

  probeOf = cfg: lans: let
    keys = lib.unique (lib.concatMap collectKeys (selectorsOf cfg lans));
    wantLatency = builtins.elem "latency" keys;
    httpNames = lib.filter (name:
      name != "latency"
      && cfg.labels ? ${name}
      && lib.any (r: (r.match.kind or null) == "http") (cfg.labels.${name}.rules or [])
      && builtins.elem name keys)
    (builtins.attrNames cfg.labels);
    lat = cfg.labels.latency or {};
    seconds =
      (lib.optional wantLatency (durationSeconds (lat.interval or "5m")))
      ++ map (name: let
        interval = httpInterval cfg.labels.${name};
      in durationSeconds (if interval == null then "1h" else interval)) httpNames;
  in {
    enable = wantLatency || httpNames != [];
    interval =
      if seconds == []
      then "300s"
      else "${toString (lib.foldl' lib.min (builtins.head seconds) seconds)}s";
  };

  modelLabels = cfg: let
    lat = cfg.labels.latency or {};
    normRule = rule: {
      match = {
        kind = rule.match.kind;
        pattern = rule.match.pattern;
        caseInsensitive = rule.match.caseInsensitive;
        countries = rule.match.countries or [];
        url = rule.match.url or null;
        timeout = rule.match.timeout or null;
        interval = rule.match.interval or null;
      };
      value = rule.value or null;
    };
  in {
    vendor = {
      type = "string";
      rules = [];
    };
    protocol = {
      type = "enum";
      values = protocols;
      rules = [];
    };
    latency = {
      type = "number";
      timeout = lat.timeout or "3s";
      interval = lat.interval or "5m";
      rules = [];
    };
  } // lib.mapAttrs (_: spec: {
    type = spec.type;
    values = spec.values or [];
    rules = map normRule (spec.rules or []);
  }) (lib.removeAttrs cfg.labels ["vendor" "protocol" "latency"]);

  check = cfg: lans: let
    defs = defsOf cfg;
  in
    declarationErrors cfg ++ nodeErrors cfg defs ++ targetErrors cfg lans defs;
in {
  inherit official protocols modelLabels check probeOf;
}
