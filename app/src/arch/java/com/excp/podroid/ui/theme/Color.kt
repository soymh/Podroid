package com.excp.podroid.ui.theme

import androidx.compose.ui.graphics.Color

// ── ArchDroid palette ─────────────────────────────────────────────────────────
// Flavor override of the main Color.kt: identical except the accent, which
// follows the Arch crystal blue instead of Podroid green. Only compiled into
// the arch flavor (same package/classpath slot replaces main's file); the
// alpine flavor keeps green. Accent flows everywhere via Theme.kt +
// PodroidTokens (primary/secondary, both modes).
// Dark
val PodroidDarkBg        = Color(0xFF0A0A0A)
val PodroidDarkSurface   = Color(0xFF141414)
val PodroidDarkSurface2  = Color(0xFF1A1A1A)
val PodroidDarkBorder    = Color(0xFF262626)
val PodroidDarkText      = Color(0xFFEDEDED)
val PodroidDarkTextMute  = Color(0xFFA3A3A3)
val PodroidDarkTextFaint = Color(0xFF737373)

// Light
val PodroidLightBg        = Color(0xFFFAFAFA)
val PodroidLightSurface   = Color(0xFFFFFFFF)
val PodroidLightSurface2  = Color(0xFFF4F4F5)
val PodroidLightBorder    = Color(0xFFE4E4E7)
val PodroidLightText      = Color(0xFF0A0A0A)
val PodroidLightTextMute  = Color(0xFF525252)

// Accent (mode-invariant)
val PodroidAccent     = Color(0xFF1793D1)
val PodroidAccentInk  = Color(0xFF082F49)
val PodroidAmber      = Color(0xFFF59E0B)
val PodroidRed        = Color(0xFFEF4444)
