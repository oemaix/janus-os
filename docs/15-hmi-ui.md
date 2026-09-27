# 15 — Panel User Interface

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-27 |

The panel is a status and maintenance surface. It does not edit
`configuration.nix`, hot overrides, or secrets. Anything it can change is
already a maintenance action in *14 — CLI*.

One interaction model serves every panel. A profile supplies a framebuffer
size and a map from physical controls to input capabilities. The renderer
picks a layout from the framebuffer. A missing control hides the actions
that needed it. It does not invent a second interface.

## 1. Size classes

The class comes from the framebuffer in pixels, not from the diagonal in
inches. A 2.4" module is 240×320 on one board and 320×240 on another.

| Class | Rule | Typical panel | What it adds |
|-------|------|---------------|--------------|
| `compact` | height ≤ 64, or width < 200 | 1.3" 128×64 SH1106 | The baseline. Every page must fit this. |
| `medium` | height 65–200 | 2.x" 240×240 or 240×135 | More rows of the same fields. A value that was truncated on `compact` is shown in full when it fits. |
| `wide` | height > 200, or width ≥ 320 | 3.x" 320×240 or 480×320 | The same pages, drawn as a list plus a detail pane. Focus is still one row. |

`compact` is the test. A page that only makes sense on `wide` is not a page.

## 2. Pages

Pages are a fixed ring. A page is omitted when its subject is absent (no
`power` peripheral, proxy disabled, no LAN). The order does not change.

| Page | Rows |
|------|------|
| Overview | Host name. Uptime. One alarm line, or `ok`. |
| WAN | One row per WAN: name, `up` or `down`, IPv4 address or `-`. |
| LAN | One row per LAN: name, lease count. |
| Tunnel | Traffic mode. One row per group: group name, selected node. |
| Battery | Voltage, current direction (`charge`, `discharge`, `idle`), shutdown armed or not. |

A row that does not fit the visible body scrolls. The focused row stays on
screen. Text that does not fit the column is cut at the end. `medium` and
`wide` use the extra columns for the cut text before they add any new field.

The tunnel page can push one screen, the node list for the focused group.
That screen is not a page in the ring. It is a list of node names. Confirm
runs `janus proxy select` for the focused node and returns to the tunnel
page. There is no other pushed screen.

## 3. Input capabilities

A profile maps each physical control onto at most one capability. The
joystick directions of the 1.3" HAT are capabilities, not free actions.

| Capability | Effect |
|------------|--------|
| `page-prev`, `page-next` | Move along the page ring. Inside a pushed screen, `page-prev` is back. |
| `item-prev`, `item-next` | Move the focus row. On Overview and Battery, which have no list, they do nothing. |
| `confirm` | On Tunnel, push the node list. On the node list, select that node. Elsewhere, nothing. |
| `back` | Leave a pushed screen. On a page, nothing. |
| `refresh` | Refresh subscriptions. |
| `reboot-hold` | Reboot only after the control has been held for 3 seconds. A shorter press does nothing. |
| `factory-reset` | Unbound unless the configuration sets it. Same 3-second hold. |

`confirm` never reboots, never refreshes, and never wipes the state
partition.

When a capability is missing, the UI changes as follows and does not add a
gesture that the profile did not declare.

| Missing | Result |
|---------|--------|
| `page-prev` and `page-next` | The first screen is the list of page names. `item-next` moves in that list. `confirm` enters the page. `back` returns to the list. |
| `item-prev` and `item-next` | Lists do not scroll. The page shows the first rows that fit. The node list is unavailable. |
| `confirm` | The node list is unavailable. Tunnel rows are status only. |
| `back`, while a screen is pushed | `page-prev` leaves the screen. |
| Only one control | Short press is `page-next`. A hold of 3 seconds is `refresh`. No other action exists. |
| Extra keys | They map to `refresh`, `reboot-hold`, or `factory-reset`, or they stay unbound. They do not create pages. |

## 4. Compact layout

128×64, 6×8 font: 21 columns and 8 rows. This is the Waveshare 1.3" HAT.

| Row | Content |
|-----|---------|
| 0 | Page name, left. A one-letter alarm at the right if one exists: `W` WAN down, `T` tunnel or refresh error, `B` battery warning. `B` wins over `T`, `T` wins over `W`. |
| 1–6 | Body. The focused row is prefixed with `>`. Other rows start with a space. |
| 7 | Blank, or `hold` while a hold action is in progress, counting down. |

No icons, no window frame, no help line. The panel sleeps after 60 seconds
with no input and wakes on the next input to the same page.

## 5. Medium and wide layouts

The page ring, the focus, and the capabilities stay as in §2 and §3.

`medium` keeps a single column. It shows more body rows and the full IPv4
address and node name when they fit in the width. Row 0 is the same alarm
rule. There is still no help line.

`wide` splits the framebuffer. The left pane is the body of the current
page, with the same `>` focus. The right pane is the focused row in full:
for a WAN, state, IPv4, IPv6, and uptime of the link; for a group, the
selected node and the strategy; for a LAN, the subnet and the lease count.
The right pane is empty on Overview. A pushed node list replaces the left
pane, and the right pane shows that node's name only. The alarm letter
stays on row 0 across both panes.

A 2.x" or 3.x" module whose framebuffer falls in `compact` uses §4. The
diagonal does not choose the layout.

## 6. The 1.3" HAT binding

This is the profile `waveshare-1.3-oled-hat`. Pins are in *10* §4.6.

| Control | Capability |
|---------|------------|
| Joystick left / right | `page-prev` / `page-next` |
| Joystick up / down | `item-prev` / `item-next` |
| Joystick press | `confirm` |
| KEY1 | `refresh` |
| KEY2 | unbound |
| KEY3 | `reboot-hold` |

Left at the top level moves to the previous page. Left inside the node
list is back, because this profile has no `back` control.

## 7. Out of scope

* Editing configuration, overrides, or secrets.
* A pointer or touch screen. A touch panel would be a new set of
  capabilities, not a resize of this one.
* A different page order per product.
* Drawing the `wide` detail pane on a `compact` framebuffer by shrinking
  the font below 6×8.
