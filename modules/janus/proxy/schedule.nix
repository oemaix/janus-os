# SPDX-License-Identifier: Apache-2.0
# Refresh schedules for subscriptions and Geo data. D-0044.
# Cron day-of-week: 0 and 7 are Sunday, 1 is Monday. systemd weekday
# names avoid systemd's own numbering.
{lib}: let
  dowName = {
    "0" = "Sun";
    "1" = "Mon";
    "2" = "Tue";
    "3" = "Wed";
    "4" = "Thu";
    "5" = "Fri";
    "6" = "Sat";
    "7" = "Sun";
  };

  formError = s: "janus interval '${s}' is not Nh, Nm, weekly, daily, hourly, or a five-field cron expression. The day-of-month and month must be *. The day-of-week may be * or a list such as 2,4,6 (0 and 7 are Sunday).";

  dowError = field: "janus interval day-of-week '${field}' must be * or a comma-separated list of 0-7. 0 and 7 are Sunday.";

  dowNames = field: let
    days = lib.splitString "," field;
    bad = lib.filter (day: !(dowName ? ${day})) days;
  in
    if days == [] || bad != []
    then null
    else lib.unique (map (day: dowName.${day}) days);

  pad = v:
    if v == "*"
    then "*"
    else if lib.stringLength v < 2
    then "0${v}"
    else v;

  parse = s: let
    parts = lib.splitString " " s;
    cron =
      lib.length parts == 5
      && builtins.elemAt parts 2 == "*"
      && builtins.elemAt parts 3 == "*";
    field = if cron then builtins.elemAt parts 4 else "";
    names = if field == "*" then [] else dowNames field;
  in
    if s == "weekly" || s == "daily" || s == "hourly"
    then {calendar = s;}
    else if lib.match "[0-9]+h" s != null
    then {calendar = "00/${lib.removeSuffix "h" s}:00:00";}
    else if lib.match "[0-9]+m" s != null
    then {calendar = "*:0/${lib.removeSuffix "m" s}:00";}
    else if cron && field == "*"
    then {calendar = "*-*-* ${pad (builtins.elemAt parts 1)}:${pad (builtins.elemAt parts 0)}:00";}
    else if cron && names != null
    then {calendar = "${lib.concatStringsSep "," names} *-*-* ${pad (builtins.elemAt parts 1)}:${pad (builtins.elemAt parts 0)}:00";}
    else if cron
    then {error = dowError field;}
    else {error = formError s;};
in {
  onCalendar = s: let
    parsed = parse s;
  in
    if parsed ? error
    then throw parsed.error
    else parsed.calendar;

  scheduleError = s: (parse s).error or null;
}
