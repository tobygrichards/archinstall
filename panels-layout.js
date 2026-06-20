// panels-layout.js — rebuilds Toby's panel layout programmatically.
// Monitor-agnostic by design: positions are expressed as alignment
// (center / right), not absolute pixels, so the layout lands correctly on
// any screen width — VM, real rig, or a different monitor count.
//
// Applied on first login by the plasma-layout autostart one-shot (see the
// dotfiles plasma package). Re-applying clears existing panels first so it
// is idempotent.

// --- remove any existing panels so re-runs don't stack duplicates ---
panels().forEach(function (p) { p.remove(); });

var H = 46;        // panel height
var LEN = 271;     // panel length (px)

// --- Panel 1: floating, bottom, centre-aligned ---------------------
// launcher + tasks + activity pager
var p1 = new Panel();
p1.location = "bottom";
p1.height = H;
p1.alignment = "center";
p1.length = LEN;
p1.floating = true;
p1.addWidget("org.kde.plasma.marginsseparator");
p1.addWidget("org.kde.plasma.activitypager");
p1.addWidget("org.kde.plasma.icontasks");
p1.addWidget("org.kde.plasma.kickoff");

// --- Panel 2: floating, bottom, right-aligned ----------------------
// status: tray + clock + show-desktop + cpu monitor
var p2 = new Panel();
p2.location = "bottom";
p2.height = H;
p2.alignment = "right";
p2.length = LEN;
p2.floating = true;
p2.addWidget("org.kde.plasma.marginsseparator");
p2.addWidget("org.kde.plasma.systemtray");
p2.addWidget("org.kde.plasma.digitalclock");
p2.addWidget("org.kde.plasma.showdesktop");
p2.addWidget("org.kde.plasma.systemmonitor.cpu");
